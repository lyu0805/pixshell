using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>
/// 服务器监控仪表盘侧栏（对齐 mac UI/MonitorSidebar.swift）。
/// MainWindow 用一个 3 秒定时器执行 <see cref="MonitorCommand"/>，把输出交给 <see cref="Update"/> 解析展示。
/// </summary>
public partial class MonitorSidebar : UserControl
{
    public event Action? OnCopyIp;
    public event Action? OnSysInfo;

    public MonitorSidebar()
    {
        InitializeComponent();
        CpuBar.Kind = MetricBar.BarKind.Cpu; CpuBar.SetLabel("CPU");
        MemBar.Kind = MetricBar.BarKind.Mem; MemBar.SetLabel("内存");
        SwapBar.Kind = MetricBar.BarKind.Swap; SwapBar.SetLabel("交换");
        NetSpark.SetColor(Color.FromRgb(0x30, 0xD1, 0x58));
        PingSpark.SetColor(Color.FromRgb(0x0A, 0x84, 0xFF));
    }

    private void CopyIp_Click(object sender, RoutedEventArgs e) => OnCopyIp?.Invoke();
    private void SysInfo_Click(object sender, RoutedEventArgs e) => OnSysInfo?.Invoke();
    private void ConnToggle_Click(object sender, RoutedEventArgs e) => OnToggleConnection?.Invoke();

    /// <summary>点状态行的按钮：已连接 → 手动断开；已断开 → 重连。</summary>
    public event Action? OnToggleConnection;

    public void SetConnected(bool on, string ip)
    {
        // 红绿灯：绿=已连接 / 红=已断开（原来断开是黄色，和"警告"混淆，改成红绿灯语义）
        ConnDot.Fill = new SolidColorBrush(on ? Color.FromRgb(0x30, 0xD1, 0x58) : Color.FromRgb(0xFF, 0x45, 0x3A));
        ConnText.Text = on ? "已连接" : "已断开";
        ConnToggleBtn.Content = on ? "断开" : "连接";
        IpValue.Text = string.IsNullOrEmpty(ip) ? "-" : ip;
        if (!on)
        {
            UptimeValue.Text = "-"; LoadValue.Text = "-";
            CpuBar.SetValue(0, ""); MemBar.SetValue(0, ""); SwapBar.SetValue(0, "");
            ProcBody.Children.Clear(); DiskBody.Children.Clear();
            NetTitle.Text = "-";
        }
    }

    /// <summary>解析 KEY=value 文本(见 MonitorCommand 输出)并刷新各控件。</summary>
    public void Update(Dictionary<string, string> m)
    {
        UptimeValue.Text = m.GetValueOrDefault("uptime", "-");
        LoadValue.Text = m.GetValueOrDefault("load", "-");
        CpuBar.SetValue(ParseDouble(m.GetValueOrDefault("cpu")), "");
        if (m.TryGetValue("mem", out var mem)) { var (p, s) = SplitPct(mem); MemBar.SetValue(p, s); }
        if (m.TryGetValue("swap", out var sw)) { var (p, s) = SplitPct(sw); SwapBar.SetValue(p, s); }

        ProcBody.Children.Clear();
        var procs = (m.GetValueOrDefault("procs") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries).Take(5).ToList();
        for (int i = 0; i < procs.Count; i++)
        {
            var f = procs[i].Split('|');
            if (f.Length >= 3) ProcBody.Children.Add(ProcRow(f[0], f[1], f[2], i % 2 == 1));
        }

        DiskBody.Children.Clear();
        var disks = (m.GetValueOrDefault("disks") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries).Take(6).ToList();
        for (int i = 0; i < disks.Count; i++)
        {
            var f = disks[i].Split('|');
            if (f.Length >= 3) DiskBody.Children.Add(DiskRow(f[0], $"{f[1]}/{f[2]}", i % 2 == 1));
        }

        NetTitle.Text = m.GetValueOrDefault("netif", "-");
        if (double.TryParse(m.GetValueOrDefault("netval"), out var nv)) NetSpark.Push(nv);

        // 延迟：网关 ping。此前"延迟"整块是死的——标题写死"网关"两个字，PushPing 也从没人调用，
        // 火花线永远空白。现在监控命令里带回 pinghost/pingms，这里直接消费（与 mac 同一份数据口径）。
        var gw = m.GetValueOrDefault("pinghost", "");
        if (double.TryParse(m.GetValueOrDefault("pingms"), out var ms))
        {
            PingTitle.Text = string.IsNullOrEmpty(gw) ? $"网关 {ms:F1} ms" : $"网关 {gw} · {ms:F1} ms";
            PingSpark.Push(ms);
        }
        else
        {
            PingTitle.Text = string.IsNullOrEmpty(gw) ? "网关 -" : $"网关 {gw} · 超时";
        }
    }

    /// <summary>网关延迟(ms)推送：给外部（如 MainWindow 自己测 TCP 时延）额外喂点用。</summary>
    public void PushPing(double ms) => PingSpark.Push(ms);

