using System;
using System.Collections.Generic;
using System.Linq;
using System.Media;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PixShell.Store;

namespace PixShell;

/// <summary>
/// 命令板（底部坞「命令」tab）。**照 mac UI/CommandPanel.swift 左右分栏重做**（老仓库 native-94）：
///   顶部：分组文件夹 chips（WrapPanel 换行）+ ＋新建
///   左栏：带边框命令列表（换行铺开，每条 [名称][⚙]）+ 发送到[下拉][发送]
///   右栏：命令编辑器（213px，可收起成占满窄条的展开按钮）+ [下拉][发送]
///
/// 交互对齐 mac：单击命令 = 选中并载入编辑器；**双击 = 直接发送**（分两级避免误触）。
/// 右键菜单里老仓库叫"文件夹"，这里统一叫**分组**（同一个东西）。
/// 发送目标的实际解析交给宿主（MainWindow）通过 <see cref="OnSendTo"/> 回调完成。
/// </summary>
public partial class CommandPanel : UserControl
{
    /// <summary>快捷命令持久化存储（quick-commands.json）。公开供 MainWindow 导出真实备份数据。</summary>
    public QuickCommandStore CommandStore { get; } = new();

    /// <summary>发送回调：(命令文本, 目标)。文本已含换行/回车。</summary>
    public Action<string, SendTarget>? OnSendTo { get; set; }

    /// <summary>目标下拉数据源：所有会话标题 + 是否已连接（由宿主提供）。</summary>
    public Func<List<(string title, bool connected)>>? SessionsProvider { get; set; }

    private string? _selectedGroup;
    private string? _selectedCmdId;   // 列表里被选中的那条（左栏「发送」用）
    private bool _editorCollapsed;

    // 右栏展开宽度；收起后只留一个窄条（对齐 mac rightExpanded/rightCollapsed）。
    private const double RightExpanded = 213;
    private const double RightCollapsed = 30;

    public CommandPanel()
    {
        InitializeComponent();
        ChipsRow.ContextMenu = BlankMenu();   // 列表空白处右键：新建分组 / 添加命令
        Reload();
    }

    // =====================================================================
    // 数据刷新
    // =====================================================================
    public void Reload()
    {
        ReloadTargets();
        ReloadGroups();
        ReloadChips();
    }

    public void ReloadTargets()
    {
        foreach (var combo in new[] { EdTargetCombo })
        {
            var keep = combo.SelectedIndex;
            combo.Items.Clear();
            combo.Items.Add(L10n.T("cmd.current"));
            combo.Items.Add(L10n.T("cmd.allConnected"));
            foreach (var s in SessionsProvider?.Invoke() ?? new List<(string, bool)>())
                if (s.connected) combo.Items.Add(s.title);
            combo.SelectedIndex = keep >= 0 && keep < combo.Items.Count ? keep : 0;
        }
    }

    private void TargetCombo_DropDownOpened(object? sender, EventArgs e) => ReloadTargets();

    /// <summary>把某个下拉选中项解析成 SendTarget（下标 2 起对应"已连接会话"出现顺序）。</summary>
    private SendTarget TargetOf(ComboBox combo)
    {
        var idx = combo.SelectedIndex;
        if (idx <= 0) return SendTarget.Current;
        if (idx == 1) return SendTarget.AllConnected;
        var connectedIdx = idx - 2;
        var all = SessionsProvider?.Invoke() ?? new List<(string, bool)>();
        var seen = -1;
        for (int i = 0; i < all.Count; i++)
        {
            if (!all[i].connected) continue;
            seen++;
            if (seen == connectedIdx) return SendTarget.Session(i);
        }
        return SendTarget.Current;
    }

    // =====================================================================
    // 分组文件夹 chips（换行）
    // =====================================================================
    private void ReloadGroups()
    {
        GroupRow.Children.Clear();
        GroupRow.Children.Add(FolderChip(L10n.T("cmd.all"), "", _selectedGroup == null));
        foreach (var g in CommandStore.Groups())
            GroupRow.Children.Add(FolderChip(g, g, _selectedGroup == g));
    }

