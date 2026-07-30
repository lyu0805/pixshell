using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;

namespace PixShell.Sftp.RemoteFs;

/// <summary>
/// 包装 ScpBackend（SCP 协议 + shell ls）。
/// Dropbear 原生支持，无 openssh-sftp-server 依赖。
/// </summary>
internal class ScpAdapter : IRemoteFs
{
    private readonly ScpBackend _scp;

    public bool Connected => _scp.Connected;
    public string WorkingDirectory => "/";
    public bool SupportsTree => false;

    public ScpAdapter(ScpBackend scp) { _scp = scp; }

    public List<FsRow> ListDirectory(string path) => _scp.ListDirectory(path);
    public List<FsRow>? ListTreeChildren(string path) => null;

    public void DownloadFile(string remotePath, Stream localStream)
    {
        // ScpBackend 下载到临时文件再复制到流
        var tmp = Path.GetTempFileName();
        try { _scp.DownloadFile(remotePath, tmp); using var fs = File.OpenRead(tmp); fs.CopyTo(localStream); }
        finally { try { File.Delete(tmp); } catch { } }
    }

    public void UploadFile(Stream localStream, string remotePath)
    {
        var tmp = Path.GetTempFileName();
        try { using var fs = File.Create(tmp); localStream.CopyTo(fs); _scp.UploadFile(tmp, remotePath); }
        finally { try { File.Delete(tmp); } catch { } }
    }

    public void MakeDirectory(string path) => _scp.MakeDirectory(path);
    public void Delete(string path, bool isDir) => _scp.Delete(path, isDir);
    public void Rename(string from, string to) => _scp.Rename(from, to);
    public void Close() => _scp.Close();
    public void Dispose() => _scp.Close();
}
