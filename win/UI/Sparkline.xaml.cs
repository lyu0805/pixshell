using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace PixShell.UI;

/// <summary>
/// 迷你图：环形缓冲 + 复用 PointCollection，避免每 3s new 分配（Win10 监控侧栏 jank）。
/// BarMode=true 时画柱状矩形，false 时画折线（默认）。
/// </summary>
public partial class Sparkline : UserControl
{
    private const int Cap = 60;
    private readonly double[] _ring = new double[Cap];
    private int _count;
    private int _head;
    private readonly PointCollection _pts = new();
    private bool _barMode;

    public bool BarMode
    {
        get => _barMode;
        set
        {
            _barMode = value;
            BarCanvas.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            Line.Visibility = value ? Visibility.Collapsed : Visibility.Visible;
            Redraw();
        }
    }

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
        BarCanvas.Children.Clear();
    }

    private void Root_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_count >= 2) Redraw();
    }

    private void Redraw()
    {
        if (_count < 2 || ActualWidth < 4 || ActualHeight < 4)
        {
            if (_pts.Count > 0) { _pts.Clear(); Line.Points = _pts; }
            BarCanvas.Children.Clear();
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

        if (_barMode)
        {
            BarCanvas.Children.Clear();
            var barW = w / _count * 0.55;
            var gap = w / _count * 0.45;
            var color = (Line.Stroke as SolidColorBrush)?.Color ?? Colors.DodgerBlue;
            var fillBrush = new SolidColorBrush(Color.FromArgb(0x99, color.R, color.G, color.B));
            fillBrush.Freeze();
            var maxH = h * 0.7;
            for (int i = 0; i < _count; i++)
            {
                var val = At(i);
                var ratio = (val - mn) / span;
                var barH = maxH * ratio;
                if (barH < 1) barH = 1;
                var x = i * (barW + gap);
                var y = h - barH;
                var rect = new Rectangle
                {
                    Width = barW,
                    Height = barH,
                    Fill = fillBrush,
                    RadiusX = 1,
                    RadiusY = 1,
                };
                Canvas.SetLeft(rect, x);
                Canvas.SetTop(rect, y);
                BarCanvas.Children.Add(rect);
            }
        }
        else
        {
            _pts.Clear();
            for (int i = 0; i < _count; i++)
            {
                var x = w * i / (_count - 1);
                var y = 3 + (h - 6) * (1 - (At(i) - mn) / span);
                _pts.Add(new Point(x, y));
            }
            Line.Points = _pts;
        }
    }

    private double At(int logical)
    {
        var start = (_count < Cap) ? 0 : _head;
        return _ring[(start + logical) % Cap];
    }
}
