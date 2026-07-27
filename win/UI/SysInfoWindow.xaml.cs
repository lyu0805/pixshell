using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using PixShell.Logging;
using PixShell.Monitor;

namespace PixShell.UI;

/// <summary>
/// 结构化系统信息弹窗：exec 一段采集命令，把 KEY=value 文本解析成卡片/表格展示。
/// 对齐 mac UI/SysInfoPanel.swift + Monitor/SysInfoParser.swift（字段/命令均 1:1 移植）。
/// </summary>
public partial class SysInfoWindow : Window
{
    /// <summary>采集命令：busybox ash 安全（无 bashism/local/数组），输出简单 KEY=value 行。
    /// 与 mac 版 SysInfoPanel.command 逐字节一致（唯一区别是 Swift 三引号字符串的转义已还原）。</summary>
    public const string Command = """
    HN=`hostname 2>/dev/null || uname -n 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null`
    echo "hostname=${HN:-}"
    DISTRO=""
    if [ -f /etc/openwrt_release ]; then
      DISTRO=`awk -F"'" '/DISTRIB_DESCRIPTION/{print $2; exit}' /etc/openwrt_release 2>/dev/null`
      [ -z "$DISTRO" ] && DISTRO=`awk -F"'" '/DISTRIB_ID/{id=$2} /DISTRIB_RELEASE/{r=$2} END{if(id!="")print id" "r}' /etc/openwrt_release 2>/dev/null`
    elif [ -f /etc/os-release ]; then
      DISTRO=`awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null`
    fi
    echo "distro=${DISTRO:-}"
    echo "kernel=`uname -r 2>/dev/null`"
    echo "arch=`uname -m 2>/dev/null`"
    if [ -f /proc/uptime ]; then
      U=`cut -d. -f1 /proc/uptime 2>/dev/null`
      D=`expr $U / 86400 2>/dev/null`
      H=`expr \( $U % 86400 \) / 3600 2>/dev/null`
      M=`expr \( $U % 3600 \) / 60 2>/dev/null`
      echo "uptime=${D}d${H}h${M}m"
    else
      echo "uptime="
    fi
    if [ -f /proc/loadavg ]; then
      LA=`cat /proc/loadavg 2>/dev/null`
      set -- $LA
      echo "load=$1,$2,$3"
    else
      echo "load="
    fi
    IP=""
    if command -v ip >/dev/null 2>&1; then
      IP=`ip -o -4 addr show br-lan 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'`
      if [ -z "$IP" ]; then
        IP=`ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -v '^127\.' | grep -E '^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^192\.168\.' | head -n1`
      fi
    fi
    echo "ip=${IP:-}"
    CPU_MODEL=`awk -F: '/^model name/{gsub(/^[ \t]+/,"",$2);print $2;exit} /^Hardware/{gsub(/^[ \t]+/,"",$2);print $2;exit} /^cpu model/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
    echo "cpu_model=${CPU_MODEL:-}"
    CPU_CORES=`grep -c '^processor' /proc/cpuinfo 2>/dev/null`
    if [ -z "$CPU_CORES" ] || [ "$CPU_CORES" = "0" ]; then CPU_CORES=`nproc 2>/dev/null`; fi
    echo "cpu_cores=${CPU_CORES:-}"
    CPU_MHZ=`awk -F: '/^cpu MHz/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
    echo "cpu_mhz=${CPU_MHZ:-}"
    CPU_CACHE=`awk -F: '/^cache size/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
    echo "cpu_cache=${CPU_CACHE:-}"
    CPU_BOGO=`awk -F: '/^[Bb]ogo[Mm][Ii][Pp][Ss]/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
    echo "cpu_bogomips=${CPU_BOGO:-}"
    S1=`grep '^cpu ' /proc/stat 2>/dev/null`
    sleep 1
    S2=`grep '^cpu ' /proc/stat 2>/dev/null`
    if [ -n "$S1" ] && [ -n "$S2" ]; then
      set -- $S1
      U1=$2; N1=$3; SY1=$4; ID1=$5; IO1=$6; IRQ1=$7; SIRQ1=$8; ST1=$9
      set -- $S2
      U2=$2; N2=$3; SY2=$4; ID2=$5; IO2=$6; IRQ2=$7; SIRQ2=$8; ST2=$9
      awk -v u1=$U1 -v n1=$N1 -v s1=$SY1 -v i1=$ID1 -v w1=$IO1 -v q1=$IRQ1 -v r1=$SIRQ1 -v t1=$ST1 \
          -v u2=$U2 -v n2=$N2 -v s2=$SY2 -v i2=$ID2 -v w2=$IO2 -v q2=$IRQ2 -v r2=$SIRQ2 -v t2=$ST2 '
      BEGIN{
        du=u2-u1; dn=n2-n1; ds=s2-s1; di=i2-i1; dw=w2-w1; dq=q2-q1; dr=r2-r1; dst=t2-t1
        tot = du+dn+ds+di+dw+dq+dr+dst
        if(tot<=0) tot=1
        printf "cpu_busy=%.1f\n", (tot-di)*100/tot
        printf "cpu_user=%.1f\n", (du+dn)*100/tot
        printf "cpu_system=%.1f\n", ds*100/tot
        printf "cpu_idle=%.1f\n", di*100/tot
        printf "cpu_iowait=%.1f\n", dw*100/tot
      }'
    else
      echo "cpu_busy="
      echo "cpu_user="
      echo "cpu_system="
      echo "cpu_idle="
      echo "cpu_iowait="
    fi
    awk '
      /^MemTotal:/{t=$2+0}
      /^MemAvailable:/{a=$2+0}
      /^MemFree:/{f=$2+0}
      /^Buffers:/{b=$2+0}
      /^Cached:/{c=$2+0}
      /^SReclaimable:/{s=$2+0}
      /^SwapTotal:/{st=$2+0}
      /^SwapFree:/{sf=$2+0}
      END{
        if(t>0){
          if(a<=0) a=f+b+c+s
          u=t-a; if(u<0) u=0
          pct=int(u*100/t+0.5)
          printf "mem_pct=%d\n", pct
          printf "mem_used_mb=%d\n", int(u/1024)
          printf "mem_total_mb=%d\n", int(t/1024)
        } else {
          print "mem_pct="
          print "mem_used_mb="
          print "mem_total_mb="
        }
        if(st>0){
          su=st-sf; if(su<0) su=0
          sp=int(su*100/st+0.5)
          printf "swap_pct=%d\n", sp
          printf "swap_used_mb=%d\n", int(su/1024)
          printf "swap_total_mb=%d\n", int(st/1024)
        } else {
          print "swap_pct=0"
          print "swap_used_mb=0"
          print "swap_total_mb=0"
        }
      }
    ' /proc/meminfo 2>/dev/null
    for NDIR in /sys/class/net/*; do
      [ -d "$NDIR" ] || continue
      NAME=`basename "$NDIR"`
      [ "$NAME" = "lo" ] && continue
      MAC=`cat "$NDIR/address" 2>/dev/null`
      RXTX=`awk -v want="$NAME:" 'index($1,want)==1{print $2" "$10}' /proc/net/dev 2>/dev/null`
      set -- $RXTX
      RX=$1; TX=$2
      IFIP=""
      if command -v ip >/dev/null 2>&1; then
        IFIP=`ip -o -4 addr show "$NAME" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'`
      fi
      printf 'net_row=%s\t%s\t%s\t%s\t%s\n' "$NAME" "${IFIP:-}" "${MAC:-}" "${RX:-0}" "${TX:-0}"
    done
    df -h 2>/dev/null | awk 'NR>1 {
      fs=$1
      if(fs ~ /^(tmpfs|devtmpfs|sysfs)$/) next
      if($5 ~ /%$/){
        size=$2; used=$3; avail=$4; pct=$5; mnt=$6
        for(i=7;i<=NF;i++) mnt=mnt" "$i
      } else next
      print mnt"|"size"|"used"|"avail"|"pct"|"fs
    }' | awk -F'|' '!seen[$1]++ {printf "disk_row=%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6}'
    """;

