using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using PixShell.Logging;
using PixShell.Sftp;
using Renci.SshNet;
using Renci.SshNet.Sftp;

namespace PixShell;

/// <summary>
/// 远端文件浏览器：左侧远端目录树（懒加载）+ 右侧明细列表（文件名/大小/类型/修改时间）。
/// 工具按钮（返回上级/刷新/下载/上传/新建目录/删除/显示隐藏本地）由 MainWindow 的
/// bottom-dock 单行按钮驱动，调用本类的公开方法；本类本身不再画自己的工具条。
/// 远端连接复用「当前活动会话」的主机+凭据（<see cref="TerminalSession.CreateSftpClient"/>）。
/// </summary>
public partial class SftpPanel : UserControl
{
    // WPF {Binding Xxx} 只认属性，不认字段。Name 曾是 public 字段 → 图标能显示（Icon 是属性）
    // 但文件名永远空白。全部改成属性，禁止再写字段。
    private sealed class FsRow
    {
        public string Name { get; set; } = "";
        public bool IsDir { get; set; }
        public bool IsLink { get; set; }
        public long Size { get; set; }
        public DateTime Mtime { get; set; }
        /// <summary>POSIX 低 9 位权限（对齐 mac SFTPEntry.perms）；未知时 0 → 弹窗回落 0755。</summary>
        public uint Perms { get; set; }
        public string Icon => IsDir ? "📁" : (IsLink ? "🔗" : "📄");
        public string SizeText => IsDir ? "" : HumanSize(Size);
        public string TypeText => IsDir ? "目录" : (IsLink ? "链接" : "文件");
        public string TimeText => Mtime.Year <= 1971 ? "" : Mtime.ToString("yyyy/MM/dd HH:mm");
    }

    private sealed class SftpNode
    {
        public string Path; public string Name; public bool Loaded;
        public SftpNode(string path, string name) { Path = path; Name = name; }
    }

    public event Action<string>? OnPathChange;
    /// <summary>双击远端文件（非目录）→ 下载到临时文件成功 → (远端路径, 文本内容) 交给编辑器。</summary>
    public event Action<string, string>? OnOpenFile;
    /// <summary>右键「插入命令框」→ 把选中项路径交给命令框。</summary>
    public event Action<string>? OnInsertToCommand;

    /// <summary>远端执行命令（智能打包传输需要）：宿主注入当前活动会话的 <see cref="TerminalSession.ExecAsync"/>。
    /// 对齐 mac SFTPPanel.execRunner。</summary>
    public Func<string, Task<string>>? ExecRunner { get; set; }
    /// <summary>用户在 SFTP 里主动进目录（双击/树点击/上级）→ 命令框据此反向 cd 终端。
    /// 注意：命令框驱动的 <see cref="Navigate"/> 不会触发这个事件，否则会来回死循环。</summary>
    public event Action<string>? OnUserNavigate;

    /// <summary>打包传输开关（默认开，%APPDATA%\PixShell\sftp_pack_transfer.json，对齐 mac UserDefaults pixshell.sftp.packTransfer）。</summary>
    private static readonly string PackTransferPath = Path.Combine(HostStore.AppDir, "sftp_pack_transfer.json");
    private bool _packTransferEnabled = LoadPackTransferPref();
    public bool PackTransferEnabled
    {
        get => _packTransferEnabled;
        set
        {
            _packTransferEnabled = value;
            try { File.WriteAllText(PackTransferPath, value ? "true" : "false"); } catch { /* 静默 */ }
        }
    }
    private static bool LoadPackTransferPref()
    {
        try
        {
            if (!File.Exists(PackTransferPath)) return true; // 默认开
            var t = File.ReadAllText(PackTransferPath).Trim().ToLowerInvariant();
            if (t is "false" or "0" or "off") return false;
            return true;
        }
        catch { return true; }
    }

    /// <summary>当前远端目录（命令框 cd 同步用，对齐 mac currentRemotePath）。</summary>
    public string CurrentRemotePath => _remoteDir;

    /// <summary>外部（命令框 cd）驱动切目录：不触发 OnUserNavigate。</summary>
    public void Navigate(string path)
    {
        if (_shellFallback) { LoadRemoteDetailProc(string.IsNullOrEmpty(path) ? "/" : path); return; }
        if (_sftp is not { IsConnected: true }) return;
        LoadRemoteDetail(string.IsNullOrEmpty(path) ? "/" : path);
    }

    /// <summary>用户在面板里主动进入某目录：刷新 + 反向通知命令框同步 cd。</summary>
    private void EnterDirectory(string path)
    {
        LoadRemoteDetail(path);
        OnUserNavigate?.Invoke(_remoteDir);
    }

    private TerminalSession? _session;
    private SftpClient? _sftp;
    private ProcSftpClient? _procSftp;        // SFTP 失败后的 proc ssh fallback
    private string _remoteDir = "/";
    private List<FsRow> _remoteEntries = new();
    /// <summary>SFTP 失败后启用 proc fallback 模式（Dropbear 无 openssh-sftp-server）。</summary>
    private bool _shellFallback;

    private string _localDir;
    private List<FsRow> _localEntries = new();
    private bool _localHidden = true;
    /// <summary>左栏两种模式：本地文件浏览 / 与本机 CLI agent 对话。默认文件。</summary>
    private bool _chatMode;
    /// <summary>进对话前左栏是不是收着的 —— 退出对话要**原样还回去**：
    /// 本来只有远端就回到只有远端，本来是远端+本地就回到远端+本地。</summary>
    private bool? _localHiddenBeforeChat;
    private UI.AgentChatView? _chat;
    private UI.ChmodWindow? _chmodWindow;

