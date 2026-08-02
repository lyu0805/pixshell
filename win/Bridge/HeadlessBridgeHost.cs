using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using PixShell.Logging;
using PixShell.Proxy;
using Renci.SshNet;

namespace PixShell.Bridge;

/// <summary>
/// 无头模式（--headless）的桥宿主：**自己建 SSH/SFTP 会话**，不依赖任何 UI/WebView2。
///
/// 与有头版（MainWindow 实现 IBridgeHost）的区别：有头复用已打开 Tab 的 TerminalSession
/// （其 Connect/ReadPump 都耦合 WebView2 Dispatcher）；无头进程没有窗口，这里直接用
/// SSH.NET 的 SshClient/ShellStream/SftpClient（纯库，无 UI 依赖），每条会话自管一个输出缓冲，
/// 供 exec / screen 读。凭据路径与有头一致：HostStore + CredentialStore（DPAPI）。
///
/// 会话生命周期随本进程：CLI 通过 /v1/app/connect 建会话 → exec/screen/sftp 操作 →
/// 进程退出（有头接管发 /v1/app/shutdown 或自然退出）时 close 全部。
/// </summary>
public sealed class HeadlessBridgeHost : IBridgeHost
{
    /// <summary>无头会话：SshClient + ShellStream + 自管输出缓冲。</summary>
    private sealed class HeadlessSession
    {
        public string Title = "";
        public HostEntry Host = null!;
        public SshClient Ssh = null!;
        public ShellStream? Shell;
        public string Password = "";
        public bool Connected;

        /// <summary>交互 shell 的最近输出（exec 是独立通道不进这里；screen 读它）。</summary>
        public StringBuilder Output = new();
        public readonly object OutputLock = new();
        private const int OutputCap = 512 * 1024;   // 只保留最近 512 KiB

        public void AppendOutput(string text)
        {
            if (text.Length == 0) return;
            lock (OutputLock)
            {
                Output.Append(text);
                if (Output.Length > OutputCap)
                    Output.Remove(0, Output.Length - OutputCap);
            }
        }

        public string RecentOutput(int lines)
        {
            lock (OutputLock)
            {
                var n = lines > 0 ? lines : 200;
                var text = Output.ToString();
                var rows = text.Split('\n');
                return rows.Length <= n ? text : string.Join("\n", rows.Skip(rows.Length - n));
            }
        }

        public void Close()
        {
            try { Shell?.Dispose(); } catch { }
            try { Ssh?.Dispose(); } catch { }
            Connected = false;
        }
    }

    private readonly List<HeadlessSession> _sessions = new();
    private readonly object _lock = new();

    /// <summary>无头进程退出回调：全部会话 close 后调用（App 退出）。由 App 入口设置。</summary>
    public Action? OnShutdown;

    /// <summary>主线程互斥：桥请求在主线程路由，会话操作也在主线程完成；仅输出缓冲跨线程（读线程写）。
    /// 这里统一锁 _lock 保护 sessions 列表的增删改查。</summary>
    private T WithLock<T>(Func<T> body) { lock (_lock) return body(); }

    // =====================================================================
    // IBridgeHost
    // =====================================================================

    public List<Dictionary<string, object?>> BridgeHosts()
    {
        // 绝不含密码/私钥内容——只挑元数据字段，对齐 MainWindow.BridgeHosts()。
        return HostStore.Load().Select(h => new Dictionary<string, object?>
        {
            ["id"] = h.Id,
            ["name"] = h.Display,
            ["host"] = h.Host,
            ["port"] = h.Port,
            ["username"] = h.Username,
            ["group"] = h.Group,
        }).ToList();
    }

    public List<Dictionary<string, object?>> BridgeSessions()
    {
        lock (_lock)
        {
            return _sessions.Select((s, i) => new Dictionary<string, object?>
            {
                ["session"] = i,
                ["title"] = s.Title,
                ["host"] = s.Host.Host,
                ["username"] = s.Host.Username,
                ["connected"] = s.Connected,
                ["active"] = i == _sessions.Count - 1,
            }).ToList();
        }
    }

    public async Task<Dictionary<string, object?>> BridgeConnectAsync(string hostId)
    {
        // 无头进程没有 UI，但桥路由跑在 WPF Dispatcher 上（AgentBridge.cs 派发）。
        // SSH 建连可能阻塞数秒，绝不能在 Dispatcher 上做——否则 shutdown 请求排队等不到，
        // 有头接管会卡住。这里把建连整体甩到线程池，Dispatcher 保持响应。
        return await Task.Run(() => ConnectOnPool(hostId)).ConfigureAwait(false);
    }

