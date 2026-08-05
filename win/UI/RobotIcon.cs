using System.Windows;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>
/// 机器人图标（坞里「对话」按钮用），对齐 mac UI/RobotIcon.swift。
///
/// 为什么自己画：Segoe MDL2 里没有合适的机器人字形；emoji 🤖 是彩色的，跟不了主题。
/// 这里画成**几何图形**并用 <c>SetResourceReference</c> 绑定 BrushText，
/// 四套主题切换时自动跟随，不用为每套主题各准备一张图。
/// </summary>
public static class RobotIcon
{
    /// <summary>返回一个可直接塞进 Button.Content 的机器人图形。</summary>
    public static UIElement Make(double size = 15)
    {
        var canvas = new System.Windows.Controls.Canvas { Width = size, Height = size };

        double lw = System.Math.Max(1, size * 0.085);

        // 天线：竖线 + 顶端小圆点
        var antenna = new System.Windows.Shapes.Rectangle
        {
            Width = lw, Height = size * 0.16,
            Margin = new Thickness(size / 2 - lw / 2, size * 0.06, 0, 0),
        };
        antenna.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "BrushText");
        canvas.Children.Add(antenna);

        var dotR = size * 0.075;
        var dot = new System.Windows.Shapes.Ellipse
        {
            Width = dotR * 2, Height = dotR * 2,
            Margin = new Thickness(size / 2 - dotR, 0, 0, 0),
        };
        dot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "BrushText");
        canvas.Children.Add(dot);

        // 头：圆角矩形描边（描边比实心更透气，小尺寸下更像"标志"）
        var head = new System.Windows.Shapes.Rectangle
        {
            Width = size * 0.68, Height = size * 0.46,
            RadiusX = size * 0.14, RadiusY = size * 0.14,
            StrokeThickness = lw, Fill = Brushes.Transparent,
            Margin = new Thickness(size * 0.16, size * 0.30, 0, 0),
        };
        head.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, "BrushText");
        canvas.Children.Add(head);

        // 两只眼睛
        var eyeR = size * 0.062;
        foreach (var fx in new[] { 0.26, 0.74 })
        {
            var eye = new System.Windows.Shapes.Ellipse
            {
                Width = eyeR * 2, Height = eyeR * 2,
                Margin = new Thickness(size * 0.16 + size * 0.68 * fx - eyeR, size * 0.49, 0, 0),
            };
            eye.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "BrushText");
            canvas.Children.Add(eye);
        }

        // 两侧耳朵
        foreach (var (x, w) in new[] { (size * 0.13, size * 0.06), (size * 0.82, size * 0.06) })
        {
            var ear = new System.Windows.Shapes.Rectangle
            {
                Width = w, Height = size * 0.14,
                Margin = new Thickness(x, size * 0.46, 0, 0),
            };
            ear.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "BrushText");
            canvas.Children.Add(ear);
        }

        return canvas;
    }
}