    /// <summary>是否正处于对话模式（宿主据此决定按钮态）。</summary>
    public bool IsChatMode => _chatMode;

    public SftpPanel()
    {
        InitializeComponent();
        _localDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        LoadLocal(_localDir);
    }

    // =====================================================================
    // 会话 / 连接
    // =====================================================================
    public void SetSession(TerminalSession? session)
    {
        if (ReferenceEquals(_session, session)) return;
        _session = session;
        DisconnectSftp();
        _remoteEntries.Clear(); RemoteList.ItemsSource = null;
        RemoteTree.Items.Clear();
        OnPathChange?.Invoke("远端未连接");
    }

    /// <summary>供 MainWindow 在切到「文件」tab 时调用：若尚未为当前会话建立 SFTP 连接则自动建立。
    /// Batch 34：Connect + WorkingDirectory 下放到线程池，避免 UI 卡死（Win10 切文件 tab 卡顿）。</summary>
    private int _connectGen;
    public void ConnectIfNeeded()
    {
        if (_procSftp is { Connected: true }) return;
        if (_sftp is { IsConnected: true }) return;
        if (_shellFallback) return;
        if (_session is not { Connected: true }) { OnPathChange?.Invoke("远端未连接"); return; }
        // 本机终端无远端 SFTP
        if (_session.SourceHost?.IsLocal == true)
        {
            OnPathChange?.Invoke("本机终端（无远端）");
            StatusLabel.Text = "本机终端无 SFTP";
            return;
        }
        var session = _session;
        var gen = System.Threading.Interlocked.Increment(ref _connectGen);
        OnPathChange?.Invoke("连接中…");
        StatusLabel.Text = "SFTP 连接中…";
        System.Threading.Tasks.Task.Run(() =>
        {
            try
            {
                var client = session.CreateSftpClient();
                var dir = client.WorkingDirectory;
                Dispatcher.InvokeAsync(() =>
                {
                    if (gen != _connectGen) { try { client.Dispose(); } catch { } return; }
                    if (!ReferenceEquals(_session, session)) { try { client.Dispose(); } catch { } return; }
                    // 期间可能已连上
                    if (_sftp is { IsConnected: true }) { try { client.Dispose(); } catch { } return; }
                    _sftp = client;
                    _remoteDir = dir;
                    BuildTreeRoot();
                    LoadRemoteDetail(_remoteDir);
                    StatusLabel.Text = "SFTP 已连接";
                });
            }
            catch (Exception ex)
            {
                Dispatcher.InvokeAsync(() =>
                {
                    if (gen != _connectGen) return;
                    var msg = ex.Message;
                    var isChannelClosed = msg.Contains("Channel was closed")
                        || msg.Contains("channel") || msg.Contains("closed");
                    if (isChannelClosed)
                    {
                        // 尝试 ProcSftpClient（对齐 Mac OpenSSH 回落：ssh exec sftp-server）
                        TryProcSftpFallback(session, gen);
                    }
                    else
                    {
                        StatusLabel.Text = "SFTP 连接失败: " + ex.Message;
                        OnPathChange?.Invoke("远端未连接");
                    }
                });
            }
        });
    }

    private void TryProcSftpFallback(TerminalSession session, int gen)
    {
        StatusLabel.Text = "SFTP 回落 exec sftp-server …";
        System.Threading.Tasks.Task.Run(() =>
        {
            var proc = new ProcSftpClient();
            var host = session.HostName();
            var port = session.HostPort();
            var user = session.HostUser();
            var err = proc.Connect(host, port, user, null, session.HostKeyPath());
            Dispatcher.InvokeAsync(() =>
            {
                if (gen != _connectGen) { proc.Dispose(); return; }
                if (!ReferenceEquals(_session, session)) { proc.Dispose(); return; }
                if (err != null)
                {
                    StatusLabel.Text = $"SFTP 不可用：{err}。在 OpenWrt 运行 opkg install openssh-sftp-server 后重试。";
                    OnPathChange?.Invoke("SFTP 不可用（缺 sftp-server）");
                    proc.Dispose();
                    return;
                }
                _procSftp = proc;
                _shellFallback = true;
                _remoteDir = "/";
                BuildTreeRoot();
                LoadRemoteDetail("/");
                StatusLabel.Text = "SFTP 已连接 (ssh exec)";
            });
        });
    }

    private void DisconnectSftp()
    {
        _shellFallback = false;
        try { _procSftp?.Close(); } catch { }
        try { _procSftp?.Dispose(); } catch { }
        _procSftp = null;
        try { if (_sftp is { IsConnected: true }) _sftp.Disconnect(); } catch { }
        try { _sftp?.Dispose(); } catch { }
        _sftp = null;
        Dispatcher.InvokeAsync(() => {
            RemoteTree.Items.Clear();
            RemoteList.Items.Clear();
        });
    }

    // =====================================================================
    // 远端目录树（懒加载）
    // =====================================================================
    private void BuildTreeRoot()
    {
        RemoteTree.Items.Clear();
        var root = MakeTreeItem(new SftpNode("/", "/"));
        RemoteTree.Items.Add(root);
        root.IsExpanded = true;
    }

