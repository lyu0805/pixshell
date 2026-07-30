using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using PixShell;

namespace PixShell.Sftp;

/// <summary>
/// 用系统 ssh.exe exec sftp-server 作为 SFTP 后端（对齐 Mac OpenSSHSFTPSession.swift）。
/// Dropbear 不支持 SFTP 子系统，但可以 exec openssh-sftp-server 独立二进制。
/// 原理: ssh user@host /usr/libexec/sftp-server → 原生 SFTP v3 二进制帧。
/// </summary>
public class ProcSftpClient : IDisposable
{
    private Process? _proc;
    private Stream? _stdin;
    private Stream? _stdout;
    private uint _reqId;
    private readonly object _lock = new();
    private string? _serverPath;

    public bool Connected => _proc is { HasExited: false } && _stdin != null && _stdout != null;
    public string WorkingDirectory => "/";

    public string? Connect(string host, int port, string user, string? password, string? keyPath)
    {
        if (!RuntimeSupportsSsh()) return "系统未安装 OpenSSH 客户端";

        var paths = new[] {
            "/usr/libexec/sftp-server", "/usr/lib/sftp-server",
            "/usr/lib/openssh/sftp-server", "/usr/libexec/openssh/sftp-server",
        };

        string? lastErr = null;
        foreach (var p in paths)
        {
            try { if (TryConnectExec(host, port, user, keyPath, p) == null) { _serverPath = p; return null; } }
            catch (Exception ex) { lastErr = ex.Message; }
        }
        try { if (TryConnectSubsystem(host, port, user, keyPath) == null) { _serverPath = "sftp-subsystem"; return null; } }
        catch (Exception ex) { lastErr = ex.Message; }

        return lastErr ?? "所有 SFTP 路径均失败";
    }

    private static bool RuntimeSupportsSsh()
    {
        try { using var p = Process.Start(new ProcessStartInfo("ssh", "-V") { RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true }); p?.WaitForExit(5000); return p?.ExitCode <= 1; }
        catch { return false; }
    }

    private string? TryConnectExec(string host, int port, string user, string? keyPath, string remoteExe)
    {
        var psi = new ProcessStartInfo("ssh", "")
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            UseShellExecute = false, CreateNoWindow = true,
        };
        var args = new List<string> { "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10", "-p", port.ToString() };
        if (!string.IsNullOrEmpty(keyPath)) { args.Add("-i"); args.Add(keyPath); }
        args.Add($"{user}@{host}"); args.Add(remoteExe);
        psi.Arguments = string.Join(" ", args.Select(EscapeArg));

        _proc = Process.Start(psi)!;
        _stdin = _proc.StandardInput.BaseStream;
        _stdout = _proc.StandardOutput.BaseStream;

