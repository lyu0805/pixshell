using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using PixShell.Logging;
using PixShell.Monitor;

namespace PixShell.UI;

/// <summary>
/// 结构化系统信息弹窗：exec 一段采集命令，把 KEY=value 文本解析成卡片/表格展示。
/// 解析字段对齐 mac Monitor/SysInfoParser.swift；采集命令按远端 OS 自动分支
/// （Linux /proc、Darwin sw_vers/sysctl、Windows PowerShell），本机/Windows 用 <see cref="WindowsCommand"/>。
/// </summary>
public partial class SysInfoWindow : Window
{
    /// <summary>
    /// 采集命令（POSIX sh，busybox ash 安全：无 bashism/local/数组）。
    /// 按 <c>OS=`uname -s`</c> 自动分支：
    /// Linux → /proc；Darwin(macOS) → sw_vers/sysctl/vm_stat/top/df；
    /// Windows(MSYS/Cygwin 或无 uname) → 回落 powershell/systeminfo。
    /// 输出统一 KEY=value（表格类 net_row/disk_row 用 TAB 分隔），供 <see cref="SysInfoParser"/> 解析。
    /// 本机 Windows 会话 / 远端 Windows OpenSSH 请用 <see cref="WindowsCommand"/>。
    /// </summary>
    public const string Command = """
OS=`uname -s 2>/dev/null`
HN=`hostname 2>/dev/null || uname -n 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null`
echo "hostname=${HN:-}"
echo "kernel=`uname -r 2>/dev/null`"
echo "arch=`uname -m 2>/dev/null`"

# ---------- helpers (POSIX) ----------
# KB → 人类可读
_humank() {
  awk -v k="$1" 'BEGIN{
    if(k+0<=0){print "0"; exit}
    v=k+0
    if(v<1024){printf "%dK", v; exit}
    v=v/1024
    if(v<1024){printf (v<10?"%.1fM":"%.0fM"), v; exit}
    v=v/1024
    if(v<1024){printf (v<10?"%.1fG":"%.0fG"), v; exit}
    v=v/1024
    printf (v<10?"%.1fT":"%.0fT"), v
  }'
}

_emit_win_ps() {
  PSBIN=""
  if command -v powershell.exe >/dev/null 2>&1; then PSBIN=powershell.exe
  elif command -v powershell >/dev/null 2>&1; then PSBIN=powershell
  elif [ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then PSBIN="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  elif [ -x "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then PSBIN="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  fi
  if [ -z "$PSBIN" ]; then
    # 极简 systeminfo / wmic 回落
    if command -v systeminfo >/dev/null 2>&1; then
      SI=`systeminfo 2>/dev/null`
      echo "$SI" | awk -F: '
        BEGIN{IGNORECASE=1}
        /^OS Name/{gsub(/^[ \t]+/,"",$2); print "distro="$2}
        /^OS Version/{gsub(/^[ \t]+/,"",$2); print "kernel="$2}
        /^System Type/{gsub(/^[ \t]+/,"",$2); print "arch="$2}
        /^System Boot Time/{gsub(/^[ \t]+/,"",$2); boot=$2}
      '
    fi
    if command -v wmic >/dev/null 2>&1; then
      wmic cpu get Name,NumberOfLogicalProcessors,MaxClockSpeed /format:list 2>/dev/null | awk -F= '
        BEGIN{IGNORECASE=1}
        /^Name=/{gsub(/\r/,"",$2); if(length($2)) print "cpu_model="$2}
        /^NumberOfLogicalProcessors=/{gsub(/\r/,"",$2); print "cpu_cores="$2}
        /^MaxClockSpeed=/{gsub(/\r/,"",$2); print "cpu_mhz="$2}
      '
      wmic OS get TotalVisibleMemorySize,FreePhysicalMemory /format:list 2>/dev/null | awk -F= '
        BEGIN{IGNORECASE=1}
        /^TotalVisibleMemorySize=/{gsub(/\r/,"",$2); t=$2+0}
        /^FreePhysicalMemory=/{gsub(/\r/,"",$2); f=$2+0}
        END{
          if(t>0){
            u=t-f; if(u<0)u=0
            printf "mem_pct=%d\nmem_used_mb=%d\nmem_total_mb=%d\n", int(u*100/t+0.5), int(u/1024), int(t/1024)
          }
        }'
    fi
    echo "load="; echo "cpu_busy="; echo "cpu_user="; echo "cpu_system="; echo "cpu_idle="; echo "cpu_iowait="
    echo "cpu_cache="; echo "cpu_bogomips="; echo "swap_pct=0"; echo "swap_used_mb=0"; echo "swap_total_mb=0"; echo "ip="; echo "uptime="
    return
  fi
  # PowerShell 采集（与 WindowsCommand 同脚本，EncodedCommand 防引号/cmd 破坏）
  "$PSBIN" -NoProfile -ExecutionPolicy Bypass -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQAnAAoAJABvAHMAPQBHAGUAdAAtAEMAaQBtAEkAbgBzAHQAYQBuAGMAZQAgAFcAaQBuADMAMgBfAE8AcABlAHIAYQB0AGkAbgBnAFMAeQBzAHQAZQBtAAoAJABjAHAAdQA9AEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8AUAByAG8AYwBlAHMAcwBvAHIAIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQAKACQAbQBlAG0AVABvAHQAYQBsAD0AWwBpAG4AdABdACgAJABvAHMALgBUAG8AdABhAGwAVgBpAHMAaQBiAGwAZQBNAGUAbQBvAHIAeQBTAGkAegBlAC8AMQAwADIANAApAAoAJABtAGUAbQBGAHIAZQBlAD0AWwBpAG4AdABdACgAJABvAHMALgBGAHIAZQBlAFAAaAB5AHMAaQBjAGEAbABNAGUAbQBvAHIAeQAvADEAMAAyADQAKQAKACQAbQBlAG0AVQBzAGUAZAA9ACQAbQBlAG0AVABvAHQAYQBsAC0AJABtAGUAbQBGAHIAZQBlAAoAJABtAGUAbQBQAGMAdAA9AGkAZgAoACQAbQBlAG0AVABvAHQAYQBsACAALQBnAHQAIAAwACkAewBbAGkAbgB0AF0AKAAkAG0AZQBtAFUAcwBlAGQAKgAxADAAMAAvACQAbQBlAG0AVABvAHQAYQBsACkAfQBlAGwAcwBlAHsAMAB9AAoAJAB1AHAAPQAoAEcAZQB0AC0ARABhAHQAZQApAC0AJABvAHMALgBMAGEAcwB0AEIAbwBvAHQAVQBwAFQAaQBtAGUACgAkAGkAcAA9ACgARwBlAHQALQBOAGUAdABJAFAAQQBkAGQAcgBlAHMAcwAgAC0AQQBkAGQAcgBlAHMAcwBGAGEAbQBpAGwAeQAgAEkAUAB2ADQAIAB8ACAAVwBoAGUAcgBlAC0ATwBiAGoAZQBjAHQAIAB7ACAAJABfAC4ASQBQAEEAZABkAHIAZQBzAHMAIAAtAG4AbwB0AGwAaQBrAGUAIAAnADEAMgA3AC4AKgAnACAALQBhAG4AZAAgACQAXwAuAFAAcgBlAGYAaQB4AE8AcgBpAGcAaQBuACAALQBuAGUAIAAnAFcAZQBsAGwASwBuAG8AdwBuACcAIAB9ACAAfAAgAFMAZQBsAGUAYwB0AC0ATwBiAGoAZQBjAHQAIAAtAEYAaQByAHMAdAAgADEAIAAtAEUAeABwAGEAbgBkAFAAcgBvAHAAZQByAHQAeQAgAEkAUABBAGQAZAByAGUAcwBzACkACgBpAGYAKAAtAG4AbwB0ACAAJABpAHAAKQB7ACAAJABpAHAAPQAoAEcAZQB0AC0ATgBlAHQASQBQAEEAZABkAHIAZQBzAHMAIAAtAEEAZABkAHIAZQBzAHMARgBhAG0AaQBsAHkAIABJAFAAdgA0ACAAfAAgAFcAaABlAHIAZQAtAE8AYgBqAGUAYwB0ACAAewAgACQAXwAuAEkAUABBAGQAZAByAGUAcwBzACAALQBuAG8AdABsAGkAawBlACAAJwAxADIANwAuACoAJwAgAH0AIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQAgAC0ARQB4AHAAYQBuAGQAUAByAG8AcABlAHIAdAB5ACAASQBQAEEAZABkAHIAZQBzAHMAKQAgAH0ACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAJwBoAG8AcwB0AG4AYQBtAGUAPQAnACAAKwAgACQAZQBuAHYAOgBDAE8ATQBQAFUAVABFAFIATgBBAE0ARQApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAZABpAHMAdAByAG8APQAnACAAKwAgACgAJABvAHMALgBDAGEAcAB0AGkAbwBuACkALgBUAHIAaQBtACgAKQAgACsAIAAnACAAJwAgACsAIAAkAG8AcwAuAFYAZQByAHMAaQBvAG4AKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAnAGsAZQByAG4AZQBsAD0AJwAgACsAIAAkAG8AcwAuAFYAZQByAHMAaQBvAG4AKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAnAGEAcgBjAGgAPQAnACAAKwAgACQAZQBuAHYAOgBQAFIATwBDAEUAUwBTAE8AUgBfAEEAUgBDAEgASQBUAEUAQwBUAFUAUgBFACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAJwB1AHAAdABpAG0AZQA9ACcAIAArACAAJAB1AHAALgBEAGEAeQBzACAAKwAgACcAZAAnACAAKwAgACQAdQBwAC4ASABvAHUAcgBzACAAKwAgACcAaAAnACAAKwAgACQAdQBwAC4ATQBpAG4AdQB0AGUAcwAgACsAIAAnAG0AJwApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAGwAbwBhAGQAPQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAaQBwAD0AJwAgACsAIAAkAGkAcAApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAYwBwAHUAXwBtAG8AZABlAGwAPQAnACAAKwAgACgAJABjAHAAdQAuAE4AYQBtAGUAKQAuAFQAcgBpAG0AKAApACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAJwBjAHAAdQBfAGMAbwByAGUAcwA9ACcAIAArACAAJABjAHAAdQAuAE4AdQBtAGIAZQByAE8AZgBMAG8AZwBpAGMAYQBsAFAAcgBvAGMAZQBzAHMAbwByAHMAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAnAGMAcAB1AF8AbQBoAHoAPQAnACAAKwAgACQAYwBwAHUALgBNAGEAeABDAGwAbwBjAGsAUwBwAGUAZQBkACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACcAYwBwAHUAXwBjAGEAYwBoAGUAPQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAGMAcAB1AF8AYgBvAGcAbwBtAGkAcABzAD0AJwAKACQAbABwAD0AMAA7ACAAdAByAHkAIAB7ACAAJABsAHAAPQBbAGQAbwB1AGIAbABlAF0AJABjAHAAdQAuAEwAbwBhAGQAUABlAHIAYwBlAG4AdABhAGcAZQAgAH0AIABjAGEAdABjAGgAIAB7ACAAJABsAHAAPQAwACAAfQAKAGkAZgAoACQAbgB1AGwAbAAgAC0AZQBxACAAJABsAHAAKQB7ACQAbABwAD0AMAB9AAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAYwBwAHUAXwBiAHUAcwB5AD0AJwAgACsAIABbAG0AYQB0AGgAXQA6ADoAUgBvAHUAbgBkACgAJABsAHAALAAxACkAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAJwBjAHAAdQBfAHUAcwBlAHIAPQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAGMAcAB1AF8AcwB5AHMAdABlAG0APQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAYwBwAHUAXwBpAGQAbABlAD0AJwAgACsAIABbAG0AYQB0AGgAXQA6ADoAUgBvAHUAbgBkACgAWwBtAGEAdABoAF0AOgA6AE0AYQB4ACgAMAAsADEAMAAwAC0AJABsAHAAKQAsADEAKQApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAGMAcAB1AF8AaQBvAHcAYQBpAHQAPQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAbQBlAG0AXwBwAGMAdAA9ACcAIAArACAAJABtAGUAbQBQAGMAdAApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAbQBlAG0AXwB1AHMAZQBkAF8AbQBiAD0AJwAgACsAIAAkAG0AZQBtAFUAcwBlAGQAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAnAG0AZQBtAF8AdABvAHQAYQBsAF8AbQBiAD0AJwAgACsAIAAkAG0AZQBtAFQAbwB0AGEAbAApAAoAJABwAGEAZwBlAFQAbwB0AGEAbAA9AFsAaQBuAHQAXQAoACQAbwBzAC4AVABvAHQAYQBsAFYAaQByAHQAdQBhAGwATQBlAG0AbwByAHkAUwBpAHoAZQAvADEAMAAyADQAKQAKACQAcABhAGcAZQBGAHIAZQBlAD0AWwBpAG4AdABdACgAJABvAHMALgBGAHIAZQBlAFYAaQByAHQAdQBhAGwATQBlAG0AbwByAHkALwAxADAAMgA0ACkACgAkAHMAdAA9AFsAbQBhAHQAaABdADoAOgBNAGEAeAAoACQAcABhAGcAZQBUAG8AdABhAGwALQAkAG0AZQBtAFQAbwB0AGEAbAAsADAAKQAKACQAcwB1AD0AWwBtAGEAdABoAF0AOgA6AE0AYQB4ACgAKAAkAHAAYQBnAGUAVABvAHQAYQBsAC0AJABwAGEAZwBlAEYAcgBlAGUAKQAtACQAbQBlAG0AVQBzAGUAZAAsADAAKQAKAGkAZgAoACQAcwB0ACAALQBnAHQAIAAwACkAewAkAHMAcAA9AFsAaQBuAHQAXQAoACQAcwB1ACoAMQAwADAALwAkAHMAdAApAH0AZQBsAHMAZQB7ACQAcwBwAD0AMAA7ACQAcwB1AD0AMAA7ACQAcwB0AD0AMAB9AAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAcwB3AGEAcABfAHAAYwB0AD0AJwAgACsAIAAkAHMAcAApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAcwB3AGEAcABfAHUAcwBlAGQAXwBtAGIAPQAnACAAKwAgACQAcwB1ACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAJwBzAHcAYQBwAF8AdABvAHQAYQBsAF8AbQBiAD0AJwAgACsAIAAkAHMAdAApAAoARwBlAHQALQBOAGUAdABBAGQAYQBwAHQAZQByACAAfAAgAFcAaABlAHIAZQAtAE8AYgBqAGUAYwB0ACAAewAgACQAXwAuAFMAdABhAHQAdQBzACAALQBlAHEAIAAnAFUAcAAnACAALQBhAG4AZAAgACQAXwAuAE4AYQBtAGUAIAAtAG4AbwB0AG0AYQB0AGMAaAAgACcATABvAG8AcABiAGEAYwBrACcAIAB9ACAAfAAgAEYAbwByAEUAYQBjAGgALQBPAGIAagBlAGMAdAAgAHsACgAgACAAJABhAD0ARwBlAHQALQBOAGUAdABJAFAAQQBkAGQAcgBlAHMAcwAgAC0ASQBuAHQAZQByAGYAYQBjAGUASQBuAGQAZQB4ACAAJABfAC4AaQBmAEkAbgBkAGUAeAAgAC0AQQBkAGQAcgBlAHMAcwBGAGEAbQBpAGwAeQAgAEkAUAB2ADQAIAAtAEUAcgByAG8AcgBBAGMAdABpAG8AbgAgAFMAaQBsAGUAbgB0AGwAeQBDAG8AbgB0AGkAbgB1AGUAIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQAgAC0ARQB4AHAAYQBuAGQAUAByAG8AcABlAHIAdAB5ACAASQBQAEEAZABkAHIAZQBzAHMACgAgACAAJABzAHQAYQB0AHMAPQBHAGUAdAAtAE4AZQB0AEEAZABhAHAAdABlAHIAUwB0AGEAdABpAHMAdABpAGMAcwAgAC0ATgBhAG0AZQAgACQAXwAuAE4AYQBtAGUAIAAtAEUAcgByAG8AcgBBAGMAdABpAG8AbgAgAFMAaQBsAGUAbgB0AGwAeQBDAG8AbgB0AGkAbgB1AGUACgAgACAAJAByAHgAPQAwADsAIAAkAHQAeAA9ADAAOwAgAGkAZgAoACQAcwB0AGEAdABzACkAewAkAHIAeAA9ACQAcwB0AGEAdABzAC4AUgBlAGMAZQBpAHYAZQBkAEIAeQB0AGUAcwA7ACAAJAB0AHgAPQAkAHMAdABhAHQAcwAuAFMAZQBuAHQAQgB5AHQAZQBzAH0ACgAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAbgBlAHQAXwByAG8AdwA9ACcAIAArACAAJABfAC4ATgBhAG0AZQAgACsAIABbAGMAaABhAHIAXQA5ACAAKwAgACQAYQAgACsAIABbAGMAaABhAHIAXQA5ACAAKwAgACQAXwAuAE0AYQBjAEEAZABkAHIAZQBzAHMAIAArACAAWwBjAGgAYQByAF0AOQAgACsAIAAkAHIAeAAgACsAIABbAGMAaABhAHIAXQA5ACAAKwAgACQAdAB4ACkACgB9AAoARwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBMAG8AZwBpAGMAYQBsAEQAaQBzAGsAIAAtAEYAaQBsAHQAZQByACAAJwBEAHIAaQB2AGUAVAB5AHAAZQA9ADMAJwAgAHwAIABGAG8AcgBFAGEAYwBoAC0ATwBiAGoAZQBjAHQAIAB7AAoAIAAgACQAcwBpAHoAZQA9ACQAXwAuAFMAaQB6AGUAOwAgACQAZgByAGUAZQA9ACQAXwAuAEYAcgBlAGUAUwBwAGEAYwBlADsAIABpAGYAKAAtAG4AbwB0ACAAJABzAGkAegBlACkAewByAGUAdAB1AHIAbgB9AAoAIAAgACQAdQBzAGUAZAA9ACQAcwBpAHoAZQAtACQAZgByAGUAZQA7ACAAJABwAGMAdAA9AFsAaQBuAHQAXQAoACQAdQBzAGUAZAAqADEAMAAwAC8AJABzAGkAegBlACkACgAgACAAJABoAHMAPQBpAGYAKAAkAHMAaQB6AGUAIAAtAGcAZQAgADEARwBCACkAewAoACcAewAwADoAMAAuACMAfQBHACcAIAAtAGYAIAAoACQAcwBpAHoAZQAvADEARwBCACkAKQB9AGUAbABzAGUAaQBmACgAJABzAGkAegBlACAALQBnAGUAIAAxAE0AQgApAHsAKAAnAHsAMAA6ADAALgAjAH0ATQAnACAALQBmACAAKAAkAHMAaQB6AGUALwAxAE0AQgApACkAfQBlAGwAcwBlAHsAKAAnAHsAMAA6ADAAfQBLACcAIAAtAGYAIAAoACQAcwBpAHoAZQAvADEASwBCACkAKQB9AAoAIAAgACQAaAB1AD0AaQBmACgAJAB1AHMAZQBkACAALQBnAGUAIAAxAEcAQgApAHsAKAAnAHsAMAA6ADAALgAjAH0ARwAnACAALQBmACAAKAAkAHUAcwBlAGQALwAxAEcAQgApACkAfQBlAGwAcwBlAGkAZgAoACQAdQBzAGUAZAAgAC0AZwBlACAAMQBNAEIAKQB7ACgAJwB7ADAAOgAwAC4AIwB9AE0AJwAgAC0AZgAgACgAJAB1AHMAZQBkAC8AMQBNAEIAKQApAH0AZQBsAHMAZQB7ACgAJwB7ADAAOgAwAH0ASwAnACAALQBmACAAKAAkAHUAcwBlAGQALwAxAEsAQgApACkAfQAKACAAIAAkAGgAZgA9AGkAZgAoACQAZgByAGUAZQAgAC0AZwBlACAAMQBHAEIAKQB7ACgAJwB7ADAAOgAwAC4AIwB9AEcAJwAgAC0AZgAgACgAJABmAHIAZQBlAC8AMQBHAEIAKQApAH0AZQBsAHMAZQBpAGYAKAAkAGYAcgBlAGUAIAAtAGcAZQAgADEATQBCACkAewAoACcAewAwADoAMAAuACMAfQBNACcAIAAtAGYAIAAoACQAZgByAGUAZQAvADEATQBCACkAKQB9AGUAbABzAGUAewAoACcAewAwADoAMAB9AEsAJwAgAC0AZgAgACgAJABmAHIAZQBlAC8AMQBLAEIAKQApAH0ACgAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAZABpAHMAawBfAHIAbwB3AD0AJwAgACsAIAAkAF8ALgBEAGUAdgBpAGMAZQBJAEQAIAArACAAWwBjAGgAYQByAF0AOQAyACAAKwAgAFsAYwBoAGEAcgBdADkAIAArACAAJABoAHMAIAArACAAWwBjAGgAYQByAF0AOQAgACsAIAAkAGgAdQAgACsAIABbAGMAaABhAHIAXQA5ACAAKwAgACQAaABmACAAKwAgAFsAYwBoAGEAcgBdADkAIAArACAAKAAkAHAAYwB0AC4AVABvAFMAdAByAGkAbgBnACgAKQAgACsAIAAnACUAJwApACAAKwAgAFsAYwBoAGEAcgBdADkAIAArACAAJABfAC4ARgBpAGwAZQBTAHkAcwB0AGUAbQApAAoAfQAKAA== 2>/dev/null
}

case "$OS" in
  Darwin)
    # ---- macOS ----
    PN=`sw_vers -productName 2>/dev/null`
    PV=`sw_vers -productVersion 2>/dev/null`
    PB=`sw_vers -buildVersion 2>/dev/null`
    if [ -n "$PB" ]; then echo "distro=${PN:-macOS} ${PV:-} ($PB)"; else echo "distro=${PN:-macOS} ${PV:-}"; fi
    BT=`sysctl -n kern.boottime 2>/dev/null | awk -F'[=,]' '{print $2}' | tr -d ' '`
    NOW=`date +%s 2>/dev/null`
    if [ -n "$BT" ] && [ -n "$NOW" ]; then
      U=`expr $NOW - $BT 2>/dev/null`
      D=`expr $U / 86400 2>/dev/null`
      H=`expr \( $U % 86400 \) / 3600 2>/dev/null`
      M=`expr \( $U % 3600 \) / 60 2>/dev/null`
      echo "uptime=${D}d${H}h${M}m"
    else
      echo "uptime="
    fi
    LA=`sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'`
    set -- $LA
    echo "load=$1,$2,$3"
    IP=""
    for IF in en0 en1 en2 en3; do
      IP=`ipconfig getifaddr $IF 2>/dev/null`
      [ -n "$IP" ] && break
    done
    [ -z "$IP" ] && IP=`ifconfig 2>/dev/null | awk '/inet / && $2!="127.0.0.1"{print $2; exit}'`
    echo "ip=${IP:-}"
    CPU_MODEL=`sysctl -n machdep.cpu.brand_string 2>/dev/null`
    [ -z "$CPU_MODEL" ] && CPU_MODEL=`sysctl -n hw.model 2>/dev/null`
    echo "cpu_model=${CPU_MODEL:-}"
    echo "cpu_cores=`sysctl -n hw.ncpu 2>/dev/null`"
    FREQ=`sysctl -n hw.cpufrequency 2>/dev/null`
    if [ -n "$FREQ" ] && [ "$FREQ" -gt 0 ] 2>/dev/null; then
      echo "cpu_mhz=`expr $FREQ / 1000000 2>/dev/null`"
    else
      echo "cpu_mhz="
    fi
    L3=`sysctl -n hw.l3cachesize 2>/dev/null`
    if [ -n "$L3" ] && [ "$L3" -gt 0 ] 2>/dev/null; then
      echo "cpu_cache=`expr $L3 / 1024 2>/dev/null` KB"
    else
      echo "cpu_cache="
    fi
    echo "cpu_bogomips="
    CPU_LINE=`top -l 2 -n 0 -s 1 2>/dev/null | grep 'CPU usage' | tail -n1`
    if [ -n "$CPU_LINE" ]; then
      echo "$CPU_LINE" | awk '{
        for(i=1;i<=NF;i++){
          if($i ~ /user/){gsub(/%/,"",$(i-1)); u=$(i-1)+0}
          if($i ~ /sys/){gsub(/%/,"",$(i-1)); s=$(i-1)+0}
          if($i ~ /idle/){gsub(/%/,"",$(i-1)); id=$(i-1)+0}
        }
        printf "cpu_busy=%.1f\ncpu_user=%.1f\ncpu_system=%.1f\ncpu_idle=%.1f\ncpu_iowait=\n", u+s, u, s, id
      }'
    else
      echo "cpu_busy="; echo "cpu_user="; echo "cpu_system="; echo "cpu_idle="; echo "cpu_iowait="
    fi
    PAGESIZE=`sysctl -n hw.pagesize 2>/dev/null`; [ -z "$PAGESIZE" ] && PAGESIZE=4096
    MEMTOTAL_B=`sysctl -n hw.memsize 2>/dev/null`
    VS=`vm_stat 2>/dev/null`
    ACTIVE=`echo "$VS" | awk '/Pages active/{gsub(/\./,"",$3); print $3+0}'`
    WIRED=`echo "$VS" | awk '/Pages wired/{gsub(/\./,"",$4); print $4+0}'`
    COMP=`echo "$VS" | awk '/Pages occupied by compressor/{gsub(/\./,"",$5); print $5+0}'`
    if [ -n "$MEMTOTAL_B" ] && [ "$MEMTOTAL_B" -gt 0 ] 2>/dev/null; then
      MEM_TOTAL_MB=`expr $MEMTOTAL_B / 1048576 2>/dev/null`
      USED_PAGES=`expr ${ACTIVE:-0} + ${WIRED:-0} + ${COMP:-0} 2>/dev/null`
      USED_B=`expr ${USED_PAGES:-0} \* $PAGESIZE 2>/dev/null`
      MEM_USED_MB=`expr ${USED_B:-0} / 1048576 2>/dev/null`
      [ "${MEM_USED_MB:-0}" -gt "${MEM_TOTAL_MB:-0}" ] 2>/dev/null && MEM_USED_MB=$MEM_TOTAL_MB
      MEM_PCT=0
      [ "${MEM_TOTAL_MB:-0}" -gt 0 ] 2>/dev/null && MEM_PCT=`expr ${MEM_USED_MB:-0} \* 100 / $MEM_TOTAL_MB 2>/dev/null`
      echo "mem_pct=${MEM_PCT:-0}"
      echo "mem_used_mb=${MEM_USED_MB:-0}"
      echo "mem_total_mb=${MEM_TOTAL_MB:-0}"
    else
      echo "mem_pct="; echo "mem_used_mb="; echo "mem_total_mb="
    fi
    SU=`sysctl -n vm.swapusage 2>/dev/null`
    if [ -n "$SU" ]; then
      TOTAL_S=`echo "$SU" | sed -n 's/.*total = \([0-9.]*\)\([A-Za-z]\).*/\1 \2/p'`
      USED_S=`echo "$SU" | sed -n 's/.*used = \([0-9.]*\)\([A-Za-z]\).*/\1 \2/p'`
      set -- $TOTAL_S; TV=$1; TU=$2
      set -- $USED_S; UV=$1; UU=$2
      _to_mb() {
        V=$1; U=$2
        case "$U" in
          M|m) echo "$V" | awk '{printf "%d",$1+0.5}' ;;
          G|g) echo "$V" | awk '{printf "%d",$1*1024+0.5}' ;;
          K|k) echo "$V" | awk '{printf "%d",$1/1024+0.5}' ;;
          *) echo "$V" | awk '{printf "%d",$1+0.5}' ;;
        esac
      }
      ST_MB=`_to_mb "$TV" "$TU"`
      SU_MB=`_to_mb "$UV" "$UU"`
      if [ -n "$ST_MB" ] && [ "$ST_MB" -gt 0 ] 2>/dev/null; then
        SP=`expr ${SU_MB:-0} \* 100 / $ST_MB 2>/dev/null`
        echo "swap_pct=${SP:-0}"
        echo "swap_used_mb=${SU_MB:-0}"
        echo "swap_total_mb=${ST_MB:-0}"
      else
        echo "swap_pct=0"; echo "swap_used_mb=0"; echo "swap_total_mb=0"
      fi
    else
      echo "swap_pct=0"; echo "swap_used_mb=0"; echo "swap_total_mb=0"
    fi
    netstat -ibn 2>/dev/null | awk 'NR>1 && $3 ~ /^<Link#/ {
      name=$1
      if(name=="lo0" || name=="lo") next
      if(name ~ /^(gif|stf|XHC|awdl|llw|utun|pktap|bridge|ap|vmnet|vmenet)/) next
      mac=$4; ibytes=$(NF-4); obytes=$(NF-1)
      printf "NET|%s|%s|%s|%s\n", name, mac, ibytes, obytes
    }' | while IFS='|' read _ NAME MAC RX TX; do
      IFIP=`ipconfig getifaddr "$NAME" 2>/dev/null`
      [ -z "$IFIP" ] && IFIP=`ifconfig "$NAME" 2>/dev/null | awk '/inet / && $2!="127.0.0.1"{print $2; exit}'`
      if [ -z "$IFIP" ] && [ "${RX:-0}" = "0" ] && [ "${TX:-0}" = "0" ]; then
        case "$NAME" in en*|eth*|wlan*|wl*) ;; *) continue ;; esac
      fi
      printf 'net_row=%s\t%s\t%s\t%s\t%s\n' "$NAME" "${IFIP:-}" "${MAC:-}" "${RX:-0}" "${TX:-0}"
    done
    df -kP 2>/dev/null | awk 'NR>1 {
      fs=$1; blocks=$2+0; used=$3+0; avail=$4+0; pct=$5; mnt=$6
      for(i=7;i<=NF;i++) mnt=mnt" "$i
      if(fs ~ /^(devfs|map|tmpfs|none)$/) next
      if(mnt ~ /^\/System\/Volumes\/(Preboot|VM|Update|xarts|iSCPreboot|Hardware)/) next
      if(mnt ~ /^\/private\/var\/vm/) next
      if(mnt ~ /MobileAsset|DVTDownloads|MetalToolchain/) next
      if(index(fs,"//")==1 && mnt ~ /^\/private\/tmp\// && mnt != "/private/tmp/win146") next
      gsub(/%/,"",pct)
      # 跳过 win146 下的 DOS 短路径挂载噪音，只保留根挂载
      if(mnt ~ /^\/private\/tmp\/win146\//) next
      printf "%s\t%d\t%d\t%d\t%s\t%s\n", mnt, blocks, used, avail, pct, fs
    }' | while IFS="$(printf '\t')" read MNT BLOCKS USED AVAIL PCT FS; do
      SZ=`_humank "$BLOCKS"`; US=`_humank "$USED"`; AV=`_humank "$AVAIL"`
      printf 'disk_row=%s\t%s\t%s\t%s\t%s%%\t%s\n' "$MNT" "$SZ" "$US" "$AV" "$PCT" "$FS"
    done
    ;;

  MINGW*|MSYS*|CYGWIN*|Windows_NT*)
    # Git Bash / MSYS / Cygwin on Windows
    [ -z "$HN" ] && HN=`cmd.exe /c hostname 2>/dev/null | tr -d '\r'`
    echo "hostname=${HN:-}"
    _emit_win_ps
    ;;

  *)
    # ---- Linux 及其他：优先 /proc；没有则尝试 Windows 回落 ----
    if [ -f /proc/meminfo ] || [ -f /proc/cpuinfo ] || [ -f /proc/uptime ]; then
      DISTRO=""
      if [ -f /etc/openwrt_release ]; then
        DISTRO=`awk -F"'" '/DISTRIB_DESCRIPTION/{print $2; exit}' /etc/openwrt_release 2>/dev/null`
        [ -z "$DISTRO" ] && DISTRO=`awk -F"'" '/DISTRIB_ID/{id=$2} /DISTRIB_RELEASE/{r=$2} END{if(id!="")print id" "r}' /etc/openwrt_release 2>/dev/null`
      elif [ -f /etc/os-release ]; then
        DISTRO=`awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null`
      fi
      echo "distro=${DISTRO:-}"
      if [ -f /proc/uptime ]; then
        U=`cut -d. -f1 /proc/uptime 2>/dev/null`
        D=`expr $U / 86400 2>/dev/null`
        H=`expr \( $U % 86400 \) / 3600 2>/dev/null`
        M=`expr \( $U % 3600 \) / 60 2>/dev/null`
        echo "uptime=${D}d${H}h${M}m"
      else
        echo "uptime="
      fi
      if [ -f /proc/loadavg ]; then
        LA=`cat /proc/loadavg 2>/dev/null`
        set -- $LA
        echo "load=$1,$2,$3"
      else
        echo "load="
      fi
      IP=""
      if command -v ip >/dev/null 2>&1; then
        IP=`ip -o -4 addr show br-lan 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'`
        if [ -z "$IP" ]; then
          IP=`ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -v '^127\.' | grep -E '^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^192\.168\.' | head -n1`
        fi
        if [ -z "$IP" ]; then
          IP=`ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -v '^127\.' | head -n1`
        fi
      fi
      echo "ip=${IP:-}"
      CPU_MODEL=`awk -F: '/^model name/{gsub(/^[ \t]+/,"",$2);print $2;exit} /^Hardware/{gsub(/^[ \t]+/,"",$2);print $2;exit} /^cpu model/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
      echo "cpu_model=${CPU_MODEL:-}"
      CPU_CORES=`grep -c '^processor' /proc/cpuinfo 2>/dev/null`
      if [ -z "$CPU_CORES" ] || [ "$CPU_CORES" = "0" ]; then CPU_CORES=`nproc 2>/dev/null`; fi
      echo "cpu_cores=${CPU_CORES:-}"
      CPU_MHZ=`awk -F: '/^cpu MHz/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
      echo "cpu_mhz=${CPU_MHZ:-}"
      CPU_CACHE=`awk -F: '/^cache size/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
      echo "cpu_cache=${CPU_CACHE:-}"
      CPU_BOGO=`awk -F: '/^[Bb]ogo[Mm][Ii][Pp][Ss]/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
      echo "cpu_bogomips=${CPU_BOGO:-}"
      S1=`grep '^cpu ' /proc/stat 2>/dev/null`
      sleep 1
      S2=`grep '^cpu ' /proc/stat 2>/dev/null`
      if [ -n "$S1" ] && [ -n "$S2" ]; then
        set -- $S1
        U1=$2; N1=$3; SY1=$4; ID1=$5; IO1=$6; IRQ1=$7; SIRQ1=$8; ST1=$9
        set -- $S2
        U2=$2; N2=$3; SY2=$4; ID2=$5; IO2=$6; IRQ2=$7; SIRQ2=$8; ST2=$9
        awk -v u1=$U1 -v n1=$N1 -v s1=$SY1 -v i1=$ID1 -v w1=$IO1 -v q1=$IRQ1 -v r1=$SIRQ1 -v t1=$ST1 \
            -v u2=$U2 -v n2=$N2 -v s2=$SY2 -v i2=$ID2 -v w2=$IO2 -v q2=$IRQ2 -v r2=$SIRQ2 -v t2=$ST2 '
        BEGIN{
          du=u2-u1; dn=n2-n1; ds=s2-s1; di=i2-i1; dw=w2-w1; dq=q2-q1; dr=r2-r1; dst=t2-t1
          tot = du+dn+ds+di+dw+dq+dr+dst
          if(tot<=0) tot=1
          printf "cpu_busy=%.1f\n", (tot-di)*100/tot
          printf "cpu_user=%.1f\n", (du+dn)*100/tot
          printf "cpu_system=%.1f\n", ds*100/tot
          printf "cpu_idle=%.1f\n", di*100/tot
          printf "cpu_iowait=%.1f\n", dw*100/tot
        }'
      else
        echo "cpu_busy="; echo "cpu_user="; echo "cpu_system="; echo "cpu_idle="; echo "cpu_iowait="
      fi
      awk '
        /^MemTotal:/{t=$2+0}
        /^MemAvailable:/{a=$2+0}
        /^MemFree:/{f=$2+0}
        /^Buffers:/{b=$2+0}
        /^Cached:/{c=$2+0}
        /^SReclaimable:/{s=$2+0}
        /^SwapTotal:/{st=$2+0}
        /^SwapFree:/{sf=$2+0}
        END{
          if(t>0){
            if(a<=0) a=f+b+c+s
            u=t-a; if(u<0) u=0
            pct=int(u*100/t+0.5)
            printf "mem_pct=%d\n", pct
            printf "mem_used_mb=%d\n", int(u/1024)
            printf "mem_total_mb=%d\n", int(t/1024)
          } else {
            print "mem_pct="
            print "mem_used_mb="
            print "mem_total_mb="
          }
          if(st>0){
            su=st-sf; if(su<0) su=0
            sp=int(su*100/st+0.5)
            printf "swap_pct=%d\n", sp
            printf "swap_used_mb=%d\n", int(su/1024)
            printf "swap_total_mb=%d\n", int(st/1024)
          } else {
            print "swap_pct=0"
            print "swap_used_mb=0"
            print "swap_total_mb=0"
          }
        }
      ' /proc/meminfo 2>/dev/null
      for NDIR in /sys/class/net/*; do
        [ -d "$NDIR" ] || continue
        NAME=`basename "$NDIR"`
        [ "$NAME" = "lo" ] && continue
        MAC=`cat "$NDIR/address" 2>/dev/null`
        RXTX=`awk -v want="$NAME:" 'index($1,want)==1{print $2" "$10}' /proc/net/dev 2>/dev/null`
        set -- $RXTX
        RX=$1; TX=$2
        IFIP=""
        if command -v ip >/dev/null 2>&1; then
          IFIP=`ip -o -4 addr show "$NAME" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'`
        fi
        printf 'net_row=%s\t%s\t%s\t%s\t%s\n' "$NAME" "${IFIP:-}" "${MAC:-}" "${RX:-0}" "${TX:-0}"
      done
      df -h 2>/dev/null | awk 'NR>1 {
        fs=$1
        if(fs ~ /^(tmpfs|devtmpfs|sysfs)$/) next
        if($5 ~ /%$/){
          size=$2; used=$3; avail=$4; pct=$5; mnt=$6
          for(i=7;i<=NF;i++) mnt=mnt" "$i
        } else next
        print mnt"|"size"|"used"|"avail"|"pct"|"fs
      }' | awk -F'|' '!seen[$1]++ {printf "disk_row=%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6}'
    else
      # 无 /proc：当作 Windows / 未知，回落 PS
      _emit_win_ps
    fi
    ;;
esac
""";

