using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace PixShell.UI;

/// <summary>
/// 迷你折线：环形缓冲 + 复用 PointCollection，避免每 3s new 分配（Win10 监控侧栏 jank）。
/// </summary>
public partial class Sparkline : UserControl
{
    private const int Cap = 60;
    private readonly double[] _ring = new double[Cap];
    private int _count;
    private int _head; // next write index
    private readonly PointCollection _pts = new();

    public Sparkline()
    {
        InitializeComponent();
    }

    public void SetColor(Color c)
    {
        var br = new SolidColorBrush(c);
        br.Freeze();
        Line.Stroke = br;
    }

    public void Push(double v)
    {
        _ring[_head] = v;
        _head = (_head + 1) % Cap;
        if (_count < Cap) _count++;
        Redraw();
    }

    public void Clear()
    {
        _count = 0;
        _head = 0;
        _pts.Clear();
        Line.Points = _pts;
    }

    private void Root_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_count >= 2) Redraw();
    }

    private void Redraw()
    {
        if (_count < 2 || ActualWidth < 4 || ActualHeight < 4)
        {
            if (_pts.Count > 0)
            {
                _pts.Clear();
                Line.Points = _pts;
            }
            return;
        }
        double mn = double.MaxValue, mx = double.MinValue;
        for (int i = 0; i < _count; i++)
        {
            var v = At(i);
            if (v < mn) mn = v;
            if (v > mx) mx = v;
        }
        var span = mx - mn;
        if (span < 1e-9) span = 1;
        var w = ActualWidth > 0 ? ActualWidth : (Root?.ActualWidth ?? 0);
        var h = ActualHeight > 0 ? ActualHeight : (Root?.ActualHeight ?? 0);
        if (w < 4 || h < 4) return;
        _pts.Clear();
        for (int i = 0; i < _count; i++)
        {
            var x = w * i / (_count - 1);
            var y = 3 + (h - 6) * (1 - (At(i) - mn) / span);
            _pts.Add(new Point(x, y));
        }
        Line.Points = _pts;
    }

    private double At(int logical)
    {
        // logical 0 = oldest
        var start = (_count < Cap) ? 0 : _head;
        return _ring[(start + logical) % Cap];
    }
}