    private static double ParseDouble(string? s) => double.TryParse((s ?? "").Replace("%", ""), out var d) ? d : 0;
    private static (double, string) SplitPct(string s)
    {
        var f = s.Split('|');
        var p = double.TryParse(f.ElementAtOrDefault(0), out var d) ? d : 0;
        return (p, f.ElementAtOrDefault(1) ?? "");
    }

    private static UIElement ProcRow(string mem, string cpu, string cmd, bool even)
    {
        var row = new Grid { Height = 17, Background = new SolidColorBrush(Color.FromArgb((byte)(even ? 12 : 0), 255, 255, 255)) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(52) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(42) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var mono = (FontFamily)Application.Current.Resources["FontMono"];
        var memT = new TextBlock { Text = mem, FontSize = 10, FontFamily = mono, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Foreground = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) };
        var cpuT = new TextBlock { Text = cpu, FontSize = 10, FontFamily = mono, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x45, 0x3A)) };
        Grid.SetColumn(cpuT, 1);
        var cmdT = new TextBlock { Text = cmd, FontSize = 10, FontFamily = mono, Margin = new Thickness(4, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = (Brush)Application.Current.Resources["BrushText"] };
        Grid.SetColumn(cmdT, 2);
        row.Children.Add(memT); row.Children.Add(cpuT); row.Children.Add(cmdT);
        return row;
    }

    private static UIElement DiskRow(string path, string sizeInfo, bool even)
    {
        var row = new Grid { Height = 17, Background = new SolidColorBrush(Color.FromArgb((byte)(even ? 12 : 0), 255, 255, 255)) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(82) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var mono = (FontFamily)Application.Current.Resources["FontMono"];
        var text = (Brush)Application.Current.Resources["BrushText"];
        var pT = new TextBlock { Text = path, FontSize = 10, FontFamily = mono, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = text };
        var sT = new TextBlock { Text = sizeInfo, FontSize = 10, FontFamily = mono, Margin = new Thickness(4, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center, Foreground = text };
        Grid.SetColumn(sT, 1);
        row.Children.Add(pT); row.Children.Add(sT);
        return row;
    }

    // Linux 监控一行命令：与 mac AppDelegate+Sessions.swift 的 monitorCommand 完全一致，
    // 输出 KEY=value，保证两端行为一致。
    public const string MonitorCommand = @"
echo ===mon===
awk '{printf ""uptime=%dd%dh%dm\n"",$1/86400,($1%86400)/3600,($1%3600)/60}' /proc/uptime 2>/dev/null
echo ""load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null | tr ' ' ',')""
c1=$(awk '/^cpu /{i=$5;t=0;for(x=2;x<=NF;x++)t+=$x;print i,t}' /proc/stat 2>/dev/null); sleep 1; c2=$(awk '/^cpu /{i=$5;t=0;for(x=2;x<=NF;x++)t+=$x;print i,t}' /proc/stat 2>/dev/null)
echo ""cpu=$(echo ""$c1 $c2"" | awk '{di=$3-$1;dt=$4-$2; if(dt>0)printf ""%.0f"",100-di*100/dt; else printf ""0""}')""
free -m 2>/dev/null | awk '/^Mem:/{printf ""mem=%.0f|%.1fG/%.1fG\n"",$3*100/$2,$3/1024,$2/1024}'
free -m 2>/dev/null | awk '/^Swap:/{if($2>0)printf ""swap=%.0f|%.1fG/%.1fG\n"",$3*100/$2,$3/1024,$2/1024; else printf ""swap=0|0/0\n""}'
printf ""disks=""; df -h 2>/dev/null | awk '$1 ~ /^\/dev/{printf ""%s|%s|%s;"",$6,$4,$2}'; echo
printf ""procs=""; ps aux 2>/dev/null | sed 1d | sort -rk4 | awk 'NR<=5{c=$11; sub(/.*\//,"""",c); printf ""%dM|%s|%s;"",$6/1024,$3,c}'; echo
cat /proc/net/dev 2>/dev/null | tr ':' ' ' | awk 'NR>2 && $1!=""lo"" && $1 !~ /^(docker|veth|br-)/{print ""netif=""$1; print ""netval=""$2+$10; exit}'
gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}'); [ -n ""$gw"" ] || gw=$(netstat -rn 2>/dev/null | awk '/^0.0.0.0|^default/{print $2; exit}')
if [ -n ""$gw"" ]; then echo ""pinghost=$gw""; ping -c 1 -W 1 ""$gw"" 2>/dev/null | awk -F'time=' '/time=/{split($2,a,"" "");printf ""pingms=%s\n"",a[1];exit}'; fi
";

    /// <summary>解析 ===mon=== 之后的 KEY=value 输出行（对齐 mac parseMonitor）。</summary>
    public static Dictionary<string, string> ParseMonitor(string output)
    {
        var m = new Dictionary<string, string>();
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            var eq = line.IndexOf('=');
            if (eq <= 0) continue;
            var k = line[..eq].Trim();
            var v = line[(eq + 1)..].Trim();
            if (k.Length > 0) m[k] = v;
        }
        return m;
    }
}
