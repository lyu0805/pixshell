using System;
using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace PixShell.UI;

public class NetworkChart : FrameworkElement
{
    private const int Cap = 60;
    private readonly double[] _rxRing = new double[Cap];
    private readonly double[] _txRing = new double[Cap];
    private int _count;
    private int _head;

    private readonly Pen _gridPen;
    private readonly Brush _rxBrush;
    private readonly Brush _txBrush;
    private readonly Brush _textBrush;
    private readonly Typeface _typeface;

    public NetworkChart()
    {
        _gridPen = new Pen(new SolidColorBrush(Color.FromArgb(0x40, 0x80, 0x80, 0x80)), 1)
        {
            DashStyle = new DashStyle(new double[] { 2, 2 }, 0)
        };
        _gridPen.Freeze();

        // Theme.c("#30d158").withAlphaComponent(0.6) - Green for RX (down)
        _rxBrush = new SolidColorBrush(Color.FromArgb(153, 0x30, 0xD1, 0x58));
        _rxBrush.Freeze();

        // Theme.c("#ff9f0a").withAlphaComponent(0.6) - Orange for TX (up)
        _txBrush = new SolidColorBrush(Color.FromArgb(153, 0xFF, 0x9F, 0x0A));
        _txBrush.Freeze();

        _textBrush = new SolidColorBrush(Color.FromRgb(128, 128, 128)); // muted
        _textBrush.Freeze();

        _typeface = new Typeface(new FontFamily("Consolas"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    }

    public void Push(double rx, double tx)
    {
        _rxRing[_head] = rx;
        _txRing[_head] = tx;
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

    private double RxAt(int logical)
    {
        var start = (_count < Cap) ? 0 : _head;
        return _rxRing[(start + logical) % Cap];
    }

    private double TxAt(int logical)
    {
        var start = (_count < Cap) ? 0 : _head;
        return _txRing[(start + logical) % Cap];
    }

    private string FormatLabel(double v)
    {
        if (v < 1000) return $"{(int)v}";
        if (v < 1000_000) return (v / 1000).ToString("0.1", CultureInfo.InvariantCulture).Replace(".0", "") + "K";
        if (v < 1000_000_000) return (v / 1000_000).ToString("0.1", CultureInfo.InvariantCulture).Replace(".0", "") + "M";
        return (v / 1000_000_000).ToString("0.1", CultureInfo.InvariantCulture).Replace(".0", "") + "G";
    }

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);

        if (_count == 0) return;

        double w = ActualWidth;
        double h = ActualHeight;
        if (w < 10 || h < 10) return;

        double mx = 1;
        for (int i = 0; i < _count; i++)
        {
            mx = Math.Max(mx, Math.Max(RxAt(i), TxAt(i)));
        }
        mx *= 1.1; // 10% headroom

        double labelWidth = 32;
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
            double rxH = maxH * (RxAt(i) / mx);
            double txH = maxH * (TxAt(i) / mx);

            if (txH > 0)
            {
                dc.DrawRectangle(_txBrush, null, new Rect(x, h - txH, barW, Math.Max(1, txH)));
            }
            if (rxH > 0)
            {
                dc.DrawRectangle(_rxBrush, null, new Rect(x, h - rxH, barW, Math.Max(1, rxH)));
            }
        }
    }
}
