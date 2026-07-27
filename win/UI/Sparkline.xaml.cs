using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PixShell.UI;

public partial class Sparkline : UserControl
{
    private readonly List<double> _values = new();
    private const int MaxPoints = 60;

    public Sparkline()
    {
        InitializeComponent();
        Line.Stroke = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
    }

    /// <summary>线条颜色（网络=绿色，延迟=accent 蓝，对齐 mac 构造参数）。</summary>
    public void SetColor(Color c) => Line.Stroke = new SolidColorBrush(c);

    public void Push(double v)
    {
        _values.Add(v);
        if (_values.Count > MaxPoints) _values.RemoveAt(0);
        Redraw();
    }

    private void Root_SizeChanged(object sender, SizeChangedEventArgs e) => Redraw();

    private void Redraw()
    {
        if (_values.Count < 2 || Root.ActualWidth <= 0 || Root.ActualHeight <= 0)
        {
            Line.Points = null;
            return;
        }
        var mn = _values.Min();
        var mx = _values.Max();
        var span = System.Math.Max(mx - mn, 1);
        var w = Root.ActualWidth;
        var h = Root.ActualHeight;
        var pts = new PointCollection();
        for (int i = 0; i < _values.Count; i++)
        {
            var x = w * i / (_values.Count - 1);
            var y = 3 + (h - 6) * (1 - (_values[i] - mn) / span); // 屏幕坐标 y 向下，翻转一下让数值大的往上
            pts.Add(new Point(x, y));
        }
        Line.Points = pts;
    }
}
