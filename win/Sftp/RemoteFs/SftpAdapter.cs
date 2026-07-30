using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Renci.SshNet;

namespace PixShell.Sftp.RemoteFs;

/// <summary>
/// 包装 SSH.NET SftpClient，直接委托。
/// </summary>
internal class SftpAdapter : IRemoteFs
{
    private readonly SftpClient _sftp;

    public bool Connected => _sftp.IsConnected;
    public string WorkingDirectory => _sftp.WorkingDirectory;
    public bool SupportsTree => true;

    public SftpAdapter(SftpClient sftp)
    {
        _sftp = sftp;
    }

    public List<FsRow> ListDirectory(string path)
    {
        if (!Connected) return new();
        return _sftp.ListDirectory(path)
            .Where(f => f.Name != "." && f.Name != "..")
            .Select(f => new FsRow
            {
                Name = f.Name,
                IsDir = f.IsDirectory,
                Size = f.IsDirectory ? 0 : f.Length,
                Mtime = f.LastWriteTime,
                Perms = (uint)(f.IsDirectory ? 0x41ED : 0x81A4),
            })
            .OrderByDescending(r => r.IsDir)
            .ThenBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public List<FsRow>? ListTreeChildren(string path)
    {
        if (!Connected) return null;
        return _sftp.ListDirectory(path)
            .Where(f => f.IsDirectory && f.Name != "." && f.Name != "..")
            .Select(f => new FsRow { Name = f.Name, IsDir = true, Size = 0 })
            .OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public void DownloadFile(string remotePath, Stream localStream)
        => _sftp.DownloadFile(remotePath, localStream);

    public void UploadFile(Stream localStream, string remotePath)
        => _sftp.UploadFile(localStream, remotePath);

    public void MakeDirectory(string path) => _sftp.CreateDirectory(path);
    public void Delete(string path, bool isDir) { if (isDir) _sftp.DeleteDirectory(path); else _sftp.DeleteFile(path); }
    public void Rename(string from, string to) => _sftp.RenameFile(from, to);

    public void Close()
    {
        try { if (Connected) _sftp.Disconnect(); } catch { }
        try { _sftp.Dispose(); } catch { }
    }

    public void Dispose() => Close();
}
