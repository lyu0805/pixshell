using System;
using System.Collections.Generic;
using System.Linq;
using System.Media;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using PixShell.Logging;

namespace PixShell.UI;

/// <summary>
/// 内置文本编辑器窗口：对齐 mac UI/EditorPanel.swift。
/// 入口：SFTP 面板双击文件 → 下载到临时文件 → Open(path, text) → 编辑 → 保存 → OnSave 回调上传回远端。
/// 实现方式与 mac（NSTextView + NSAttributedString 属性染色）不同——WPF 用单个 Paragraph
/// 装满 Run/LineBreak，靠 Debounce 定时器在停止输入后重建整段 Inlines 重新着色；
/// **不变式**：无论是否着色，ExtractPlainText() 拼回来的文本必须和用户实际输入的字符一模一样。
/// </summary>
public partial class EditorWindow : Window
{
    /// <summary>保存回调：(文本, 完成回报)。调用方写回远端/本地后，用回报回调告知结果
    /// （null = 成功；非 null = 错误原因）。**必须回报**：只有成功才清脏标记 / 才关闭，
    /// 失败留在编辑器里显示原因——否则远端写失败时改动会静默丢失（mac 踩过的丢数据 bug）。</summary>
    public Action<string, Action<string?>>? OnSave;

    private string _filePath = "";
    private EditorLang _lang = EditorLang.Plain;
    private bool _wrapEnabled;
    private bool _isDirty;
    private bool _isLoadingDocument;
    private readonly Paragraph _paragraph = new();
    private readonly DispatcherTimer _rehighlightTimer;

    private static readonly Dictionary<string, Brush> BrushCache = new();

    public EditorWindow()
    {
        InitializeComponent();
        Editor.Document.Blocks.Clear();
        Editor.Document.Blocks.Add(_paragraph);

        _rehighlightTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(220) };
        _rehighlightTimer.Tick += (_, _) => { _rehighlightTimer.Stop(); Rehighlight(); };

