using System;
using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace PixShell.UI;

public class LatencyChart : FrameworkElement
{
    private const int Cap = 60;
    private readonly double[] _ring = new double[Cap];
    private int _count;
    private int _head;

    private readonly Pen _gridPen;
    private readonly Brush _brush;
    private readonly Brush _textBrush;
    private readonly Typeface _typeface;

    public LatencyChart()
    {
        _gridPen = new Pen(new SolidColorBrush(Color.FromArgb(0x40, 0x80, 0x80, 0x80)), 1)
        {
            DashStyle = new DashStyle(new double[] { 2, 2 }, 0)
        };
        _gridPen.Freeze();

        // Theme.accent.withAlphaComponent(0.8) - ColorAccent in WPF
        var accentColor = (Color)Application.Current.Resources["ColorAccent"];
        _brush = new SolidColorBrush(Color.FromArgb(204, accentColor.R, accentColor.G, accentColor.B));
        _brush.Freeze();

        _textBrush = new SolidColorBrush(Color.FromRgb(128, 128, 128)); // muted
        _textBrush.Freeze();

        _typeface = new Typeface(new FontFamily("Consolas"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    }

    public void Push(double val)
    {
        _ring[_head] = val;
        _head = (_head + 1) % Cap;
        if (_count < Cap) _count++;
        InvalidateVisual();
    }

    public void Clear()
    {
        _count = 0;
        _head = 0;
        InvalidateVisual();
    }

    private double At(int logical)
    {
        var start = (_count < Cap) ? 0 : _head;
        return _ring[(start + logical) % Cap];
    }

    private string FormatLabel(double v)
    {
        return v.ToString("0");
    }

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);

        if (_count == 0) return;

        double w = ActualWidth;
        double h = ActualHeight;
        if (w < 10 || h < 10) return;

        double mx = 10; // minimum 10ms
        for (int i = 0; i < _count; i++)
        {
            mx = Math.Max(mx, At(i));
        }
        mx *= 1.1; // 10% headroom

        double labelWidth = 24;
        double chartX = labelWidth + 4;
        double chartW = w - chartX;

        int steps = 3;
        for (int i = 1; i <= steps; i++)
        {
            double val = mx * i / steps;
            double y = h - (h * i / steps); // Bottom to top

            // Draw line
            dc.DrawLine(_gridPen, new Point(chartX, y), new Point(w, y));

            // Draw label
            var text = FormatLabel(val);
#pragma warning disable CS0618
            var ft = new FormattedText(
                text,
                CultureInfo.CurrentCulture,
                FlowDirection.LeftToRight,
                _typeface,
                9,
                _textBrush,
                VisualTreeHelper.GetDpi(this).PixelsPerDip);
#pragma warning restore CS0618
            
            ft.TextAlignment = TextAlignment.Right;
            ft.MaxTextWidth = labelWidth;
            dc.DrawText(ft, new Point(0, y - ft.Height / 2));
        }

        double unit = chartW / Cap;
        double barW = Math.Max(unit * 0.85, 1);
        double gap = unit * 0.15;
        double maxH = h * 0.95;

        for (int i = 0; i < _count; i++)
        {
            double x = chartX + i * (barW + gap);
            double barH = maxH * (At(i) / mx);

            if (barH > 0)
            {
                dc.DrawRectangle(_brush, null, new Rect(x, h - barH, barW, Math.Max(1, barH)));
            }
        }
    }
}
