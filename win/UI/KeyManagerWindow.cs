using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>
/// 密钥管理器（对齐 mac UI/KeyManager.swift）。
/// 老仓库 config.json 里有 secret_key_list，但没做出独立 UI；这里补上：
/// 列出 ~/.ssh 下的私钥（类型/位数/指纹/注释/是否带口令），
/// 支持 生成 / 复制公钥 / 用于此主机 / 在资源管理器中显示 / 删除。
///
/// 纯代码构建（不配 XAML）：内容是一个动态列表 + 几个按钮，为它单开一套 XAML 不划算，
/// 与 UI/ToolResultWindow.cs 同样的取舍。
/// </summary>
public sealed class KeyManagerWindow
{
    private Window? _window;
    private StackPanel? _list;
    private TextBlock? _count;
    private List<SshKeys.KeyInfo> _keys = new();

    /// <summary>「用于此主机」：把选中的私钥路径回填给调用方。</summary>
    public Action<string>? OnUseKey { get; set; }

    private static Brush B(string key) => (Brush)Application.Current.Resources[key];

    public void Show(Window owner)
    {
        if (_window == null) Build(owner);
        Reload();
        _window!.Show();
        _window.Activate();
    }

    private void Build(Window owner)
    {
        _count = new TextBlock { FontSize = 12, Foreground = B("BrushMuted"), Margin = new Thickness(0, 0, 0, 8) };
        _list = new StackPanel();

        var genBtn = new Button { Content = L10n.T("keys.generate"), Style = (Style)Application.Current.Resources["PillButton"], Tag = "Primary", Margin = new Thickness(0, 0, 6, 0) };
        genBtn.Click += (_, _) => GenerateFlow();
        var refBtn = new Button { Content = L10n.T("keys.refresh"), Style = (Style)Application.Current.Resources["PillButton"], Margin = new Thickness(0, 0, 6, 0) };
        refBtn.Click += (_, _) => Reload();
        var closeBtn = new Button { Content = L10n.T("common.close"), Style = (Style)Application.Current.Resources["PillButton"] };
        closeBtn.Click += (_, _) => _window!.Hide();

        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var btns = new StackPanel { Orientation = Orientation.Horizontal };
        btns.Children.Add(genBtn); btns.Children.Add(refBtn); btns.Children.Add(closeBtn);
        DockPanel.SetDock(btns, Dock.Right);
        head.Children.Add(btns);
        head.Children.Add(new TextBlock
        {
            Text = L10n.T("keys.title"), FontSize = 15, FontWeight = FontWeights.SemiBold,
            Foreground = B("BrushText"), VerticalAlignment = VerticalAlignment.Center,
        });

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = _list };

        var root = new DockPanel { Margin = new Thickness(14) };
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(_count, Dock.Top);
        root.Children.Add(head);
        root.Children.Add(_count);
        root.Children.Add(scroll);

