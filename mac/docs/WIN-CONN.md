# WIN-CONN — mac ↔ Windows 开发机稳定连接方法

目标机：`192.168.1.146`（`DESKTOP-H5FR90B`），用户 `Administrator`。
本方法用 **SSH 公钥认证 + 连接复用**，彻底避免密码尝试导致的账户锁定。
所有连接（人、其他智能体、PixShell app 的 SFTP 测试）都应复用这里的 `pixwin` 别名与密钥。

> 原问题：mac 反复用密码 SSH，频繁触发账户锁定（正确密码也被 `Permission denied`）。
> 现状态：已改为免密公钥认证，且账户锁定策略已关闭（双保险）。

---

## 1. 一句话用法（日常）

```bash
ssh pixwin "whoami"                       # 免密、秒回、走复用
ssh pixwin "cd /d C:\PixShell-win && dotnet build"   # 远端构建
scp ./local.txt pixwin:C:/PixShell-win/local.txt     # 上传（scp 用 C:/ 正斜杠）
scp pixwin:C:/PixShell-win/out.log ./out.log         # 下载
```

无需再用 `sshpass`、无需再输密码。

---

## 2. 关键落位（已完成，勿改）

| 项 | 位置 / 值 |
|----|-----------|
| mac 私钥 | `~/.ssh/pixshell_win`（ed25519，**不要外传**） |
| mac 公钥 | `~/.ssh/pixshell_win.pub` |
| Windows 授权文件 | `C:\ProgramData\ssh\administrators_authorized_keys` |
| mac 别名 | `~/.ssh/config` 中的 `Host pixwin` |
| 复用 socket | `~/.ssh/cm-Administrator@192.168.1.146:22` |

### 为什么是 administrators_authorized_keys（不是家目录）

`Administrator` 属于管理员组。Windows OpenSSH 的 `sshd_config` 有：

```
Match Group administrators
        AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

所以管理员账号的公钥**必须**放这个文件，家目录 `~/.ssh/authorized_keys` 对管理员无效。

### 该文件的 ACL（严格模式要求，已修好）

sshd 的 StrictModes 要求此文件只允许 `Administrators` 和 `SYSTEM`，否则拒用。已用 icacls 收紧：

```cmd
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r ^
  /grant SYSTEM:F /grant BUILTIN\Administrators:F
```

修完 `icacls <file>` 应只剩两行：
```
BUILTIN\Administrators:(F)
NT AUTHORITY\SYSTEM:(F)
```
（不能有 `BUILTIN\Users` 或继承项 `(I)`。）

---

## 3. mac `~/.ssh/config` 别名（已写入）

```sshconfig
Host pixwin
    HostName 192.168.1.146
    User Administrator
    IdentityFile ~/.ssh/pixshell_win
    IdentitiesOnly yes
    PreferredAuthentications publickey
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 300
```

- `ControlMaster/ControlPath/ControlPersist`：第一条连接建主控通道，后续 300s 内复用，**不再重复握手**，进一步防锁 + 提速。
- `PreferredAuthentications publickey` + `IdentitiesOnly yes`：只用这把 key，**永不回退到密码**，从根源杜绝密码锁定。

复用管理命令：
```bash
ssh -O check pixwin     # 查看主控通道是否在跑
ssh -O exit  pixwin     # 主动关闭主控通道
```

---

## 4. 账户锁定策略（治标，已关闭）

```cmd
net accounts /lockoutthreshold:0
net accounts                 # 确认「锁定阈值: 从不 / Never」
```

当前 `net accounts` 输出：`锁定阈值: 从不`。即使将来误用密码也不会再锁。
（注：Windows 中文 cmd 输出为 GBK，mac 端可 `... | iconv -f CP936 -t UTF-8` 解码。）

---

## 5. SFTP（PixShell app 会用到）——重要坑点

**坑**：本机默认 `sshd_config` 里 `Subsystem sftp sftp-server.exe` 用的是**相对路径**，
sshd 作为服务运行时工作目录是 `C:\Windows\System32`（不是 OpenSSH 目录），找不到
`sftp-server.exe`，导致 SFTP/scp 一律 `Connection closed`（而 `ssh exec` 正常）。

**已修**为绝对路径并重启 sshd：

```
Subsystem	sftp	C:/Windows/System32/OpenSSH/sftp-server.exe
```

修完后 SFTP/scp 均正常。验证：

```bash
sftp pixwin            # 进入后 pwd 应返回 /C:/Users/Administrator
```

### SFTP 路径写法差异（务必注意）
- **scp**：远端绝对路径写 `C:/Windows/Temp/x.txt`（盘符 + 正斜杠）。
- **sftp**：远端绝对路径要写成 **`/C:/Windows/Temp/x.txt`**（前导斜杠），
  否则 `C:/...` 会被当成相对家目录，被拼成 `/C:/Users/Administrator/C:/...`。

重启 sshd 的安全做法（避免在 SSH 会话内 stop 自己导致服务停住不起）：用一次性计划任务在
独立上下文里重启——
```cmd
schtasks /create /tn RestartSSHD /tr "powershell -NoProfile -Command Restart-Service sshd" /sc once /st 00:00 /ru SYSTEM /f
schtasks /run    /tn RestartSSHD
schtasks /delete /tn RestartSSHD /f
```

---

## 6. 远端 .NET 构建

```bash
ssh pixwin "cd /d C:\PixShell-win && dotnet build"
```

已验证 `dotnet --version` = 9.0.316，`C:\PixShell-win` 存在，`dotnet build` 成功（已成功生成）。

---

## 7. 稳定性压测结果

- 连续 10 次 `ssh pixwin "echo ..."`：**10/10 通过，约 2s**，全程免密、无密码提示、无锁定。
- SFTP/scp 上传下载往返：通过。
- 复用主控通道：`ssh -O check pixwin` → `Master running`。

---

## 8. 故障排查速查

| 现象 | 排查 |
|------|------|
| `ssh pixwin` 要密码 | 检查 `administrators_authorized_keys` 内容与 ACL（第 2 节）；`ssh -v pixwin` 看是否 offer 了 `pixshell_win` |
| SFTP/scp `Connection closed`（但 exec 正常） | `sshd_config` 的 `Subsystem sftp` 必须是绝对路径（第 5 节），改后重启 sshd |
| 连不上/超时 | 可能账户仍被锁或 sshd 重启中，**间隔 ≥45s 再试**，别狂连加重锁定 |
| 中文输出乱码 | mac 端管道 `| iconv -f CP936 -t UTF-8` |
| C 盘挂载读写 | mac 本地 `/private/tmp/win146/` ↔ Windows `C:\`（可直接改 sshd_config 等，注意行尾） |

配置备份：`~/.ssh/config.bak.*`、`C:\ProgramData\ssh\sshd_config.bak.*`。
