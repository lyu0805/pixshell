using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PixShell.Logging;

namespace PixShell.UI;

/// <summary>
/// 与**本机 CLI agent** 对话的面板（挂在 SFTP 面板左栏，与「本地文件」互为两种模式）。
/// 对齐 mac UI/AgentChatView.swift。
///
/// 用途：一边看着远端目录，一边让本机 agent 帮忙想命令/解释报错/生成脚本，不用切出去开另一个终端。
/// 工作目录取当前本地路径，agent 因此能看到你正在浏览的那批文件。
///
/// 走**非交互一次性调用**（`claude -p` / `codex exec`），不维持长驻会话：一次问答一个进程，
/// 好取消、不会留半死不活的子进程。代价是没有多轮上下文，所以把最近几轮拼进 prompt 当简易上下文。
///
/// 纯代码构建（不配 XAML）：控件不多，为它单开一套 XAML 不划算，与 ToolResultWindow 同样的取舍。
/// </summary>
public sealed class AgentChatView : UserControl
{
    private sealed record Agent(string Key, string Display, string Exe, Func<string, string[]> Argv);

    /// <summary>支持的本机 agent。新增一个只改这张表。</summary>
    private static readonly Agent[] Agents =
    {
        new("claude", "Claude", "claude", p => new[] { "-p", p }),
        new("codex", "Codex", "codex", p => new[] { "exec", p }),
    };

    private readonly ComboBox _agentBox = new() { FontSize = 11, Margin = new Thickness(0, 0, 6, 0) };
    private readonly TextBlock _cwdLabel = new() { FontSize = 10, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBox _transcript = new()
    {
        IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true,
        BorderThickness = new Thickness(0), Background = Brushes.Transparent,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, FontSize = 11, Padding = new Thickness(6),
    };
    private readonly TextBox _input = new() { FontSize = 11 };
    private readonly Button _sendBtn = new() { Content = "发送", Width = 52, FontSize = 11 };
    private readonly ProgressBar _spinner = new()
    {
        IsIndeterminate = true, Height = 2, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 2, 0, 0),
    };

    private Process? _running;
    private readonly List<(string Role, string Text)> _history = new();
    private const int HistoryKeep = 6;

    private string _workingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    /// <summary>工作目录（= SFTP 面板当前本地路径）。宿主切目录时更新它。</summary>
    public string WorkingDirectory
    {
        get => _workingDirectory;
        set { _workingDirectory = value; _cwdLabel.Text = value; }
    }

