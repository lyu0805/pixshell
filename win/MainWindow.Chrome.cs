using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace PixShell
{
    // WindowStyle=None + WindowChrome 的最大化修正。
    // 无边框窗口最大化时，Win32 默认让窗口比显示器工作区更大：会盖住任务栏，
    // 顶栏（含右上角 最小化/最大化/关闭 按钮）被推到屏幕外裁掉。
    // 这里挂 WM_GETMINMAXINFO，把最大化的尺寸/位置钳制到「当前显示器工作区」（自动避让任务栏）。
    // mac 版是原生窗口无此问题；这是 Windows 无边框自绘标题栏必须补的一课。
    public partial class MainWindow
    {
        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);
            (PresentationSource.FromVisual(this) as HwndSource)?.AddHook(ChromeWndProc);
        }

        private const int WM_GETMINMAXINFO = 0x0024;

        private IntPtr ChromeWndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == WM_GETMINMAXINFO)
            {
                ClampMaximizeToWorkArea(hwnd, lParam);
                handled = true;
            }
            return IntPtr.Zero;
        }

        private static void ClampMaximizeToWorkArea(IntPtr hwnd, IntPtr lParam)
        {
            var mmi = Marshal.PtrToStructure<MINMAXINFO>(lParam);
            IntPtr monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            if (monitor != IntPtr.Zero)
            {
                var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
                if (GetMonitorInfo(monitor, ref info))
                {
                    RECT work = info.rcWork, mon = info.rcMonitor;
                    // 位置相对于显示器左上（多显示器/非零原点也正确）
                    mmi.ptMaxPosition.X = work.left - mon.left;
                    mmi.ptMaxPosition.Y = work.top - mon.top;
                    mmi.ptMaxSize.X = work.right - work.left;
                    mmi.ptMaxSize.Y = work.bottom - work.top;
                    Marshal.StructureToPtr(mmi, lParam, true);
                }
            }
        }

        private const int MONITOR_DEFAULTTONEAREST = 0x00000002;
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr handle, int flags);
        [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)]
        private struct MINMAXINFO { public POINT ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize; }
        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int left, top, right, bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }
    }
}
