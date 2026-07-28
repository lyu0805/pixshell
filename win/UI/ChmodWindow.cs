using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using PixShell.Logging;
using PixShell.Sftp;

namespace PixShell.UI;

/// <summary>
/// SFTP「文件权限…」弹窗（对齐 mac UI/ChmodWindow.swift）。
/// 纯代码构建：ToolWindow + CanResizeWithGrip；Owner/Group/Other rwx 复选 + 实时八进制；
/// 递归 + 应用范围；OK 经 SSH ExecAsync 跑 chmod / chmod -R / find -type f|d -exec chmod。
/// 铁律：所有色值走 DynamicResource（SetResourceReference），零色差。
/// </summary>
public sealed class ChmodWindow
{
    private Window? _window;
    private TextBlock? _pathLabel;
    private TextBlock? _octalLabel;
    private CheckBox[] _ownerBoxes = Array.Empty<CheckBox>();
    private CheckBox[] _groupBoxes = Array.Empty<CheckBox>();
    private CheckBox[] _otherBoxes = Array.Empty<CheckBox>();
    private CheckBox? _recursiveBox;
    private RadioButton? _scopeBoth;
    private RadioButton? _scopeFiles;
    private RadioButton? _scopeDirs;
    private StackPanel? _scopePanel;

    private List<string> _paths = new();
    private uint _initialMode = 0x1ED; // 0755
    private Func<string, Task<string>>? _execRunner;
    private Action<string>? _onDone;
    private bool _busy;

    /// <summary>展示：paths 为远端绝对路径；mode 为 POSIX 权限位（可含文件类型高位，取低 9 位）。</summary>
    public void Show(
        Window? owner,
        IReadOnlyList<string> paths,
        uint mode,
        Func<string, Task<string>>? execRunner,
        Action<string>? onDone = null)
    {
        if (paths == null || paths.Count == 0) return;
        _paths = paths.ToList();
        _execRunner = execRunner;
        _onDone = onDone;
        _initialMode = mode & 0x1FF; // 0777
        if (_window == null) Build(owner);
        else if (owner != null && !ReferenceEquals(_window.Owner, owner)) _window.Owner = owner;

        ApplyMode(_initialMode);
        var shown = string.Join("\n", _paths.Take(3));
        if (_paths.Count > 3) shown += $"\n…共 {_paths.Count} 项";
        _pathLabel!.Text = shown;
        _recursiveBox!.IsChecked = false;
        _scopeBoth!.IsChecked = true;
        UpdateScopeEnabled();
        _busy = false;

        _window!.Show();
        _window.Activate();
    }

    public void Hide() => _window?.Hide();

