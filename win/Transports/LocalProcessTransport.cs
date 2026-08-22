using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using PixShell.Logging;
using PixShell;

namespace PixShell.Transports;

public sealed class LocalProcessTransport : ITerminalTransport
{
    private uint _cols;
    private uint _rows;

    private Process? _localProc;
    private Stream? _localStdin;
    private Thread? _readThread;
    private volatile bool _connected;

    public bool Connected => _connected;

    public event Action<string>? Base64DataReceived;
    public event Action<string>? TextReceived;
    public event Action<string>? StatusChanged;
    public event Action<bool>? ConnectedChanged;

    public LocalProcessTransport(uint cols, uint rows)
    {
        _cols = cols;
        _rows = rows;
    }

    public async Task ConnectAsync()
    {
        await Task.Run(StartLocalShell);
    }

    private void StartLocalShell()
    {
        var shell = ResolveLocalShell(out var args);
        var psi = new ProcessStartInfo
        {
            FileName = shell,
            Arguments = args,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
        };
        psi.Environment["TERM"] = "xterm-256color";
        psi.Environment["COLORTERM"] = "truecolor";
        psi.Environment["PIXSHELL_LOCAL"] = "1";
        try { psi.Environment["COLUMNS"] = _cols.ToString(); } catch { }
        try { psi.Environment["LINES"] = _rows.ToString(); } catch { }

        var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
        if (!proc.Start())
            throw new InvalidOperationException("无法启动本机 shell：" + shell);

        _localProc = proc;
        _localStdin = proc.StandardInput.BaseStream;
        _connected = true;

        proc.Exited += (_, _) =>
        {
            if (_connected)
            {
                _connected = false;
                Log.Info("本机 shell 已退出", "local");
                StatusChanged?.Invoke("本机终端已关闭");
                ConnectedChanged?.Invoke(false);
            }
        };

        _readThread = new Thread(() => LocalReadPump(proc))
        {
            IsBackground = true,
            Name = "local-shell-read"
        };
        _readThread.Start();
    }

    private static string ResolveLocalShell(out string args)
    {
        var comspec = Environment.GetEnvironmentVariable("ComSpec");
        if (!string.IsNullOrWhiteSpace(comspec) && File.Exists(comspec))
        {
            args = "/K chcp 65001>nul";
            return comspec;
        }
        var sysCmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        if (File.Exists(sysCmd))
        {
            args = "/K chcp 65001>nul";
            return sysCmd;
        }
        args = "-NoLogo -NoExit";
        return "powershell.exe";
    }

    private void LocalReadPump(Process proc)
    {
        var outs = new[] { proc.StandardOutput.BaseStream, proc.StandardError.BaseStream };
        var threads = new List<Thread>();
        foreach (var stream in outs)
        {
            var s = stream;
            var th = new Thread(() =>
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
                        try { n = s.Read(buf, 0, buf.Length); }
                        catch { break; }
                        if (n <= 0) break;
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
            { IsBackground = true, Name = "local-shell-stream" };
            th.Start();
            threads.Add(th);
        }
        foreach (var t in threads)
        {
            try { t.Join(); } catch { }
        }
        try { proc.WaitForExit(500); } catch { }
    }

    public void Write(byte[] bytes)
    {
        var stdin = _localStdin;
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
            if (_localProc is { HasExited: false })
            {
                try { _localProc.Kill(entireProcessTree: true); } catch { try { _localProc.Kill(); } catch { } }
            }
        }
        catch { }
        try { _localStdin?.Dispose(); } catch { }
        try { _localProc?.Dispose(); } catch { }
        _localStdin = null;
        _localProc = null;
        try { _readThread?.Join(2000); } catch { }
        _readThread = null;
    }

    public async Task<string> ExecAsync(string command)
    {
        try
        {
            return await Task.Run(() =>
            {
                var psi = new ProcessStartInfo
                {
                    FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe",
                    Arguments = "/c " + command,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8,
                };
                using var p = Process.Start(psi);
                if (p == null) return "";
                var stdout = p.StandardOutput.ReadToEnd();
                var stderr = p.StandardError.ReadToEnd();
                p.WaitForExit(20_000);
                return string.IsNullOrEmpty(stdout) ? stderr : stdout;
            });
        }
        catch (Exception ex)
        {
            return "执行失败: " + ex.Message;
        }
    }

    public void Dispose()
    {
        Disconnect();
    }
}
