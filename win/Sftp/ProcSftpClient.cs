using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace PixShell.Sftp;

/// <summary>
/// 用系统 ssh.exe exec sftp-server 作为 SFTP 后端（对齐 Mac OpenSSHSFTPSession.swift）。
/// 适用场景：Dropbear 下 SSH.NET SftpClient 因无 "sftp" 子系统而失败时自动启用。
/// 原理：ssh user@host /usr/libexec/sftp-server → 走原生 SFTP v3 协议（纯二进制帧）。
/// </summary>
public class ProcSftpClient : IDisposable
{
    private Process? _proc;
    private Stream? _stdin;
    private Stream? _stdout;
    private uint _reqId;
    private readonly object _lock = new();
    private bool _disposed;
    private string? _serverPath;   // 实际连接成功的 sftp-server 路径

    public bool Connected => _proc is { HasExited: false } && _stdin != null && _stdout != null;
    public string WorkingDirectory => "/";

    public string? Connect(string host, int port, string user, string? password, string? keyPath)
    {
        var sftpPaths = new[]
        {
            "/usr/libexec/sftp-server",
            "/usr/lib/sftp-server",
            "/usr/lib/openssh/sftp-server",
            "/usr/libexec/openssh/sftp-server",
        };

        // 构建 ssh 命令
        string? lastError = null;
        foreach (var sftpPath in sftpPaths)
        {
            try
            {
                var result = TryConnect(host, port, user, password, keyPath, sftpPath);
                if (result == null)
                {
                    _serverPath = sftpPath;
                    return null; // 成功
                }
                lastError = result;
            }
            catch (Exception ex)
            {
                lastError = ex.Message;
            }
        }

        // 最后试 subsystem "sftp"
        try
        {
            var result = TryConnectSubsystem(host, port, user, password, keyPath);
            if (result == null) { _serverPath = "subsystem:sftp"; return null; }
            lastError = result;
        }
        catch (Exception ex)
        {
            lastError = ex.Message;
        }

        return lastError ?? "no sftp backend available";
    }

    private string? TryConnect(string host, int port, string user, string? password, string? keyPath, string sftpPath)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "ssh",
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        var args = new List<string>
        {
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-p", port.ToString(),
        };

        if (!string.IsNullOrEmpty(keyPath))
        {
            args.Add("-i");
            args.Add(keyPath);
        }

        args.Add($"{user}@{host}");
        args.Add(sftpPath);

        psi.Arguments = string.Join(" ", args.Select(EscapeArg));
        psi.Environment["SSH_ASKPASS"] = "";
        psi.Environment["DISPLAY"] = "";

        _proc = Process.Start(psi);
        if (_proc == null) return "无法启动 ssh";

        _stdin = _proc.StandardInput.BaseStream;
        _stdout = _proc.StandardOutput.BaseStream;