    /// <summary>
    /// 本机 Windows 会话 / 远端 Windows OpenSSH 采集命令（PowerShell）。
    /// 输出 KEY=value 与 <see cref="Command"/> 一致，可直接喂给 <see cref="SysInfoParser"/>。
    /// </summary>
    public const string WindowsCommand =
        "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQAnAAoAJABvAHMAPQBHAGUAdAAtAEMAaQBtAEkAbgBzAHQAYQBuAGMAZQAgAFcAaQBuADMAMgBfAE8AcABlAHIAYQB0AGkAbgBnAFMAeQBzAHQAZQBtAAoAJABjAHAAdQA9AEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8AUAByAG8AYwBlAHMAcwBvAHIAIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQAKACQAbQBlAG0AVABvAHQAYQBsAD0AWwBpAG4AdABdACgAJABvAHMALgBUAG8AdABhAGwAVgBpAHMAaQBiAGwAZQBNAGUAbQBvAHIAeQBTAGkAegBlAC8AMQAwADIANAApAAoAJABtAGUAbQBGAHIAZQBlAD0AWwBpAG4AdABdACgAJABvAHMALgBGAHIAZQBlAFAAaAB5AHMAaQBjAGEAbABNAGUAbQBvAHIAeQAvADEAMAAyADQAKQAKACQAbQBlAG0AVQBzAGUAZAA9ACQAbQBlAG0AVABvAHQAYQBsAC0AJABtAGUAbQBGAHIAZQBlAAoAJABtAGUAbQBQAGMAdAA9AGkAZgAoACQAbQBlAG0AVABvAHQAYQBsACAALQBnAHQAIAAwACkAewBbAGkAbgB0AF0AKAAkAG0AZQBtAFUAcwBlAGQAKgAxADAAMAAvACQAbQBlAG0AVABvAHQAYQBsACkAfQBlAGwAcwBlAHsAMAB9AAoAJAB1AHAAPQAoAEcAZQB0AC0ARABhAHQAZQApAC0AJABvAHMALgBMAGEAcwB0AEIAbwBvAHQAVQBwAFQAaQBtAGUACgAkAGkAcAA9ACgARwBlAHQALQBOAGUAdABJAFAAQQBkAGQAcgBlAHMAcwAgAC0AQQBkAGQAcgBlAHMAcwBGAGEAbQBpAGwAeQAgAEkAUAB2ADQAIAB8ACAAVwBoAGUAcgBlAC0ATwBiAGoAZQBjAHQAIAB7ACAAJABfAC4ASQBQAEEAZABkAHIAZQBzAHMAIAAtAG4AbwB0AGwAaQBrAGUAIAAnADEAMgA3AC4AKgAnACAALQBhAG4AZAAgACQAXwAuAFAAcgBlAGYAaQB4AE8AcgBpAGcAaQBuACAALQBuAGUAIAAnAFcAZQBsAGwASwBuAG8AdwBuACcAIAB9ACAAfAAgAFMAZQBsAGUAYwB0AC0ATwBiAGoAZQBjAHQAIAAtAEYAaQByAHMAdAAgADEAIAAtAEUAeABwAGEAbgBkAFAAcgBvAHAAZQByAHQAeQAgAEkAUABBAGQAZAByAGUAcwBzACkACgBpAGYAKAAtAG4AbwB0ACAAJABpAHAAKQB7ACAAJABpAHAAPQAoAEcAZQB0AC0ATgBlAHQASQBQAEEAZABkAHIAZQBzAHMAIAAtAEEAZABkAHIAZQBzAHMARgBhAG0AaQBsAHkAIABJAFAAdgA0ACAAfAAgAFcAaABlAHIAZQAtAE8AYgBqAGUAYwB0ACAAewAgACQAXwAuAEkAUABBAGQAZAByAGUAcwBzACAALQBuAG8AdABsAGkAawBlACAAJwAxADIANwAuACoAJwAgAH0AIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQAgAC0ARQB4AHAAYQBuAGQAUAByAG8AcABlAHIAdAB5ACAASQBQAEEAZABkAHIAZQBzAHMAKQAgAH0ACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAJwBoAG8AcwB0AG4AYQBtAGUAPQAnACAAKwAgACQAZQBuAHYAOgBDAE8ATQBQAFUAVABFAFIATgBBAE0ARQApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAZABpAHMAdAByAG8APQAnACAAKwAgACgAJABvAHMALgBDAGEAcAB0AGkAbwBuACkALgBUAHIAaQBtACgAKQAgACsAIAAnACAAJwAgACsAIAAkAG8AcwAuAFYAZQByAHMAaQBvAG4AKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAnAGsAZQByAG4AZQBsAD0AJwAgACsAIAAkAG8AcwAuAFYAZQByAHMAaQBvAG4AKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAnAGEAcgBjAGgAPQAnACAAKwAgACQAZQBuAHYAOgBQAFIATwBDAEUAUwBTAE8AUgBfAEEAUgBDAEgASQBUAEUAQwBUAFUAUgBFACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAJwB1AHAAdABpAG0AZQA9ACcAIAArACAAJAB1AHAALgBEAGEAeQBzACAAKwAgACcAZAAnACAAKwAgACQAdQBwAC4ASABvAHUAcgBzACAAKwAgACcAaAAnACAAKwAgACQAdQBwAC4ATQBpAG4AdQB0AGUAcwAgACsAIAAnAG0AJwApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAGwAbwBhAGQAPQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAaQBwAD0AJwAgACsAIAAkAGkAcAApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAYwBwAHUAXwBtAG8AZABlAGwAPQAnACAAKwAgACgAJABjAHAAdQAuAE4AYQBtAGUAKQAuAFQAcgBpAG0AKAApACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAJwBjAHAAdQBfAGMAbwByAGUAcwA9ACcAIAArACAAJABjAHAAdQAuAE4AdQBtAGIAZQByAE8AZgBMAG8AZwBpAGMAYQBsAFAAcgBvAGMAZQBzAHMAbwByAHMAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAnAGMAcAB1AF8AbQBoAHoAPQAnACAAKwAgACQAYwBwAHUALgBNAGEAeABDAGwAbwBjAGsAUwBwAGUAZQBkACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACcAYwBwAHUAXwBjAGEAYwBoAGUAPQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAGMAcAB1AF8AYgBvAGcAbwBtAGkAcABzAD0AJwAKACQAbABwAD0AMAA7ACAAdAByAHkAIAB7ACAAJABsAHAAPQBbAGQAbwB1AGIAbABlAF0AJABjAHAAdQAuAEwAbwBhAGQAUABlAHIAYwBlAG4AdABhAGcAZQAgAH0AIABjAGEAdABjAGgAIAB7ACAAJABsAHAAPQAwACAAfQAKAGkAZgAoACQAbgB1AGwAbAAgAC0AZQBxACAAJABsAHAAKQB7ACQAbABwAD0AMAB9AAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAYwBwAHUAXwBiAHUAcwB5AD0AJwAgACsAIABbAG0AYQB0AGgAXQA6ADoAUgBvAHUAbgBkACgAJABsAHAALAAxACkAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAJwBjAHAAdQBfAHUAcwBlAHIAPQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAGMAcAB1AF8AcwB5AHMAdABlAG0APQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAYwBwAHUAXwBpAGQAbABlAD0AJwAgACsAIABbAG0AYQB0AGgAXQA6ADoAUgBvAHUAbgBkACgAWwBtAGEAdABoAF0AOgA6AE0AYQB4ACgAMAAsADEAMAAwAC0AJABsAHAAKQAsADEAKQApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAGMAcAB1AF8AaQBvAHcAYQBpAHQAPQAnAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAbQBlAG0AXwBwAGMAdAA9ACcAIAArACAAJABtAGUAbQBQAGMAdAApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAbQBlAG0AXwB1AHMAZQBkAF8AbQBiAD0AJwAgACsAIAAkAG0AZQBtAFUAcwBlAGQAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAnAG0AZQBtAF8AdABvAHQAYQBsAF8AbQBiAD0AJwAgACsAIAAkAG0AZQBtAFQAbwB0AGEAbAApAAoAJABwAGEAZwBlAFQAbwB0AGEAbAA9AFsAaQBuAHQAXQAoACQAbwBzAC4AVABvAHQAYQBsAFYAaQByAHQAdQBhAGwATQBlAG0AbwByAHkAUwBpAHoAZQAvADEAMAAyADQAKQAKACQAcABhAGcAZQBGAHIAZQBlAD0AWwBpAG4AdABdACgAJABvAHMALgBGAHIAZQBlAFYAaQByAHQAdQBhAGwATQBlAG0AbwByAHkALwAxADAAMgA0ACkACgAkAHMAdAA9AFsAbQBhAHQAaABdADoAOgBNAGEAeAAoACQAcABhAGcAZQBUAG8AdABhAGwALQAkAG0AZQBtAFQAbwB0AGEAbAAsADAAKQAKACQAcwB1AD0AWwBtAGEAdABoAF0AOgA6AE0AYQB4ACgAKAAkAHAAYQBnAGUAVABvAHQAYQBsAC0AJABwAGEAZwBlAEYAcgBlAGUAKQAtACQAbQBlAG0AVQBzAGUAZAAsADAAKQAKAGkAZgAoACQAcwB0ACAALQBnAHQAIAAwACkAewAkAHMAcAA9AFsAaQBuAHQAXQAoACQAcwB1ACoAMQAwADAALwAkAHMAdAApAH0AZQBsAHMAZQB7ACQAcwBwAD0AMAA7ACQAcwB1AD0AMAA7ACQAcwB0AD0AMAB9AAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAcwB3AGEAcABfAHAAYwB0AD0AJwAgACsAIAAkAHMAcAApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAcwB3AGEAcABfAHUAcwBlAGQAXwBtAGIAPQAnACAAKwAgACQAcwB1ACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAJwBzAHcAYQBwAF8AdABvAHQAYQBsAF8AbQBiAD0AJwAgACsAIAAkAHMAdAApAAoARwBlAHQALQBOAGUAdABBAGQAYQBwAHQAZQByACAAfAAgAFcAaABlAHIAZQAtAE8AYgBqAGUAYwB0ACAAewAgACQAXwAuAFMAdABhAHQAdQBzACAALQBlAHEAIAAnAFUAcAAnACAALQBhAG4AZAAgACQAXwAuAE4AYQBtAGUAIAAtAG4AbwB0AG0AYQB0AGMAaAAgACcATABvAG8AcABiAGEAYwBrACcAIAB9ACAAfAAgAEYAbwByAEUAYQBjAGgALQBPAGIAagBlAGMAdAAgAHsACgAgACAAJABhAD0ARwBlAHQALQBOAGUAdABJAFAAQQBkAGQAcgBlAHMAcwAgAC0ASQBuAHQAZQByAGYAYQBjAGUASQBuAGQAZQB4ACAAJABfAC4AaQBmAEkAbgBkAGUAeAAgAC0AQQBkAGQAcgBlAHMAcwBGAGEAbQBpAGwAeQAgAEkAUAB2ADQAIAAtAEUAcgByAG8AcgBBAGMAdABpAG8AbgAgAFMAaQBsAGUAbgB0AGwAeQBDAG8AbgB0AGkAbgB1AGUAIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQAgAC0ARQB4AHAAYQBuAGQAUAByAG8AcABlAHIAdAB5ACAASQBQAEEAZABkAHIAZQBzAHMACgAgACAAJABzAHQAYQB0AHMAPQBHAGUAdAAtAE4AZQB0AEEAZABhAHAAdABlAHIAUwB0AGEAdABpAHMAdABpAGMAcwAgAC0ATgBhAG0AZQAgACQAXwAuAE4AYQBtAGUAIAAtAEUAcgByAG8AcgBBAGMAdABpAG8AbgAgAFMAaQBsAGUAbgB0AGwAeQBDAG8AbgB0AGkAbgB1AGUACgAgACAAJAByAHgAPQAwADsAIAAkAHQAeAA9ADAAOwAgAGkAZgAoACQAcwB0AGEAdABzACkAewAkAHIAeAA9ACQAcwB0AGEAdABzAC4AUgBlAGMAZQBpAHYAZQBkAEIAeQB0AGUAcwA7ACAAJAB0AHgAPQAkAHMAdABhAHQAcwAuAFMAZQBuAHQAQgB5AHQAZQBzAH0ACgAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAbgBlAHQAXwByAG8AdwA9ACcAIAArACAAJABfAC4ATgBhAG0AZQAgACsAIABbAGMAaABhAHIAXQA5ACAAKwAgACQAYQAgACsAIABbAGMAaABhAHIAXQA5ACAAKwAgACQAXwAuAE0AYQBjAEEAZABkAHIAZQBzAHMAIAArACAAWwBjAGgAYQByAF0AOQAgACsAIAAkAHIAeAAgACsAIABbAGMAaABhAHIAXQA5ACAAKwAgACQAdAB4ACkACgB9AAoARwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBMAG8AZwBpAGMAYQBsAEQAaQBzAGsAIAAtAEYAaQBsAHQAZQByACAAJwBEAHIAaQB2AGUAVAB5AHAAZQA9ADMAJwAgAHwAIABGAG8AcgBFAGEAYwBoAC0ATwBiAGoAZQBjAHQAIAB7AAoAIAAgACQAcwBpAHoAZQA9ACQAXwAuAFMAaQB6AGUAOwAgACQAZgByAGUAZQA9ACQAXwAuAEYAcgBlAGUAUwBwAGEAYwBlADsAIABpAGYAKAAtAG4AbwB0ACAAJABzAGkAegBlACkAewByAGUAdAB1AHIAbgB9AAoAIAAgACQAdQBzAGUAZAA9ACQAcwBpAHoAZQAtACQAZgByAGUAZQA7ACAAJABwAGMAdAA9AFsAaQBuAHQAXQAoACQAdQBzAGUAZAAqADEAMAAwAC8AJABzAGkAegBlACkACgAgACAAJABoAHMAPQBpAGYAKAAkAHMAaQB6AGUAIAAtAGcAZQAgADEARwBCACkAewAoACcAewAwADoAMAAuACMAfQBHACcAIAAtAGYAIAAoACQAcwBpAHoAZQAvADEARwBCACkAKQB9AGUAbABzAGUAaQBmACgAJABzAGkAegBlACAALQBnAGUAIAAxAE0AQgApAHsAKAAnAHsAMAA6ADAALgAjAH0ATQAnACAALQBmACAAKAAkAHMAaQB6AGUALwAxAE0AQgApACkAfQBlAGwAcwBlAHsAKAAnAHsAMAA6ADAAfQBLACcAIAAtAGYAIAAoACQAcwBpAHoAZQAvADEASwBCACkAKQB9AAoAIAAgACQAaAB1AD0AaQBmACgAJAB1AHMAZQBkACAALQBnAGUAIAAxAEcAQgApAHsAKAAnAHsAMAA6ADAALgAjAH0ARwAnACAALQBmACAAKAAkAHUAcwBlAGQALwAxAEcAQgApACkAfQBlAGwAcwBlAGkAZgAoACQAdQBzAGUAZAAgAC0AZwBlACAAMQBNAEIAKQB7ACgAJwB7ADAAOgAwAC4AIwB9AE0AJwAgAC0AZgAgACgAJAB1AHMAZQBkAC8AMQBNAEIAKQApAH0AZQBsAHMAZQB7ACgAJwB7ADAAOgAwAH0ASwAnACAALQBmACAAKAAkAHUAcwBlAGQALwAxAEsAQgApACkAfQAKACAAIAAkAGgAZgA9AGkAZgAoACQAZgByAGUAZQAgAC0AZwBlACAAMQBHAEIAKQB7ACgAJwB7ADAAOgAwAC4AIwB9AEcAJwAgAC0AZgAgACgAJABmAHIAZQBlAC8AMQBHAEIAKQApAH0AZQBsAHMAZQBpAGYAKAAkAGYAcgBlAGUAIAAtAGcAZQAgADEATQBCACkAewAoACcAewAwADoAMAAuACMAfQBNACcAIAAtAGYAIAAoACQAZgByAGUAZQAvADEATQBCACkAKQB9AGUAbABzAGUAewAoACcAewAwADoAMAB9AEsAJwAgAC0AZgAgACgAJABmAHIAZQBlAC8AMQBLAEIAKQApAH0ACgAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACcAZABpAHMAawBfAHIAbwB3AD0AJwAgACsAIAAkAF8ALgBEAGUAdgBpAGMAZQBJAEQAIAArACAAWwBjAGgAYQByAF0AOQAyACAAKwAgAFsAYwBoAGEAcgBdADkAIAArACAAJABoAHMAIAArACAAWwBjAGgAYQByAF0AOQAgACsAIAAkAGgAdQAgACsAIABbAGMAaABhAHIAXQA5ACAAKwAgACQAaABmACAAKwAgAFsAYwBoAGEAcgBdADkAIAArACAAKAAkAHAAYwB0AC4AVABvAFMAdAByAGkAbgBnACgAKQAgACsAIAAnACUAJwApACAAKwAgAFsAYwBoAGEAcgBdADkAIAArACAAJABfAC4ARgBpAGwAZQBTAHkAcwB0AGUAbQApAAoAfQAKAA==";

