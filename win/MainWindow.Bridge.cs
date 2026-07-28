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
        for (var i = 0; i < Sessions.Items.Count; i++)
        {
            if (Sessions.Items[i] is not TabItem { Tag: TerminalSession s }) continue;
            list.Add(new Dictionary<string, object?>
            {
                ["session"] = i,
                // 对外暴露用户命名（TabTitle），与标签栏一致；OSC 系统标题不进 bridge。
                ["title"] = s.TabTitle,
                ["oscTitle"] = s.Title,
                ["host"] = s.SourceHost?.Host ?? s.HostName,
                ["username"] = s.SourceHost?.Username ?? "",
                ["connected"] = s.Connected,
                ["active"] = ReferenceEquals(Sessions.SelectedItem, Sessions.Items[i]),
            });
        }
        return list;
    }

    public async Task<Dictionary<string, object?>> BridgeConnectAsync(string hostId)
    {
        var h = _hosts.FirstOrDefault(x => x.Id == hostId);
        if (h == null) throw new Exception($"未找到主机 {hostId}");

        // 只用已保存的密码/私钥；桥不弹密码框（无人值守场景不该阻塞）。
        var pw = CredentialStore.GetPassword(h.Id) ?? "";
        if (string.IsNullOrEmpty(pw) && string.IsNullOrEmpty(h.KeyPath))
            throw new Exception("该主机没有保存的密码或私钥，请先在界面里连接一次");

        await OpenSessionTab(h, pw);
        var idx = Sessions.Items.Count - 1;

        // 等 shell 真正打开再回，最多 20s（对齐 mac bridgeConnect 的 poll()）。
        var waited = 0.0;
        while (waited <= 20.0)
        {
            if (idx < Sessions.Items.Count && Sessions.Items[idx] is TabItem { Tag: TerminalSession s } && s.Connected)
                return new Dictionary<string, object?> { ["session"] = idx, ["title"] = s.TabTitle };
            await Task.Delay(250);
            waited += 0.25;
        }
        throw new Exception("连接超时");
    }

    public bool BridgeWrite(int session, string text)
    {
        if (session < 0 || session >= Sessions.Items.Count) return false;
        if (Sessions.Items[session] is not TabItem { Tag: TerminalSession s } || !s.Connected) return false;
        s.SendText(text);
        return true;
    }

    public async Task<string> BridgeExecAsync(int session, string cmd)
    {
        if (session < 0 || session >= Sessions.Items.Count) return "";
        if (Sessions.Items[session] is not TabItem { Tag: TerminalSession s }) return "";
        return await s.ExecAsync(cmd);
    }

    public string BridgeScreen(int session, int lines)
    {
        if (session < 0 || session >= Sessions.Items.Count) return "";
        if (Sessions.Items[session] is not TabItem { Tag: TerminalSession s }) return "";
        return s.GetRecentOutput(lines);
    }

    public Task<List<Dictionary<string, object?>>> BridgeSftpListAsync(int session, string path)
    {
        if (!TryGetConnectedSession(session, out var s)) throw new Exception("会话不存在");
        return Task.Run(() =>
        {
            using var sftp = s.CreateSftpClient();
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
        if (!TryGetConnectedSession(session, out var s)) throw new Exception("会话不存在");
        return Task.Run<string?>(() =>
        {
            try
            {
                using var sftp = s.CreateSftpClient();
                var dir = Path.GetDirectoryName(local);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                using var fs = File.Create(local);
                sftp.DownloadFile(remote, fs);
                return local;
            }
            catch (Exception ex)
            {
                Log.Warn($"桥 SFTP 下载失败 {remote}: {ex.Message}", "bridge");
                return null;
            }
        });
    }

    public Task<string?> BridgeSftpUploadAsync(int session, string local, string remote)
    {
        if (!TryGetConnectedSession(session, out var s)) throw new Exception("会话不存在");
        return Task.Run<string?>(() =>
        {
            try
            {
                using var sftp = s.CreateSftpClient();
                using var fs = File.OpenRead(local);
                sftp.UploadFile(fs, remote, true);
                return remote;
            }
            catch (Exception ex)
            {
                Log.Warn($"桥 SFTP 上传失败 {local} → {remote}: {ex.Message}", "bridge");
                return null;
            }
        });
    }

    private bool TryGetConnectedSession(int session, out TerminalSession result)
    {
        if (session >= 0 && session < Sessions.Items.Count &&
            Sessions.Items[session] is TabItem { Tag: TerminalSession s } && s.Connected)
        {
            result = s;
            return true;
        }
        result = null!;
        return false;
    }
}