    /// <summary>线程池上的真实建连（对齐 MainWindow.Connect 的 SSH.NET 路径，去掉 WebView2）。</summary>
    private Dictionary<string, object?> ConnectOnPool(string hostId)
    {
        var h = HostStore.Load().FirstOrDefault(x => x.Id == hostId);
        if (h == null) throw new Exception($"未找到主机 {hostId}");

        // 复用：同主机已有活跃会话 → 直接返回，不重复建连/不重认证（持久化交互关键）。
        lock (_lock)
        {
            var existing = _sessions.FindIndex(x => x.Host.Id == hostId && x.Connected);
            if (existing >= 0)
                return new Dictionary<string, object?> { ["session"] = existing, ["title"] = _sessions[existing].Title, ["ok"] = true };
        }

        // 只用已保存的密码/私钥；桥不弹密码框（无人值守场景不该阻塞）。
        var pw = CredentialStore.GetPassword(h.Id) ?? "";
        if (string.IsNullOrEmpty(pw) && string.IsNullOrEmpty(h.KeyPath))
            throw new Exception("该主机没有保存的密码或私钥，请先在有头界面连接一次");
        if (h.IsRdp || h.IsLocal)
            throw new Exception("RDP/本机终端不能经 Web 桥连接");

        // Web 主机（type 400）底层仍走 SSH PTY；剥掉 Web 标记（对齐 MainWindow.BridgeConnectAsync）。
        if (h.IsWebSsh)
        {
            h = new HostEntry
            {
                Id = h.Id, Name = h.Name, Host = h.Host, Port = h.Port,
                Username = h.Username, Group = h.Group, OsId = h.OsId,
                KeyPath = h.KeyPath, ProxyId = h.ProxyId, ConnectionType = 100,
            };
        }

        // 代理：主机配置 proxyId → ProxyStore 匹配（对齐 MainWindow 的 OpenSessionTab 路径）。
        var proxy = ProxyStore.Find(h.ProxyId);
        // FIDO2 硬件密钥（sk-*）：SSH.NET 无 sk-* 算法支持，无头模式直接报错提示换凭据。
        var expandedKey = string.IsNullOrEmpty(h.KeyPath) ? null : TerminalSession.ExpandKeyPath(h.KeyPath);
        if (expandedKey != null && TerminalSession.IsFIDO2Key(expandedKey))
            throw new Exception("FIDO2 硬件密钥会话暂不支持无头模式（SSH.NET 无 sk-* 算法）。请改用密码或普通密钥登录。");

        // 域名快解析（避免 SSH.NET 内部反向/多栈解析导致局域网停顿）。
        var connectHost = ResolveFast(h.Host);
        var info = TerminalSession.BuildConnectionInfo(connectHost, h.Port, h.Username, pw, h.KeyPath, proxy);
        info.Timeout = TimeSpan.FromSeconds(20);

        var ssh = new SshClient(info)
        {
            KeepAliveInterval = TimeSpan.FromSeconds(30),
        };
        var sess = new HeadlessSession
        {
            Title = h.Display,
            Host = h,
            Ssh = ssh,
            Password = pw,
        };

        int idx;
        lock (_lock)
        {
            _sessions.Add(sess);
            idx = _sessions.Count - 1;
        }

        try
        {
            ssh.Connect();
            var shell = ssh.CreateShellStream("xterm-256color", 100, 30, 0, 0, 4096);
            sess.Shell = shell;
            sess.Connected = true;

            // 后台读线程：ShellStream.Read 阻塞直到有数据；返回 0 表示通道关闭。
            var readThread = new Thread(() => ReadPump(sess))
            {
                IsBackground = true,
                Name = "headless-ssh-read",
            };
            readThread.Start();
        }
        catch (Exception ex)
        {
            sess.Close();
            lock (_lock) _sessions.Remove(sess);
            Log.Warn($"无头连接失败 {h.Username}@{h.Host}:{h.Port}: {ex.Message}", "bridge");
            throw new Exception("连接失败: " + ex.Message);
        }

        return new Dictionary<string, object?> { ["session"] = idx, ["title"] = sess.Title };
    }

    /// <summary>后台读线程主体（对齐 TerminalSession.ReadPump，去掉 WebView2/SendToTerm，只进缓冲）。</summary>
    private static void ReadPump(HeadlessSession sess)
    {
        var shell = sess.Shell;
        if (shell == null) return;
        var buf = new byte[4096];
        var decoder = Encoding.UTF8.GetDecoder();
        var chars = new char[Encoding.UTF8.GetMaxCharCount(buf.Length)];
        try
        {
            while (true)
            {
                int n = shell.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                int c = decoder.GetChars(buf, 0, n, chars, 0, flush: false);
                if (c > 0) sess.AppendOutput(new string(chars, 0, c));
            }
        }
        catch
        {
            // 断开时 Read 会抛异常，属正常收尾。
        }
        finally
        {
            sess.Connected = false;
        }
    }