    /// <summary>
    /// 按会话/主机选择采集命令：本机或 Windows 远端用 PowerShell；其余走多 OS POSIX 脚本。
    /// </summary>
    public static string CommandFor(bool isLocal, string? osId)
    {
        if (isLocal) return WindowsCommand;
        var id = (osId ?? "").Trim().ToLowerInvariant();
        if (id.Length == 0) return Command;
        if (id is "windows" or "win" or "win32" or "win64" or "windows_nt") return WindowsCommand;
        if (id.StartsWith("win", StringComparison.Ordinal) || id.Contains("windows", StringComparison.Ordinal))
            return WindowsCommand;
        return Command;
    }

    /// <summary>拉取远端系统信息的回调（MainWindow 注入：ExecAsync(CommandFor(...))）。</summary>
    public Func<Task<string>>? OnRefresh;

    public SysInfoWindow()
    {
        InitializeComponent();
        ShowPlaceholder("采集中…");
    }

    private async void RefreshBtn_Click(object sender, RoutedEventArgs e) => await Reload();
    private void CloseBtn_Click(object sender, RoutedEventArgs e) => Close();

    /// <summary>调用方（MainWindow）在窗口打开后调用一次触发首次采集。</summary>
    public async Task Reload()
    {
        Log.Info("刷新系统信息", "ui");
        ShowPlaceholder("采集中…");
        if (OnRefresh == null) return;
        var text = await OnRefresh();
        Dispatcher.Invoke(() => ShowText(text));
    }