        // SFTP v3 握手：发 INIT(3)
        try
        {
            var init = new byte[9]; // length(4) + type(1) + version(4)
            WriteU32BE(init, 0, 5); // length
            init[4] = 1;             // SSH_FXP_INIT
            WriteU32BE(init, 5, 3);  // version 3
            _stdin.Write(init, 0, init.Length);
            _stdin.Flush();

            // 读 VERSION 回应
            var header = ReadExact(5); // length(4) + type(1)
            var pktLen = ReadU32BE(header, 0);
            var typ = header[4];

            if (typ != 2) return $"期望 VERSION，收到 type={typ}";

            var remaining = (int)(pktLen - 1); // minus type byte
            var body = ReadExact(remaining);
            // VERSION 响应体: version(4) + extensions...
            if (remaining >= 4)
            {
                var serverVersion = ReadU32BE(body, 0);
                if (serverVersion < 3) return $"服务端 SFTP 版本 {serverVersion}（需要 >=3）";
            }
            return null; // 成功
        }
        catch (Exception ex)
        {
            Cleanup();
            return ex.Message;
        }
    }

    private string? TryConnectSubsystem(string host, int port, string user, string? password, string? keyPath)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "ssh",
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        var args = new List<string>
        {
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-p", port.ToString(),
            "-s",   // subsystem mode
        };

        if (!string.IsNullOrEmpty(keyPath))
        {
            args.Add("-i");
            args.Add(keyPath);
        }

        args.Add($"{user}@{host}");
        args.Add("sftp");

        psi.Arguments = string.Join(" ", args.Select(EscapeArg));
        psi.Environment["SSH_ASKPASS"] = "";
        psi.Environment["DISPLAY"] = "";

        _proc = Process.Start(psi);
        if (_proc == null) return "无法启动 ssh";

        _stdin = _proc.StandardInput.BaseStream;
        _stdout = _proc.StandardOutput.BaseStream;

        try
        {
            var init = new byte[9];
            WriteU32BE(init, 0, 5);
            init[4] = 1;
            WriteU32BE(init, 5, 3);
            _stdin.Write(init, 0, init.Length);
            _stdin.Flush();

            var header = ReadExact(5);
            var typ = header[4];
            if (typ != 2) return $"子系统 SFTP 握手失败，收到 type={typ}";
            return null;
        }
        catch (Exception ex)
        {
            Cleanup();
            return ex.Message;
        }
    }

    public List<FsRow> ListDirectory(string path)
    {
        if (_stdin == null || _stdout == null) return new List<FsRow>();

        lock (_lock)
        {
            var id = ++_reqId;
            using var ms = new MemoryStream();
            WriteU32(ms, id);
            WriteSFTPString(ms, path);
            SendPacket(11, ms.ToArray()); // SSH_FXP_OPENDIR

            var resp = ReadResponseRaw();
            if (resp.Length < 10) return new List<FsRow>(); // type(1)+id(4)+handle_len(4)+handle(>=1)
            var handle = ExtractBytes(resp, 5); // type(1)+id(4)=5

            var entries = new List<FsRow>();
            while (true)
            {
                var rid = ++_reqId;
                var dirMs = new MemoryStream();
                WriteU32(dirMs, rid);
                WriteBytes(dirMs, handle);
                SendPacket(12, dirMs.ToArray());

                var r = ReadResponseRaw();
                if (r.Length < 5) break; // type(1)+id(4)

                var rtyp = r[0];
                if (rtyp == 101) // SSH_FXP_STATUS
                {
                    var stCode = ReadU32BE(r, 5); // type(1)+id(4)=5
                    if (stCode == 1) break; // SSH_FX_EOF
                    continue;
                }

                if (rtyp == 104) // SSH_FXP_NAME
                {
                    var count = (int)ReadU32BE(r, 5); // type(1)+id(4)=5
                    var offset = 9; // type(1)+id(4)+count(4)=9
                    for (var i = 0; i < count && offset + 4 <= r.Length; i++)
                    {
                        var (filename, next1) = ReadSFTPString(r, offset);
                        offset = next1;
                        var (_, next2) = ReadSFTPString(r, offset); // longname
                        offset = next2;
                        var (attrs, next3) = ReadAttrs(r, offset);
                        offset = next3;

                        if (filename != "." && filename != "..")
                        {
                            entries.Add(new FsRow
                            {
                                Name = filename,
                                IsDir = attrs.isDir,
                                Size = attrs.size,
                                Perms = attrs.permissions,
                            });
                        }
                    }
                }
            }

            // CLOSE handle
            var cMs = new MemoryStream();
            WriteU32(cMs, id);
            WriteBytes(cMs, handle);
            SendPacket(4, cMs.ToArray());
            ReadResponseRaw(); // discard

            return entries;
        }
    }

    public void DownloadFile(string remotePath, Stream localStream)
    {
        if (_stdin == null || _stdout == null) throw new InvalidOperationException("未连接");
        lock (_lock)
        {
            var id = ++_reqId;
            var oMs = new MemoryStream();
            WriteU32(oMs, id);
            WriteSFTPString(oMs, remotePath);
            WriteU32BE(oMs, 4, 1); // SSH_FXF_READ
            WriteU32BE(oMs, 8, 0); // empty attrs
            SendPacket(3, oMs.ToArray()); // SSH_FXP_OPEN

            var openResp = ReadResponseRaw();
            var handle = ExtractBytes(openResp, 5); // type(1)+id(4)=5

            long offset = 0;
            while (true)
            {
                var rid = ++_reqId;
                var rMs = new MemoryStream();
                WriteU32(rMs, rid);
                WriteBytes(rMs, handle);
                WriteU64BE(rMs, (ulong)offset);
                WriteU32BE(rMs, 0, 32768u);
                SendPacket(5, rMs.ToArray()); // SSH_FXP_READ

                var r = ReadResponseRaw();
                if (r.Length < 5) break;

                var rtyp = r[0];
                if (rtyp == 101 && ReadU32BE(r, 5) == 1) break; // STATUS EOF
                if (rtyp == 103) // SSH_FXP_DATA
                {
                    var (data, _) = ReadSFTPBytes(r, 5); // type(1)+id(4)=5
                    if (data != null && data.Length > 0)
                    {
                        localStream.Write(data, 0, data.Length);
                        offset += data.Length;
                    }
                    if (data == null || data.Length < 32768) break;
                }
            }

            // CLOSE
            var cMs = new MemoryStream();
            WriteU32(cMs, id);
            WriteBytes(cMs, handle);
            SendPacket(4, cMs.ToArray());
            ReadResponseRaw();
        }
    }

    public void UploadFile(Stream localStream, string remotePath)
    {
        if (_stdin == null || _stdout == null) throw new InvalidOperationException("未连接");
        lock (_lock)
        {
            var id = ++_reqId;
            var oMs = new MemoryStream();
            WriteU32(oMs, id);
            WriteSFTPString(oMs, remotePath);
            // FXF_WRITE | FXF_CREAT | FXF_TRUNC = 0x1A
            var attrOff = 4; // id(4)
            WriteU32BE(oMs, attrOff, 0x1A);
            // attrs: flags(4) + permissions(4)
            WriteU32BE(oMs, attrOff + 4, 4); // ATTR_PERMISSIONS
            WriteU32BE(oMs, attrOff + 8, 0x1A4); // 0644
            SendPacket(3, oMs.ToArray()); // SSH_FXP_OPEN

            var openResp = ReadResponseRaw();
            var handle = ExtractBytes(openResp, 5); // type(1)+id(4)=5

            var buf = new byte[32768];
            long offset = 0;
            int n;
            while ((n = localStream.Read(buf, 0, buf.Length)) > 0)
            {
                var wid = ++_reqId;
                var wMs = new MemoryStream();
                WriteU32(wMs, wid);
                WriteBytes(wMs, handle);
                WriteU64BE(wMs, (ulong)offset);
                WriteRawBytes(wMs, buf, 0, n);
                SendPacket(6, wMs.ToArray()); // SSH_FXP_WRITE

                var status = ReadResponseRaw();
                if (status.Length >= 9 && status[0] == 101 && ReadU32BE(status, 5) != 0)
                    throw new IOException($"SFTP WRITE status: {ReadU32BE(status, 5)}");
                offset += n;
            }

            // CLOSE
            var cMs = new MemoryStream();
            WriteU32(cMs, id);
            WriteBytes(cMs, handle);
            SendPacket(4, cMs.ToArray());
            ReadResponseRaw();
        }
    }

    public void Close()
    {
        Cleanup();
    }

    public void Dispose()
    {
        Cleanup();
    }

    private void Cleanup()
    {
        try { _stdin?.Close(); } catch { }
        try { _stdout?.Close(); } catch { }
        try { if (_proc is { HasExited: false }) _proc.Kill(); } catch { }
        try { _proc?.Dispose(); } catch { }
        _proc = null;
        _stdin = null;
        _stdout = null;
    }

    // ==================== SFTP Wire Protocol Helpers ====================

    private byte[] ReadExact(int count)
    {
        var buf = new byte[count];
        var offset = 0;
        while (offset < count)
        {
            var n = _stdout!.Read(buf, offset, count - offset);
            if (n <= 0) throw new EndOfStreamException("ssh pipe closed");
            offset += n;
        }
        return buf;
    }

    private byte[] ReadResponseRaw()
    {
        try
        {
            var header = ReadExact(4);
            var pktLen = (int)ReadU32BE(header, 0);
            if (pktLen < 1 || pktLen > 1024 * 1024) return Array.Empty<byte>();
            return ReadExact(pktLen);
        }
        catch
        {
            return Array.Empty<byte>();
        }
    }

    private void SendPacket(byte type, byte[] payload)
    {
        var frame = new byte[5 + payload.Length];
        WriteU32BE(frame, 0, (uint)(1 + payload.Length));
        frame[4] = type;
        Array.Copy(payload, 0, frame, 5, payload.Length);
        _stdin!.Write(frame, 0, frame.Length);
        _stdin.Flush();
    }

    private byte[] ExtractBytes(byte[] buf, int offset)
    {
        if (offset + 4 > buf.Length) return Array.Empty<byte>();
        var len = (int)ReadU32BE(buf, offset);
        var data = new byte[len];
        Array.Copy(buf, offset + 4, data, 0, Math.Min(len, buf.Length - offset - 4));
        return data;
    }

    private void WriteIdAndPath(MemoryStream ms, uint id, string path)
    {
        WriteU32(ms, id);
        WriteSFTPString(ms, path);
    }

    private static uint ReadU32BE(byte[] b, int offset)
    {
        return ((uint)b[offset] << 24) | ((uint)b[offset + 1] << 16) | ((uint)b[offset + 2] << 8) | b[offset + 3];
    }

    private static byte ReadU8BE(byte[] b, int offset) => b[offset];

    private static void WriteU32BE(byte[] b, int offset, uint v)
    {
        b[offset] = (byte)(v >> 24);
        b[offset + 1] = (byte)(v >> 16);
        b[offset + 2] = (byte)(v >> 8);
        b[offset + 3] = (byte)v;
    }

    private static void WriteU64BE(byte[] b, int offset, ulong v)
    {
        b[offset] = (byte)(v >> 56);
        b[offset + 1] = (byte)(v >> 48);
        b[offset + 2] = (byte)(v >> 40);
        b[offset + 3] = (byte)(v >> 32);
        b[offset + 4] = (byte)(v >> 24);
        b[offset + 5] = (byte)(v >> 16);
        b[offset + 6] = (byte)(v >> 8);
        b[offset + 7] = (byte)v;
    }

    private static void WriteU32BE(MemoryStream ms, int offset, uint v)
    {
        var b = ms.GetBuffer();
        b[offset] = (byte)(v >> 24);
        b[offset + 1] = (byte)(v >> 16);
        b[offset + 2] = (byte)(v >> 8);
        b[offset + 3] = (byte)v;
    }

    private static void WriteU64BE(MemoryStream ms, ulong v)
    {
        ms.WriteByte((byte)(v >> 56));
        ms.WriteByte((byte)(v >> 48));
        ms.WriteByte((byte)(v >> 40));
        ms.WriteByte((byte)(v >> 32));
        ms.WriteByte((byte)(v >> 24));
        ms.WriteByte((byte)(v >> 16));
        ms.WriteByte((byte)(v >> 8));
        ms.WriteByte((byte)(byte)v);
    }

    private static void WriteU32(MemoryStream ms, uint v)
    {
        ms.WriteByte((byte)(v >> 24));
        ms.WriteByte((byte)(v >> 16));
        ms.WriteByte((byte)(v >> 8));
        ms.WriteByte((byte)v);
    }

    private void WriteSFTPString(MemoryStream ms, string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        WriteU32(ms, (uint)bytes.Length);
        ms.Write(bytes, 0, bytes.Length);
    }

    private void WriteBytes(MemoryStream ms, byte[] data)
    {
        WriteU32(ms, (uint)data.Length);
        ms.Write(data, 0, data.Length);
    }

    private void WriteRawBytes(MemoryStream ms, byte[] data, int offset, int count)
    {
        WriteU32(ms, (uint)count);
        ms.Write(data, offset, count);
    }

    private static (string, int) ReadSFTPString(byte[] buf, int offset)
    {
        if (offset + 4 > buf.Length) return ("", offset + 4);
        var len = (int)ReadU32BE(buf, offset);
        var s = Encoding.UTF8.GetString(buf, offset + 4, Math.Min(len, buf.Length - offset - 4));
        return (s, offset + 4 + len);
    }

    private static (byte[]?, int) ReadSFTPBytes(byte[] buf, int offset)
    {
        if (offset + 4 > buf.Length) return (null, offset + 4);
        var len = (int)ReadU32BE(buf, offset);
        var data = new byte[len];
        Array.Copy(buf, offset + 4, data, 0, Math.Min(len, buf.Length - offset - 4));
        return (data, offset + 4 + len);
    }

    private static (FileAttrs, int) ReadAttrs(byte[] buf, int offset)
    {
        if (offset + 4 > buf.Length) return (default, offset + 4);
        var flags = ReadU32BE(buf, offset);
        offset += 4;
        var a = new FileAttrs();

        if ((flags & 1) != 0) { a.size = (long)ReadU64BE(buf, offset); offset += 8; }
        if ((flags & 2) != 0) { offset += 8; } // skip uid/gid
        if ((flags & 4) != 0) { a.permissions = ReadU32BE(buf, offset); offset += 4; }
        if ((flags & 8) != 0) { /* atime */ offset += 4; /* mtime */ offset += 4; }
        if ((flags & 0x80000000) != 0)
        {
            var count = (int)ReadU32BE(buf, offset);
            offset += 4;
            for (var i = 0; i < count; i++)
            {
                var (_, o1) = ReadSFTPString(buf, offset);
                offset = o1;
                var (_, o2) = ReadSFTPString(buf, offset);
                offset = o2;
            }
        }

        return (a, offset);
    }

    private static string EscapeArg(string arg)
    {
        if (string.IsNullOrEmpty(arg)) return "\"\"";
        if (!arg.Any(c => char.IsWhiteSpace(c) || c == '"'))
            return arg;
        return "\"" + arg.Replace("\"", "\\\"") + "\"";
    }

    private struct FileAttrs
    {
        public long size;
        public uint permissions;
        public bool isDir => (permissions & 0x4000) != 0;
    }

    public sealed class ProcEntry
    {
        public string Name { get; set; } = "";
        public bool IsDir { get; set; }
        public long Size { get; set; }
        public uint Perms { get; set; }
    }
}
