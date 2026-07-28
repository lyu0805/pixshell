using System;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using PixShell.Logging;

namespace PixShell;

/// <summary>
/// 应用入口。GPU 加速策略：**优先硬件，失败可回落**。
/// 硬开硬件且无回落会在弱 GPU / 远程桌面场景花屏或黑屏，因此：
/// 1) 启动探测 RenderCapability.Tier
/// 2) 上次崩溃标记 → 强制软件渲染
/// 3) 未处理异常 / 渲染失败 → 写标记，下次启动回落
/// 4) 环境变量 PIXSHELL_RENDER=hw|sw 可手动覆盖
/// </summary>
public partial class App : Application
{
    private static string CrashFlagPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "PixShell", "render-fallback.flag");

    private static string PrefPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "PixShell", "render.json");

    /// <summary>当前是否走软件渲染（供设置页/诊断显示）。</summary>
    public static bool UsingSoftwareRender { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        // 先挂全局异常，再碰渲染模式：万一硬件路径启动就炸，能记下 flag。
        DispatcherUnhandledException += OnDispatcherCrash;
        AppDomain.CurrentDomain.UnhandledException += OnDomainCrash;

        var mode = ResolveRenderMode();
        ApplyRenderMode(mode);

        base.OnStartup(e);

        // 启动 8 秒内若仍存活且无崩溃 → 清掉「上次疑似硬件崩溃」标记
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            try
            {
                if (File.Exists(CrashFlagPath) && !UsingSoftwareRender)
                    File.Delete(CrashFlagPath);
            }
            catch { /* ignore */ }
        };
        t.Start();
    }

    private enum RenderPref { Auto, Hardware, Software }

    private static RenderPref ResolveRenderMode()
    {
        // 1) 环境变量最高优先
        var env = (Environment.GetEnvironmentVariable("PIXSHELL_RENDER") ?? "").Trim().ToLowerInvariant();
        if (env is "sw" or "software" or "soft") return RenderPref.Software;
        if (env is "hw" or "hardware" or "gpu") return RenderPref.Hardware;

        // 2) 用户偏好文件
        try
        {
            if (File.Exists(PrefPath))
            {
                var raw = File.ReadAllText(PrefPath);
                using var doc = JsonDocument.Parse(raw);
                if (doc.RootElement.TryGetProperty("mode", out var m))
                {
                    var s = m.GetString()?.ToLowerInvariant();
                    if (s is "software" or "sw") return RenderPref.Software;
                    if (s is "hardware" or "hw") return RenderPref.Hardware;
                }
            }
        }
        catch { /* 配置坏了当 Auto */ }

        // 3) 上次启动疑似因硬件渲染崩溃 → 本轮强制软件
        try
        {
            if (File.Exists(CrashFlagPath))
            {
                Log.Warn("检测到上次渲染崩溃标记，本轮回落软件渲染", "ui");
                return RenderPref.Software;
            }
        }
        catch { }

        return RenderPref.Auto;
    }

    private static void ApplyRenderMode(RenderPref pref)
    {
        try
        {
            int tier = 0;
            try { tier = RenderCapability.Tier >> 16; } catch { tier = 0; }

            bool forceSw = pref == RenderPref.Software;
            bool forceHw = pref == RenderPref.Hardware;

            // Auto：Tier==0（无 GPU / 远程桌面弱）→ 软件；否则硬件
            bool useSw = forceSw || (!forceHw && tier <= 0);

            if (useSw)
            {
                RenderOptions.ProcessRenderMode = System.Windows.Interop.RenderMode.SoftwareOnly;
                UsingSoftwareRender = true;
                Log.Info($"WPF 渲染=软件兜底 (pref={pref}, Tier={tier})", "ui");
            }
            else
            {
                // Default = 允许硬件；**不要**在无兜底时强写死 Hardware 且禁止回落
                RenderOptions.ProcessRenderMode = System.Windows.Interop.RenderMode.Default;
                UsingSoftwareRender = false;
                Log.Info($"WPF 渲染=硬件优先 (pref={pref}, Tier={tier}；崩溃将写回落标记)", "ui");
            }
        }
        catch (Exception ex)
        {
            // 设置渲染模式本身失败 → 绝不抛死，记日志继续（系统默认）
            UsingSoftwareRender = true;
            try { Log.Warn("设置渲染模式失败，沿用系统默认: " + ex.Message, "ui"); } catch { }
        }
    }

    /// <summary>设置页/诊断可调：持久化偏好并提示重启生效。</summary>
    public static void SaveRenderPreference(string mode /* auto|hardware|software */)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(PrefPath)!);
            File.WriteAllText(PrefPath, JsonSerializer.Serialize(new { mode }));
            // 清崩溃标记，让用户手动选硬件时有机会再试
            if (mode is "hardware" or "hw" or "auto")
            {
                try { if (File.Exists(CrashFlagPath)) File.Delete(CrashFlagPath); } catch { }
            }
            Log.Info($"渲染偏好已保存 mode={mode}（重启生效）", "ui");
        }
        catch (Exception ex) { Log.Warn("保存渲染偏好失败: " + ex.Message, "ui"); }
    }

    private void OnDispatcherCrash(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MarkCrashIfGpuRelated(e.Exception);
        // 不设 Handled：让现有错误路径继续；只负责写标记
    }

    private static void OnDomainCrash(object sender, UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception ex) MarkCrashIfGpuRelated(ex);
    }

    private static void MarkCrashIfGpuRelated(Exception ex)
    {
        if (UsingSoftwareRender) return; // 已经是软件，再标也没意义
        try
        {
            var msg = (ex.Message + " " + ex.GetType().FullName + " " + ex.StackTrace).ToLowerInvariant();
            // D3D / DXGI / MIL (Media Integration Layer) / 显卡相关关键字
            bool gpuish =
                msg.Contains("d3d") || msg.Contains("dxgi") || msg.Contains("direct3d") ||
                msg.Contains("render") && (msg.Contains("failed") || msg.Contains("device")) ||
                msg.Contains("milcore") || msg.Contains("warp") ||
                msg.Contains("0x887a") || // DXGI_ERROR
                msg.Contains("0x8898") || // D3DERR
                msg.Contains("gpu") || msg.Contains("video memory") ||
                msg.Contains("out of memory") && msg.Contains("display");
            // 保守：任何启动 8 秒内的未处理异常也标（定时器清标前）—— 花屏/黑屏常伴随早崩
            bool early = (DateTime.UtcNow - _startedUtc).TotalSeconds < 8;
            if (gpuish || early)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(CrashFlagPath)!);
                File.WriteAllText(CrashFlagPath,
                    $"{DateTime.UtcNow:o}\n{ex.GetType().FullName}: {ex.Message}\n");
                Log.Warn("已写渲染回落标记，下次启动将走软件渲染", "ui");
            }
        }
        catch { /* 崩溃路径绝不能再抛 */ }
    }

    private static readonly DateTime _startedUtc = DateTime.UtcNow;
}
