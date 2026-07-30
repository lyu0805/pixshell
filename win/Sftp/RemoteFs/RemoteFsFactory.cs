using System;
using System.Threading.Tasks;
using PixShell.Logging;
using Renci.SshNet.Common;

namespace PixShell.Sftp.RemoteFs;

/// <summary>
/// 自动探测可用协议并返回 IRemoteFs 实例。
/// 探测顺序：SftpClient → ProcSftpClient → ScpBackend。
/// </summary>
public static class RemoteFsFactory
{
    /// <summary>
    /// 连接远端并返回统一文件后端。
    /// 成功时返回 IRemoteFs 实例；全失败时抛 RemoteFsException。
    /// </summary>
    public static Task<IRemoteFs> Connect(TerminalSession session)
        => Task.Run(() => ConnectSync(session));

    private static IRemoteFs ConnectSync(TerminalSession session)
    {
        if (!session.Connected) throw new RemoteFsException(RemoteFsError.NotConnected, "SSH 会话未连接");

        // Tier 1: SSH.NET SftpClient（最快，标准 OpenSSH 环境）
        try
        {
            var sftp = session.CreateSftpClient();
            Log.Info("RemoteFs: SFTP (SSH.NET) 已连接", "sftp");
            return new SftpAdapter(sftp);
        }
        catch (SshConnectionException ex)
        {
            Log.Warn($"RemoteFs: SFTP 不可用 ({ex.Message})，回落 exec sftp-server …", "sftp");
        }
        catch (Exception ex)
        {
            Log.Warn($"RemoteFs: SFTP 连接失败 ({ex.Message})，回落 exec sftp-server …", "sftp");
        }

        // Tier 2: ProcSftpClient（ssh exec sftp-server, 需要 openssh-sftp-server）
        try
        {
            var proc = new ProcSftpClient();
            var err = proc.Connect(session.HostName, session.HostPort(), session.HostUser(), null, session.HostKeyPath());
            if (err == null)
            {
                Log.Info("RemoteFs: SFTP (ssh exec) 已连接", "sftp");
                return new ProcAdapter(proc);
            }
            proc.Dispose();
            Log.Warn($"RemoteFs: exec sftp 失败 ({err})，回落 SCP …", "sftp");
        }
        catch (Exception ex)
        {
            Log.Warn($"RemoteFs: exec sftp 异常 ({ex.Message})，回落 SCP …", "sftp");
        }

        // Tier 3: ScpBackend（SCP + shell, Dropbear 原生支持）
        var scp = new ScpBackend(session);
        Log.Info("RemoteFs: SCP (Dropbear) 已启用", "sftp");
        return new ScpAdapter(scp);
    }
}
