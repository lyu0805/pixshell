using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using PixShell.Logging;
using Renci.SshNet;

namespace PixShell.Sftp;

/// <summary>
/// Dropbear 原生 SCP + Shell exec 文件后端。
/// 不依赖 openssh-sftp-server，纯 Dropbear 即可用。
/// 列表用 shell ls -la，上传下载走 SSH.NET ScpClient，增删改用 shell exec。
/// </summary>
public class ScpBackend
{
    private readonly TerminalSession _session;
    private bool _connected;

    public bool Connected => _connected;
    public string WorkingDirectory => "/";

    public ScpBackend(TerminalSession session)
    {
        _session = session;
        _connected = true;
    }

    // ==================== List ====================

    public List<FsRow> ListDirectory(string path)
    {
        var entries = new List<FsRow>();
        try
        {
            var raw = _session.ExecAsync($"ls -la {EscapeArg(path)} 2>&1").GetAwaiter().GetResult();
            foreach (var line in raw.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                if (line.StartsWith("total ")) continue;
                var parts = line.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 9) continue;
                var perms = parts[0];
                var isDir = perms.StartsWith("d");
                var isLink = perms.StartsWith("l");
                var name = parts[^1];
                if (name == "." || name == "..") continue;
                // Handle "name -> target" for symlinks
                if (isLink && name.Contains(" -> "))
                {
                    var arrow = name.IndexOf(" -> ");
                    if (arrow > 0) name = name[..arrow];
                }
                long size = 0;
                long.TryParse(parts[^4], out size);
                entries.Add(new FsRow { Name = name, IsDir = isDir, IsLink = isLink, Size = size });
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"SCP list failed: {ex.Message}", "sftp");
        }
        return entries;
    }

    // ==================== Upload / Download ====================

    public void UploadFile(string localPath, string remotePath)
    {
        using var scp = _session.CreateScpClient();
        scp.Connect();
        using var fs = File.OpenRead(localPath);
        scp.Upload(fs, remotePath);
    }

    public void DownloadFile(string remotePath, string localPath)
    {
        using var scp = _session.CreateScpClient();
        scp.Connect();
        using var fs = File.Create(localPath);
        scp.Download(remotePath, fs);
    }

    // ==================== Shell operations ====================

    public void MakeDirectory(string path)
    {
        _session.ExecAsync($"mkdir -p {EscapeArg(path)}").GetAwaiter().GetResult();
    }

    public void Delete(string path, bool isDir)
    {
        var cmd = isDir ? $"rm -rf {EscapeArg(path)}" : $"rm -f {EscapeArg(path)}";
        _session.ExecAsync(cmd).GetAwaiter().GetResult();
    }

    public void Rename(string from, string to)
    {
        _session.ExecAsync($"mv {EscapeArg(from)} {EscapeArg(to)}").GetAwaiter().GetResult();
    }

    public void Close()
    {
        _connected = false;
    }

    private static string EscapeArg(string s)
        => s.Contains(' ') || s.Contains('"') ? $"\"{s.Replace("\"", "\\\"")}\"" : s;
}
