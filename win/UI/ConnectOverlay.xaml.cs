using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace PixShell.UI;

/// <summary>
/// 连接动画（覆盖终端区）。对齐 mac UI/ConnectOverlay.swift。
/// 生命周期：连接开始 <see cref="Begin"/> → shell 打开 <see cref="Succeed"/> 淡出 → 失败 <see cref="Fail"/>。
/// </summary>
public partial class ConnectOverlay : UserControl
{
    /// <summary>分步文案（对齐真实 SSH 流程的观感；不是真进度，只表达"在动"）。</summary>
    private static readonly string[] Steps = { "正在建立 TCP 连接…", "SSH 握手…", "身份认证…", "打开会话…" };

    private readonly DispatcherTimer _stepTimer = new() { Interval = TimeSpan.FromMilliseconds(900) };
    private int _stepIndex;

    public ConnectOverlay()
    {
        InitializeComponent();
        _stepTimer.Tick += (_, _) =>
        {
            _stepIndex = Math.Min(_stepIndex + 1, Steps.Length - 1);
            StepText.Text = Steps[_stepIndex];
        };
    }

    public void Begin(string title)
    {
        _stepIndex = 0;
        TitleText.Text = title;
        StepText.Text = Steps[0];
        StepText.Foreground = (Brush)Application.Current.Resources["BrushMuted"];
        PulseCore.Fill = (Brush)Application.Current.Resources["BrushAccent"];
        PulseRing.Opacity = 0.35;
        Opacity = 1;
        Visibility = Visibility.Visible;
        StartAnimations();
        _stepTimer.Start();
    }

    /// <summary>连上了：绿点一闪即淡出。</summary>
    public void Succeed()
    {
        if (Visibility != Visibility.Visible) return;
        _stepTimer.Stop();
        StepText.Text = "已连接";
        StepText.Foreground = new SolidColorBrush(Color.FromRgb(0x30, 0xD1, 0x58));
        StopPulse(ok: true);
        FadeOut(TimeSpan.FromMilliseconds(280));
    }

    /// <summary>失败：红字提示后淡出（密码重试框由调用方弹）。</summary>
    public void Fail(string reason)
    {
        if (Visibility != Visibility.Visible) return;
        _stepTimer.Stop();
        StepText.Text = reason;
        StepText.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x45, 0x3A));
        StopPulse(ok: false);
        FadeOut(TimeSpan.FromMilliseconds(900));
    }

    public void HideNow()
    {
        _stepTimer.Stop();
        StopPulse(ok: false);
        Visibility = Visibility.Collapsed;
    }

    private void StartAnimations()
    {
        // 外圈：0.45→1.0 放大同时淡出，无限循环
        var scale = new DoubleAnimation(0.45, 1.0, TimeSpan.FromMilliseconds(1350))
        { RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        PulseScale.BeginAnimation(ScaleTransform.ScaleXProperty, scale);
        PulseScale.BeginAnimation(ScaleTransform.ScaleYProperty, scale);
        var fade = new DoubleAnimation(0.55, 0.0, TimeSpan.FromMilliseconds(1350))
        { RepeatBehavior = RepeatBehavior.Forever };
        PulseRing.BeginAnimation(OpacityProperty, fade);

        // 进度条高亮块左右滑动
        var slide = new DoubleAnimation(-70, 220, TimeSpan.FromMilliseconds(1100))
        { RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } };
        BarShift.BeginAnimation(TranslateTransform.XProperty, slide);
    }

    private void StopPulse(bool ok)
    {
        PulseScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        PulseScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        PulseRing.BeginAnimation(OpacityProperty, null);
        BarShift.BeginAnimation(TranslateTransform.XProperty, null);
        PulseRing.Opacity = 0;
        PulseCore.Fill = new SolidColorBrush(ok ? Color.FromRgb(0x30, 0xD1, 0x58) : Color.FromRgb(0xFF, 0x45, 0x3A));
    }

    private void FadeOut(TimeSpan delay)
    {
        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(250)) { BeginTime = delay };
        fade.Completed += (_, _) => { Visibility = Visibility.Collapsed; Opacity = 1; };
        BeginAnimation(OpacityProperty, fade);
    }
}
