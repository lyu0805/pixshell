using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using PixShell.Logging;
using PixShell;

namespace PixShell.Transports;

public sealed class OpenSshProcessTransport : ITerminalTransport
{
    private readonly string _host;
    private readonly int _port;
    private readonly string _user;
    private readonly string _keyPath;
    private uint _cols;
    private uint _rows;

    private Process? _ossProc;
    private Stream? _ossStdin;
    private Thread? _readThread;
    private volatile bool _connected;
    private int _closeReported;

    public bool Connected => _connected;

    public event Action<string>? Base64DataReceived;
    public event Action<string>? TextReceived;
    public event Action<string>? StatusChanged;
    public event Action<bool>? ConnectedChanged;

    public OpenSshProcessTransport(string host, int port, string user, string keyPath, uint cols, uint rows)
    {
        _host = host;
        _port = port;
        _user = user;
        _keyPath = keyPath;
        _cols = cols;
        _rows = rows;
    }

    public async Task ConnectAsync()
    {
        var connectHost = ResolveFast(_host);
        await Task.Run(() => ConnectViaOpenSSH(connectHost, _port, _user, _keyPath));
    }

    private void ConnectViaOpenSSH(string host, int port, string user, string keyPath)
    {
        var sshExe = TerminalSession.LocateOpenSSH();
        if (sshExe == null)
        {
            throw new InvalidOperationException(
                "FIDO2 硬件密钥需要系统 OpenSSH 客户端（C:\\Windows\\System32\\OpenSSH\\ssh.exe），当前系统未安装。\n" +
                "可在「设置 → 系统 → 可选功能 → 添加功能 → OpenSSH 客户端」安装后重试。");
        }
        
        var expandedKey = TerminalSession.ExpandKeyPath(keyPath);
        Log.Info($"FIDO2 硬件密钥会话，走系统 OpenSSH：{sshExe}", "ssh");
        var psi = new ProcessStartInfo
        {
            FileName = sshExe,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
        };
        psi.ArgumentList.Add("-tt");
        psi.ArgumentList.Add("-p"); psi.ArgumentList.Add(port.ToString());
        psi.ArgumentList.Add("-i"); psi.ArgumentList.Add(expandedKey);
        psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("IdentitiesOnly=yes");
        psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("StrictHostKeyChecking=accept-new");
        psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("ServerAliveInterval=30");
        psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("PubkeyAuthentication=yes");
        psi.ArgumentList.Add($"{user}@{host}");
        
        psi.Environment["TERM"] = "xterm-256color";
        psi.Environment["COLORTERM"] = "truecolor";
        psi.Environment["PIXSHELL_FIDO2"] = "1";
        try { psi.Environment["COLUMNS"] = _cols.ToString(); } catch { }
        try { psi.Environment["LINES"] = _rows.ToString(); } catch { }

        var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
        if (!proc.Start())
            throw new InvalidOperationException("无法启动 OpenSSH 客户端：" + sshExe);

        _ossProc = proc;
        _ossStdin = proc.StandardInput.BaseStream;
        Interlocked.Exchange(ref _closeReported, 0);
        _connected = true;

        proc.Exited += (_, _) => ReportProcessClosed();
        if (proc.HasExited) ReportProcessClosed();

        _readThread = new Thread(() => OpenSSHReadPump(proc))
        {
            IsBackground = true,
            Name = "openssh-read-pump"
        };
        _readThread.Start();
    }

    private void ReportProcessClosed()
    {
        if (Interlocked.Exchange(ref _closeReported, 1) != 0 || !_connected) return;
        _connected = false;
        Log.Info($"FIDO2 SSH 会话退出 {_user}@{_host}:{_port}", "ssh");
        StatusChanged?.Invoke("连接已关闭");
        ConnectedChanged?.Invoke(false);
    }

    private void OpenSSHReadPump(Process proc)
    {
        var stderrBuf = new byte[64 * 1024];
        var stderrLen = 0;
        var hadOutput = false;
        var outThread = new Thread(() =>
        {
            var buf = new byte[4096];
            var decoder = Encoding.UTF8.GetDecoder();
            var chars = new char[Encoding.UTF8.GetMaxCharCount(buf.Length)];
            bool activeColor = false;
            string incompleteAnsi = "";
            try
            {
                while (true)
                {
                    int n;
                    try { n = proc.StandardOutput.BaseStream.Read(buf, 0, buf.Length); }
                    catch { break; }
                    if (n <= 0) break;
                    hadOutput = true;
                    int c = decoder.GetChars(buf, 0, n, chars, 0, flush: false);
                    var text = c > 0 ? new string(chars, 0, c) : "";
                    
                    string b64;
                    if (TerminalSession.HighlightEnabled)
                    {
                        if (c == 0 && string.IsNullOrEmpty(incompleteAnsi)) continue;
                        var fullText = incompleteAnsi + text;
                        TransportHelper.ExtractIncompleteANSI(fullText, out var complete, out incompleteAnsi);
                        if (complete.Length > 0) TextReceived?.Invoke(complete);
                        if (complete.Length == 0) continue;
                        
                        b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(
                            Highlight.SemanticHighlight.Decorate(complete, ThemeManager.IsDark, ref activeColor)));
                    }
                    else
                    {
                        if (text.Length > 0) TextReceived?.Invoke(text);
                        b64 = Convert.ToBase64String(buf, 0, n);
                    }
                    Base64DataReceived?.Invoke(b64);
                }
            }
            catch { /* 进程退出 */ }
        })
        { IsBackground = true, Name = "openssh-out" };
        var errThread = new Thread(() =>
        {
            try
            {
                var sink = new byte[8192];
                while (true)
                {
                    int n;
                    try { n = proc.StandardError.BaseStream.Read(sink, 0, sink.Length); }
                    catch { break; }
                    if (n <= 0) break;
                    lock (stderrBuf)
                    {
                        var room = stderrBuf.Length - stderrLen;
                        if (room > 0) Array.Copy(sink, 0, stderrBuf, stderrLen, Math.Min(n, room));
                        stderrLen = Math.Min(stderrBuf.Length, stderrLen + n);
                    }
                }
            }
            catch { /* 进程退出 */ }
        })
        { IsBackground = true, Name = "openssh-err" };
        outThread.Start();
        errThread.Start();
        try { outThread.Join(); } catch { }
        try { errThread.Join(); } catch { }
        try
        {
            proc.WaitForExit(500);
            if (proc.HasExited) ReportProcessClosed();
        }
        catch { }