    public AgentChatView()
    {
        var muted = (Brush)Application.Current.Resources["BrushMuted"];
        var text = (Brush)Application.Current.Resources["BrushText"];
        _cwdLabel.Foreground = muted;
        _cwdLabel.FontFamily = (FontFamily)Application.Current.Resources["FontMono"];
        _cwdLabel.Text = WorkingDirectory;
        _cwdLabel.ToolTip = "agent 的工作目录（跟随左栏本地路径）";
        _transcript.Foreground = text;
        _transcript.FontFamily = (FontFamily)Application.Current.Resources["FontMono"];

        // 本机没装的 agent 直接置灰，别让用户点了才发现
        foreach (var a in Agents)
        {
            var found = Which(a.Exe) != null;
            _agentBox.Items.Add(new ComboBoxItem
            {
                Content = found ? a.Display : a.Display + "（未安装）",
                Tag = a.Key, IsEnabled = found,
            });
        }
        var firstUsable = Agents.ToList().FindIndex(a => Which(a.Exe) != null);
        _agentBox.SelectedIndex = firstUsable >= 0 ? firstUsable : 0;

        _input.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; Send(); } };
        _sendBtn.Click += (_, _) => Send();

        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 2) };
        DockPanel.SetDock(_agentBox, Dock.Left);
        head.Children.Add(_agentBox);
        head.Children.Add(new TextBlock());   // 占位

        var box = new Border
        {
            Background = (Brush)Application.Current.Resources["BrushBg2"],
            BorderBrush = (Brush)Application.Current.Resources["BrushBorder"],
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(7),
            Child = _transcript,
        };

        var inputRow = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };
        DockPanel.SetDock(_sendBtn, Dock.Right);
        _sendBtn.Margin = new Thickness(6, 0, 0, 0);
        inputRow.Children.Add(_sendBtn);
        inputRow.Children.Add(_input);

        var root = new DockPanel { Margin = new Thickness(4) };
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(_cwdLabel, Dock.Top);
        DockPanel.SetDock(_spinner, Dock.Top);
        DockPanel.SetDock(inputRow, Dock.Bottom);
        root.Children.Add(head);
        root.Children.Add(_cwdLabel);
        root.Children.Add(_spinner);
        root.Children.Add(inputRow);
        root.Children.Add(box);
        Content = root;

        if (Agents.All(a => Which(a.Exe) == null))
        {
            Append("系统", "本机没找到 claude / codex 命令。装好并确保在 PATH 里就能用了。");
            _input.IsEnabled = false; _sendBtn.IsEnabled = false;
        }
        else
        {
            Append("系统", "工作目录 = 左栏本地路径。一次一问一答（非交互模式）。");
        }
    }

    // ── 发送 / 取消 ─────────────────────────────────────────────────────
    private void Send()
    {
        if (_running != null)   // 正在跑就当"停止"用
        {
            Log.Info($"用户取消 agent 调用 pid={_running.Id}", "agent");
            try { _running.Kill(entireProcessTree: true); } catch { }
            _running = null;
            FinishRunning();
            Append("系统", "已取消。");
            return;
        }
        var q = _input.Text.Trim();
        if (q.Length == 0) return;
        var agent = SelectedAgent();
        if (agent == null) return;

        _input.Text = "";
        Append("我", q);
        _history.Add(("user", q));
        var prompt = BuildPrompt(q);
        Log.Info($"agent 提问 {agent.Display} cwd={WorkingDirectory} prompt={prompt.Length} 字", "agent");
        StartRunning();

        _ = Task.Run(() =>
        {
            var outText = RunAgent(agent, prompt, WorkingDirectory, p => _running = p);
            Dispatcher.Invoke(() =>
            {
                FinishRunning();
                var shown = string.IsNullOrWhiteSpace(outText) ? "（没有输出）" : outText.Trim();
                Log.Info($"agent 返回 {agent.Display} {shown.Length} 字" +
                         (string.IsNullOrWhiteSpace(outText) ? "（空！检查 agent 是否需要登录/额度）" : ""), "agent");
                Append(agent.Display, shown);
                _history.Add(("assistant", shown));
                if (_history.Count > HistoryKeep) _history.RemoveRange(0, _history.Count - HistoryKeep);
            });
        });
    }

    /// <summary>把「你可以操作本软件」的说明 + 最近几轮拼成 prompt。
    /// 一次性调用没有服务端会话，上下文只能这么带。</summary>
    private string BuildPrompt(string q)
    {
        var sb = new StringBuilder();
        sb.AppendLine(Bridge.AgentCLI.PromptPreamble()).AppendLine();
        var prior = _history.Take(_history.Count - 1).ToList();   // 最后一条就是本次提问
        if (prior.Count > 0)
        {
            sb.AppendLine("以下是我们之前的对话，供你参考上下文：");
            foreach (var h in prior) sb.AppendLine((h.Role == "user" ? "我：" : "你：") + h.Text);
            sb.AppendLine();
        }
        sb.Append("现在的问题：").Append(q);
        return sb.ToString();
    }

    private Agent? SelectedAgent()
    {
        if (_agentBox.SelectedItem is not ComboBoxItem it || it.Tag is not string key) return null;
        var a = Agents.FirstOrDefault(x => x.Key == key);
        if (a == null) return null;
        if (Which(a.Exe) == null) { Append("系统", $"{a.Display} 没装或不在 PATH 里。"); return null; }
        return a;
    }

    private void StartRunning()
    {
        _spinner.Visibility = Visibility.Visible;
        _sendBtn.Content = "停止";
    }
    private void FinishRunning()
    {
        _running = null;
        _spinner.Visibility = Visibility.Collapsed;
        _sendBtn.Content = "发送";
    }

    private void Append(string who, string text)
    {
        if (_transcript.Text.Length > 0) _transcript.AppendText("\n");
        _transcript.AppendText(who + "\n" + text + "\n");
        _transcript.ScrollToEnd();
    }

    // ── 跑 CLI ──────────────────────────────────────────────────────────
    /// <summary>非交互调用。stdin 立刻关闭 —— agent 拿不到 tty 就不会尝试进交互模式卡住。</summary>
    private static string RunAgent(Agent agent, string prompt, string cwd, Action<Process> onStart)
    {
        var exe = Which(agent.Exe);
        if (exe == null) return $"找不到 {agent.Exe}";
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
                UseShellExecute = false, CreateNoWindow = true,
                WorkingDirectory = Directory.Exists(cwd) ? cwd : Environment.CurrentDirectory,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var a in agent.Argv(prompt)) psi.ArgumentList.Add(a);

            using var p = Process.Start(psi);
            if (p == null) { Log.Error($"agent 启动失败 {exe}", "agent"); return "启动失败"; }
            onStart(p);
            Log.Info($"agent 进程 pid={p.Id} exe={exe}", "agent");
            p.StandardInput.Close();
            var o = p.StandardOutput.ReadToEnd();
            var e = p.StandardError.ReadToEnd();
            p.WaitForExit();
            if (p.ExitCode != 0) Log.Warn($"agent 退出码 {p.ExitCode}（非 0，输出可能是错误信息）", "agent");
            return string.IsNullOrWhiteSpace(o) ? e : o;
        }
        catch (Exception ex) { Log.Error("agent 启动异常：" + ex.Message, "agent"); return "启动失败：" + ex.Message; }
    }

    /// <summary>在 PATH（含常见用户目录）里找可执行文件。
    /// GUI 进程的 PATH 通常比登录 shell 窄，得自己补几个常见安装位置。</summary>
    private static string? Which(string name)
    {
        var exts = new[] { ".cmd", ".exe", ".bat", "" };
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';').Where(d => d.Length > 0).ToList();
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        dirs.Add(Path.Combine(home, ".local", "bin"));
        dirs.Add(Path.Combine(home, "bin"));
        dirs.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"));
        foreach (var d in dirs)
        {
            foreach (var ext in exts)
            {
                try { var p = Path.Combine(d, name + ext); if (File.Exists(p)) return p; } catch { }
            }
        }
        return null;
    }
}
