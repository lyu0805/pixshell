using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Renci.SshNet;
using PixShell.Logging;
using PixShell.Proxy;
using PixShell;

namespace PixShell.Transports;

public sealed class SshNetTransport : ITerminalTransport
{
    private readonly string _host;
    private readonly int _port;
    private readonly string _user;
    private readonly string _pass;
    private readonly string? _keyPath;
    private readonly ProxyConfig? _proxy;
    private uint _cols;
    private uint _rows;

    private SshClient? _ssh;
    private ShellStream? _shell;
    private Thread? _readThread;
    private object? _channel;
    private MethodInfo? _windowChange;
    private volatile bool _connected;
    private CancellationTokenSource? _execCts;

    public bool Connected => _connected;

    public event Action<string>? Base64DataReceived;
    public event Action<string>? TextReceived;
    public event Action<string>? StatusChanged;
    public event Action<bool>? ConnectedChanged;

    public SshNetTransport(string host, int port, string user, string pass, string? keyPath, ProxyConfig? proxy, uint cols, uint rows)
    {
        _host = host;
        _port = port;
        _user = user;
        _pass = pass;
        _keyPath = keyPath;
        _proxy = proxy;
        _cols = cols;
        _rows = rows;
    }

    public async Task ConnectAsync()
    {
        var connectHost = ResolveFast(_host);
        var info = TerminalSession.BuildConnectionInfo(connectHost, _port, _user, _pass, _keyPath, _proxy);

        var ssh = new SshClient(info);
        try
        {
            ssh.KeepAliveInterval = TimeSpan.FromSeconds(30);
            await Task.Run(() => ssh.Connect());

            var shell = ssh.CreateShellStream("xterm-256color", _cols, _rows, 0, 0, 4096);

            _ssh = ssh;
            _shell = shell;
            ssh = null;

            CacheChannelReflection(shell);

            _connected = true;
            _readThread = new Thread(ReadPump) { IsBackground = true, Name = "ssh-read-pump" };
            _readThread.Start();
        }
        finally
        {
            if (ssh != null)
            {
                try { ssh.Dispose(); } catch { }
            }
        }
    }

    private void ReadPump()
    {
        var shell = _shell;
        if (shell == null) return;
        var buf = new byte[4096];
        var decoder = Encoding.UTF8.GetDecoder();
        var chars = new char[Encoding.UTF8.GetMaxCharCount(buf.Length)];
        bool activeColor = false;
        string incompleteAnsi = "";
        try
        {
            while (true)
            {
                int n = shell.Read(buf, 0, buf.Length);
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
        catch
        {
            // 断开时可能抛异常，属正常收尾
        }
        finally
        {
            if (_connected)
            {
                _connected = false;
                StatusChanged?.Invoke("连接已关闭");
                ConnectedChanged?.Invoke(false);
            }
        }
    }

    public void Write(byte[] bytes)
    {
        var shell = _shell;
        if (shell == null) return;
        shell.Write(bytes, 0, bytes.Length);
        shell.Flush();
    }

    public void Resize(uint cols, uint rows)
    {
        if (cols == 0 || rows == 0) return;
        _cols = cols;
        _rows = rows;
        var ch = _channel;
        var wc = _windowChange;
        if (!_connected || wc == null || ch == null) return;
        try
        {
            wc.Invoke(ch, new object[] { cols, rows, 0u, 0u });
        }
        catch { }
    }

    public void Disconnect()
    {
        _connected = false;
        try { _execCts?.Cancel(); } catch { }
        try { _execCts?.Dispose(); } catch { }
        _execCts = null;
        try { _shell?.Dispose(); } catch { }
        try { _ssh?.Disconnect(); } catch { }
        try { _ssh?.Dispose(); } catch { }
        _shell = null;
        _ssh = null;
        _channel = null;
        _windowChange = null;
        try { _readThread?.Join(2000); } catch { }
        _readThread = null;
    }

    public async Task<string> ExecAsync(string command)
    {
        if (_ssh is not { IsConnected: true }) return "";
        _execCts?.Cancel(); _execCts?.Dispose();
        _execCts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var ct = _execCts.Token;
        try
        {
            return await Task.Run(() =>
            {
                using var cmd = _ssh.CreateCommand(command);
                cmd.CommandTimeout = TimeSpan.FromSeconds(20);
                ct.ThrowIfCancellationRequested();
                var result = cmd.Execute();
                return string.IsNullOrEmpty(result) ? (cmd.Error ?? "") : result;
            }, ct);
        }
        catch (OperationCanceledException)
        {
            return "执行取消: 会话已断开";
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

    private void CacheChannelReflection(ShellStream shell)
    {
        try
        {
            var f = typeof(ShellStream).GetField("_channel",
                BindingFlags.NonPublic | BindingFlags.Instance);
            _channel = f?.GetValue(shell);
            _windowChange = _channel?.GetType().GetMethod("SendWindowChangeRequest",
                new[] { typeof(uint), typeof(uint), typeof(uint), typeof(uint) });
        }
        catch
        {
            _channel = null;
            _windowChange = null;
        }
    }
    /// <summary>快路径解析：字面量 IP 直接返回；主机名用 DNS 解析，优先 IPv4，失败原样返回。
    /// 与 HeadlessBridgeHost 内同名私有实现保持同一语义。</summary>
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
                if (v4 != null) return v4.ToString();
                var any = addrs.FirstOrDefault();
                if (any != null) return any.ToString();
            }
        }
        catch { /* 回退原主机名 */ }
        return host;
    }
}
