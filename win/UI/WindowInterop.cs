using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace PixShell.UI;

public static class WindowInterop
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;

    public static void ApplyBackdrop(Window window, bool isDark)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;

        // 原生标题栏/系统菜单/DWM 边框的深浅必须跟 UI 主题一致，
        // 否则浅色/水墨 UI 会套上系统暗色描边（“淡色主题暗色边框”）。
        int trueValue = 1;
        int falseValue = 0;
        int darkVal = isDark ? trueValue : falseValue;

        // Windows 11 / 10 20H1+
        if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkVal, sizeof(int)) != 0)
        {
            // Windows 10 1903
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref darkVal, sizeof(int));
        }

        // Mica：深色/浅色都开，靠上面的 immersive dark mode 决定色调。
        // 2 = DWMSBT_MAINWINDOW (Mica)
        int backdropType = 2;
        DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdropType, sizeof(int));
    }
}
