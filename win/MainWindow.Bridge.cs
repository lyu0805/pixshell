using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Controls;
using PixShell.Bridge;
using PixShell.Logging;

namespace PixShell;

/// <summary>
/// 本地 CLI/AI-Agent 桥的宿主实现（对齐 mac App/AppDelegate+Bridge.swift 的 BridgeHost 扩展）。
/// 桥本身（Bridge/AgentBridge.cs）只监听 127.0.0.1 且强制 token 鉴权；这里只负责把请求映射到
/// 会话/主机操作。所有方法都在 WPF 主线程被调用（AgentBridge 已把路由派发 Dispatcher 化）。
/// </summary>
public partial class MainWindow : IBridgeHost
{
    public List<Dictionary<string, object?>> BridgeHosts()
    {
        // 绝不含密码/私钥内容——只挑元数据字段，对齐 mac bridgeHosts()。
        return _hosts.Select(h => new Dictionary<string, object?>
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
        var list = new List<Dictionary<string, object?>>();
        foreach (var item in Sessions.Items.OfType<TabItem>())
        {
            if (item.Tag is not TerminalSession s) continue;
            list.Add(new Dictionary<string, object?>
            {
                ["session"] = s.SessionId,
                // 对外暴露用户命名（TabTitle），与标签栏一致；OSC 系统标题不进 bridge。
                ["title"] = s.TabTitle,
                ["oscTitle"] = s.Title,
                ["host"] = s.SourceHost?.Host ?? s.HostName,
                ["username"] = s.SourceHost?.Username ?? "",
                ["connected"] = s.Connected,
                ["active"] = ReferenceEquals(Sessions.SelectedItem, item) && s.Connected,
            });
        }
        return list;
    }

    public bool BridgeSessionExists(string session, out bool connected)
    {
        var result = FindBridgeSession(session);
        connected = result?.Connected == true;
        return result != null;
    }

    public async Task<Dictionary<string, object?>> BridgeConnectAsync(string hostId)
    {
        var h = _hosts.FirstOrDefault(x => x.Id == hostId);
        if (h == null) throw new Exception($"未找到主机 {hostId}");

        // 只用已保存的密码/私钥；桥不弹密码框（无人值守场景不该阻塞）。
        var pw = CredentialStore.GetPassword(h.Id) ?? "";
        if (string.IsNullOrEmpty(pw) && string.IsNullOrEmpty(h.KeyPath))
            throw new Exception("该主机没有保存的密码或私钥，请先在界面里连接一次");
        if (h.IsRdp || h.IsLocal)
            throw new Exception("RDP/本机终端不能经 Web 桥连接");

        // Web 主机（type 400）底层仍走 SSH PTY；剥掉 Web 标记，避免 SSH 标签被当成 Web 视图。
        var connectHost = h;
        if (connectHost.IsWebSsh)
        {
            connectHost = new HostEntry
            {
                Id = h.Id,
                Name = h.Name,
                Host = h.Host,
                Port = h.Port,
                Username = h.Username,
                Group = h.Group,
                OsId = h.OsId,
                KeyPath = h.KeyPath,
                ProxyId = h.ProxyId,
                ConnectionType = 100,
            };
        }

        await OpenSessionTab(connectHost, pw);
        var session = Sessions.Items.OfType<TabItem>()
            .Select(item => item.Tag as TerminalSession)
            .LastOrDefault(s => s != null && ReferenceEquals(s.SourceHost, connectHost));
        if (session == null) throw new Exception("无法创建会话");
        var sessionId = session.SessionId;

        // 等 shell 真正打开再回，最多 20s（对齐 mac bridgeConnect 的 poll()）。
        var waited = 0.0;
        while (waited <= 20.0)
        {
            if (BridgeSessionExists(sessionId, out var connected) && connected)
                return new Dictionary<string, object?> { ["session"] = sessionId, ["title"] = session.TabTitle };
            await Task.Delay(250);
            waited += 0.25;
        }
        throw new Exception("连接超时");
    }

    public bool BridgeWrite(string session, string text)
    {
        return TryGetConnectedSession(session, out var target, out var transportGeneration)
            && target.SendTextForTransportGeneration(text, transportGeneration);
    }

    public async Task<string> BridgeExecAsync(string session, string cmd)
    {
        if (!TryGetConnectedSession(session, out var target, out var transportGeneration))
            throw new BridgeSessionUnavailableException($"会话 {session} 已断开，请重新连接后再试");
        var output = await target.ExecAsync(cmd);
        if (!target.IsCurrentConnectedTransportGeneration(transportGeneration))
            throw new BridgeSessionUnavailableException($"会话 {session} 在执行期间已断开或重连");
        return output;
    }

    public string BridgeScreen(string session, int lines)
    {
        return FindBridgeSession(session)?.GetRecentOutput(lines) ?? "";
    }

    public Task<List<Dictionary<string, object?>>> BridgeSftpListAsync(string session, string path)
    {
        if (!TryGetConnectedSession(session, out var target, out var transportGeneration))
            throw new BridgeSessionUnavailableException($"会话 {session} 已断开，请重新连接后再试");
        return Task.Run(() =>
        {
            using var sftp = target.CreateSftpClient();
            var entries = sftp.ListDirectory(path)
                .Where(f => f.Name != "." && f.Name != "..")
                .Select(f => new Dictionary<string, object?>
                {
                    ["name"] = f.Name,
                    ["isDir"] = f.IsDirectory,
                    ["size"] = f.Length,
                    ["mtime"] = f.LastWriteTime.ToUniversalTime().ToString("o"),
                })
                .ToList();
            EnsureBridgeTransportCurrent(target, transportGeneration, session);
            return entries;
        });
    }

    public Task<string?> BridgeSftpDownloadAsync(string session, string remote, string local)
    {
        if (!TryGetConnectedSession(session, out var target, out var transportGeneration))
            throw new BridgeSessionUnavailableException($"会话 {session} 已断开，请重新连接后再试");
        return Task.Run<string?>(() =>
        {
            try
            {
                using var sftp = target.CreateSftpClient();
                var dir = Path.GetDirectoryName(local);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                using var fs = File.Create(local);
                sftp.DownloadFile(remote, fs);
                EnsureBridgeTransportCurrent(target, transportGeneration, session);
                return local;
            }
            catch (BridgeSessionUnavailableException) { throw; }
            catch (Exception ex)
            {
                Log.Warn($"桥 SFTP 下载失败 {remote}: {ex.Message}", "bridge");
                return null;
            }
        });
    }

    public Task<string?> BridgeSftpUploadAsync(string session, string local, string remote)
    {
        if (!TryGetConnectedSession(session, out var target, out var transportGeneration))
            throw new BridgeSessionUnavailableException($"会话 {session} 已断开，请重新连接后再试");
        return Task.Run<string?>(() =>
        {
            try
            {
                using var sftp = target.CreateSftpClient();
                using var fs = File.OpenRead(local);
                sftp.UploadFile(fs, remote, true);
                EnsureBridgeTransportCurrent(target, transportGeneration, session);
                return remote;
            }
            catch (BridgeSessionUnavailableException) { throw; }
            catch (Exception ex)
            {
                Log.Warn($"桥 SFTP 上传失败 {local} → {remote}: {ex.Message}", "bridge");
                return null;
            }
        });
    }

    private TerminalSession? FindBridgeSession(string session) =>
        Sessions.Items.OfType<TabItem>()
            .Select(item => item.Tag as TerminalSession)
            .FirstOrDefault(candidate => candidate?.SessionId == session);

    private bool TryGetConnectedSession(string session, out TerminalSession result, out long transportGeneration)
    {
        result = FindBridgeSession(session)!;
        transportGeneration = -1;
        return result != null && result.TryGetConnectedTransportGeneration(out transportGeneration);
    }

    private static void EnsureBridgeTransportCurrent(TerminalSession session, long transportGeneration, string sessionId)
    {
        if (!session.IsCurrentConnectedTransportGeneration(transportGeneration))
            throw new BridgeSessionUnavailableException($"会话 {sessionId} 在传输期间已断开或重连");
    }

    /// <summary>有头模式不会真的被 shutdown（无头才需要退出让位）；实现为空。
    /// 若未来有头需要主动让位（如双实例），再在这里关会话。对齐 mac AppDelegate+Bridge 的无头专用路径。</summary>
    public void BridgeShutdown()
    {
        // 有头是主进程，不因 shutdown 退出；仅兼容接口签名。
    }
}
