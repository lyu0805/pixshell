using System.Collections.Generic;
using System.IO;

namespace PixShell.Sftp.RemoteFs;

/// <summary>
/// 包装 ProcSftpClient（ssh exec sftp-server → 原生 SFTP v3）。
/// 无目录树，WorkingDirectory 固定为 /。
/// </summary>
internal class ProcAdapter : IRemoteFs
{
    private readonly ProcSftpClient _proc;

    public bool Connected => _proc.Connected;
    public string WorkingDirectory => "/";
    public bool SupportsTree => false;

    public ProcAdapter(ProcSftpClient proc) { _proc = proc; }

    public List<FsRow> ListDirectory(string path) => _proc.ListDirectory(path);
    public List<FsRow>? ListTreeChildren(string path) => null;
    public void DownloadFile(string remotePath, Stream localStream) => _proc.DownloadFile(remotePath, localStream);
    public void UploadFile(Stream localStream, string remotePath) => _proc.UploadFile(localStream, remotePath);
    public void MakeDirectory(string path) { /* ProcSftpClient 暂未实现 */ }
    public void Delete(string path, bool isDir) { }
    public void Rename(string from, string to) { }
    public void Close() => _proc.Close();
    public void Dispose() => _proc.Dispose();
}