    private void Build(Window? owner)
    {
        var title = new TextBlock
        {
            Text = "修改文件权限",
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        BindText(title);

        var closeBtn = new Button
        {
            Content = "取消",
            Style = (Style)Application.Current.Resources["PillButton"],
            Margin = new Thickness(0, 0, 0, 0),
            IsCancel = true,
        };
        closeBtn.Click += (_, _) => Hide();

        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(closeBtn, Dock.Right);
        head.Children.Add(closeBtn);
        head.Children.Add(title);

        _pathLabel = new TextBlock
        {
            FontSize = 11,
            FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
            MaxHeight = 64,
        };
        BindMuted(_pathLabel);

        _ownerBoxes = MakeTriad();
        _groupBoxes = MakeTriad();
        _otherBoxes = MakeTriad();

        var octTitle = new TextBlock
        {
            Text = "权限值",
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        BindText(octTitle);
        _octalLabel = new TextBlock
        {
            Text = "0755",
            FontSize = 18,
            FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _octalLabel.SetResourceReference(TextBlock.ForegroundProperty, "BrushAccent");

        var octRow = new DockPanel { Margin = new Thickness(0, 4, 0, 8) };
        DockPanel.SetDock(_octalLabel, Dock.Right);
        octRow.Children.Add(_octalLabel);
        octRow.Children.Add(octTitle);

        _recursiveBox = new CheckBox
        {
            Content = "递归设置子目录",
            FontSize = 12,
            Margin = new Thickness(0, 2, 0, 6),
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        BindText(_recursiveBox);
        _recursiveBox.Checked += (_, _) => UpdateScopeEnabled();
        _recursiveBox.Unchecked += (_, _) => UpdateScopeEnabled();

        _scopeBoth = MakeScopeRadio("应用于文件和目录", true);
        _scopeFiles = MakeScopeRadio("只应用于文件", false);
        _scopeDirs = MakeScopeRadio("只应用于目录", false);
        _scopePanel = new StackPanel { Margin = new Thickness(18, 0, 0, 8) };
        _scopePanel.Children.Add(_scopeBoth);
        _scopePanel.Children.Add(_scopeFiles);
        _scopePanel.Children.Add(_scopeDirs);

        var okBtn = new Button
        {
            Content = "确定",
            Style = (Style)Application.Current.Resources["PillButton"],
            Tag = "Primary",
            MinWidth = 72,
            IsDefault = true,
            Margin = new Thickness(8, 0, 0, 0),
        };
        okBtn.Click += async (_, _) => await ConfirmAsync();
        var cancelBtn = new Button
        {
            Content = "取消",
            Style = (Style)Application.Current.Resources["PillButton"],
            MinWidth = 64,
            IsCancel = true,
        };
        cancelBtn.Click += (_, _) => Hide();

        var foot = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 8, 0, 0),
        };
        foot.Children.Add(cancelBtn);
        foot.Children.Add(okBtn);

        var body = new StackPanel();
        body.Children.Add(head);
        body.Children.Add(_pathLabel);
        body.Children.Add(TriadRow("Owner", _ownerBoxes));
        body.Children.Add(TriadRow("Group", _groupBoxes));
        body.Children.Add(TriadRow("Other", _otherBoxes));
        body.Children.Add(octRow);
        body.Children.Add(_recursiveBox);
        body.Children.Add(_scopePanel);
        body.Children.Add(foot);

        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = new Border
            {
                Padding = new Thickness(14),
                Child = body,
            },
        };

        _window = new Window
        {
            Title = "修改文件权限",
            Owner = owner,
            Width = 360,
            Height = 420,
            MinWidth = 340,
            MinHeight = 380,
            WindowStartupLocation = owner != null
                ? WindowStartupLocation.CenterOwner
                : WindowStartupLocation.CenterScreen,
            WindowStyle = WindowStyle.ToolWindow,
            ResizeMode = ResizeMode.CanResizeWithGrip,
            ShowInTaskbar = false,
            Content = scroll,
        };
        _window.SetResourceReference(Control.BackgroundProperty, "BrushBg");
        // 关掉只隐藏，下次复用
        _window.Closing += (_, e) => { e.Cancel = true; _window!.Hide(); };
    }

    private CheckBox[] MakeTriad()
    {
        // bit tags: r=4 w=2 x=1
        var labels = new[] { ("读 (r=4)", 4), ("写 (w=2)", 2), ("执行 (x=1)", 1) };
        var boxes = new CheckBox[3];
        for (var i = 0; i < 3; i++)
        {
            var (text, bit) = labels[i];
            var box = new CheckBox
            {
                Content = text,
                Tag = bit,
                FontSize = 12,
                Margin = new Thickness(0, 0, 10, 0),
                VerticalContentAlignment = VerticalAlignment.Center,
            };
            BindText(box);
            box.Checked += (_, _) => RefreshOctal();
            box.Unchecked += (_, _) => RefreshOctal();
            boxes[i] = box;
        }
        return boxes;
    }

    private static UIElement TriadRow(string name, CheckBox[] boxes)
    {
        var lab = new TextBlock
        {
            Text = name,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Width = 52,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0),
        };
        BindText(lab);
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 0, 0, 6),
        };
        row.Children.Add(lab);
        foreach (var b in boxes) row.Children.Add(b);
        return row;
    }

    private RadioButton MakeScopeRadio(string text, bool isChecked)
    {
        var rb = new RadioButton
        {
            Content = text,
            GroupName = "ChmodScope",
            FontSize = 12,
            IsChecked = isChecked,
            Margin = new Thickness(0, 0, 0, 4),
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        BindText(rb);
        return rb;
    }

    private void UpdateScopeEnabled()
    {
        var on = _recursiveBox?.IsChecked == true;
        if (_scopePanel != null) _scopePanel.IsEnabled = on;
    }

    private uint CurrentMode()
    {
        static uint Sum(CheckBox[] boxes)
        {
            uint n = 0;
            foreach (var b in boxes)
                if (b.IsChecked == true && b.Tag is int bit) n += (uint)bit;
            return n;
        }
        return (Sum(_ownerBoxes) << 6) | (Sum(_groupBoxes) << 3) | Sum(_otherBoxes);
    }

    private void ApplyMode(uint mode)
    {
        var m = mode & 0x1FF; // 0777
        static void Set(CheckBox[] boxes, uint nibble)
        {
            foreach (var b in boxes)
            {
                var bit = b.Tag is int t ? (uint)t : 0;
                b.IsChecked = (nibble & bit) != 0;
            }
        }
        Set(_ownerBoxes, (m >> 6) & 0x7);
        Set(_groupBoxes, (m >> 3) & 0x7);
        Set(_otherBoxes, m & 0x7);
        RefreshOctal();
    }

    private void RefreshOctal()
    {
        if (_octalLabel == null) return;
        _octalLabel.Text = $"0{Convert.ToString(CurrentMode(), 8).PadLeft(3, '0')}";
    }

    private async Task ConfirmAsync()
    {
        if (_busy) return;
        if (_paths.Count == 0) { Hide(); return; }

        var mode = CurrentMode();
        var oct = Convert.ToString(mode, 8).PadLeft(3, '0');
        var recursive = _recursiveBox?.IsChecked == true;
        var scope = 0; // 0 both / 1 files / 2 dirs
        if (_scopeFiles?.IsChecked == true) scope = 1;
        else if (_scopeDirs?.IsChecked == true) scope = 2;

        var quoted = string.Join(" ", _paths.Select(SftpTransfer.Quote));
        string cmd;
        if (recursive)
        {
            cmd = scope switch
            {
                1 => $"find {quoted} -type f -exec chmod {oct} {{}} + 2>&1",
                2 => $"find {quoted} -type d -exec chmod {oct} {{}} + 2>&1",
                _ => $"chmod -R {oct} {quoted} 2>&1",
            };
        }
        else
        {
            cmd = $"chmod {oct} {quoted} 2>&1";
        }

        if (_execRunner == null)
        {
            _onDone?.Invoke("需要 SSH 会话才能改权限");
            Hide();
            return;
        }

        _busy = true;
        Log.Info($"chmod {oct}{(recursive ? " -R" : "")} {_paths.Count} 项", "sftp");
        try
        {
            var outp = await _execRunner(cmd).ConfigureAwait(true);
            var trimmed = (outp ?? "").Trim();
            var msg = string.IsNullOrEmpty(trimmed)
                ? $"已设置权限 0{oct}"
                : "chmod: " + trimmed;
            _onDone?.Invoke(msg);
            Hide();
        }
        catch (Exception ex)
        {
            Log.Warn($"chmod 失败: {ex.Message}", "sftp");
            _onDone?.Invoke("chmod 失败: " + ex.Message);
            Hide();
        }
        finally
        {
            _busy = false;
        }
    }

    private static void BindText(FrameworkElement el)
    {
        if (el is Control c)
            c.SetResourceReference(Control.ForegroundProperty, "BrushText");
        else if (el is TextBlock tb)
            tb.SetResourceReference(TextBlock.ForegroundProperty, "BrushText");
    }

    private static void BindMuted(TextBlock tb)
        => tb.SetResourceReference(TextBlock.ForegroundProperty, "BrushMuted");
}