    private TreeViewItem MakeTreeItem(SftpNode node)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal };
        header.Children.Add(new TextBlock
        {
            Text = "📁",
            Foreground = new SolidColorBrush(Color.FromRgb(0xE8, 0xBD, 0x4A)),
            Margin = new Thickness(0, 0, 5, 0),
        });
        // 必须 DynamicResource：静态 Resources[] 取到的是创建瞬间的 brush 引用，
        // 主题切换后不跟色；暗色下若残留浅色主题 brush 会变成黑字压黑底。
        var nameTb = new TextBlock { Text = node.Name };
        nameTb.SetResourceReference(TextBlock.ForegroundProperty, "BrushText");
        header.Children.Add(nameTb);
        var item = new TreeViewItem { Header = header, Tag = node };
        // 强制整项前景也绑主题，防 TreeViewItem 模板/系统默认吃掉
        item.SetResourceReference(Control.ForegroundProperty, "BrushText");
        item.Items.Add(new TextBlock { Text = "加载中…" }); // 占位子项，使展开箭头出现
        item.Expanded += TreeItem_Expanded;
        return item;
    }

    private void TreeItem_Expanded(object sender, RoutedEventArgs e)
    {
        if (sender is not TreeViewItem item || item.Tag is not SftpNode node) return;
        if (node.Loaded) return;
        node.Loaded = true;
        var sftp = _sftp;
        if (sftp is not { IsConnected: true }) { item.Items.Clear(); return; }
        var path = node.Path;
        System.Threading.Tasks.Task.Run(() =>
        {
            List<ISftpFile>? dirs = null;
            try { dirs = sftp.ListDirectory(path).Where(f => f.IsDirectory && f.Name != "." && f.Name != "..").OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase).ToList(); }
            catch { }
            Dispatcher.BeginInvoke(new Action(() =>
            {
                item.Items.Clear();
                foreach (var d in dirs ?? new List<ISftpFile>())
                    item.Items.Add(MakeTreeItem(new SftpNode(JoinRemote(path, d.Name), d.Name)));
            }));
        });
    }

    private void RemoteTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if (RemoteTree.SelectedItem is TreeViewItem { Tag: SftpNode node })
            EnterDirectory(node.Path);
    }

    // =====================================================================
    // Proc SFTP 回退：用系统 ssh.exe exec sftp-server（对齐 Mac OpenSSHSFTPSession）
    // =====================================================================
    private async System.Threading.Tasks.Task LoadRemoteDetailProc(string dir)
    {
        OnPathChange?.Invoke(dir);
        var entries = await System.Threading.Tasks.Task.Run(() =>
        {
            try { return _procSftp!.ListDirectory(dir); }
            catch (Exception ex) { StatusLabel.Text = "列表失败: " + ex.Message; return new List<FsRow>(); }
        });
        _remoteEntries = entries;
        RemoteList.ItemsSource = null;
        RemoteList.ItemsSource = _remoteEntries;
        _remoteDir = dir;
    }

    // =====================================================================
    // 远端明细列表
    // =====================================================================
    private async void LoadRemoteDetail(string dir)
    {
        // Proc SFTP 回退模式
        if (_shellFallback)
        {
            await LoadRemoteDetailProc(dir);
            return;
        }
        var sftp = _sftp;
        if (sftp is not { IsConnected: true }) return;
        OnPathChange?.Invoke(dir);
        System.Threading.Tasks.Task.Run(() =>
        {
            List<FsRow>? rows = null;
            string? err = null;
            try
            {
                var listing = sftp.ListDirectory(dir).Where(f => f.Name != "." && f.Name != "..").ToList();
                rows = listing
                    .OrderByDescending(f => f.IsDirectory)
                    .ThenBy(f => f.Name, StringComparer.OrdinalIgnoreCase)
                    .Select(f => new FsRow
                    {
                        Name = f.Name,
                        IsDir = f.IsDirectory,
                        IsLink = f.IsSymbolicLink,
                        Size = f.Length,
                        Mtime = f.LastWriteTime,
                        Perms = ReadPerms(f),
                    })
                    .ToList();
            }
            catch (Exception ex) { err = ex.Message; }
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (err != null) { StatusLabel.Text = "列目录失败: " + err; return; }
                _remoteDir = dir;
                _remoteEntries = rows ?? new List<FsRow>();
                RemoteList.ItemsSource = _remoteEntries;
            }));
        });
    }

    private void RemoteList_DoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (RemoteList.SelectedItem is not FsRow r) return;
        if (r.IsDir) EnterDirectory(JoinRemote(_remoteDir, r.Name));
        else OpenRemoteFileForEdit(r);
    }

    // =====================================================================
    // 内置编辑器：双击文件 / 右键"打开" → 下载到临时文件 → 交给 EditorWindow
    // =====================================================================
    private async void OpenRemoteFileForEdit(FsRow r)
    {
        var sftp = _sftp;
        if (sftp is not { IsConnected: true }) return;
        if (r.Size > 4 * 1024 * 1024) { StatusLabel.Text = "文件过大（>4MB），请先下载"; return; }
        var remote = JoinRemote(_remoteDir, r.Name);
        var tmp = Path.Combine(Path.GetTempPath(), "pixshell_edit_" + r.Name);
        StatusLabel.Text = $"打开 {r.Name} …";
        try
        {
            await Task.Run(() =>
            {
                using (var fs = File.Create(tmp)) sftp.DownloadFile(remote, fs);
            });
            string text;
            try { text = File.ReadAllText(tmp, Encoding.UTF8); }
            catch { text = File.ReadAllText(tmp, Encoding.Latin1); }
            StatusLabel.Text = "";
            Log.Info($"打开远端文件 {remote}（{text.Length} 字符）", "editor");
            OnOpenFile?.Invoke(remote, text);
        }
        catch (Exception ex)
        {
            Log.Error($"打开远端文件失败 {remote}: {ex.Message}", "editor");
            StatusLabel.Text = "打开失败: " + ex.Message;
        }
        finally
        {
            try { File.Delete(tmp); } catch { }
        }
    }

    /// <summary>编辑器保存 → 写回远端（MainWindow 把 EditorWindow.OnSave 接到这里）。</summary>
    public async void SaveRemoteFile(string remotePath, string text, Action<string?> done)
    {
        var sftp = _sftp;
        if (sftp is not { IsConnected: true }) { done("远端未连接"); return; }
        var tmp = "";
        try
        {
            tmp = Path.Combine(Path.GetTempPath(), "pixshell_save_" + Path.GetFileName(remotePath));
            await Task.Run(() =>
            {
                File.WriteAllText(tmp, text, new UTF8Encoding(false));
                using (var fs = File.OpenRead(tmp)) sftp.UploadFile(fs, remotePath, true);
            });
            done(null);
            if (remotePath.StartsWith(_remoteDir)) LoadRemoteDetail(_remoteDir);
        }
        catch (Exception ex) { done(ex.Message); }
        finally
        {
            if (!string.IsNullOrEmpty(tmp)) try { File.Delete(tmp); } catch { }
        }
    }

    // =====================================================================
    // 坞行按钮驱动的公开操作
    // =====================================================================
    public void GoUp()
    {
        if (_remoteDir == "/") return;
        EnterDirectory(RemoteParent(_remoteDir));
    }

    public void Refresh()
    {
        if (!_localHidden) LoadLocal(_localDir);
        LoadRemoteDetail(_remoteDir);
    }

    public async void Mkdir()
    {
        var sftp = _sftp;
        if (sftp is not { IsConnected: true }) return;
        var name = Prompt("新建远端目录名：");
        if (string.IsNullOrWhiteSpace(name)) return;
        try
        {
            await Task.Run(() => sftp.CreateDirectory(JoinRemote(_remoteDir, name)));
            LoadRemoteDetail(_remoteDir);
        }
        catch (Exception ex) { StatusLabel.Text = "新建失败: " + ex.Message; }
    }

    /// <summary>右键/键盘 Delete 目标条目：优先当前多选（⌘/Shift 多选，对齐 mac 版 §5）。</summary>
    private List<FsRow> TargetRemoteRows() => RemoteList.SelectedItems.Cast<FsRow>().ToList();

    public async void Delete()
    {
        var sftp = _sftp;
        if (sftp is not { IsConnected: true }) return;
        var rows = TargetRemoteRows();
        if (rows.Count == 0) return;
        var preview = string.Join("\n", rows.Take(6).Select(r => r.Name));
        if (MessageBox.Show($"删除 {rows.Count} 项？\n{preview}", "PixShell", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        await Task.Run(() =>
        {
            foreach (var r in rows)
            {
                try
                {
                    var p = JoinRemote(_remoteDir, r.Name);
                    if (r.IsDir) sftp.DeleteDirectory(p); else sftp.DeleteFile(p);
                }
                catch (Exception ex) { StatusLabel.Text = "删除失败: " + ex.Message; }
            }
        });
        LoadRemoteDetail(_remoteDir);
    }

    /// <summary>F2 / 右键"重命名…"：只对第一个选中项生效。</summary>
    public async void Rename()
    {
        var sftp = _sftp;
        if (sftp is not { IsConnected: true }) return;
        var rows = TargetRemoteRows();
        if (rows.Count == 0) return;
        var r = rows[0];
        var name = Prompt($"重命名\"{r.Name}\"为：", r.Name);
        if (string.IsNullOrWhiteSpace(name) || name == r.Name) return;
        try
        {
            await Task.Run(() => sftp.RenameFile(JoinRemote(_remoteDir, r.Name), JoinRemote(_remoteDir, name)));
            LoadRemoteDetail(_remoteDir);
        }
        catch (Exception ex) { StatusLabel.Text = "重命名失败: " + ex.Message; }
    }

    /// <summary>右键"复制路径"：多选则用空格拼接各自完整路径。</summary>
    public void CopyPath()
    {
        var rows = TargetRemoteRows();
        var text = rows.Count == 0 ? _remoteDir : string.Join(" ", rows.Select(r => JoinRemote(_remoteDir, r.Name)));
        try { Clipboard.SetText(text); } catch { /* 剪贴板偶发占用，忽略 */ }
        StatusLabel.Text = "已复制路径";
    }

    /// <summary>右键"插入命令框"：交给 MainWindow 订阅的 OnInsertToCommand 写入命令输入框。</summary>
    public void InsertToCommand()
    {
        var rows = TargetRemoteRows();
        var text = rows.Count == 0 ? _remoteDir : string.Join(" ", rows.Select(r => JoinRemote(_remoteDir, r.Name)));
        OnInsertToCommand?.Invoke(text);
    }

    /// <summary>右键"打开 / 进入"：目录则导航进入，文件则走编辑器打开路径。</summary>
    private void CtxOpenAction()
    {
        var rows = TargetRemoteRows();
        if (rows.Count == 0) return;
        var r = rows[0];
        if (r.IsDir) EnterDirectory(JoinRemote(_remoteDir, r.Name));
        else OpenRemoteFileForEdit(r);
    }

    /// <summary>上传：单个小文件直传；多选 / 目录 / ≥8MB 走本地打包 → 上传 → 远端解压（对齐 mac native-102）。</summary>
    public void Upload()
    {
        if (_sftp is not { IsConnected: true }) { StatusLabel.Text = "请先连接远端"; return; }
        // 本地栏已选（可多选/含目录）→ 用之；否则弹文件选择器（Windows 原生对话框不支持文件+目录混选，仅单/多文件）。
        var paths = new List<string>();
        if (!_localHidden)
            paths = LocalList.SelectedItems.Cast<FsRow>().Select(r => Path.Combine(_localDir, r.Name)).ToList();
        if (paths.Count == 0)
        {
            var dlg = new OpenFileDialog { Multiselect = true };
            if (dlg.ShowDialog() != true) return;
            paths = dlg.FileNames.ToList();
        }
        UploadItems(paths);
    }

    /// <summary>上传一组本地路径（拖拽/选择共用）。文件/目录均可。
    /// 打包开 + 多项/目录/≥8MB → tar；否则逐项直传（目录跳过并提示，对齐 mac）。</summary>
    public void UploadItems(List<string> paths)
    {
        if (_sftp is not { IsConnected: true } sftp || paths.Count == 0) return;
        bool autoNeed = paths.Count > 1 || paths.Any(p =>
        {
            if (Directory.Exists(p)) return true;
            try { return new FileInfo(p).Length >= SftpTransfer.PackThreshold; } catch { return false; }
        });
        // 打包传输关：全部直传；开：多项/目录/大文件走 tar
        var needPack = PackTransferEnabled && autoNeed;
        if (!needPack)
        {
            UploadDirect(paths, sftp);
            return;
        }
        if (ExecRunner == null) { StatusLabel.Text = "需要 SSH 会话才能打包上传"; return; }
        _ = UploadItemsPackedAsync(paths);
    }

    /// <summary>关闭打包时：逐项直传上传（目录跳过并提示）。</summary>
    private async void UploadDirect(List<string> paths, SftpClient sftp)
    {
        var skippedDirs = 0;
        var uploaded = 0;
        await Task.Run(() =>
        {
            foreach (var one in paths)
            {
                if (Directory.Exists(one))
                {
                    skippedDirs++;
                    continue;
                }
                if (!File.Exists(one)) continue;
                try
                {
                    var remote = JoinRemote(_remoteDir, Path.GetFileName(one));
                    using var fs = File.OpenRead(one);
                    StatusLabel.Text = $"上传 {Path.GetFileName(one)} …";
                    Log.Info($"直传上传 {one} → {remote}", "sftp");
                    sftp.UploadFile(fs, remote, true);
                    uploaded++;
                }
                catch (Exception ex)
                {
                    Log.Error($"上传失败 {one}: {ex.Message}", "sftp");
                    StatusLabel.Text = "上传失败: " + ex.Message;
                    return;
                }
            }
        });
        StatusLabel.Text = skippedDirs > 0
            ? $"直传完成（{skippedDirs} 个目录已跳过，请开启「打包传输」）"
            : (uploaded > 0 ? "上传完成" : "无���上传文件");
        if (uploaded > 0) LoadRemoteDetail(_remoteDir);
    }

    private async Task UploadItemsPackedAsync(List<string> paths)
    {
        if (_sftp is not { IsConnected: true } sftp || ExecRunner == null) return;
        var st = SftpTransfer.Stamp();
        var localArchive = Path.Combine(Path.GetTempPath(), $"pixshell_up_{st}.tar.gz");
        var remoteArchive = $"/tmp/pixshell_up_{st}.tar.gz";
        StatusLabel.Text = $"本地打包 {paths.Count} 项 …";
        Log.Info("智能打包上传 " + string.Join(", ", paths.Select(Path.GetFileName)), "sftp");
        var err = await SftpTransfer.PackLocalAsync(localArchive, paths).ConfigureAwait(false);
        if (err != null) { Log.Error("本地打包失败: " + err, "sftp"); StatusLabel.Text = "打包失败: " + err; return; }
        try
        {
            StatusLabel.Text = "上传压缩包 …";
            using (var fs = File.OpenRead(localArchive)) sftp.UploadFile(fs, remoteArchive, true);
        }
        catch (Exception ex)
        {
            Log.Error("压缩包上传失败: " + ex.Message, "sftp");
            StatusLabel.Text = "上传失败: " + ex.Message;
            TryDelete(localArchive);
            return;
        }
        TryDelete(localArchive);
        var outp = await ExecRunner(SftpTransfer.ExtractCommand(remoteArchive, _remoteDir));
        var (rc, msg) = SftpTransfer.ParseRemoteRC(outp ?? "");
        if (rc != 0)
        {
            Log.Error($"远端解压失败 rc={rc}: {msg}", "sftp");
            StatusLabel.Text = string.IsNullOrWhiteSpace(msg) ? $"远端解压失败 (rc={rc})" : "远端解压: " + msg;
        }
        else
        {
            StatusLabel.Text = $"已上传并解压 {paths.Count} 项";
            Log.Info("打包上传完成 → " + _remoteDir, "sftp");
        }
        LoadRemoteDetail(_remoteDir);
    }

    /// <summary>下载：打包开且（多选/目录/≥8MB）走远端 tar；否则逐项直传（对齐 mac）。</summary>
    public void Download()
    {
        if (_sftp is not { IsConnected: true } sftp) { StatusLabel.Text = "请先连接远端"; return; }
        var rows = TargetRemoteRows();
        if (rows.Count == 0) { StatusLabel.Text = "请选择远端文件"; return; }
        var destDir = _localHidden
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\Downloads"
            : _localDir;

        var needPack = PackTransferEnabled && SftpTransfer.ShouldPack(rows.Count, rows[0].IsDir, rows[0].Size);
        if (!needPack)
        {
            DownloadDirect(rows, destDir, sftp);
            return;
        }
        if (ExecRunner == null) { StatusLabel.Text = "需要 SSH 会话才能打包下载"; return; }
        _ = PackedDownloadAsync(rows, destDir);
    }

    /// <summary>关闭打包时：逐项直传下载（目录跳过并提示）。</summary>
    private async void DownloadDirect(List<FsRow> rows, string destDir, SftpClient sftp)
    {
        var skippedDirs = 0;
        var downloaded = 0;
        try { Directory.CreateDirectory(destDir); } catch { /* 目标目录创建失败后面再报 */ }
        await Task.Run(() =>
        {
            foreach (var r in rows)
            {
                if (r.IsDir)
                {
                    skippedDirs++;
                    continue;
                }
                Guid? task = null;
                try
                {
                    var local = Path.Combine(destDir, r.Name);
                    using var fs = File.Create(local);
                    StatusLabel.Text = $"下载 {r.Name} …";
                    Log.Info($"直传下载 {JoinRemote(_remoteDir, r.Name)} → {local}", "sftp");
                    task = DownloadTasks.Start(r.Name, local);
                    sftp.DownloadFile(JoinRemote(_remoteDir, r.Name), fs);
                    DownloadTasks.Finish(task.Value, ok: true);
                    downloaded++;
                }
                catch (Exception ex)
                {
                    Log.Error($"下载失败 {r.Name}: {ex.Message}", "sftp");
                    if (task.HasValue) DownloadTasks.Finish(task.Value, ok: false, detail: ex.Message);
                    StatusLabel.Text = "下载失败: " + ex.Message;
                    return;
                }
            }
        });
        StatusLabel.Text = skippedDirs > 0
            ? $"直传完成（{skippedDirs} 个目录已跳过，请开启「打包传输」）"
            : (downloaded > 0 ? $"下载完成: {destDir}" : "无可下载文件");
        if (downloaded > 0 && !_localHidden) LoadLocal(_localDir);
    }

    /// <summary>远端打包 → 下载 → 本地解压 → 两端清理。</summary>
    private async Task PackedDownloadAsync(List<FsRow> items, string destDir)
    {
        if (_sftp is not { IsConnected: true } sftp || ExecRunner == null) return;
        var st = SftpTransfer.Stamp();
        var remoteArchive = $"/tmp/pixshell_dl_{st}.tar.gz";
        var localArchive = Path.Combine(Path.GetTempPath(), $"pixshell_dl_{st}.tar.gz");
        var paths = items.Select(r => JoinRemote(_remoteDir, r.Name)).ToList();
        StatusLabel.Text = $"远端打包 {items.Count} 项 …";
        Log.Info("智能打包下载 " + string.Join(", ", paths), "sftp");
        var out1 = await ExecRunner(SftpTransfer.PackCommand(remoteArchive, paths));
        var (packRc, packMsg) = SftpTransfer.ParseRemoteRC(out1 ?? "");
        if (packRc != 0)
        {
            Log.Error($"远端打包失败 rc={packRc}: {packMsg}", "sftp");
            StatusLabel.Text = string.IsNullOrWhiteSpace(packMsg)
                ? $"远端打包失败 (rc={packRc})"
                : "打包失败: " + packMsg;
            _ = ExecRunner($"rm -f {SftpTransfer.Quote(remoteArchive)}");
            return;
        }
        StatusLabel.Text = "下载压缩包 …";
        try
        {
            Directory.CreateDirectory(destDir);
            using (var fs = File.Create(localArchive)) sftp.DownloadFile(remoteArchive, fs);
        }
        catch (Exception ex)
        {
            Log.Error($"打包下载失败: {ex.Message} 远端输出={out1}", "sftp");
            StatusLabel.Text = "下载失败: " + ex.Message;
            _ = ExecRunner($"rm -f {SftpTransfer.Quote(remoteArchive)}");
            return;
        }
        _ = ExecRunner($"rm -f {SftpTransfer.Quote(remoteArchive)}");
        var err = await SftpTransfer.ExtractLocalAsync(localArchive, destDir).ConfigureAwait(false);
        if (err != null)
        {
            Log.Error("本地解压失败: " + err, "sftp");
            StatusLabel.Text = "解压失败: " + err;
        }
        else
        {
            StatusLabel.Text = $"已下载并解压 {items.Count} 项 → {destDir}";
            Log.Info("打包下载完成 → " + destDir, "sftp");
            if (!_localHidden) LoadLocal(_localDir);
        }
        TryDelete(localArchive);
    }

    private static void TryDelete(string path) { try { File.Delete(path); } catch { } }

    public void ToggleLocal()
    {
        _localHidden = !_localHidden;
        ApplyLocalHidden();
        if (!_localHidden) LoadLocal(_localDir);
    }

    private void ApplyLocalHidden()
    {
        LocalCol.Width = new GridLength(_localHidden ? 0 : 220);
        // 同一列里两种模式二选一：文件表 或 对话面板
        LocalPanel.Visibility = (_localHidden || _chatMode) ? Visibility.Collapsed : Visibility.Visible;
        AgentChatHost.Visibility = (!_localHidden && _chatMode) ? Visibility.Visible : Visibility.Collapsed;
        LocalSplitter.Visibility = _localHidden ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>坞里的机器人按钮：点一下进对话，再点一下退出并**恢复原来的界面**。</summary>
    public void ToggleChat()
    {
        if (_chatMode)
        {
            _chatMode = false;
            if (_localHiddenBeforeChat is { } before) _localHidden = before;   // 原样还回去
            _localHiddenBeforeChat = null;
            ApplyLocalHidden();
            if (!_localHidden) LoadLocal(_localDir);
            return;
        }
        _localHiddenBeforeChat = _localHidden;   // 记住原样，退出时还原
        _chatMode = true;
        if (_localHidden) _localHidden = false;  // 对话要占地方，先展开
        _chat ??= new UI.AgentChatView();
        AgentChatHost.Content = _chat;
        _chat.WorkingDirectory = _localDir;      // agent 的工作目录跟随左栏本地路径
        ApplyLocalHidden();
    }

    // =====================================================================
    // 本地（默认隐藏）
    // =====================================================================
    private async void LoadLocal(string dir)
    {
        try
        {
            var rows = await Task.Run(() =>
            {
                var di = new DirectoryInfo(dir);
                var result = new List<FsRow>();
                foreach (var d in di.GetDirectories().OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
                    result.Add(new FsRow { Name = d.Name, IsDir = true });
                foreach (var f in di.GetFiles().OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
                    result.Add(new FsRow { Name = f.Name, IsDir = false, Size = f.Length, Mtime = f.LastWriteTime });
                return (di.FullName, result);
            });
            _localDir = rows.FullName;
            LocalPathLabel.Text = _localDir;
            _localEntries = rows.result;
            LocalList.ItemsSource = rows.result;
        }
        catch (Exception ex) { StatusLabel.Text = "本地读取失败: " + ex.Message; }
    }

    private void LocalList_DoubleClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (LocalList.SelectedItem is not FsRow r || !r.IsDir) return;
        LoadLocal(Path.Combine(_localDir, r.Name));
    }

    // =====================================================================
    // 辅助
    // =====================================================================
    private static string JoinRemote(string dir, string name) => dir.EndsWith("/") ? dir + name : dir + "/" + name;
    private static string RemoteParent(string dir)
    {
        dir = dir.TrimEnd('/');
        var i = dir.LastIndexOf('/');
        return i <= 0 ? "/" : dir[..i];
    }
    private static string HumanSize(long n)
    {
        string[] u = { "B", "K", "M", "G", "T" };
        double v = n; int k = 0;
        while (v >= 1024 && k < u.Length - 1) { v /= 1024; k++; }
        return k == 0 ? $"{n}{u[0]}" : $"{v:0.#}{u[k]}";
    }
    private static string? Prompt(string message)
    {
        var win = new Window
        {

            Background = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushBg"],
            Foreground = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushText"],
            Title = "PixShell", Width = 320, Height = 140,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false
        };
        var sp = new StackPanel { Margin = new Thickness(12) };
        sp.Children.Add(new TextBlock { Text = message, Margin = new Thickness(0, 0, 0, 6) });
        var tb = new TextBox();
        sp.Children.Add(tb);
        var ok = new Button { Content = "确定", Width = 70, Margin = new Thickness(0, 12, 0, 0), HorizontalAlignment = HorizontalAlignment.Right, IsDefault = true };
        string? result = null;
        ok.Click += (_, _) => { result = tb.Text; win.DialogResult = true; };
        sp.Children.Add(ok);
        win.Content = sp;
        tb.Focus();
        return win.ShowDialog() == true ? result : null;
    }

    /// <summary>带预填值的输入框（重命名用：光标默认选中扩展名前的部分，更贴近 Finder/资源管理器习惯）。</summary>
    private static string? Prompt(string message, string preset)
    {
        var win = new Window
        {

            Background = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushBg"],
            Foreground = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushText"],
            Title = "PixShell", Width = 320, Height = 140,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false
        };
        var sp = new StackPanel { Margin = new Thickness(12) };
        sp.Children.Add(new TextBlock { Text = message, Margin = new Thickness(0, 0, 0, 6) });
        var tb = new TextBox { Text = preset };
        sp.Children.Add(tb);
        var ok = new Button { Content = "确定", Width = 70, Margin = new Thickness(0, 12, 0, 0), HorizontalAlignment = HorizontalAlignment.Right, IsDefault = true };
        string? result = null;
        ok.Click += (_, _) => { result = tb.Text; win.DialogResult = true; };
        sp.Children.Add(ok);
        win.Content = sp;
        var dot = preset.LastIndexOf('.');
        tb.Focus();
        tb.Select(0, dot > 0 ? dot : preset.Length);
        return win.ShowDialog() == true ? result : null;
    }

    // =====================================================================
    // 右键菜单 / 拖拽上传 / F5·F2·Delete 快捷键（对齐 mac UI/SFTPPanel.swift §5）
    // =====================================================================

    /// <summary>右键一个未被选中的行时，先把选择改成"仅该行"（保留已有多选时右键选区内某项的情况）。</summary>
    private void RemoteItem_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is ListViewItem { Content: FsRow } item && !item.IsSelected)
        {
            RemoteList.SelectedItems.Clear();
            item.IsSelected = true;
        }
    }

    private void RemoteList_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.F5: Refresh(); e.Handled = true; break;
            case Key.F2: Rename(); e.Handled = true; break;
            case Key.Delete: Delete(); e.Handled = true; break;
        }
    }

    private void CtxOpen_Click(object sender, RoutedEventArgs e) => CtxOpenAction();
    private void CtxDownload_Click(object sender, RoutedEventArgs e) => Download();
    private void CtxUpload_Click(object sender, RoutedEventArgs e) => Upload();
    private void CtxMkdir_Click(object sender, RoutedEventArgs e) => Mkdir();
    private void CtxRename_Click(object sender, RoutedEventArgs e) => Rename();
    private void CtxDelete_Click(object sender, RoutedEventArgs e) => Delete();
    private void CtxChmod_Click(object sender, RoutedEventArgs e) => CtxChmod();
    private void CtxCopyPath_Click(object sender, RoutedEventArgs e) => CopyPath();
    private void CtxInsertToCommand_Click(object sender, RoutedEventArgs e) => InsertToCommand();
    private void CtxRefresh_Click(object sender, RoutedEventArgs e) => Refresh();

    /// <summary>右键「文件权限…」：对齐 mac ctxChmod → ChmodWindow。</summary>
    private void CtxChmod()
    {
        if (_sftp is not { IsConnected: true })
        {
            StatusLabel.Text = "请先连接远端";
            return;
        }
        var rows = TargetRemoteRows();
        if (rows.Count == 0)
        {
            StatusLabel.Text = "先选远端文件";
            return;
        }
        var paths = rows.Select(r => JoinRemote(_remoteDir, r.Name)).ToList();
        // 多项时以第一项权限为初值（勾选可再改）；未知回落 0755
        var mode = rows[0].Perms != 0 ? rows[0].Perms : 0x1EDu; // 0755
        _chmodWindow ??= new UI.ChmodWindow();
        var owner = Window.GetWindow(this);
        _chmodWindow.Show(
            owner,
            paths,
            mode,
            ExecRunner,
            msg =>
            {
                StatusLabel.Text = msg;
                LoadRemoteDetail(_remoteDir);
            });
    }

    /// <summary>从 SSH.NET 列表项取 POSIX 低 9 位；取不到返回 0（调用方回落 0755）。</summary>
    private static uint ReadPerms(ISftpFile f)
    {
        try
        {
            // SSH.NET 2024：SftpFile.Attributes 带 Owner/Group/Others CanRead|Write|Execute
            if (f is SftpFile sf && sf.Attributes != null)
            {
                var a = sf.Attributes;
                uint m = 0;
                if (a.OwnerCanRead) m |= 0x100;      // 0400
                if (a.OwnerCanWrite) m |= 0x80;      // 0200
                if (a.OwnerCanExecute) m |= 0x40;    // 0100
                if (a.GroupCanRead) m |= 0x20;       // 0040
                if (a.GroupCanWrite) m |= 0x10;      // 0020
                if (a.GroupCanExecute) m |= 0x8;     // 0010
                if (a.OthersCanRead) m |= 0x4;       // 0004
                if (a.OthersCanWrite) m |= 0x2;      // 0002
                if (a.OthersCanExecute) m |= 0x1;    // 0001
                return m;
            }
        }
        catch { /* 属性缺失/不支持时忽略 */ }
        return 0;
    }

    /// <summary>右键「✓ 打包传输」：切换开关并持久化（对齐 mac ctxTogglePackTransfer）。</summary>
    private void CtxTogglePackTransfer_Click(object sender, RoutedEventArgs e)
    {
        PackTransferEnabled = !PackTransferEnabled;
        RefreshPackTransferMenuHeader();
        StatusLabel.Text = PackTransferEnabled ? "已开启打包传输" : "已关闭打包传输（直传）";
        Log.Info("打包传输 → " + (PackTransferEnabled ? "开" : "关"), "sftp");
    }

    private void RefreshPackTransferMenuHeader()
    {
        if (CtxPackTransferItem != null)
            CtxPackTransferItem.Header = PackTransferEnabled ? "✓ 打包传输" : "打包传输";
        // IsCheckable 勾选态也同步（双保险，暗色主题下 ✓ 前缀更直观）
        if (CtxPackTransferItem != null)
        {
            CtxPackTransferItem.IsCheckable = true;
            CtxPackTransferItem.IsChecked = PackTransferEnabled;
        }
    }

    private void RemoteList_ContextMenuOpening(object sender, ContextMenuEventArgs e) =>
        RefreshPackTransferMenuHeader();

    /// <summary>拖文件到面板上传（对齐 mac draggingEntered/performDragOperation，暂不支持拖目录）。</summary>
    private void Panel_DragEnter(object sender, DragEventArgs e)
    {
        e.Effects = (_sftp is { IsConnected: true } && e.Data.GetDataPresent(DataFormats.FileDrop))
            ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    /// <summary>拖文件/目录到面板上传：走智能打包同一条路径（对齐 mac performDragOperation → uploadItems）。</summary>
    private void Panel_Drop(object sender, DragEventArgs e)
    {
        if (_sftp is not { IsConnected: true } || !e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        var files = ((string[])e.Data.GetData(DataFormats.FileDrop)!).ToList();
        if (files.Count == 0) return;
        Log.Info("拖拽上传 " + string.Join(", ", files.Select(Path.GetFileName)), "sftp");
        UploadItems(files);
    }

    /// <summary>面板释放：断开 SFTP。</summary>
    public void Cleanup() => DisconnectSftp();
}