    /// <summary>拉取远端系统信息的回调（MainWindow 注入：ExecAsync(Command)）。</summary>
    public Func<Task<string>>? OnRefresh;

    public SysInfoWindow()
    {
        InitializeComponent();
        ShowPlaceholder("采集中…");
    }

    private async void RefreshBtn_Click(object sender, RoutedEventArgs e) => await Reload();
    private void CloseBtn_Click(object sender, RoutedEventArgs e) => Close();

    /// <summary>调用方（MainWindow）在窗口打开后调用一次触发首次采集。</summary>
    public async Task Reload()
    {
        Log.Info("刷新系统信息", "ui");
        ShowPlaceholder("采集中…");
        if (OnRefresh == null) return;
        var text = await OnRefresh();
        Dispatcher.Invoke(() => ShowText(text));
    }

    private void ShowText(string text)
    {
        var trimmed = (text ?? "").Trim();
        if (trimmed.Length == 0)
        {
            ShowPlaceholder("采集失败或无输出");
            return;
        }
        var info = SysInfoParser.Parse(text!);
        BuildCards(info);
    }

    private void ShowPlaceholder(string text)
    {
        CardsPanel.Children.Clear();
        CardsPanel.Children.Add(new TextBlock
        {
            Text = text, FontSize = 13,
            Foreground = (Brush)Application.Current.Resources["BrushMuted"],
            Margin = new Thickness(4),
        });
    }

