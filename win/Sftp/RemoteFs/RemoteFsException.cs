using System;

namespace PixShell.Sftp.RemoteFs;

public enum RemoteFsError
{
    Unknown,
    NotConnected,
    ChannelClosed,       // Dropbear 无 SFTP 子系统
    SshNotAvailable,     // 系统无 ssh.exe (Proc fallback)
    SftpServerMissing,   // 远端无 sftp-server (所有路径均失败)
    AuthFailed,
    Timeout,
    PermissionDenied,
    FileNotFound,
    Protocol,
}

public class RemoteFsException : Exception
{
    public RemoteFsError Code { get; }
    public string? Remediation { get; }

    public RemoteFsException(RemoteFsError code, string message, string? remediation = null)
        : base(message)
    {
        Code = code;
        Remediation = remediation;
    }
}
