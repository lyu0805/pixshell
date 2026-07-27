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

        // Apply Dark Mode for titlebar/context menus if any native ones exist
        int trueValue = 1;
        int falseValue = 0;
        int darkVal = isDark ? trueValue : falseValue;
        
        // Try Windows 11 / 10 20H1+
        if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkVal, sizeof(int)) != 0)
        {
            // Try Windows 10 1903
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref darkVal, sizeof(int));
        }

        // Apply Mica Backdrop (Windows 11 22H2+)
        // 2 = DWMSBT_MAINWINDOW (Mica)
        // 3 = DWMSBT_TRANSIENTWINDOW (Acrylic)
        // 4 = DWMSBT_TABBEDWINDOW (Mica Alt)
        int backdropType = 2; // Mica
        DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdropType, sizeof(int));
    }
}
