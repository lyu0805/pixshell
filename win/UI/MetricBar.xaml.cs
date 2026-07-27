using System.Windows.Controls;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>
/// 单条指标进度条（CPU/内存/交换）。Kind 决定 &lt;75% 时的基础渐变色，
/// 90%+/75%+ 统一变橙/红警示色，对齐 mac Bar.set(pct:size:) 的配色阶梯。
/// </summary>
public partial class MetricBar : UserControl
{
    public enum BarKind { Cpu, Mem, Swap, Disk }

    public BarKind Kind { get; set; } = BarKind.Cpu;

    public MetricBar()
    {
        InitializeComponent();
    }

    public void SetLabel(string text) => LabelText.Text = text;

    /// <summary>更新百分比(0-100)与右侧尺寸文本(如 "1.2G/3.9G")。</summary>
    public void SetValue(double pct, string sizeText)
    {
        var c = pct < 0 ? 0 : pct > 100 ? 100 : pct;
        FillCol.Width = new System.Windows.GridLength(c, System.Windows.GridUnitType.Star);
        RestCol.Width = new System.Windows.GridLength(100 - c, System.Windows.GridUnitType.Star);
        PctText.Text = $"{c:0}%";
        SizeText.Text = sizeText;

        Color a, b;
        if (c >= 90) { a = Color.FromRgb(0xFF, 0x9F, 0x0A); b = Color.FromRgb(0xFF, 0x45, 0x3A); }
        else if (c >= 75) { a = Color.FromRgb(0xFF, 0xD6, 0x0A); b = Color.FromRgb(0xFF, 0x9F, 0x0A); }
        else
        {
            switch (Kind)
            {
                case BarKind.Mem:  a = Color.FromRgb(0x64, 0xD2, 0xFF); b = Color.FromRgb(0x0A, 0x84, 0xFF); break;
                case BarKind.Swap: a = Color.FromRgb(0xBF, 0x5A, 0xF2); b = Color.FromRgb(0x5E, 0x5C, 0xE6); break;
                case BarKind.Disk: a = Color.FromRgb(0x30, 0xD1, 0x58); b = Color.FromRgb(0x0A, 0x84, 0xFF); break;
                default:           a = Color.FromRgb(0x30, 0xD1, 0x58); b = Color.FromRgb(0x64, 0xD2, 0xFF); break;
            }
        }
        Fill.Background = new LinearGradientBrush(a, b, 0);
    }
}
