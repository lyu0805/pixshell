using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace PixShell
{
    // WindowStyle=None + WindowChrome 的最大化 / 最小尺寸修正。
    // 1) 无边框最大化：Win32 默认比工作区更大，会盖任务栏、把右上角 ✕ 顶出屏幕。
    // 2) 最小尺寸：一旦 handled=true 接管 WM_GETMINMAXINFO，必须自己写 ptMinTrackSize，
    //    否则 200% DPI 下窗口可被缩到裁掉 历史/发送/▾ 和顶栏关闭键（用户报缩放重叠）。
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
                ApplyMinMaxInfo(hwnd, lParam);
                handled = true;
            }
            return IntPtr.Zero;
        }

        private void ApplyMinMaxInfo(IntPtr hwnd, IntPtr lParam)
        {
            var mmi = Marshal.PtrToStructure<MINMAXINFO>(lParam);

            // 物理像素最小跟踪尺寸：WPF MinWidth/MinHeight 是 DIP，Win32 要像素。
            double dipMinW = MinWidth > 0 ? MinWidth : 720;
            double dipMinH = MinHeight > 0 ? MinHeight : 500;
            double scaleX = 1.0, scaleY = 1.0;
            try
            {
                var src = PresentationSource.FromVisual(this);
                if (src?.CompositionTarget != null)
                {
                    var m = src.CompositionTarget.TransformToDevice;
                    scaleX = m.M11;
                    scaleY = m.M22;
                }
                else
                {
                    // 源尚未就绪时用窗口 DPI
                    int dpi = GetDpiForWindow(hwnd);
                    if (dpi > 0) { scaleX = dpi / 96.0; scaleY = dpi / 96.0; }
                }
            }
            catch { /* keep 1.0 */ }

            mmi.ptMinTrackSize.X = Math.Max(1, (int)Math.Ceiling(dipMinW * scaleX));
            mmi.ptMinTrackSize.Y = Math.Max(1, (int)Math.Ceiling(dipMinH * scaleY));

            IntPtr monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            if (monitor != IntPtr.Zero)
            {
                var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
                if (GetMonitorInfo(monitor, ref info))
                {
                    RECT work = info.rcWork, mon = info.rcMonitor;
                    mmi.ptMaxPosition.X = work.left - mon.left;
                    mmi.ptMaxPosition.Y = work.top - mon.top;
                    mmi.ptMaxSize.X = work.right - work.left;
                    mmi.ptMaxSize.Y = work.bottom - work.top;
                    // 最小不能超过工作区
                    if (mmi.ptMinTrackSize.X > mmi.ptMaxSize.X) mmi.ptMinTrackSize.X = mmi.ptMaxSize.X;
                    if (mmi.ptMinTrackSize.Y > mmi.ptMaxSize.Y) mmi.ptMinTrackSize.Y = mmi.ptMaxSize.Y;
                }
            }

            Marshal.StructureToPtr(mmi, lParam, true);
        }

        private const int MONITOR_DEFAULTTONEAREST = 0x00000002;
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr handle, int flags);
        [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
        [DllImport("user32.dll")] private static extern int GetDpiForWindow(IntPtr hwnd);

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