    public bool BridgeWrite(int session, string text)
    {
        return WithLock(() =>
        {
            if (!Valid(session, out var s)) return false;
            try { s.Shell.Write(text); return true; }
            catch { return false; }
        });
    }

    public Task<string> BridgeExecAsync(int session, string cmd)
    {
        var s = WithLock(() => Valid(session, out var v) ? v : null);
        if (s == null) return Task.FromResult("");
        if (s.Ssh is not { IsConnected: true }) return Task.FromResult("");
        return Task.Run(() =>
        {
            try
            {
                using var c = s.Ssh.CreateCommand(cmd);
                c.CommandTimeout = TimeSpan.FromSeconds(20);
                var result = c.Execute();
                return string.IsNullOrEmpty(result) ? (c.Error ?? "") : result;
            }
            catch (Exception ex)
            {
                return "执行失败: " + ex.Message;
            }
        });
    }

    public string BridgeScreen(int session, int lines)
    {
        return WithLock(() =>
        {
            if (!Valid(session, out var s)) return "";
            return s.RecentOutput(lines);
        });
    }

    public Task<List<Dictionary<string, object?>>> BridgeSftpListAsync(int session, string path)
    {
        return Task.Run(() =>
        {
            using var sftp = OpenSftp(session);
            return sftp.ListDirectory(path)
                .Where(f => f.Name != "." && f.Name != "..")
                .Select(f => new Dictionary<string, object?>
                {
                    ["name"] = f.Name,
                    ["isDir"] = f.IsDirectory,
                    ["size"] = f.Length,
                    ["mtime"] = f.LastWriteTime.ToUniversalTime().ToString("o"),
                })
                .ToList();
        });
    }

    public Task<string?> BridgeSftpDownloadAsync(int session, string remote, string local)
    {
        return Task.Run<string?>(() =>
        {
            try
            {
                using var sftp = OpenSftp(session);
                var dir = Path.GetDirectoryName(local);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                using var fs = File.Create(local);
                sftp.DownloadFile(remote, fs);
                return local;
            }
            catch (Exception ex)
            {
                Log.Warn($"无头 SFTP 下载失败 {remote}: {ex.Message}", "bridge");
                return null;
            }
        });
    }

    public Task<string?> BridgeSftpUploadAsync(int session, string local, string remote)
    {
        return Task.Run<string?>(() =>
        {
            try
            {
                using var sftp = OpenSftp(session);
                using var fs = File.OpenRead(local);
                sftp.UploadFile(fs, remote, true);
                return remote;
            }
            catch (Exception ex)
            {
                Log.Warn($"无头 SFTP 上传失败 {local} → {remote}: {ex.Message}", "bridge");
                return null;
            }
        });
    }

    /// <summary>有头接管：`POST /v1/app/shutdown` 到达时关闭全部会话并退出让位。</summary>
    public void BridgeShutdown()
    {
        CloseAll();
    }

    // =====================================================================
    // 内部
    // =====================================================================

    private bool Valid(int session, out HeadlessSession s)
    {
        if (session >= 0 && session < _sessions.Count)
        {
            s = _sessions[session];
            return true;
        }
        s = null!;
        return false;
    }

    /// <summary>与终端同主机+凭据新建独立 SftpClient（对齐 MainWindow 走 CreateSftpClient，
    /// 但无头不能调 TerminalSession.CreateSftpClient()——它检查 _connected/_isLocal/_isOpenSSH）。
    /// 调用方负责 Dispose。</summary>
    private SftpClient OpenSftp(int session)
    {
        var s = WithLock(() => Valid(session, out var v) ? v : null);
        if (s == null) throw new Exception("会话不存在");
        var proxy = ProxyStore.Find(s.Host.ProxyId);
        var info = TerminalSession.BuildConnectionInfo(ResolveFast(s.Host.Host), s.Host.Port,
            s.Host.Username, s.Password, s.Host.KeyPath, proxy);
        info.Timeout = TimeSpan.FromSeconds(30);
        var sftp = new SftpClient(info) { OperationTimeout = TimeSpan.FromSeconds(30) };
        sftp.Connect();
        return sftp;
    }

    /// <summary>关闭全部会话并触发退出回调（有头接管 / 无头自然退出用）。</summary>
    public void CloseAll()
    {
        List<HeadlessSession> all;
        lock (_lock)
        {
            all = _sessions.ToList();
            _sessions.Clear();
        }
        foreach (var s in all) s.Close();
        OnShutdown?.Invoke();
    }

    /// <summary>快路径解析：字面量 IP 直接返回；主机名用 DNS 解析，优先 IPv4，失败原样返回。
    /// 复制自 TerminalSession.ResolveFast（其为 private，这里独立保留一份避免动内部实现）。</summary>
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
