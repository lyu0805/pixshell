using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>
/// 单条指标进度条。缓存 brush、跳过无变化写入，减轻 3s 监控 tick 分配（Win10 jank）。
/// </summary>
public partial class MetricBar : UserControl
{
    public enum BarKind { Cpu, Mem, Swap, Disk }

    public BarKind Kind { get; set; } = BarKind.Cpu;

    private double _lastPct = double.NaN;
    private string _lastText = "";
    private string _lastPctLabel = "";
    private int _lastBand = -1;

    private static readonly LinearGradientBrush[][] Frozen = new LinearGradientBrush[4][];
    private static bool _brushesReady;

    public MetricBar()
    {
        InitializeComponent();
        EnsureBrushes();
    }

    public void SetLabel(string label)
    {
        LabelText.Text = label ?? "";
    }

    private static void EnsureBrushes()
    {
        if (_brushesReady) return;
        for (int k = 0; k < 4; k++)
            Frozen[k] = new LinearGradientBrush[3];

        for (int k = 0; k < 4; k++)
        {
            for (int band = 0; band < 3; band++)
            {
                Color ca, cb;
                if (band >= 2) { ca = Color.FromRgb(0xFF, 0x45, 0x3A); cb = Color.FromRgb(0xFF, 0x69, 0x64); }
                else if (band == 1) { ca = Color.FromRgb(0xFF, 0xD6, 0x0A); cb = Color.FromRgb(0xFF, 0x9F, 0x0A); }
                else
                {
                    switch (k)
                    {
                        case 0: // Cpu
                            ca = Color.FromRgb(0x30, 0xD1, 0x58); cb = Color.FromRgb(0x64, 0xD2, 0xFF); break;
                        case 1: // Mem
                            ca = Color.FromRgb(0x30, 0xD1, 0x58); cb = Color.FromRgb(0xBF, 0x5A, 0xF2); break;
                        case 2: // Swap
                            ca = Color.FromRgb(0x30, 0xD1, 0x58); cb = Color.FromRgb(0xFF, 0x9F, 0x0A); break;
                        default: // Disk
                            ca = Color.FromRgb(0x0A, 0x84, 0xFF); cb = Color.FromRgb(0x64, 0xD2, 0xFF); break;
                    }
                }
                var br = new LinearGradientBrush(ca, cb, 0);
                br.Freeze();
                Frozen[k][band] = br;
            }
        }
        _brushesReady = true;
    }

    public void SetValue(double pct, string sizeText)
    {
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        var text = sizeText ?? "";
        var band = pct >= 90 ? 2 : pct >= 75 ? 1 : 0;
        var kind = Kind switch
        {
            BarKind.Cpu => 0,
            BarKind.Mem => 1,
            BarKind.Swap => 2,
            _ => 3,
        };

        var pctLabel = $"{pct:0}%";
        if (!double.IsNaN(_lastPct)
            && System.Math.Abs(pct - _lastPct) < 0.5
            && text == _lastText
            && band == _lastBand
            && pctLabel == _lastPctLabel)
            return;

        _lastPct = pct;
        _lastText = text;
        _lastBand = band;
        _lastPctLabel = pctLabel;

        var rest = 100 - pct;
        if (rest < 0) rest = 0;
        FillCol.Width = new GridLength(pct, GridUnitType.Star);
        RestCol.Width = new GridLength(rest <= 0 ? 0.0001 : rest, GridUnitType.Star);
        SizeText.Text = text;
        PctText.Text = pctLabel;
        EnsureBrushes();
        Fill.Background = Frozen[kind][band];
    }
}
