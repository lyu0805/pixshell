import Foundation
import NIOCore

/// SFTP v3 线协议常量与编解码辅助。
/// 参考 draft-ietf-secsh-filexfer-02（OpenSSH 实际使用的 v3）。
///
/// 报文外层帧：uint32 length | byte type | payload...
/// 除 INIT/VERSION 外，payload 开头都是 uint32 request-id，用于请求/响应关联。
enum SFTP {
    static let version: UInt32 = 3

    // MARK: 报文类型（客户端 → 服务端）
    static let INIT: UInt8 = 1
    static let VERSION: UInt8 = 2       // 服务端 → 客户端
    static let OPEN: UInt8 = 3
    static let CLOSE: UInt8 = 4
    static let READ: UInt8 = 5
    static let WRITE: UInt8 = 6
    static let LSTAT: UInt8 = 7
    static let FSTAT: UInt8 = 8
    static let SETSTAT: UInt8 = 9
    static let FSETSTAT: UInt8 = 10
    static let OPENDIR: UInt8 = 11
    static let READDIR: UInt8 = 12
    static let REMOVE: UInt8 = 13
    static let MKDIR: UInt8 = 14
    static let RMDIR: UInt8 = 15
    static let REALPATH: UInt8 = 16
    static let STAT: UInt8 = 17
    static let RENAME: UInt8 = 18

    // MARK: 报文类型（服务端 → 客户端 响应）
    static let STATUS: UInt8 = 101
    static let HANDLE: UInt8 = 102
    static let DATA: UInt8 = 103
    static let NAME: UInt8 = 104
    static let ATTRS: UInt8 = 105

    // MARK: STATUS 状态码
    static let FX_OK: UInt32 = 0
    static let FX_EOF: UInt32 = 1
    static let FX_NO_SUCH_FILE: UInt32 = 2
    static let FX_PERMISSION_DENIED: UInt32 = 3

    // MARK: OPEN pflags
    static let FXF_READ: UInt32 = 0x0000_0001
    static let FXF_WRITE: UInt32 = 0x0000_0002
    static let FXF_APPEND: UInt32 = 0x0000_0004
    static let FXF_CREAT: UInt32 = 0x0000_0008
    static let FXF_TRUNC: UInt32 = 0x0000_0010
    static let FXF_EXCL: UInt32 = 0x0000_0020

    // MARK: ATTR flags
    static let ATTR_SIZE: UInt32 = 0x0000_0001
    static let ATTR_UIDGID: UInt32 = 0x0000_0002
    static let ATTR_PERMISSIONS: UInt32 = 0x0000_0004
    static let ATTR_ACMODTIME: UInt32 = 0x0000_0008
    static let ATTR_EXTENDED: UInt32 = 0x8000_0000

    // POSIX 文件类型掩码
    static let S_IFMT: UInt32 = 0o170000
    static let S_IFDIR: UInt32 = 0o040000

    /// 单次 READ/WRITE 分块大小（32 KiB，OpenSSH 兼容的保守值）。
    static let chunkSize = 32 * 1024
}

/// 解析后的文件属性（SFTP v3 ATTRS 结构）。
struct SFTPAttributes {
    var size: UInt64 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var permissions: UInt32 = 0
    var atime: UInt32 = 0
    var mtime: UInt32 = 0

    var isDir: Bool { (permissions & SFTP.S_IFMT) == SFTP.S_IFDIR }
}

/// 解析后的一条 NAME 项。
struct SFTPName {
    var filename: String
    var longname: String
    var attrs: SFTPAttributes
}

// MARK: - ByteBuffer SFTP 编解码扩展

extension ByteBuffer {
    /// 写入 SFTP string：uint32 长度前缀 + 原始字节（UTF-8）。
    mutating func writeSFTPString(_ s: String) {
        let bytes = Array(s.utf8)
        self.writeInteger(UInt32(bytes.count), endianness: .big)
        self.writeBytes(bytes)
    }

    /// 写入 SFTP string（不透明字节，如文件 handle）。
    mutating func writeSFTPBytes(_ bytes: [UInt8]) {
        self.writeInteger(UInt32(bytes.count), endianness: .big)
        self.writeBytes(bytes)
    }

    /// 读取 SFTP string 为 UTF-8 文本。
    mutating func readSFTPString() -> String? {
        guard let len: UInt32 = self.readInteger(endianness: .big) else { return nil }
        guard let s = self.readString(length: Int(len)) else { return nil }
        return s
    }

    /// 读取 SFTP string 为原始字节（handle 等不透明数据）。
    mutating func readSFTPBytes() -> [UInt8]? {
        guard let len: UInt32 = self.readInteger(endianness: .big) else { return nil }
        return self.readBytes(length: Int(len))
    }

    /// 读取一个 v3 ATTRS 结构，按 flags 逐段解析。
    mutating func readSFTPAttributes() -> SFTPAttributes? {
        guard let flags: UInt32 = self.readInteger(endianness: .big) else { return nil }
        var a = SFTPAttributes()
        if flags & SFTP.ATTR_SIZE != 0 {
            guard let v: UInt64 = self.readInteger(endianness: .big) else { return nil }
            a.size = v
        }
        if flags & SFTP.ATTR_UIDGID != 0 {
            guard let uid: UInt32 = self.readInteger(endianness: .big),
                  let gid: UInt32 = self.readInteger(endianness: .big) else { return nil }
            a.uid = uid; a.gid = gid
        }
        if flags & SFTP.ATTR_PERMISSIONS != 0 {
            guard let p: UInt32 = self.readInteger(endianness: .big) else { return nil }
            a.permissions = p
        }
        if flags & SFTP.ATTR_ACMODTIME != 0 {
            guard let at: UInt32 = self.readInteger(endianness: .big),
                  let mt: UInt32 = self.readInteger(endianness: .big) else { return nil }
            a.atime = at; a.mtime = mt
        }
        if flags & SFTP.ATTR_EXTENDED != 0 {
            guard let count: UInt32 = self.readInteger(endianness: .big) else { return nil }
            for _ in 0..<count {
                guard self.readSFTPString() != nil, self.readSFTPString() != nil else { return nil }
            }
        }
        return a
    }
}

/// 把 SFTPAttributes 映射成对外的 SFTPEntry。
extension SFTPName {
    func toEntry() -> SFTPEntry {
        SFTPEntry(
            name: filename,
            isDir: attrs.isDir,
            size: attrs.size,
            mtime: Date(timeIntervalSince1970: TimeInterval(attrs.mtime)),
            perms: attrs.permissions
        )
    }
}