    /// <summary>分组 chip：文件夹字形（Segoe MDL2 E8B7，单色随主题）+ 标签。
    /// 右键 = 分组菜单（新建/添加命令 + 重命名/删除）。真实分组值放 Uid，避免与 Tag(样式高亮) 冲突。</summary>
    private Button FolderChip(string title, string groupValue, bool active)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(new TextBlock
        {
            Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"),
            FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0)
        });
        content.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });

        var b = new Button
        {
            Content = content,
            Style = (Style)Application.Current.Resources["PillButton"],
            Padding = new Thickness(8, 1, 8, 1),
            Margin = new Thickness(0, 0, 6, 6),
            FontSize = 11,
            Tag = active ? "Primary" : null,
            Uid = groupValue,
            ContextMenu = GroupMenu(groupValue),
        };
        b.Click += OnPickGroup;
        return b;
    }

    private void OnPickGroup(object sender, RoutedEventArgs e)
    {
        var g = ((Button)sender).Uid;
        _selectedGroup = string.IsNullOrEmpty(g) ? null : g;
        ReloadGroups();
        ReloadChips();
    }

    private ContextMenu GroupMenu(string key)
    {
        var m = new ContextMenu();
        m.Items.Add(MenuItem("新建分组…", NewGroup));
        m.Items.Add(MenuItem("添加命令…", () => EditCommand(null)));
        if (!string.IsNullOrEmpty(key))
        {
            m.Items.Add(new Separator());
            m.Items.Add(MenuItem("重命名分组…", () => RenameGroup(key)));
            m.Items.Add(MenuItem("删除分组", () => DeleteGroup(key)));
        }
        return m;
    }

    // =====================================================================
    // 命令列表（换行，每条 [名称][⚙]）
    // =====================================================================
    private void ReloadChips()
    {
        ChipsRow.Children.Clear();
        foreach (var c in CommandStore.List(_selectedGroup))
        {
            var hasParam = (c.Params is { Count: > 0 }) || CommandParams.HasUnresolved(c.Command);
            var isSel = _selectedCmdId == c.Id;

            var name = new Button
            {
                Content = hasParam ? c.Name + " ⋯" : c.Name,
                Style = (Style)Application.Current.Resources["PillButton"],
                Padding = new Thickness(8, 1, 8, 1),
                FontSize = 11,
                Tag = isSel ? "Primary" : null,
                ToolTip = c.Command,
                Uid = c.Id,
                ContextMenu = ChipMenu(c.Id),
            };
            // 单击 = 选中并载入编辑器；双击 = 直接发送（用 ClickCount 区分，避免误触打到服务器）。
            name.PreviewMouseLeftButtonDown += OnChipMouseDown;

            // ⚙ = 这条命令的编辑/删除入口（老仓库每条命令后面都有个齿轮）
            var gear = new Button
            {
                Content = "⚙",
                Style = (Style)Application.Current.Resources["PillButton"],
                Padding = new Thickness(4, 1, 4, 1),
                FontSize = 11,
                Uid = c.Id,
                ToolTip = "编辑 / 删除",
            };
            gear.Click += OnGearClicked;

            var cell = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 6, 6) };
            cell.Children.Add(name);
            cell.Children.Add(gear);
            ChipsRow.Children.Add(cell);
        }
    }

    /// <summary>命令的右键/齿轮菜单（老仓库叫"文件夹"，这里统一叫**分组**）。</summary>
    private ContextMenu ChipMenu(string id)
    {
        var m = new ContextMenu();
        m.Items.Add(MenuItem("添加命令…", () => EditCommand(null)));
        m.Items.Add(MenuItem("复制命令", () => CopyCommandText(id)));   // = 复制命令文本到剪贴板，不是复制一条副本
        m.Items.Add(MenuItem("编辑", () => EditCommand(id)));
        m.Items.Add(MenuItem("删除", () => DeleteCommand(id)));
        m.Items.Add(new Separator());
        m.Items.Add(MenuItem("新建分组…", NewGroup));

        var move = new System.Windows.Controls.MenuItem { Header = "移动到" };
        var cur = CommandStore.Commands.FirstOrDefault(x => x.Id == id)?.Group ?? "默认";
        foreach (var g in CommandStore.Groups())
        {
            var gi = new System.Windows.Controls.MenuItem { Header = g, IsCheckable = true, IsChecked = g == cur };
            var gg = g;
            gi.Click += (_, _) => { CommandStore.Move(id, gg); ReloadGroups(); ReloadChips(); };
            move.Items.Add(gi);
        }
        m.Items.Add(move);
        return m;
    }

    /// <summary>列表空白处右键：只有"新建分组 / 添加命令"（对齐 mac menu(for:)）。</summary>
    private ContextMenu BlankMenu()
    {
        var m = new ContextMenu();
        m.Items.Add(MenuItem("新建分组…", NewGroup));
        m.Items.Add(MenuItem("添加命令…", () => EditCommand(null)));
        return m;
    }

    private static System.Windows.Controls.MenuItem MenuItem(string header, Action action)
    {
        var mi = new System.Windows.Controls.MenuItem { Header = header };
        mi.Click += (_, _) => action();
        return mi;
    }

    // =====================================================================
    // 动作：单击选中/双击发送 + 齿轮
    // =====================================================================
    private void OnChipMouseDown(object sender, MouseButtonEventArgs e)
    {
        var id = ((Button)sender).Uid;
        var c = CommandStore.Commands.FirstOrDefault(x => x.Id == id);
        if (c == null) return;
        _selectedCmdId = id;
        Editor.Text = c.Command;
        if (e.ClickCount >= 2)   // 双击 = 直接发送
        {
            SendCommand(c, TargetOf(EdTargetCombo));
            e.Handled = true;
            return;
        }
        ReloadChips();   // 刷新选中高亮
    }

    private void OnGearClicked(object sender, RoutedEventArgs e)
    {
        var gear = (Button)sender;
        var m = ChipMenu(gear.Uid);
        m.PlacementTarget = gear;
        m.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        m.IsOpen = true;
    }

    /// <summary>发送一条命令（含 ${参数} 逐个询问）—— 双击和左栏「发送」共用。</summary>
    private void SendCommand(QuickCommand c, SendTarget tgt)
    {
        var text = CommandStore.Render(c);   // 先套参数默认值
        if (CommandParams.HasUnresolved(text))
        {
            var vals = new Dictionary<string, string>();
            foreach (var name in CommandParams.Parse(text))
            {
                var v = AskParam(name);
                if (v == null) return;   // 取消 → 整条放弃
                vals[name] = v;
            }
            text = CommandParams.Render(text, vals);
        }
        var suffix = (c.AutoReturn ?? true) ? "\r" : "";
        OnSendTo?.Invoke(text + suffix, tgt);
    }



    /// <summary>右栏「发送」：发编辑器里的内容（有选中就只发选中那段）。</summary>
    private void OnSendEditor(object sender, RoutedEventArgs e)
    {
        var text = string.IsNullOrEmpty(Editor.SelectedText) ? Editor.Text : Editor.SelectedText;
        if (string.IsNullOrWhiteSpace(text)) { SystemSounds.Beep.Play(); return; }
        OnSendTo?.Invoke(text.EndsWith("\n") ? text : text + "\n", TargetOf(EdTargetCombo));
    }

    // =====================================================================
    // 右栏「选项」菜单 + 收起/展开
    // =====================================================================
    private void OnEditorOptions(object sender, RoutedEventArgs e)
    {
        var m = new ContextMenu();
        m.Items.Add(MenuItem("清空编辑器", () => Editor.Text = ""));
        m.Items.Add(MenuItem("把选中项载入编辑器", () =>
        {
            var c = _selectedCmdId == null ? null : CommandStore.Commands.FirstOrDefault(x => x.Id == _selectedCmdId);
            if (c != null) Editor.Text = c.Command;
        }));
        m.Items.Add(new Separator());
        m.Items.Add(MenuItem("存为新命令…", SaveEditorAsCommand));
        m.PlacementTarget = (UIElement)sender;
        m.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        m.IsOpen = true;
    }

    private void SaveEditorAsCommand()
    {
        var text = Editor.Text.Trim();
        if (text.Length == 0) { SystemSounds.Beep.Play(); return; }
        var n = Ask("存为新命令", "给它起个名字", "");
        if (string.IsNullOrWhiteSpace(n)) return;
        CommandStore.Upsert(new QuickCommand { Name = n.Trim(), Command = text, Group = _selectedGroup ?? "默认" });
        ReloadGroups();
        ReloadChips();
    }

    private void OnToggleEditor(object sender, RoutedEventArgs e) => SetEditorCollapsed(!_editorCollapsed);
    private void OnExpandEditor(object sender, RoutedEventArgs e) => SetEditorCollapsed(false);

    /// <summary>收起 = 右栏缩成窄条（左栏顺势占满）。**坑**：收起按钮本身在头部，栏宽只剩 30px 时
    /// 它会被挤出可见区再也打不开，所以收起态换成一个占满整条窄栏的展开按钮（对齐 mac expandStrip）。</summary>
    private void SetEditorCollapsed(bool collapsed)
    {
        _editorCollapsed = collapsed;
        RightColDef.Width = new GridLength(collapsed ? RightCollapsed : RightExpanded);
        EditorParts.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        ExpandStrip.Visibility = collapsed ? Visibility.Visible : Visibility.Collapsed;
        CollapseBtn.Content = collapsed ? L10n.T("cmd.expand") : L10n.T("cmd.collapse");
    }

    // =====================================================================
    // 分组增删改
    // =====================================================================
    private void NewGroup()
    {
        var n = Ask("新建分组", "分组名", "");
        if (string.IsNullOrWhiteSpace(n)) return;
        if (!CommandStore.AddGroup(n)) { SystemSounds.Beep.Play(); return; }   // 同名已存在
        _selectedGroup = n.Trim();
        ReloadGroups();
        ReloadChips();
    }

    private void RenameGroup(string oldName)
    {
        var n = Ask("重命名分组", $"把「{oldName}」改成", oldName);
        if (string.IsNullOrWhiteSpace(n)) return;
        CommandStore.RenameGroup(oldName, n);
        if (_selectedGroup == oldName) _selectedGroup = n.Trim();
        ReloadGroups();
        ReloadChips();
    }

    private void DeleteGroup(string g)
    {
        var r = MessageBox.Show(Window.GetWindow(this)!,
            $"删除分组「{g}」？\n里面的命令会移回「默认」分组，命令本身不会被删。",
            "删除分组", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (r != MessageBoxResult.OK) return;
        CommandStore.RemoveGroup(g);
        if (_selectedGroup == g) _selectedGroup = null;
        ReloadGroups();
        ReloadChips();
    }

    /// <summary>复制命令 = 把**命令文本**丢进剪贴板（方便贴到别处），不是复制出一条新命令。</summary>
    private void CopyCommandText(string id)
    {
        var c = CommandStore.Commands.FirstOrDefault(x => x.Id == id);
        if (c == null) return;
        try { Clipboard.SetText(c.Command); } catch { /* 剪贴板偶发占用，忽略 */ }
    }

    // =====================================================================
    // 命令 新建 / 编辑 / 删除
    // =====================================================================
    private void OnNewCommand(object sender, RoutedEventArgs e) => EditCommand(null);

    private void DeleteCommand(string id)
    {
        CommandStore.Delete(id);
        if (_selectedCmdId == id) _selectedCmdId = null;
        ReloadGroups();
        ReloadChips();
    }

    private void EditCommand(string? id)
    {
        var existing = id == null ? null : CommandStore.Commands.FirstOrDefault(x => x.Id == id);
        var win = new Window
        {
            Background = (Brush)Application.Current.Resources["BrushBg"],
            Foreground = (Brush)Application.Current.Resources["BrushText"],
            Title = existing == null ? "新建快捷命令" : "编辑快捷命令",
            Width = 480, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = Window.GetWindow(this),
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
        };
        var sp = new StackPanel { Margin = new Thickness(14) };
        sp.Children.Add(new TextBlock { Text = "名称" });
        var nameBox = new TextBox { Text = existing?.Name ?? "", Margin = new Thickness(0, 2, 0, 8) };
        sp.Children.Add(nameBox);
        sp.Children.Add(new TextBlock { Text = "分组" });
        var groupBox = new TextBox { Text = existing?.Group ?? (_selectedGroup ?? "默认"), Margin = new Thickness(0, 2, 0, 8) };
        sp.Children.Add(groupBox);
        sp.Children.Add(new TextBlock { Text = "命令" });
        var cmdBox = new TextBox { 
            Text = existing?.Command ?? "", 
            Margin = new Thickness(0, 2, 0, 4),
            AcceptsReturn = true,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            TextWrapping = TextWrapping.Wrap,
            Height = 120,
            FontFamily = new FontFamily("Consolas")
        };
        sp.Children.Add(cmdBox);
        var autoReturnBox = new CheckBox { Content = "末尾添加回车符CR", IsChecked = existing?.AutoReturn ?? true, Margin = new Thickness(0, 4, 0, 8) };
        sp.Children.Add(autoReturnBox);
        sp.Children.Add(new TextBlock
        {
            Text = "支持 ${参数}，发送时会提示填写", FontSize = 11,
            Foreground = (Brush)Application.Current.Resources["BrushMuted"],
            Margin = new Thickness(0, 0, 0, 8), TextWrapping = TextWrapping.Wrap,
        });
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var save = new Button { Content = "保存", Width = 72, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
        var cancel = new Button { Content = "取消", Width = 72, IsCancel = true };
        save.Click += (_, _) => win.DialogResult = true;
        row.Children.Add(save); row.Children.Add(cancel);
        sp.Children.Add(row);
        win.Content = sp;
        nameBox.Focus();

        if (win.ShowDialog() != true) return;
        var nm = nameBox.Text.Trim();
        var cm = cmdBox.Text.Trim();
        if (nm.Length == 0 || cm.Length == 0) return;
        var item = existing ?? new QuickCommand();
        item.Name = nm;
        item.Command = cm;
        item.Group = string.IsNullOrWhiteSpace(groupBox.Text) ? "默认" : groupBox.Text.Trim();
        item.AutoReturn = autoReturnBox.IsChecked;
        CommandStore.Upsert(item);
        ReloadGroups();
        ReloadChips();
    }

    // =====================================================================
    // 弹框取值（参数 / 分组名等）
    // =====================================================================
    private string? AskParam(string name) => Ask("参数 " + name, $"请输入 ${{{name}}} 的值", "");

    private string? Ask(string title, string prompt, string defaultValue)
    {
        var win = new Window
        {
            Background = (Brush)Application.Current.Resources["BrushBg"],
            Foreground = (Brush)Application.Current.Resources["BrushText"],
            Title = title, Width = 320, SizeToContent = SizeToContent.Height,
            Owner = Window.GetWindow(this),
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
        };
        var sp = new StackPanel { Margin = new Thickness(14) };
        sp.Children.Add(new TextBlock { Text = prompt, Margin = new Thickness(0, 0, 0, 8) });
        var tb = new TextBox { Text = defaultValue };
        sp.Children.Add(tb);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var ok = new Button { Content = "确定", Width = 72, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
        var cancel = new Button { Content = "取消", Width = 72, IsCancel = true };
        ok.Click += (_, _) => win.DialogResult = true;
        row.Children.Add(ok); row.Children.Add(cancel);
        sp.Children.Add(row);
        win.Content = sp;
        tb.Focus(); tb.SelectAll();
        return win.ShowDialog() == true ? tb.Text : null;
    }
}