        _window = new Window
        {
            Title = L10n.T("keys.title"), Owner = owner,
            Width = 420, Height = 360, MinWidth = 320, MinHeight = 240,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            WindowStyle = WindowStyle.ToolWindow,
            ResizeMode = ResizeMode.CanResizeWithGrip,
            ShowInTaskbar = false,
            Background = B("BrushBg"),
            Content = root,
        };
        // 关掉只隐藏，下次复用同一个窗口
        _window.Closing += (_, e) => { e.Cancel = true; _window!.Hide(); };
    }

    private void Reload()
    {
        _keys = SshKeys.List();
        _count!.Text = _keys.Count == 0
            ? L10n.T("keys.empty")
            : $"{_keys.Count} 个密钥 · {SshKeys.SshDir}";
        _list!.Children.Clear();
        foreach (var k in _keys) _list.Children.Add(Row(k));
    }

    private UIElement Row(SshKeys.KeyInfo k)
    {
        var box = new Border
        {
            Background = B("BrushBg2"), BorderBrush = B("BrushBorder"), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(7), Padding = new Thickness(12, 10, 12, 10),
            Margin = new Thickness(0, 0, 0, 8),
        };

        var top = new StackPanel { Orientation = Orientation.Horizontal };
        top.Children.Add(new TextBlock
        {
            Text = k.Name, FontSize = 13, FontWeight = FontWeights.SemiBold,
            Foreground = B("BrushText"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0),
        });
        top.Children.Add(Chips.Badge(k.Type == "-" ? "未知" : $"{k.Type} {k.Bits}"));
        top.Children.Add(Chips.Badge(k.Encrypted ? "带口令" : "无口令"));
        top.Children.Add(Chips.Badge(k.HasPublic ? ".pub 就绪" : "缺 .pub"));

        var fp = new TextBlock
        {
            Text = k.Fingerprint, FontSize = 11, FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            Foreground = B("BrushMuted"), Margin = new Thickness(0, 4, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var sub = new TextBlock
        {
            Text = string.IsNullOrEmpty(k.Comment) ? k.Path : $"{k.Comment} · {k.Path}",
            FontSize = 11, Foreground = B("BrushMuted"),
            Margin = new Thickness(0, 2, 0, 6), TextTrimming = TextTrimming.CharacterEllipsis,
        };

        var useBtn = new Button { Content = L10n.T("keys.useForHost"), Style = (Style)Application.Current.Resources["PillButton"], Tag = "Primary", FontSize = 11, Margin = new Thickness(0, 0, 6, 0) };
        useBtn.Click += (_, _) => { Logging.Log.Info($"选用密钥 {k.Name} → 当前主机", "keys"); OnUseKey?.Invoke(k.Path); _window!.Hide(); };
        var copyBtn = new Button { Content = L10n.T("keys.copyPub"), Style = (Style)Application.Current.Resources["PillButton"], FontSize = 11, Margin = new Thickness(0, 0, 6, 0) };
        copyBtn.Click += (_, _) => CopyPublic(k);
        var showBtn = new Button { Content = "在资源管理器中显示", Style = (Style)Application.Current.Resources["PillButton"], FontSize = 11, Margin = new Thickness(0, 0, 6, 0) };
        showBtn.Click += (_, _) => Reveal(k);
        var delBtn = new Button { Content = L10n.T("keys.delete"), Style = (Style)Application.Current.Resources["PillButton"], FontSize = 11 };
        delBtn.Click += (_, _) => DeleteFlow(k);

        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var b in new[] { useBtn, copyBtn, showBtn, delBtn }) row.Children.Add(b);

        var v = new StackPanel();
        v.Children.Add(top); v.Children.Add(fp); v.Children.Add(sub); v.Children.Add(row);
        box.Child = v;
        return box;
    }

    private void CopyPublic(SshKeys.KeyInfo k)
    {
        var text = SshKeys.PublicKeyText(k);
        if (text == null)
        {
            Logging.Log.Warn($"读不到公钥 {k.Name}（缺 .pub 且私钥带口令）", "keys");
            MessageBox.Show(_window!,
                $"缺少 {k.Name}.pub，且私钥带口令无法派生。\n可以在终端执行：\nssh-keygen -y -f \"{k.Path}\" > \"{k.Path}.pub\"",
                "读不到公钥", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        Logging.Log.Info($"复制公钥 {k.Name}", "keys");
        try { Clipboard.SetText(text); } catch { }
        MessageBox.Show(_window!, "粘到服务器的 ~/.ssh/authorized_keys 即可免密登录。",
            "公钥已复制", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void Reveal(SshKeys.KeyInfo k)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{k.Path}\"") { UseShellExecute = true }); }
        catch (Exception ex) { Logging.Log.Warn($"打开资源管理器失败: {ex.Message}", "keys"); }
    }

    private void DeleteFlow(SshKeys.KeyInfo k)
    {
        var r = MessageBox.Show(_window!,
            $"会同时删除 {k.Name} 和 {k.Name}.pub。\n此操作不可撤销；如果服务器上还留着对应的 authorized_keys 记录，请自行清理。",
            $"删除密钥 {k.Name}？", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (r != MessageBoxResult.OK) return;
        SshKeys.Delete(k);
        Reload();
    }

    /// <summary>生成密钥表单：文件名 / 类型 / 注释 / 口令。</summary>
    private void GenerateFlow()
    {
        var dlg = new Window
        {

            Title = L10n.T("keys.genTitle"), Owner = _window, Width = 380, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
            Background = B("BrushBg"),
        };
        var sp = new StackPanel { Margin = new Thickness(14) };
        sp.Children.Add(new TextBlock
        {
            Text = L10n.T("keys.genBody"),
            Foreground = B("BrushMuted"), FontSize = 11, Margin = new Thickness(0, 0, 0, 10), TextWrapping = TextWrapping.Wrap,
        });

        TextBox AddText(string label, string preset)
        {
            sp.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 6, 0, 3), Foreground = B("BrushText") });
            var tb = new TextBox { Text = preset };
            sp.Children.Add(tb);
            return tb;
        }

        var nameBox = AddText("文件名", "id_pixshell");
        sp.Children.Add(new TextBlock { Text = "类型", Margin = new Thickness(0, 6, 0, 3), Foreground = B("BrushText") });
        var typeBox = new ComboBox();
        var types = new[] { SshKeys.KeyType.Ed25519, SshKeys.KeyType.Rsa4096, SshKeys.KeyType.Ecdsa256 };
        foreach (var t in types) typeBox.Items.Add(SshKeys.Display(t));
        typeBox.SelectedIndex = 0;
        sp.Children.Add(typeBox);
        var commentBox = AddText("注释", $"{Environment.UserName}@{Environment.MachineName}");
        sp.Children.Add(new TextBlock { Text = "口令（留空 = 不加口令）", Margin = new Thickness(0, 6, 0, 3), Foreground = B("BrushText") });
        var passBox = new PasswordBox();
        sp.Children.Add(passBox);

        var ok = new Button { Content = L10n.T("keys.gen"), Width = 80, IsDefault = true, Margin = new Thickness(0, 0, 8, 0) };
        var cancel = new Button { Content = L10n.T("common.cancel"), Width = 80, IsCancel = true };
        var btnRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        btnRow.Children.Add(ok); btnRow.Children.Add(cancel);
        sp.Children.Add(btnRow);

        ok.Click += (_, _) =>
        {
            Logging.Log.Info($"请求生成密钥 name={nameBox.Text} type={types[Math.Max(0, typeBox.SelectedIndex)]} 带口令={passBox.Password.Length > 0}", "keys");
            var (path, err) = SshKeys.Generate(nameBox.Text, types[Math.Max(0, typeBox.SelectedIndex)],
                                               commentBox.Text, passBox.Password);
            if (err != null)
            {
                Logging.Log.Error("生成密钥失败: " + err, "keys");
                MessageBox.Show(dlg, err, "生成失败", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            dlg.DialogResult = true;
            Reload();
            MessageBox.Show(_window!,
                $"{path}\n\n点这条记录上的「复制公钥」，粘到服务器 ~/.ssh/authorized_keys 就能免密登录。",
                "密钥已生成", MessageBoxButton.OK, MessageBoxImage.Information);
        };
        cancel.Click += (_, _) => dlg.DialogResult = false;

        dlg.Content = sp;
        dlg.ShowDialog();
    }
}