    private void ShowText(string text)
    {
        var trimmed = (text ?? "").Trim();
        if (trimmed.Length == 0)
        {
            ShowPlaceholder("采集失败或无输出");
            return;
        }
        var info = SysInfoParser.Parse(text!);
        BuildCards(info);
    }

    private void ShowPlaceholder(string text)
    {
        CardsPanel.Children.Clear();
        CardsPanel.Children.Add(new TextBlock
        {
            Text = text, FontSize = 13,
            Foreground = (Brush)Application.Current.Resources["BrushMuted"],
            Margin = new Thickness(4),
        });
    }

    // =====================================================================
    // 卡片构建
    // =====================================================================
    private void BuildCards(SysInfoParser.SysInfo info)
    {
        CardsPanel.Children.Clear();
        CardsPanel.Children.Add(BasicCard(info));
        CardsPanel.Children.Add(CpuCard(info));
        CardsPanel.Children.Add(MemCard(info));
        if (info.Net.Count > 0) CardsPanel.Children.Add(NetCard(info.Net));
        if (info.Disks.Count > 0) CardsPanel.Children.Add(DiskCard(info.Disks));
    }

    private static string Str(string? v) => string.IsNullOrEmpty(v) ? "-" : v;

    private Border Card(params UIElement[] children)
    {
        var stack = new StackPanel { Orientation = Orientation.Vertical };
        foreach (var c in children) stack.Children.Add(c);
        return new Border
        {
            Background = (Brush)Application.Current.Resources["BrushBg2"],
            BorderBrush = (Brush)Application.Current.Resources["BrushBorder"],
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)Application.Current.Resources["RadiusMd"],
            Padding = new Thickness(14, 12, 14, 12),
            Margin = new Thickness(0, 0, 0, 12),
            Child = stack,
        };
    }

    private TextBlock CardTitle(string text) => new()
    {
        Text = text, FontSize = 13, FontWeight = FontWeights.Bold,
        Foreground = (Brush)Application.Current.Resources["BrushText"],
        Margin = new Thickness(0, 0, 0, 6),
    };

    private UIElement LabelRow(string k, string v)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 3) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var kl = new TextBlock { Text = k, FontSize = 11.5, Foreground = (Brush)Application.Current.Resources["BrushMuted"] };
        var vl = new TextBlock
        {
            Text = v, FontSize = 11.5, FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            Foreground = (Brush)Application.Current.Resources["BrushText"], TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(kl, 0);
        Grid.SetColumn(vl, 1);
        row.Children.Add(kl); row.Children.Add(vl);
        return row;
    }

    private Border BasicCard(SysInfoParser.SysInfo info) => Card(
        CardTitle("基本"),
        LabelRow("主机名", Str(info.Hostname)),
        LabelRow("发行版", Str(info.Distro)),
        LabelRow("内核", Str(info.Kernel)),
        LabelRow("架构", Str(info.Arch)),
        LabelRow("运行时长", Str(info.Uptime)),
        LabelRow("负载", Str(info.Load)),
        LabelRow("主 IP", Str(info.Ip)));

    private Border CpuCard(SysInfoParser.SysInfo info)
    {
        var cpu = info.Cpu;
        var rows = new List<UIElement>
        {
            CardTitle("CPU"),
            LabelRow("型号", Str(cpu.Model)),
            LabelRow("核心数", cpu.Cores?.ToString() ?? "-"),
        };
        if (cpu.Mhz != null) rows.Add(LabelRow("频率", $"{cpu.Mhz} MHz"));
        if (cpu.Cache != null) rows.Add(LabelRow("缓存", cpu.Cache));
        if (cpu.Bogomips != null) rows.Add(LabelRow("BogoMIPS", cpu.Bogomips));
        if (cpu.BusyPct is { } busy)
        {
            var bar = new MetricBar { Kind = MetricBar.BarKind.Cpu, Margin = new Thickness(0, 4, 0, 4) };
            bar.SetLabel("CPU");
            bar.SetValue(busy, "");
            rows.Add(bar);
            var parts = new List<string>();
            if (cpu.UserPct is { } u) parts.Add($"用户 {u:0.0}%");
            if (cpu.SystemPct is { } s) parts.Add($"系统 {s:0.0}%");
            if (cpu.IdlePct is { } i) parts.Add($"空闲 {i:0.0}%");
            if (cpu.IowaitPct is { } w) parts.Add($"等待 {w:0.0}%");
            var detail = string.Join("  ", parts);
            if (!string.IsNullOrEmpty(detail))
                rows.Add(new TextBlock { Text = detail, FontSize = 10.5, FontFamily = (FontFamily)Application.Current.Resources["FontMono"], Foreground = (Brush)Application.Current.Resources["BrushMuted"] });
        }
        return Card(rows.ToArray());
    }

    private Border MemCard(SysInfoParser.SysInfo info)
    {
        var rows = new List<UIElement> { CardTitle("内存 · 交换") };
        if (info.MemPct is { } mp)
        {
            var bar = new MetricBar { Kind = MetricBar.BarKind.Mem, Margin = new Thickness(0, 2, 0, 4) };
            bar.SetLabel("内存"); bar.SetValue(mp, "");
            rows.Add(bar);
            rows.Add(LabelRow("内存", $"{info.MemUsedMb ?? 0} / {info.MemTotalMb ?? 0} MB"));
        }
        else rows.Add(LabelRow("内存", "-"));
        if (info.SwapPct is { } sp)
        {
            var bar = new MetricBar { Kind = MetricBar.BarKind.Swap, Margin = new Thickness(0, 6, 0, 4) };
            bar.SetLabel("交换"); bar.SetValue(sp, "");
            rows.Add(bar);
            rows.Add(LabelRow("交换", $"{info.SwapUsedMb ?? 0} / {info.SwapTotalMb ?? 0} MB"));
        }
        else rows.Add(LabelRow("交换", "-"));
        return Card(rows.ToArray());
    }

    private UIElement TableHeader(string[] cols, double[] widths)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
        for (int i = 0; i < cols.Length; i++)
            row.Children.Add(new TextBlock
            {
                Text = cols[i], Width = widths[i], FontSize = 10.5, FontWeight = FontWeights.SemiBold,
                Foreground = (Brush)Application.Current.Resources["BrushMuted"],
            });
        return row;
    }

    private StackPanel TableRow(string[] cols, double[] widths)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 1, 0, 1) };
        for (int i = 0; i < cols.Length; i++)
            row.Children.Add(new TextBlock
            {
                Text = cols[i], Width = i < widths.Length ? widths[i] : 80, FontSize = 10.5,
                FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
                Foreground = (Brush)Application.Current.Resources["BrushText"], TextTrimming = TextTrimming.CharacterEllipsis,
            });
        return row;
    }

    private Border NetCard(System.Collections.Generic.List<SysInfoParser.NetRow> rows)
    {
        var views = new List<UIElement>
        {
            CardTitle("网卡"),
            TableHeader(new[] { "网卡", "IP", "MAC", "收/发" }, new double[] { 70, 110, 130, 140 }),
        };
        foreach (var r in rows)
        {
            var rx = SysInfoParser.FormatBytes(r.RxBytes);
            var tx = SysInfoParser.FormatBytes(r.TxBytes);
            views.Add(TableRow(new[] { r.Name, Str(r.Ip), Str(r.Mac), $"{rx} / {tx}" }, new double[] { 70, 110, 130, 140 }));
        }
        return Card(views.ToArray());
    }

    private Border DiskCard(System.Collections.Generic.List<SysInfoParser.DiskRow> rows)
    {
        var views = new List<UIElement>
        {
            CardTitle("磁盘"),
            TableHeader(new[] { "挂载点", "容量", "已用", "可用", "使用率" }, new double[] { 140, 70, 70, 70, 110 }),
        };
        foreach (var r in rows)
        {
            var row = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 1, 0, 1) };
            var text = TableRow(new[] { r.Mount, Str(r.Size), Str(r.Used), Str(r.Avail) }, new double[] { 140, 70, 70, 70 });
            var bar = new MetricBar { Kind = MetricBar.BarKind.Disk, Width = 130 };
            bar.SetLabel(""); bar.SetValue(r.Pct ?? 0, "");
            row.Children.Add(text); row.Children.Add(bar);
            views.Add(row);
        }
        return Card(views.ToArray());
    }
}