    // =====================================================================
    // 卡片构建
    // =====================================================================
    private void BuildCards(SysInfoParser.SysInfo info)
    {
        CardsPanel.Children.Clear();
        CardsPanel.Children.Add(BasicCard(info));
        CardsPanel.Children.Add(CpuCard(info));
        CardsPanel.Children.Add(MemCard(info));
        if (info.Net.Count > 0) CardsPanel.Children.Add(NetCard(info.Net));
        if (info.Disks.Count > 0) CardsPanel.Children.Add(DiskCard(info.Disks));
    }

    private static string Str(string? v) => string.IsNullOrEmpty(v) ? "-" : v;

    private Border Card(params UIElement[] children)
    {
        var stack = new StackPanel { Orientation = Orientation.Vertical };
        foreach (var c in children) stack.Children.Add(c);
        return new Border
        {
            Background = (Brush)Application.Current.Resources["BrushBg2"],
            BorderBrush = (Brush)Application.Current.Resources["BrushBorder"],
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)Application.Current.Resources["RadiusMd"],
            Padding = new Thickness(14, 12, 14, 12),
            Margin = new Thickness(0, 0, 0, 12),
            Child = stack,
        };
    }

    private TextBlock CardTitle(string text) => new()
    {
        Text = text, FontSize = 13, FontWeight = FontWeights.Bold,
        Foreground = (Brush)Application.Current.Resources["BrushText"],
        Margin = new Thickness(0, 0, 0, 6),
    };

    private UIElement LabelRow(string k, string v)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 3) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var kl = new TextBlock { Text = k, FontSize = 11.5, Foreground = (Brush)Application.Current.Resources["BrushMuted"] };
        var vl = new TextBlock
        {
            Text = v, FontSize = 11.5, FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            Foreground = (Brush)Application.Current.Resources["BrushText"], TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(kl, 0);
        Grid.SetColumn(vl, 1);
        row.Children.Add(kl); row.Children.Add(vl);
        return row;
    }

    private Border BasicCard(SysInfoParser.SysInfo info) => Card(
        CardTitle("基本"),
        LabelRow("主机名", Str(info.Hostname)),
        LabelRow("发行版", Str(info.Distro)),
        LabelRow("内核", Str(info.Kernel)),
        LabelRow("架构", Str(info.Arch)),
        LabelRow("运行时长", Str(info.Uptime)),
        LabelRow("负载", Str(info.Load)),
        LabelRow("主 IP", Str(info.Ip)));

    private Border CpuCard(SysInfoParser.SysInfo info)
    {
        var cpu = info.Cpu;
        var rows = new List<UIElement>
        {
            CardTitle("CPU"),
            LabelRow("型号", Str(cpu.Model)),
            LabelRow("核心数", cpu.Cores?.ToString() ?? "-"),
        };
        if (cpu.Mhz != null) rows.Add(LabelRow("频率", $"{cpu.Mhz} MHz"));
        if (cpu.Cache != null) rows.Add(LabelRow("缓存", cpu.Cache));
        if (cpu.Bogomips != null) rows.Add(LabelRow("BogoMIPS", cpu.Bogomips));
        if (cpu.BusyPct is { } busy)
        {
            var bar = new MetricBar { Kind = MetricBar.BarKind.Cpu, Margin = new Thickness(0, 4, 0, 4) };
            bar.SetLabel("CPU");
            bar.SetValue(busy, "");
            rows.Add(bar);
            var parts = new List<string>();
            if (cpu.UserPct is { } u) parts.Add($"用户 {u:0.0}%");
            if (cpu.SystemPct is { } s) parts.Add($"系统 {s:0.0}%");
            if (cpu.IdlePct is { } i) parts.Add($"空闲 {i:0.0}%");
            if (cpu.IowaitPct is { } w) parts.Add($"等待 {w:0.0}%");
            var detail = string.Join("  ", parts);
            if (!string.IsNullOrEmpty(detail))
                rows.Add(new TextBlock { Text = detail, FontSize = 10.5, FontFamily = (FontFamily)Application.Current.Resources["FontMono"], Foreground = (Brush)Application.Current.Resources["BrushMuted"] });
        }
        return Card(rows.ToArray());
    }

    private Border MemCard(SysInfoParser.SysInfo info)
    {
        var rows = new List<UIElement> { CardTitle("内存 · 交换") };
        if (info.MemPct is { } mp)
        {
            var bar = new MetricBar { Kind = MetricBar.BarKind.Mem, Margin = new Thickness(0, 2, 0, 4) };
            bar.SetLabel("内存"); bar.SetValue(mp, "");
            rows.Add(bar);
            rows.Add(LabelRow("内存", $"{info.MemUsedMb ?? 0} / {info.MemTotalMb ?? 0} MB"));
        }
        else rows.Add(LabelRow("内存", "-"));
        if (info.SwapPct is { } sp)
        {
            var bar = new MetricBar { Kind = MetricBar.BarKind.Swap, Margin = new Thickness(0, 6, 0, 4) };
            bar.SetLabel("交换"); bar.SetValue(sp, "");
            rows.Add(bar);
            rows.Add(LabelRow("交换", $"{info.SwapUsedMb ?? 0} / {info.SwapTotalMb ?? 0} MB"));
        }
        else rows.Add(LabelRow("交换", "-"));
        return Card(rows.ToArray());
    }

    private UIElement TableHeader(string[] cols, double[] widths)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
        for (int i = 0; i < cols.Length; i++)
            row.Children.Add(new TextBlock
            {
                Text = cols[i], Width = widths[i], FontSize = 10.5, FontWeight = FontWeights.SemiBold,
                Foreground = (Brush)Application.Current.Resources["BrushMuted"],
            });
        return row;
    }

    private StackPanel TableRow(string[] cols, double[] widths)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 1, 0, 1) };
        for (int i = 0; i < cols.Length; i++)
            row.Children.Add(new TextBlock
            {
                Text = cols[i], Width = i < widths.Length ? widths[i] : 80, FontSize = 10.5,
                FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
                Foreground = (Brush)Application.Current.Resources["BrushText"], TextTrimming = TextTrimming.CharacterEllipsis,
            });
        return row;
    }

    private Border NetCard(System.Collections.Generic.List<SysInfoParser.NetRow> rows)
    {
        var views = new List<UIElement>
        {
            CardTitle("网卡"),
            TableHeader(new[] { "网卡", "IP", "MAC", "收/发" }, new double[] { 70, 110, 130, 140 }),
        };
        foreach (var r in rows)
        {
            var rx = SysInfoParser.FormatBytes(r.RxBytes);
            var tx = SysInfoParser.FormatBytes(r.TxBytes);
            views.Add(TableRow(new[] { r.Name, Str(r.Ip), Str(r.Mac), $"{rx} / {tx}" }, new double[] { 70, 110, 130, 140 }));
        }
        return Card(views.ToArray());
    }

    private Border DiskCard(System.Collections.Generic.List<SysInfoParser.DiskRow> rows)
    {
        var views = new List<UIElement>
        {
            CardTitle("磁盘"),
            TableHeader(new[] { "挂载点", "容量", "已用", "可用", "使用率" }, new double[] { 140, 70, 70, 70, 110 }),
        };
        foreach (var r in rows)
        {
            var row = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 1, 0, 1) };
            var text = TableRow(new[] { r.Mount, Str(r.Size), Str(r.Used), Str(r.Avail) }, new double[] { 140, 70, 70, 70 });
            var bar = new MetricBar { Kind = MetricBar.BarKind.Disk, Width = 130 };
            bar.SetLabel(""); bar.SetValue(r.Pct ?? 0, "");
            row.Children.Add(text); row.Children.Add(bar);
            views.Add(row);
        }
        return Card(views.ToArray());
    }
}