        Editor.TextChanged += Editor_TextChanged;
        Editor.SelectionChanged += (_, _) => UpdateFooter();
        Editor.PreviewKeyDown += Editor_PreviewKeyDown;
        Editor.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler(Editor_ScrollChanged));
        Closing += EditorWindow_Closing;
        ApplyWrapSetting();
    }

    // =====================================================================
    // 打开文档
    // =====================================================================

    /// <summary>加载文件内容：探测语言、跑一次高亮、复位脏标记/查找框。</summary>
    public void Open(string path, string text)
    {
        _filePath = path;
        _lang = EditorSyntax.Detect(path);
        var name = System.IO.Path.GetFileName(path);
        Title = "编辑器 — " + name;
        FileNameText.Text = name;
        FileNameText.ToolTip = path;
        LangBadgeHost.Content = Chips.Badge(EditorSyntax.DisplayName(_lang), Chips.BadgeKind.Accent);
        FindBox.Text = "";
        ReplaceBox.Text = "";

        _isLoadingDocument = true;
        RebuildDocument(text ?? "");
        _isLoadingDocument = false;

        _isDirty = false;
        DirtyText.Visibility = Visibility.Collapsed;
        UpdateGutter();
        UpdateFooter();
        Log.Info($"打开编辑器 {path}（{(text ?? "").Length} 字符）", "editor");
    }

    // =====================================================================
    // 文档重建（着色不改字符）
    // =====================================================================

    private void RebuildDocument(string text)
    {
        var spans = EditorSyntax.Highlight(text, _lang, ThemeManager.IsDark);
        var defaultBrush = BrushFromHex(EditorSyntax.DefaultTextColor(ThemeManager.IsDark));
        string?[]? colorAt = null;
        if (spans.Count > 0)
        {
            colorAt = new string?[text.Length];
            foreach (var s in spans)
                for (var p = s.Start; p < s.Start + s.Length && p < text.Length; p++) colorAt[p] = s.ColorHex;
        }

        _paragraph.Inlines.Clear();
        var n = text.Length;
        var i = 0;
        while (i < n)
        {
            var nl = text.IndexOf('\n', i);
            var lineEnd = nl < 0 ? n : nl;
            var j = i;
            while (j < lineEnd)
            {
                var color = colorAt?[j];
                var k = j + 1;
                while (k < lineEnd && colorAt?[k] == color) k++;
                _paragraph.Inlines.Add(new Run(text[j..k]) { Foreground = color != null ? BrushFromHex(color) : defaultBrush });
                j = k;
            }
            if (nl >= 0) { _paragraph.Inlines.Add(new LineBreak()); i = nl + 1; }
            else i = n;
        }
        if (_paragraph.Inlines.Count == 0) _paragraph.Inlines.Add(new Run(""));
    }

    private static Brush BrushFromHex(string hex)
    {
        if (BrushCache.TryGetValue(hex, out var cached)) return cached;
        Brush brush;
        try
        {
            var color = (Color)ColorConverter.ConvertFromString(hex);
            var b = new SolidColorBrush(color);
            b.Freeze();
            brush = b;
        }
        catch { brush = Brushes.Black; }
        BrushCache[hex] = brush;
        return brush;
    }

    /// <summary>把编辑区当前内容拼回纯文本（只看我们自己建的 Run/LineBreak，不依赖
    /// WPF TextRange.Text 在段落边界自动插入的 \r\n，保证与用户实际输入逐字符一致）。</summary>
    private string ExtractPlainText()
    {
        var sb = new StringBuilder();
        foreach (var inline in _paragraph.Inlines)
        {
            if (inline is Run run) sb.Append(run.Text);
            else if (inline is LineBreak) sb.Append('\n');
        }
        return sb.ToString();
    }

    // =====================================================================
    // 编辑事件：回车不拆段落、粘贴导致多段落时归一化、停止输入后重新着色
    // =====================================================================

    private void Editor_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            // 默认行为会新起一个 Paragraph，破坏"单段落 + LineBreak"假设；改为插入 LineBreak。
            e.Handled = true;
            var after = Editor.CaretPosition.InsertLineBreak();
            Editor.CaretPosition = after;
        }
        else if (e.Key == Key.Escape)
        {
            e.Handled = true;
            RequestClose();
        }
    }

    private void Editor_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_isLoadingDocument) return;
        if (Editor.Document.Blocks.Count > 1) NormalizeToSingleParagraph();

        _isDirty = true;
        DirtyText.Visibility = Visibility.Visible;
        UpdateGutter();
        UpdateFooter();

        if (_lang == EditorLang.Plain) return; // 纯文本不需要重新着色
        _rehighlightTimer.Stop();
        _rehighlightTimer.Start();
    }

    /// <summary>粘贴等操作可能让 RichTextBox 自己拆出多个 Paragraph——整体拉平重建，
    /// 保证 ExtractPlainText 依旧只需要看 _paragraph 一个对象。</summary>
    private void NormalizeToSingleParagraph()
    {
        var full = new TextRange(Editor.Document.ContentStart, Editor.Document.ContentEnd).Text;
        full = full.Replace("\r\n", "\n").Replace("\r", "\n");
        if (full.EndsWith("\n")) full = full[..^1]; // TextRange 常在末段后多补一个换行

        _isLoadingDocument = true;
        Editor.Document.Blocks.Clear();
        Editor.Document.Blocks.Add(_paragraph);
        RebuildDocument(full);
        _isLoadingDocument = false;
        Editor.CaretPosition = _paragraph.ContentEnd;
    }

    private void Rehighlight()
    {
        var text = ExtractPlainText();
        var caretOffset = GetOffset(Editor.CaretPosition);
        _isLoadingDocument = true;
        RebuildDocument(text);
        _isLoadingDocument = false;
        var tp = FindPointerAtOffset(caretOffset);
        Editor.CaretPosition = tp;
    }

    // =====================================================================
    // 偏移量 ↔ TextPointer（只在 _paragraph 内部找，避免段落边界的歧义）
    // =====================================================================

    private int GetOffset(TextPointer tp)
    {
        var running = 0;
        foreach (var inline in _paragraph.Inlines)
        {
            if (inline is Run run)
            {
                if (tp.CompareTo(run.ContentStart) >= 0 && tp.CompareTo(run.ContentEnd) <= 0)
                    return running + new TextRange(run.ContentStart, tp).Text.Length;
                running += run.Text.Length;
            }
            else if (inline is LineBreak lb)
            {
                if (tp.CompareTo(lb.ElementStart) >= 0 && tp.CompareTo(lb.ElementEnd) <= 0) return running;
                running += 1;
            }
        }
        return running;
    }

    private TextPointer FindPointerAtOffset(int target)
    {
        var running = 0;
        foreach (var inline in _paragraph.Inlines)
        {
            if (inline is Run run)
            {
                var len = run.Text.Length;
                if (target <= running + len)
                    return run.ContentStart.GetPositionAtOffset(target - running, LogicalDirection.Forward) ?? run.ContentEnd;
                running += len;
            }
            else if (inline is LineBreak lb)
            {
                if (target == running) return lb.ElementStart;
                running += 1;
            }
        }
        return _paragraph.ContentEnd;
    }

    // =====================================================================
    // 行号 / 自动换行
    // =====================================================================

    private void ToggleLineNumbers(object sender, RoutedEventArgs e)
    {
        // XAML 里 LineNumberCheck IsChecked="True" 会在解析阶段触发 Checked，此时 GutterCol/
        // GutterScrollViewer 还没建好 → NRE 崩溃（编辑器一开就挂）。用 IsInitialized 挡住解析期调用。
        if (!IsInitialized) return;
        var show = LineNumberCheck.IsChecked == true;
        GutterCol.Width = show ? new GridLength(36) : new GridLength(0);
        GutterScrollViewer.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ToggleWrap(object sender, RoutedEventArgs e)
    {
        _wrapEnabled = WrapCheck.IsChecked == true;
        ApplyWrapSetting();
    }

    private void ApplyWrapSetting()
    {
        if (_wrapEnabled)
        {
            Editor.Document.ClearValue(FlowDocument.PageWidthProperty); // 恢复自动跟随容器宽度换行
            Editor.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        }
        else
        {
            Editor.Document.PageWidth = 4000; // 足够宽避免自动换行，靠横向滚动条看长行
            Editor.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        }
    }

    private void UpdateGutter()
    {
        var text = ExtractPlainText();
        var lines = text.Length == 0 ? 1 : text.Count(c => c == '\n') + 1;
        var sb = new StringBuilder();
        for (var i = 1; i <= lines; i++)
        {
            if (i > 1) sb.Append('\n');
            sb.Append(i);
        }
        GutterText.Text = sb.ToString();
    }

    private void Editor_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        GutterScrollViewer.ScrollToVerticalOffset(e.VerticalOffset);
    }

    // =====================================================================
    // 页脚：行:列 / 字符数
    // =====================================================================

    private void UpdateFooter()
    {
        var text = ExtractPlainText();
        CharCountText.Text = $"{text.Length} 字符";
        var offset = GetOffset(Editor.CaretPosition);
        var (line, col) = LineColumn(offset, text);
        PosText.Text = $"行 {line}:列 {col}";
    }

    private static (int line, int col) LineColumn(int index, string text)
    {
        if (text.Length == 0 || index <= 0) return (1, 1);
        var clamped = Math.Min(index, text.Length);
        var line = 1;
        var lastLineStart = 0;
        for (var i = 0; i < clamped; i++)
            if (text[i] == '\n') { line++; lastLineStart = i + 1; }
        return (line, clamped - lastLineStart + 1);
    }

    // =====================================================================
    // 查找 / 替换
    // =====================================================================

    private void FindBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { PerformFind(false); e.Handled = true; }
    }

    private void FindNextBtn_Click(object sender, RoutedEventArgs e) => PerformFind(false);
    private void FindPrevBtn_Click(object sender, RoutedEventArgs e) => PerformFind(true);

    private void PerformFind(bool backwards)
    {
        var query = FindBox.Text;
        if (string.IsNullOrEmpty(query)) return;
        var text = ExtractPlainText();
        if (text.Length == 0) return;
        var lowerText = text.ToLowerInvariant();
        var lowerQuery = query.ToLowerInvariant();

        var selStart = GetOffset(Editor.Selection.Start);
        var selEnd = GetOffset(Editor.Selection.End);

        int foundIndex;
        if (backwards)
        {
            foundIndex = lowerText[..Math.Min(selStart, lowerText.Length)].LastIndexOf(lowerQuery, StringComparison.Ordinal);
            if (foundIndex < 0) foundIndex = lowerText.LastIndexOf(lowerQuery, StringComparison.Ordinal); // 回绕
        }
        else
        {
            var from = Math.Min(selEnd, lowerText.Length);
            var idx = lowerText[from..].IndexOf(lowerQuery, StringComparison.Ordinal);
            foundIndex = idx >= 0 ? idx + from : lowerText.IndexOf(lowerQuery, StringComparison.Ordinal); // 回绕
        }
        if (foundIndex < 0) { SystemSounds.Beep.Play(); return; }
        SelectRange(foundIndex, query.Length);
    }

    private void SelectRange(int start, int length)
    {
        var s = FindPointerAtOffset(start);
        var e = FindPointerAtOffset(start + length);
        Editor.Selection.Select(s, e);
        Editor.Focus();
        UpdateFooter();
    }

    private void ReplaceOneBtn_Click(object sender, RoutedEventArgs e)
    {
        var query = FindBox.Text;
        if (string.IsNullOrEmpty(query)) return;
        var text = ExtractPlainText();
        var selStart = GetOffset(Editor.Selection.Start);
        var selEnd = GetOffset(Editor.Selection.End);
        var selected = selEnd > selStart && selEnd <= text.Length ? text[selStart..selEnd] : "";
        if (string.Equals(selected, query, StringComparison.OrdinalIgnoreCase))
        {
            var replaced = text[..selStart] + ReplaceBox.Text + text[selEnd..];
            _isLoadingDocument = true;
            RebuildDocument(replaced);
            _isLoadingDocument = false;
            _isDirty = true;
            DirtyText.Visibility = Visibility.Visible;
            UpdateGutter();
            var caretAfter = selStart + ReplaceBox.Text.Length;
            Editor.CaretPosition = FindPointerAtOffset(caretAfter);
        }
        PerformFind(false);
    }

    private void ReplaceAllBtn_Click(object sender, RoutedEventArgs e)
    {
        var query = FindBox.Text;
        if (string.IsNullOrEmpty(query)) return;
        var text = ExtractPlainText();
        if (text.Length == 0) return;
        string replaced;
        try
        {
            replaced = Regex.Replace(text, Regex.Escape(query), _ => ReplaceBox.Text, RegexOptions.IgnoreCase);
        }
        catch { return; }
        if (replaced == text) return;

        _isLoadingDocument = true;
        RebuildDocument(replaced);
        _isLoadingDocument = false;
        _isDirty = true;
        DirtyText.Visibility = Visibility.Visible;
        UpdateGutter();
        UpdateFooter();
    }

    // =====================================================================
    // 保存 / 关闭（脏数据二次确认）
    // =====================================================================

    private void SaveBtn_Click(object sender, RoutedEventArgs e) => SaveAction();
    private void CloseBtn_Click(object sender, RoutedEventArgs e) => RequestClose();

    /// <summary>保存。**只有远端写成功才清脏标记 / 才执行 onSuccess（关闭）**——
    /// 失败留在编辑器里、头部红字显示原因，避免静默丢数据（mac 版原来先清脏再发起保存，
    /// 远端写失败时改动就丢了）。</summary>
    private void SaveAction(Action? onSuccess = null)
    {
        var text = ExtractPlainText();
        Log.Info($"保存编辑器内容 {_filePath}（{text.Length} 字符）", "editor");
        if (OnSave == null)
        {
            _isDirty = false;
            DirtyText.Visibility = Visibility.Collapsed;
            onSuccess?.Invoke();
            return;
        }
        SetSaveStatus("保存中…", ok: null);
        OnSave.Invoke(text, err => Dispatcher.Invoke(() =>
        {
            if (err == null)
            {
                _isDirty = false;
                DirtyText.Visibility = Visibility.Collapsed;
                SetSaveStatus($"已保存 {DateTime.Now:HH:mm:ss}", ok: true);
                Log.Info($"保存成功 {_filePath}", "editor");
                onSuccess?.Invoke();
            }
            else
            {
                SetSaveStatus("保存失败：" + err, ok: false);   // 保留脏标记，不关闭
                Log.Error($"保存失败 {_filePath}: {err}", "editor");
            }
        }));
    }

    /// <summary>头部保存状态：ok=true 绿、false 红、null 中性（保存中…）。</summary>
    private void SetSaveStatus(string text, bool? ok)
    {
        SaveStatusText.Text = text;
        SaveStatusText.Foreground = ok switch
        {
            true => new SolidColorBrush(Color.FromRgb(0x34, 0xC7, 0x59)),  // 系统绿
            false => (Brush)(TryFindResource("BrushErr") ?? Brushes.Red),
            _ => (Brush)(TryFindResource("BrushMuted") ?? Brushes.Gray),
        };
    }

    private void RequestClose()
    {
        if (!_isDirty) { Close(); return; }
        var name = System.IO.Path.GetFileName(_filePath);
        var result = MessageBox.Show(this, $"是否保存对“{name}”的更改？", "文件已修改",
            MessageBoxButton.YesNoCancel, MessageBoxImage.Warning);
        switch (result)
        {
            case MessageBoxResult.Yes: SaveAction(onSuccess: Close); break;   // 只有保存成功才关
            case MessageBoxResult.No: _isDirty = false; Close(); break;
            default: break; // Cancel：不关闭
        }
    }

    private void EditorWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!_isDirty) return;
        e.Cancel = true; // 拦截默认关闭，走 RequestClose 的确认流程（它会在用户选择后再真正 Close）
        RequestClose();
    }
}