        if (!hadOutput)
        {
            string errText;
            lock (stderrBuf) { errText = Encoding.UTF8.GetString(stderrBuf, 0, stderrLen).Trim(); }
            if (errText.Length > 0)
            {
                if (errText.Contains("refused", StringComparison.OrdinalIgnoreCase)
                    || errText.Contains("timed out", StringComparison.OrdinalIgnoreCase))
                {
                    errText += "\r\n—— 连接被拒绝/超时：若目标是 Windows 主机，可能是防火墙拦截了 SSH 22 端口。" +
                               "管理员 PowerShell 执行：New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' " +
                               "-Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22";
                }
                var lines = errText.Replace("\r\n", "\n").Split('\n');
                for (int i = 0; i < lines.Length; i++)
                    lines[i] = "\x1b[38;5;196m" + lines[i] + "\x1b[0m";
                errText = string.Join("\r\n", lines);
                Base64DataReceived?.Invoke(Convert.ToBase64String(Encoding.UTF8.GetBytes(errText)));
                Log.Error($"FIDO2/OpenSSH 连接失败：{Encoding.UTF8.GetString(stderrBuf, 0, stderrLen).Trim().Replace("\n", " | ")}", "ssh");
            }
        }
    }

    public void Write(byte[] bytes)
    {
        var stdin = _ossStdin;
        if (stdin == null) return;
        stdin.Write(bytes, 0, bytes.Length);
        stdin.Flush();
    }

    public void Resize(uint cols, uint rows)
    {
        _cols = cols;
        _rows = rows;
    }

    public void Disconnect()
    {
        _connected = false;
        try
        {
            if (_ossProc is { HasExited: false })
            {
                try { _ossProc.Kill(entireProcessTree: true); } catch { try { _ossProc.Kill(); } catch { } }
            }
        }
        catch { }
        try { _ossStdin?.Dispose(); } catch { }
        try { _ossProc?.Dispose(); } catch { }
        _ossStdin = null;
        _ossProc = null;
        try { _readThread?.Join(2000); } catch { }
        _readThread = null;
    }

    public async Task<string> ExecAsync(string command)
    {
        var sshExe = TerminalSession.LocateOpenSSH();
        if (sshExe == null) return "执行失败: 未找到系统 OpenSSH 客户端";
        return await Task.Run(() =>
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = sshExe,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    RedirectStandardInput = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8,
                };
                psi.ArgumentList.Add("-T");
                psi.ArgumentList.Add("-p"); psi.ArgumentList.Add(_port.ToString());
                psi.ArgumentList.Add("-i"); psi.ArgumentList.Add(TerminalSession.ExpandKeyPath(_keyPath));
                psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("IdentitiesOnly=yes");
                psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("StrictHostKeyChecking=accept-new");
                psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("ServerAliveInterval=30");
                psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("PreferredAuthentications=publickey");
                psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("NumberOfPasswordPrompts=0");
                psi.ArgumentList.Add($"{_user}@{_host}");
                psi.ArgumentList.Add(command);
                using var p = Process.Start(psi);
                if (p == null) return "";
                var stdout = p.StandardOutput.ReadToEnd();
                var stderr = p.StandardError.ReadToEnd();
                p.WaitForExit(20_000);
                return string.IsNullOrEmpty(stdout) ? stderr : stdout;
            }
            catch (Exception ex)
            {
                return "执行失败: " + ex.Message;
            }
        });
    }

    public void Dispose()
    {
        Disconnect();
    }

    private static string ResolveFast(string host)
    {
        if (string.IsNullOrWhiteSpace(host)) return host;
        if (System.Net.IPAddress.TryParse(host, out _)) return host;
        try
        {
            var task = System.Net.Dns.GetHostAddressesAsync(host);
            if (task.Wait(TimeSpan.FromMilliseconds(500)))
            {
                var addrs = task.Result;
                var v4 = addrs.FirstOrDefault(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork);
                if (v4 != null)
                {
                    Log.Info($"DNS 快解析 {host} → {v4}", "ssh");
                    return v4.ToString();
                }
                var any = addrs.FirstOrDefault();
                if (any != null)
                {
                    Log.Info($"DNS 快解析 {host} → {any}", "ssh");
                    return any.ToString();
                }
            }
            else
            {
                Log.Warn($"DNS 快解析超时 (500ms) {host}，降级原样直连", "ssh");
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"DNS 快解析失败 {host}: {ex.Message}，回退原主机名", "ssh");
        }
        return host;
    }
}
