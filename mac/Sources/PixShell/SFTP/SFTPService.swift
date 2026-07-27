import Foundation

/// 远端文件的一条目录项。字段刻意保持“纯数据”，不带任何 NIO 类型，
/// 方便 UI / Model 层直接消费，也让 SFTPService 的实现可替换（v3 自研 / Citadel）。
public struct SFTPEntry: Sendable, Equatable {
    public var name: String        // 文件名（不含路径）
    public var isDir: Bool         // 是否目录（由 POSIX 权限位 S_IFDIR 判定）
    public var size: UInt64        // 字节大小（无 SIZE 属性时为 0）
    public var mtime: Date         // 最后修改时间（无 ACMODTIME 属性时为 1970）
    public var perms: UInt32       // POSIX 权限位（含文件类型位，无 PERMISSIONS 属性时为 0）

    public init(name: String, isDir: Bool, size: UInt64, mtime: Date, perms: UInt32) {
        self.name = name; self.isDir = isDir; self.size = size
        self.mtime = mtime; self.perms = perms
    }
}

/// SFTP 层错误。远端返回的 STATUS 非 OK 会被映射成 `.status`。
public enum SFTPError: Error, Sendable {
    case notConnected                       // 尚未连接 / 通道已关闭
    case connectFailed(String)              // TCP / SSH 握手 / 子系统请求失败
    case status(code: UInt32, message: String)  // 远端 SSH_FXP_STATUS 非 OK
    case malformedPacket                    // 收到无法解析的 SFTP 报文
    case unsupportedResponse                // 收到与请求不匹配的响应类型
    case localFileError(String)             // 本地文件读写失败
    case unsupportedAuth                    // 凭据无法构造任何可用认证方式
}

/// SFTP 后端服务接口。所有方法异步执行，**completion 一律切回主线程**（供 UI 直接用）。
/// 与交互式 shell 的 `SSHSession` 平行：同样复用 `SSHCredentials` 连接同一台主机。
///
/// 关键路径：`connect` → SSH 握手 → 开 session 子通道 → subsystem "sftp"
/// → SSH_FXP_INIT/VERSION 协商（v3）→ 后续按 request-id 关联收发。
public protocol SFTPService: AnyObject {
    /// 连接并完成 SFTP v3 初始化握手。
    func connect(_ creds: SSHCredentials, completion: @escaping (Result<Void, Error>) -> Void)

    /// 列目录。返回该目录下所有条目（不含隐藏过滤，由上层决定）。
    func listDirectory(_ path: String, completion: @escaping (Result<[SFTPEntry], Error>) -> Void)

    /// 下载：把远端 `remote` 读取写入本地 `local` 路径。
    func download(remote: String, local: String, completion: @escaping (Result<Void, Error>) -> Void)

    /// 上传：把本地 `local` 写入远端 `remote`（CREAT|TRUNC）。
    func upload(local: String, remote: String, completion: @escaping (Result<Void, Error>) -> Void)

    /// 新建目录（默认权限 0755）。
    func makeDirectory(_ path: String, completion: @escaping (Result<Void, Error>) -> Void)

    /// 删除文件；若目标是目录，自动改用 RMDIR。
    func remove(_ path: String, completion: @escaping (Result<Void, Error>) -> Void)

    /// 重命名 / 移动。
    func rename(from: String, to: String, completion: @escaping (Result<Void, Error>) -> Void)

    /// 规范化路径（解析 `.`/`..`/软链）。传 "." 即可得到登录起始目录。
    func realpath(_ path: String, completion: @escaping (Result<String, Error>) -> Void)

    /// 便捷：取用户家目录（等价 `realpath(".")`）。
    func home(completion: @escaping (Result<String, Error>) -> Void)

    /// 关闭 SFTP 通道与底层连接。
    func close()
}