        try { Handshake(); return null; }
        catch (Exception ex) { Cleanup(); return ex.Message; }
    }

    private string? TryConnectSubsystem(string host, int port, string user, string? keyPath)
    {
        var psi = new ProcessStartInfo("ssh", "")
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            UseShellExecute = false, CreateNoWindow = true,
        };
        var args = new List<string> { "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10", "-p", port.ToString(), "-s" };
        if (!string.IsNullOrEmpty(keyPath)) { args.Add("-i"); args.Add(keyPath); }
        args.Add($"{user}@{host}"); args.Add("sftp");
        psi.Arguments = string.Join(" ", args.Select(EscapeArg));

        _proc = Process.Start(psi)!;
        _stdin = _proc.StandardInput.BaseStream;
        _stdout = _proc.StandardOutput.BaseStream;

        try { Handshake(); return null; }
        catch (Exception ex) { Cleanup(); return ex.Message; }
    }

    private void Handshake()
    {
        var init = new byte[9]; // len(4)+type(1)+ver(4)
        WriteU32BE(init, 0, 5); init[4] = 1; WriteU32BE(init, 5, 3);
        _stdin!.Write(init); _stdin.Flush();

        var hdr = ReadExact(5);
        var typ = hdr[4];
        if (typ != 2) throw new IOException($"Expect VERSION, got type={typ}");
        var remaining = (int)ReadU32BE(hdr, 0) - 1;
        if (remaining > 0) ReadExact(remaining);
    }

    // ==================== Public API ====================

    public List<FsRow> ListDirectory(string path)
    {
        if (_stdin == null || _stdout == null) return new();
        lock (_lock)
        {
            var id = ++_reqId;
            SendPacket(11, BuildPayload(id, pw => WriteSFTPString(pw, path)));
            var resp = ReadPayload();
            if (resp.Length < 9) return new();
            var handle = SliceBytes(resp, 5);

            var entries = new List<FsRow>();
            while (true)
            {
                var rid = ++_reqId;
                SendPacket(12, BuildPayload(rid, pw => WriteBytes(pw, handle)));
                var r = ReadPayload();
                if (r.Length < 5) break;
                if (r[0] == 101) { if (ReadU32BE(r, 5) == 1) break; continue; }
                if (r[0] == 104)
                {
                    var count = (int)ReadU32BE(r, 5);
                    var off = 9;
                    for (var i = 0; i < count && off + 4 <= r.Length; i++)
                    {
                        var (name, o1) = ReadSftpStr(r, off); off = o1;
                        var (_, o2) = ReadSftpStr(r, off); off = o2;
                        var (attrs, o3) = ReadAttrs(r, off); off = o3;
                        if (name != "." && name != "..")
                            entries.Add(new FsRow { Name = name, IsDir = attrs.isDir, Size = attrs.size, Perms = attrs.permissions });
                    }
                }
            }
            SendPacket(4, BuildPayload(id, pw => WriteBytes(pw, handle)));
            ReadPayload();
            return entries;
        }
    }

    public void DownloadFile(string remotePath, Stream localStream)
    {
        if (_stdin == null || _stdout == null) throw new InvalidOperationException("Not connected");
        lock (_lock)
        {
            var id = ++_reqId;
            SendPacket(3, BuildPayload(id, pw => { WriteSFTPString(pw, remotePath); pw.WriteU32BE(1); pw.WriteU32BE(0); }));
            var handle = SliceBytes(ReadPayload(), 5);
            long offset = 0;
            while (true)
            {
                var rid = ++_reqId;
                SendPacket(5, BuildPayload(rid, pw => { WriteBytes(pw, handle); pw.WriteU64BE((ulong)offset); pw.WriteU32BE(32768u); }));
                var r = ReadPayload();
                if (r.Length < 5) break;
                if (r[0] == 101 && ReadU32BE(r, 5) == 1) break;
                if (r[0] == 103) { var (data, _) = ReadSftpBytes(r, 5); if (data == null || data.Length == 0) break; localStream.Write(data, 0, data.Length); offset += data.Length; if (data.Length < 32768) break; }
            }
            SendPacket(4, BuildPayload(id, pw => WriteBytes(pw, handle)));
            ReadPayload();
        }
    }

    public void UploadFile(Stream localStream, string remotePath)
    {
        if (_stdin == null || _stdout == null) throw new InvalidOperationException("Not connected");
        lock (_lock)
        {
            var id = ++_reqId;
            SendPacket(3, BuildPayload(id, pw => { WriteSFTPString(pw, remotePath); pw.WriteU32BE(0x1A); pw.WriteU32BE(4); pw.WriteU32BE(0x1A4); }));
            var handle = SliceBytes(ReadPayload(), 5);
            var buf = new byte[32768]; long offset = 0; int n;
            while ((n = localStream.Read(buf, 0, buf.Length)) > 0)
            {
                var wid = ++_reqId;
                SendPacket(6, BuildPayload(wid, pw => { WriteBytes(pw, handle); pw.WriteU64BE((ulong)offset); pw.WriteRaw(buf, n); }));
                var s = ReadPayload();
                if (s.Length >= 9 && s[0] == 101 && ReadU32BE(s, 5) != 0) throw new IOException($"SFTP write err {ReadU32BE(s, 5)}");
                offset += n;
            }
            SendPacket(4, BuildPayload(id, pw => WriteBytes(pw, handle)));
            ReadPayload();
        }
    }

    public void Close() { Cleanup(); }
    public void Dispose() { Cleanup(); }
    private void Cleanup()
    {
        try { _stdin?.Close(); } catch { }
        try { _stdout?.Close(); } catch { }
        try { if (_proc is { HasExited: false }) _proc.Kill(); } catch { }
        try { _proc?.Dispose(); } catch { }
        _proc = null; _stdin = null; _stdout = null;
    }

    // ==================== Wire Protocol ====================

    private byte[] ReadExact(int count) { var b = new byte[count]; for (int o = 0; o < count;) { int n = _stdout!.Read(b, o, count - o); if (n <= 0) throw new EndOfStreamException(); o += n; } return b; }
    private byte[] ReadPayload() { try { var h = ReadExact(4); var len = (int)ReadU32BE(h, 0); if (len < 1 || len > 1_048_576) return Array.Empty<byte>(); return ReadExact(len); } catch { return Array.Empty<byte>(); } }
    private void SendPacket(byte type, byte[] payload) { var f = new byte[5 + payload.Length]; WriteU32BE(f, 0, (uint)(1 + payload.Length)); f[4] = type; Array.Copy(payload, 0, f, 5, payload.Length); _stdin!.Write(f); _stdin.Flush(); }
    private static byte[] SliceBytes(byte[] src, int off) { if (off + 4 > src.Length) return Array.Empty<byte>(); int len = (int)ReadU32BE(src, off); var d = new byte[len]; Array.Copy(src, off + 4, d, 0, Math.Min(len, src.Length - off - 4)); return d; }
    private static byte[] BuildPayload(uint id, Action<SftpWriter> write) { var w = new SftpWriter(); w.WriteU32(id); write(w); return w.ToArray(); }

    // === Numeric I/O ===
    private static uint ReadU32BE(byte[] b, int o) => ((uint)b[o] << 24) | ((uint)b[o + 1] << 16) | ((uint)b[o + 2] << 8) | b[o + 3];
    private static void WriteU32BE(byte[] b, int o, uint v) { b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16); b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v; }

    // === String/Bytes ===
    private static (string, int) ReadSftpStr(byte[] b, int o) { if (o + 4 > b.Length) return ("", o + 4); int len = (int)ReadU32BE(b, o); return (Encoding.UTF8.GetString(b, o + 4, Math.Min(len, b.Length - o - 4)), o + 4 + len); }
    private static (byte[]?, int) ReadSftpBytes(byte[] b, int o) { if (o + 4 > b.Length) return (null, o + 4); int len = (int)ReadU32BE(b, o); var d = new byte[len]; Array.Copy(b, o + 4, d, 0, Math.Min(len, b.Length - o - 4)); return (d, o + 4 + len); }

    // === Attrs ===
    private static (FileAttrs, int) ReadAttrs(byte[] b, int o)
    {
        if (o + 4 > b.Length) return (default, o + 4);
        var f = ReadU32BE(b, o); o += 4; var a = new FileAttrs();
        if ((f & 1) != 0) { a.size = (long)(((ulong)b[o] << 56) | ((ulong)b[o + 1] << 48) | ((ulong)b[o + 2] << 40) | ((ulong)b[o + 3] << 32) | ((ulong)b[o + 4] << 24) | ((ulong)b[o + 5] << 16) | ((ulong)b[o + 6] << 8) | b[o + 7]); o += 8; }
        if ((f & 2) != 0) o += 8;
        if ((f & 4) != 0) { a.permissions = ReadU32BE(b, o); o += 4; }
        if ((f & 8) != 0) o += 8;
        if ((f & 0x80000000) != 0) { int cnt = (int)ReadU32BE(b, o); o += 4; for (int i = 0; i < cnt; i++) { var (_, oo) = ReadSftpStr(b, o); o = oo; (_, oo) = ReadSftpStr(b, o); o = oo; } }
        return (a, o);
    }

    private struct FileAttrs { public long size; public uint permissions; public bool isDir => (permissions & 0x4000) != 0; }

    // === Writer ===
    private sealed class SftpWriter
    {
        private readonly MemoryStream _ms = new();
        public void WriteU32(uint v) { _ms.WriteByte((byte)(v >> 24)); _ms.WriteByte((byte)(v >> 16)); _ms.WriteByte((byte)(v >> 8)); _ms.WriteByte((byte)v); }
        public void WriteU32BE(uint v) { WriteU32(v); }
        public void WriteU64BE(ulong v) { WriteU32((uint)(v >> 32)); WriteU32((uint)v); }
        public void WriteStr(string s) { var b = Encoding.UTF8.GetBytes(s); WriteU32((uint)b.Length); _ms.Write(b); }
        public void WriteBytes(byte[] d) { WriteU32((uint)d.Length); _ms.Write(d); }
        public void WriteRaw(byte[] d, int n) { WriteU32((uint)n); _ms.Write(d, 0, n); }
        public byte[] ToArray() => _ms.ToArray();
    }

    private static void WriteSFTPString(SftpWriter w, string s) => w.WriteStr(s);
    private static void WriteBytes(SftpWriter w, byte[] d) => w.WriteBytes(d);

    private static string EscapeArg(string a) => a.Contains(' ') || a.Contains('"') ? $"\"{a.Replace("\"", "\\\"")}\"" : a;
}
