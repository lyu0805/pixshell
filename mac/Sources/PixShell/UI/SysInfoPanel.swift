import AppKit

/// 系统信息页（弹窗）：exec 一段采集命令，把 KEY=value 文本解析成结构化卡片/表格展示。
final class SysInfoPanel: NSView {
    private let card = NSView()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let grid = NSStackView()
    private var cardX: NSLayoutConstraint!
    private var cardY: NSLayoutConstraint!
    var onClose: (() -> Void)?
    var onRefresh: (() -> Void)?

    // 采集命令：POSIX/busybox ash 安全（无 bashism/local/数组/base64），输出简单 KEY=value 行。
    // 按 uname -s 分支：Linux(/proc) · Darwin(sysctl/vm_stat/top/ifconfig) · Windows(Cygwin/MSYS 或 powershell -EncodedCommand)。
    static let command = """
OS=`uname -s 2>/dev/null || echo unknown`
# OpenSSH-Windows / bare cmd: uname 常不存在；有 powershell 则当 Windows
if [ "$OS" = "unknown" ] || [ -z "$OS" ]; then
  if command -v powershell.exe >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then OS=Windows
  elif [ -n "$WINDIR" ] || [ -n "$SystemRoot" ] || [ -n "$OS" -a "$OS" = "Windows_NT" ]; then OS=Windows
  fi
fi
case "$OS" in
Darwin)
HN=`hostname 2>/dev/null || uname -n 2>/dev/null`
echo "hostname=${HN:-}"
PN=`sw_vers -productName 2>/dev/null`
PV=`sw_vers -productVersion 2>/dev/null`
BUILD=`sw_vers -buildVersion 2>/dev/null`
if [ -n "$PN" ]; then
  DISTRO="$PN $PV"
  [ -n "$BUILD" ] && DISTRO="$DISTRO ($BUILD)"
else
  DISTRO="macOS"
fi
echo "distro=${DISTRO:-}"
echo "kernel=`uname -r 2>/dev/null`"
echo "arch=`uname -m 2>/dev/null`"
BOOT=`sysctl -n kern.boottime 2>/dev/null | awk '{for(i=1;i<=NF;i++){ if($i ~ /^[0-9]+,?$/){ gsub(/,/,"",$i); print $i; exit } }}'`
NOW=`date +%s 2>/dev/null`
if [ -n "$BOOT" ] && [ -n "$NOW" ] && [ "$NOW" -gt "$BOOT" ] 2>/dev/null; then
  U=`expr $NOW - $BOOT 2>/dev/null`
  D=`expr $U / 86400 2>/dev/null`
  H=`expr \\( $U % 86400 \\) / 3600 2>/dev/null`
  M=`expr \\( $U % 3600 \\) / 60 2>/dev/null`
  echo "uptime=${D}d${H}h${M}m"
else
  UPSTR=`uptime 2>/dev/null | sed 's/.*up *//;s/, *[0-9][0-9]* user.*//;s/, *load.*//'`
  echo "uptime=${UPSTR:-}"
fi
LA=`sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'`
set -- $LA
echo "load=$1,$2,$3"
IFACE=`route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'`
IP=""
if [ -n "$IFACE" ]; then
  IP=`ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}'`
fi
if [ -z "$IP" ]; then
  IP=`ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\\.' | head -n1`
fi
echo "ip=${IP:-}"
CPU_MODEL=`sysctl -n machdep.cpu.brand_string 2>/dev/null`
[ -z "$CPU_MODEL" ] && CPU_MODEL=`sysctl -n hw.model 2>/dev/null`
echo "cpu_model=${CPU_MODEL:-}"
CPU_CORES=`sysctl -n hw.ncpu 2>/dev/null`
echo "cpu_cores=${CPU_CORES:-}"
FREQ=`sysctl -n hw.cpufrequency 2>/dev/null`
if [ -n "$FREQ" ] && [ "$FREQ" -gt 0 ] 2>/dev/null; then
  echo "cpu_mhz=`expr $FREQ / 1000000 2>/dev/null`"
else
  echo "cpu_mhz="
fi
CACHE=`sysctl -n hw.l3cachesize 2>/dev/null`
if [ -n "$CACHE" ] && [ "$CACHE" -gt 0 ] 2>/dev/null; then
  echo "cpu_cache=`expr $CACHE / 1024 2>/dev/null` KB"
else
  echo "cpu_cache="
fi
echo "cpu_bogomips="
TOPCPU=`top -l 1 -n 0 2>/dev/null | grep "CPU usage"`
if [ -n "$TOPCPU" ]; then
  echo "$TOPCPU" | awk '{
    u=""; s=""; i=""
    for(k=1;k<=NF;k++){
      if($(k+1)=="user," || $(k+1)=="user"){u=$k}
      if($(k+1)=="sys," || $(k+1)=="sys"){s=$k}
      if($(k+1)=="idle" || $(k+1)=="idle,"){i=$k}
    }
    gsub(/%/,"",u); gsub(/%/,"",s); gsub(/%/,"",i)
    if(u=="") u=0; if(s=="") s=0; if(i=="") i=0
    busy=u+s; if(busy>100) busy=100
    printf "cpu_busy=%.1f\\n", busy
    printf "cpu_user=%.1f\\n", u+0
    printf "cpu_system=%.1f\\n", s+0
    printf "cpu_idle=%.1f\\n", i+0
    printf "cpu_iowait=\\n"
  }'
else
  echo "cpu_busy="; echo "cpu_user="; echo "cpu_system="; echo "cpu_idle="; echo "cpu_iowait="
fi
MEM_TOTAL=`sysctl -n hw.memsize 2>/dev/null`
PAGE_SIZE=`pagesize 2>/dev/null || sysctl -n hw.pagesize 2>/dev/null`
[ -z "$PAGE_SIZE" ] && PAGE_SIZE=4096
if [ -n "$MEM_TOTAL" ]; then
  vm_stat 2>/dev/null | awk -v total="$MEM_TOTAL" -v ps="$PAGE_SIZE" '
    /Pages free:/{ gsub(/\\./,"",$3); free=$3+0 }
    /Pages speculative:/{ gsub(/\\./,"",$3); spec=$3+0 }
    END{
      if(total<=0){ print "mem_pct="; print "mem_used_mb="; print "mem_total_mb="; exit }
      freep=free+spec
      used=total-freep*ps
      if(used<0) used=0
      if(used>total) used=total
      pct=int(used*100/total+0.5)
      printf "mem_pct=%d\\n", pct
      printf "mem_used_mb=%d\\n", int(used/1024/1024)
      printf "mem_total_mb=%d\\n", int(total/1024/1024)
    }'
else
  echo "mem_pct="; echo "mem_used_mb="; echo "mem_total_mb="
fi
sysctl -n vm.swapusage 2>/dev/null | awk '{
  t=0; u=0
  for(i=1;i<=NF;i++){
    if($i=="total"){ v=$(i+2); gsub(/M/,"",v); t=v+0 }
    if($i=="used"){ v=$(i+2); gsub(/M/,"",v); u=v+0 }
  }
  if(t>0){
    sp=int(u*100/t+0.5)
    printf "swap_pct=%d\\n", sp
    printf "swap_used_mb=%d\\n", int(u+0.5)
    printf "swap_total_mb=%d\\n", int(t+0.5)
  } else {
    print "swap_pct=0"; print "swap_used_mb=0"; print "swap_total_mb=0"
  }
}'
netstat -ibn 2>/dev/null | awk '
  /<Link/ {
    name=$1
    if(name=="lo0" || name=="lo") next
    if(name ~ /^(gif|stf|awdl|llw|utun|pktap|bridge|ipsec|XHC|VHC)/) next
    mac=$4; rx=$7; tx=$10
    if(rx ~ /^[0-9]+$/ && tx ~ /^[0-9]+$/){
      printf "%s\\t%s\\t%s\\t%s\\n", name, mac, rx, tx
    }
  }' | while IFS="`printf '\\t'`" read NAME MAC RX TX; do
  [ -z "$NAME" ] && continue
  IFIP=`ifconfig "$NAME" 2>/dev/null | awk '/inet /{print $2; exit}'`
  [ -z "$MAC" ] && MAC=`ifconfig "$NAME" 2>/dev/null | awk '/ether /{print $2; exit}'`
  printf 'net_row=%s\\t%s\\t%s\\t%s\\t%s\\n' "$NAME" "${IFIP:-}" "${MAC:-}" "${RX:-0}" "${TX:-0}"
done
df -Ph 2>/dev/null | awk 'NR>1 {
  fs=$1
  if(fs=="devfs" || fs ~ /^map/ || fs=="tmpfs" || fs=="autofs") next
  if($5 ~ /%$/){
    size=$2; used=$3; avail=$4; pct=$5; mnt=$6
    for(i=7;i<=NF;i++) mnt=mnt" "$i
  } else next
  if(mnt ~ /^\\/System\\/Volumes\\/(Preboot|Update|VM|Hardware|xarts|iSCPreboot)/) next
  if(mnt ~ /^\\/System\\/Volumes\\/Update\\//) next
  if(mnt=="/dev" || mnt=="/System/Volumes/Data/home") next
  if(mnt ~ /MobileAsset|MetalToolchain|PKITrustStore/) next
  if(mnt ~ /^\\/private\\/tmp\\/win146\\//) next
  print mnt"|"size"|"used"|"avail"|"pct"|"fs
}' | awk -F'|' '!seen[$1]++ {printf "disk_row=%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n", $1,$2,$3,$4,$5,$6}'
;;
CYGWIN*|MINGW*|MSYS*|Windows_NT|Windows)
PSBIN=`command -v powershell.exe 2>/dev/null || command -v powershell 2>/dev/null || echo ""`
if [ -n "$PSBIN" ]; then
  "$PSBIN" -NoProfile -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQAnAAoAWwBDAG8AbgBzAG8AbABlAF0AOgA6AE8AdQB0AHAAdQB0AEUAbgBjAG8AZABpAG4AZwA9AFsAVABlAHgAdAAuAFUAVABGADgARQBuAGMAbwBkAGkAbgBnAF0AOgA6AFUAVABGADgACgAkAG8AcwA9AEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8ATwBwAGUAcgBhAHQAaQBuAGcAUwB5AHMAdABlAG0ACgAkAGMAcwA9AEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8AQwBvAG0AcAB1AHQAZQByAFMAeQBzAHQAZQBtAAoAJABjAHAAdQA9AEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8AUAByAG8AYwBlAHMAcwBvAHIAIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGgAbwBzAHQAbgBhAG0AZQA9ACIAIAArACAAJABlAG4AdgA6AEMATwBNAFAAVQBUAEUAUgBOAEEATQBFACkACgAkAGQAaQBzAHQAcgBvACAAPQAgAGkAZgAoACQAbwBzACkAewAgACgAJABvAHMALgBDAGEAcAB0AGkAbwBuACAAKwAgACIAIAAiACAAKwAgACQAbwBzAC4AVgBlAHIAcwBpAG8AbgApAC4AVAByAGkAbQAoACkAIAB9ACAAZQBsAHMAZQAgAHsAIAAiAFcAaQBuAGQAbwB3AHMAIgAgAH0ACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBkAGkAcwB0AHIAbwA9ACIAIAArACAAJABkAGkAcwB0AHIAbwApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAawBlAHIAbgBlAGwAPQAiACAAKwAgACQAKABpAGYAKAAkAG8AcwApAHsAJABvAHMALgBWAGUAcgBzAGkAbwBuAH0AZQBsAHMAZQB7ACIAIgB9ACkAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGEAcgBjAGgAPQAiACAAKwAgACQAZQBuAHYAOgBQAFIATwBDAEUAUwBTAE8AUgBfAEEAUgBDAEgASQBUAEUAQwBUAFUAUgBFACkACgBpAGYAKAAkAG8AcwAgAC0AYQBuAGQAIAAkAG8AcwAuAEwAYQBzAHQAQgBvAG8AdABVAHAAVABpAG0AZQApAHsACgAgACAAJABiAG8AbwB0AD0AWwBNAGEAbgBhAGcAZQBtAGUAbgB0AC4ATQBhAG4AYQBnAGUAbQBlAG4AdABEAGEAdABlAFQAaQBtAGUAQwBvAG4AdgBlAHIAdABlAHIAXQA6ADoAVABvAEQAYQB0AGUAVABpAG0AZQAoACQAbwBzAC4ATABhAHMAdABCAG8AbwB0AFUAcABUAGkAbQBlACkACgAgACAAJAB1AD0AWwBNAGEAdABoAF0AOgA6AE0AYQB4ACgAMAAsAFsAaQBuAHQAXQAoACgARwBlAHQALQBEAGEAdABlACkALQAkAGIAbwBvAHQAKQAuAFQAbwB0AGEAbABTAGUAYwBvAG4AZABzACkACgAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAdQBwAHQAaQBtAGUAPQAiACAAKwAgAFsAaQBuAHQAXQAoACQAdQAvADgANgA0ADAAMAApACAAKwAgACIAZAAiACAAKwAgAFsAaQBuAHQAXQAoACgAJAB1ACUAOAA2ADQAMAAwACkALwAzADYAMAAwACkAIAArACAAIgBoACIAIAArACAAWwBpAG4AdABdACgAKAAkAHUAJQAzADYAMAAwACkALwA2ADAAKQAgACsAIAAiAG0AIgApAAoAfQAgAGUAbABzAGUAIAB7ACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAHUAcAB0AGkAbQBlAD0AIgAgAH0ACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAbABvAGEAZAA9ACIACgAkAGkAcAA9ACIAIgAKAHQAcgB5ACAAewAKACAAIAAkAGkAcAA9ACgARwBlAHQALQBOAGUAdABJAFAAQQBkAGQAcgBlAHMAcwAgAC0AQQBkAGQAcgBlAHMAcwBGAGEAbQBpAGwAeQAgAEkAUAB2ADQAIAB8ACAAVwBoAGUAcgBlAC0ATwBiAGoAZQBjAHQAIAB7ACAAJABfAC4ASQBQAEEAZABkAHIAZQBzAHMAIAAtAG4AbwB0AGwAaQBrAGUAIAAiADEAMgA3AC4AKgAiACAALQBhAG4AZAAgACQAXwAuAFAAcgBlAGYAaQB4AE8AcgBpAGcAaQBuACAALQBuAGUAIAAiAFcAZQBsAGwASwBuAG8AdwBuACIAIAB9ACAAfAAgAFMAZQBsAGUAYwB0AC0ATwBiAGoAZQBjAHQAIAAtAEYAaQByAHMAdAAgADEAIAAtAEUAeABwAGEAbgBkAFAAcgBvAHAAZQByAHQAeQAgAEkAUABBAGQAZAByAGUAcwBzACkACgB9ACAAYwBhAHQAYwBoACAAewB9AAoAaQBmACgALQBuAG8AdAAgACQAaQBwACkAewAKACAAIAAkAGkAcAA9ACgARwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBOAGUAdAB3AG8AcgBrAEEAZABhAHAAdABlAHIAQwBvAG4AZgBpAGcAdQByAGEAdABpAG8AbgAgAC0ARgBpAGwAdABlAHIAIAAiAEkAUABFAG4AYQBiAGwAZQBkAD0AVAByAHUAZQAiACAAfAAgAEYAbwByAEUAYQBjAGgALQBPAGIAagBlAGMAdAAgAHsAIAAkAF8ALgBJAFAAQQBkAGQAcgBlAHMAcwAgAH0AIAB8ACAAVwBoAGUAcgBlAC0ATwBiAGoAZQBjAHQAIAB7ACAAJABfACAALQBtAGEAdABjAGgAIAAnAF4AXABkACsAXAAuAFwAZAArACcAIAAtAGEAbgBkACAAJABfACAALQBuAG8AdABsAGkAawBlACAAJwAxADIANwAuACoAJwAgAH0AIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQApAAoAfQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGkAcAA9ACIAIAArACAAJABpAHAAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGMAcAB1AF8AbQBvAGQAZQBsAD0AIgAgACsAIAAkACgAaQBmACgAJABjAHAAdQApAHsAJABjAHAAdQAuAE4AYQBtAGUALgBUAHIAaQBtACgAKQB9AGUAbABzAGUAewAiACIAfQApACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBjAHAAdQBfAGMAbwByAGUAcwA9ACIAIAArACAAJAAoAGkAZgAoACQAYwBwAHUAKQB7ACQAYwBwAHUALgBOAHUAbQBiAGUAcgBPAGYATABvAGcAaQBjAGEAbABQAHIAbwBjAGUAcwBzAG8AcgBzAH0AZQBsAHMAZQBpAGYAKAAkAGMAcwApAHsAJABjAHMALgBOAHUAbQBiAGUAcgBPAGYATABvAGcAaQBjAGEAbABQAHIAbwBjAGUAcwBzAG8AcgBzAH0AZQBsAHMAZQB7ACIAIgB9ACkAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGMAcAB1AF8AbQBoAHoAPQAiACAAKwAgACQAKABpAGYAKAAkAGMAcAB1ACkAewAkAGMAcAB1AC4ATQBhAHgAQwBsAG8AYwBrAFMAcABlAGUAZAB9AGUAbABzAGUAewAiACIAfQApACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAYwBwAHUAXwBjAGEAYwBoAGUAPQAiAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAGMAcAB1AF8AYgBvAGcAbwBtAGkAcABzAD0AIgAKACQAbABvAGEAZAAgAD0AIABpAGYAKAAkAGMAcwAgAC0AYQBuAGQAIAAkAGMAcwAuAEwAbwBhAGQAUABlAHIAYwBlAG4AdABhAGcAZQAgAC0AbgBlACAAJABuAHUAbABsACkAewAgAFsAbQBhAHQAaABdADoAOgBSAG8AdQBuAGQAKABbAGQAbwB1AGIAbABlAF0AJABjAHMALgBMAG8AYQBkAFAAZQByAGMAZQBuAHQAYQBnAGUALAAxACkAIAB9ACAAZQBsAHMAZQAgAHsAIAAwACAAfQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGMAcAB1AF8AYgB1AHMAeQA9ACIAIAArACAAJABsAG8AYQBkACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBjAHAAdQBfAHUAcwBlAHIAPQAiACAAKwAgACQAbABvAGEAZAApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAGMAcAB1AF8AcwB5AHMAdABlAG0APQAiAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAYwBwAHUAXwBpAGQAbABlAD0AIgAgACsAIAAoAFsAbQBhAHQAaABdADoAOgBSAG8AdQBuAGQAKAAxADAAMAAtACQAbABvAGEAZAAsADEAKQApACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAYwBwAHUAXwBpAG8AdwBhAGkAdAA9ACIACgBpAGYAKAAkAG8AcwApAHsACgAgACAAJAB0AG8AdABhAGwAPQBbAGkAbgB0ADYANABdACQAbwBzAC4AVABvAHQAYQBsAFYAaQBzAGkAYgBsAGUATQBlAG0AbwByAHkAUwBpAHoAZQAKACAAIAAkAGYAcgBlAGUAPQBbAGkAbgB0ADYANABdACQAbwBzAC4ARgByAGUAZQBQAGgAeQBzAGkAYwBhAGwATQBlAG0AbwByAHkACgAgACAAJAB1AHMAZQBkAD0AWwBNAGEAdABoAF0AOgA6AE0AYQB4ACgAMAAsACQAdABvAHQAYQBsAC0AJABmAHIAZQBlACkACgAgACAAJABwAGMAdAAgAD0AIABpAGYAKAAkAHQAbwB0AGEAbAAgAC0AZwB0ACAAMAApAHsAIABbAGkAbgB0AF0AWwBtAGEAdABoAF0AOgA6AFIAbwB1AG4AZAAoACQAdQBzAGUAZAAqADEAMAAwAC4AMAAvACQAdABvAHQAYQBsACkAIAB9ACAAZQBsAHMAZQAgAHsAIAAwACAAfQAKACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBtAGUAbQBfAHAAYwB0AD0AIgAgACsAIAAkAHAAYwB0ACkACgAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAbQBlAG0AXwB1AHMAZQBkAF8AbQBiAD0AIgAgACsAIABbAGkAbgB0AF0AKAAkAHUAcwBlAGQALwAxADAAMgA0ACkAKQAKACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBtAGUAbQBfAHQAbwB0AGEAbABfAG0AYgA9ACIAIAArACAAWwBpAG4AdABdACgAJAB0AG8AdABhAGwALwAxADAAMgA0ACkAKQAKACAAIAAkAHMAdAA9AFsAaQBuAHQANgA0AF0AJABvAHMALgBUAG8AdABhAGwAVgBpAHIAdAB1AGEAbABNAGUAbQBvAHIAeQBTAGkAegBlAAoAIAAgACQAcwBmAD0AWwBpAG4AdAA2ADQAXQAkAG8AcwAuAEYAcgBlAGUAVgBpAHIAdAB1AGEAbABNAGUAbQBvAHIAeQAKACAAIAAkAHAAYQBnAGUAVABvAHQAYQBsAD0AWwBNAGEAdABoAF0AOgA6AE0AYQB4ACgAMAAsACQAcwB0AC0AJAB0AG8AdABhAGwAKQAKACAAIAAkAHAAYQBnAGUAVQBzAGUAZAA9AFsATQBhAHQAaABdADoAOgBNAGEAeAAoADAALAAoACQAcwB0AC0AJABzAGYAKQAtACgAJAB0AG8AdABhAGwALQAkAGYAcgBlAGUAKQApAAoAIAAgAGkAZgAoACQAcABhAGcAZQBUAG8AdABhAGwAIAAtAGcAdAAgADAAKQB7AAoAIAAgACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBzAHcAYQBwAF8AcABjAHQAPQAiACAAKwAgAFsAaQBuAHQAXQBbAG0AYQB0AGgAXQA6ADoAUgBvAHUAbgBkACgAJABwAGEAZwBlAFUAcwBlAGQAKgAxADAAMAAuADAALwAkAHAAYQBnAGUAVABvAHQAYQBsACkAKQAKACAAIAAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAcwB3AGEAcABfAHUAcwBlAGQAXwBtAGIAPQAiACAAKwAgAFsAaQBuAHQAXQAoACQAcABhAGcAZQBVAHMAZQBkAC8AMQAwADIANAApACkACgAgACAAIAAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAHMAdwBhAHAAXwB0AG8AdABhAGwAXwBtAGIAPQAiACAAKwAgAFsAaQBuAHQAXQAoACQAcABhAGcAZQBUAG8AdABhAGwALwAxADAAMgA0ACkAKQAKACAAIAB9ACAAZQBsAHMAZQAgAHsACgAgACAAIAAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBzAHcAYQBwAF8AcABjAHQAPQAwACIAOwAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBzAHcAYQBwAF8AdQBzAGUAZABfAG0AYgA9ADAAIgA7ACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAHMAdwBhAHAAXwB0AG8AdABhAGwAXwBtAGIAPQAwACIACgAgACAAfQAKAH0AIABlAGwAcwBlACAAewAKACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAbQBlAG0AXwBwAGMAdAA9ACIAOwAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBtAGUAbQBfAHUAcwBlAGQAXwBtAGIAPQAiADsAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAbQBlAG0AXwB0AG8AdABhAGwAXwBtAGIAPQAiAAoAIAAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBzAHcAYQBwAF8AcABjAHQAPQAwACIAOwAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBzAHcAYQBwAF8AdQBzAGUAZABfAG0AYgA9ADAAIgA7ACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAHMAdwBhAHAAXwB0AG8AdABhAGwAXwBtAGIAPQAwACIACgB9AAoARwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBOAGUAdAB3AG8AcgBrAEEAZABhAHAAdABlAHIAIAB8ACAAVwBoAGUAcgBlAC0ATwBiAGoAZQBjAHQAIAB7ACAAJABfAC4ATgBlAHQARQBuAGEAYgBsAGUAZAAgAC0AZQBxACAAJAB0AHIAdQBlACAALQBhAG4AZAAgACQAXwAuAE0AQQBDAEEAZABkAHIAZQBzAHMAIAAtAGEAbgBkACAAJABfAC4ATgBhAG0AZQAgAC0AbgBvAHQAbQBhAHQAYwBoACAAJwBMAG8AbwBwAGIAYQBjAGsAfABWAGkAcgB0AHUAYQBsAEIAbwB4AHwAVgBNAHcAYQByAGUAfABIAHkAcABlAHIALQBWAHwAdgBFAHQAaABlAHIAbgBlAHQAfABCAGwAdQBlAHQAbwBvAHQAaAAnACAAfQAgAHwAIABGAG8AcgBFAGEAYwBoAC0ATwBiAGoAZQBjAHQAIAB7AAoAIAAgACQAbgBhAG0AZQAgAD0AIABpAGYAKAAkAF8ALgBOAGUAdABDAG8AbgBuAGUAYwB0AGkAbwBuAEkARAApAHsAIAAkAF8ALgBOAGUAdABDAG8AbgBuAGUAYwB0AGkAbwBuAEkARAAgAH0AIABlAGwAcwBlACAAewAgACQAXwAuAE4AYQBtAGUAIAB9AAoAIAAgACQAbQBhAGMAPQAkAF8ALgBNAEEAQwBBAGQAZAByAGUAcwBzAAoAIAAgACQAaQBmAGkAcAA9ACIAIgAKACAAIAB0AHIAeQAgAHsACgAgACAAIAAgACQAYwBmAGcAPQBHAGUAdAAtAEMAaQBtAEkAbgBzAHQAYQBuAGMAZQAgAFcAaQBuADMAMgBfAE4AZQB0AHcAbwByAGsAQQBkAGEAcAB0AGUAcgBDAG8AbgBmAGkAZwB1AHIAYQB0AGkAbwBuACAALQBGAGkAbAB0AGUAcgAgACgAIgBJAG4AZABlAHgAPQAiACAAKwAgACQAXwAuAEkAbgB0AGUAcgBmAGEAYwBlAEkAbgBkAGUAeAApAAoAIAAgACAAIABpAGYAKAAtAG4AbwB0ACAAJABjAGYAZwApAHsAIAAkAGMAZgBnAD0ARwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBOAGUAdAB3AG8AcgBrAEEAZABhAHAAdABlAHIAQwBvAG4AZgBpAGcAdQByAGEAdABpAG8AbgAgAC0ARgBpAGwAdABlAHIAIAAoACIASQBuAGQAZQB4AD0AIgAgACsAIAAkAF8ALgBEAGUAdgBpAGMAZQBJAEQAKQAgAH0ACgAgACAAIAAgAGkAZgAoACQAYwBmAGcAIAAtAGEAbgBkACAAJABjAGYAZwAuAEkAUABBAGQAZAByAGUAcwBzACkAewAgACQAaQBmAGkAcAA9ACgAJABjAGYAZwAuAEkAUABBAGQAZAByAGUAcwBzACAAfAAgAFcAaABlAHIAZQAtAE8AYgBqAGUAYwB0ACAAewAgACQAXwAgAC0AbQBhAHQAYwBoACAAJwBeAFwAZAArAFwALgBcAGQAKwAnACAALQBhAG4AZAAgACQAXwAgAC0AbgBvAHQAbABpAGsAZQAgACcAMQAyADcALgAqACcAIAB9ACAAfAAgAFMAZQBsAGUAYwB0AC0ATwBiAGoAZQBjAHQAIAAtAEYAaQByAHMAdAAgADEAKQAgAH0ACgAgACAAfQAgAGMAYQB0AGMAaAAgAHsAfQAKACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBuAGUAdABfAHIAbwB3AD0AIgAgACsAIAAkAG4AYQBtAGUAIAArACAAIgBgAHQAIgAgACsAIAAkAGkAZgBpAHAAIAArACAAIgBgAHQAIgAgACsAIAAkAG0AYQBjACAAKwAgACIAYAB0ADAAYAB0ADAAIgApAAoAfQAKAGYAdQBuAGMAdABpAG8AbgAgAEYAbQB0ACgAWwBpAG4AdAA2ADQAXQAkAGIAKQB7AAoAIAAgAGkAZgAoACQAYgAgAC0AZwBlACAAMQBUAEIAKQB7ACAAcgBlAHQAdQByAG4AIAAoACIAewAwADoATgAxAH0AVAAiACAALQBmACAAKAAkAGIALwAxAFQAQgApACkAIAB9AAoAIAAgAGkAZgAoACQAYgAgAC0AZwBlACAAMQBHAEIAKQB7ACAAcgBlAHQAdQByAG4AIAAoACIAewAwADoATgAxAH0ARwAiACAALQBmACAAKAAkAGIALwAxAEcAQgApACkAIAB9AAoAIAAgAGkAZgAoACQAYgAgAC0AZwBlACAAMQBNAEIAKQB7ACAAcgBlAHQAdQByAG4AIAAoACIAewAwADoATgAxAH0ATQAiACAALQBmACAAKAAkAGIALwAxAE0AQgApACkAIAB9AAoAIAAgAHIAZQB0AHUAcgBuACAAKAAiAHsAMAA6AE4AMAB9AEsAIgAgAC0AZgAgACgAJABiAC8AMQBLAEIAKQApAAoAfQAKAEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8ATABvAGcAaQBjAGEAbABEAGkAcwBrACAALQBGAGkAbAB0AGUAcgAgACIARAByAGkAdgBlAFQAeQBwAGUAPQAzACIAIAB8ACAARgBvAHIARQBhAGMAaAAtAE8AYgBqAGUAYwB0ACAAewAKACAAIAAkAHMAaQB6AGUAPQBbAGkAbgB0ADYANABdACQAXwAuAFMAaQB6AGUAOwAgAGkAZgAoACQAcwBpAHoAZQAgAC0AbABlACAAMAApAHsAIAByAGUAdAB1AHIAbgAgAH0ACgAgACAAJABmAHIAZQBlAD0AWwBpAG4AdAA2ADQAXQAkAF8ALgBGAHIAZQBlAFMAcABhAGMAZQA7ACAAJAB1AHMAZQBkAD0AJABzAGkAegBlAC0AJABmAHIAZQBlAAoAIAAgACQAcABjAHQAPQBbAGkAbgB0AF0AWwBtAGEAdABoAF0AOgA6AFIAbwB1AG4AZAAoACQAdQBzAGUAZAAqADEAMAAwAC4AMAAvACQAcwBpAHoAZQApAAoAIAAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGQAaQBzAGsAXwByAG8AdwA9ACIAIAArACAAJABfAC4ARABlAHYAaQBjAGUASQBEACAAKwAgACIAXABcACIAIAArACAAIgBgAHQAIgAgACsAIAAoAEYAbQB0ACAAJABzAGkAegBlACkAIAArACAAIgBgAHQAIgAgACsAIAAoAEYAbQB0ACAAJAB1AHMAZQBkACkAIAArACAAIgBgAHQAIgAgACsAIAAoAEYAbQB0ACAAJABmAHIAZQBlACkAIAArACAAIgBgAHQAIgAgACsAIAAoACQAcABjAHQALgBUAG8AUwB0AHIAaQBuAGcAKAApACAAKwAgACIAJQAiACkAIAArACAAIgBgAHQAIgAgACsAIAAkAF8ALgBGAGkAbABlAFMAeQBzAHQAZQBtACkACgB9AAoA
else
  HN=`hostname 2>/dev/null || echo "$COMPUTERNAME"`
  echo "hostname=${HN:-}"
  echo "distro=Windows"
  echo "kernel="; echo "arch=`uname -m 2>/dev/null`"; echo "uptime="; echo "load="; echo "ip="
  echo "cpu_model="; echo "cpu_cores="; echo "cpu_mhz="; echo "cpu_cache="; echo "cpu_bogomips="
  echo "cpu_busy="; echo "cpu_user="; echo "cpu_system="; echo "cpu_idle="; echo "cpu_iowait="
  echo "mem_pct="; echo "mem_used_mb="; echo "mem_total_mb="
  echo "swap_pct=0"; echo "swap_used_mb=0"; echo "swap_total_mb=0"
fi
;;
*)
HN=`hostname 2>/dev/null || uname -n 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null`
echo "hostname=${HN:-}"
DISTRO=""
if [ -f /etc/openwrt_release ]; then
  DISTRO=`awk -F"'" '/DISTRIB_DESCRIPTION/{print $2; exit}' /etc/openwrt_release 2>/dev/null`
  [ -z "$DISTRO" ] && DISTRO=`awk -F"'" '/DISTRIB_ID/{id=$2} /DISTRIB_RELEASE/{r=$2} END{if(id!="")print id" "r}' /etc/openwrt_release 2>/dev/null`
elif [ -f /etc/os-release ]; then
  DISTRO=`awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null`
fi
# 无 /proc 且能找到 powershell：可能是 Windows 上的奇怪 uname
if [ ! -f /proc/meminfo ]; then
  PSBIN=`command -v powershell.exe 2>/dev/null || command -v powershell 2>/dev/null || echo ""`
  if [ -n "$PSBIN" ]; then
    "$PSBIN" -NoProfile -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQAnAAoAWwBDAG8AbgBzAG8AbABlAF0AOgA6AE8AdQB0AHAAdQB0AEUAbgBjAG8AZABpAG4AZwA9AFsAVABlAHgAdAAuAFUAVABGADgARQBuAGMAbwBkAGkAbgBnAF0AOgA6AFUAVABGADgACgAkAG8AcwA9AEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8ATwBwAGUAcgBhAHQAaQBuAGcAUwB5AHMAdABlAG0ACgAkAGMAcwA9AEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8AQwBvAG0AcAB1AHQAZQByAFMAeQBzAHQAZQBtAAoAJABjAHAAdQA9AEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8AUAByAG8AYwBlAHMAcwBvAHIAIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGgAbwBzAHQAbgBhAG0AZQA9ACIAIAArACAAJABlAG4AdgA6AEMATwBNAFAAVQBUAEUAUgBOAEEATQBFACkACgAkAGQAaQBzAHQAcgBvACAAPQAgAGkAZgAoACQAbwBzACkAewAgACgAJABvAHMALgBDAGEAcAB0AGkAbwBuACAAKwAgACIAIAAiACAAKwAgACQAbwBzAC4AVgBlAHIAcwBpAG8AbgApAC4AVAByAGkAbQAoACkAIAB9ACAAZQBsAHMAZQAgAHsAIAAiAFcAaQBuAGQAbwB3AHMAIgAgAH0ACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBkAGkAcwB0AHIAbwA9ACIAIAArACAAJABkAGkAcwB0AHIAbwApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAawBlAHIAbgBlAGwAPQAiACAAKwAgACQAKABpAGYAKAAkAG8AcwApAHsAJABvAHMALgBWAGUAcgBzAGkAbwBuAH0AZQBsAHMAZQB7ACIAIgB9ACkAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGEAcgBjAGgAPQAiACAAKwAgACQAZQBuAHYAOgBQAFIATwBDAEUAUwBTAE8AUgBfAEEAUgBDAEgASQBUAEUAQwBUAFUAUgBFACkACgBpAGYAKAAkAG8AcwAgAC0AYQBuAGQAIAAkAG8AcwAuAEwAYQBzAHQAQgBvAG8AdABVAHAAVABpAG0AZQApAHsACgAgACAAJABiAG8AbwB0AD0AWwBNAGEAbgBhAGcAZQBtAGUAbgB0AC4ATQBhAG4AYQBnAGUAbQBlAG4AdABEAGEAdABlAFQAaQBtAGUAQwBvAG4AdgBlAHIAdABlAHIAXQA6ADoAVABvAEQAYQB0AGUAVABpAG0AZQAoACQAbwBzAC4ATABhAHMAdABCAG8AbwB0AFUAcABUAGkAbQBlACkACgAgACAAJAB1AD0AWwBNAGEAdABoAF0AOgA6AE0AYQB4ACgAMAAsAFsAaQBuAHQAXQAoACgARwBlAHQALQBEAGEAdABlACkALQAkAGIAbwBvAHQAKQAuAFQAbwB0AGEAbABTAGUAYwBvAG4AZABzACkACgAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAdQBwAHQAaQBtAGUAPQAiACAAKwAgAFsAaQBuAHQAXQAoACQAdQAvADgANgA0ADAAMAApACAAKwAgACIAZAAiACAAKwAgAFsAaQBuAHQAXQAoACgAJAB1ACUAOAA2ADQAMAAwACkALwAzADYAMAAwACkAIAArACAAIgBoACIAIAArACAAWwBpAG4AdABdACgAKAAkAHUAJQAzADYAMAAwACkALwA2ADAAKQAgACsAIAAiAG0AIgApAAoAfQAgAGUAbABzAGUAIAB7ACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAHUAcAB0AGkAbQBlAD0AIgAgAH0ACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAbABvAGEAZAA9ACIACgAkAGkAcAA9ACIAIgAKAHQAcgB5ACAAewAKACAAIAAkAGkAcAA9ACgARwBlAHQALQBOAGUAdABJAFAAQQBkAGQAcgBlAHMAcwAgAC0AQQBkAGQAcgBlAHMAcwBGAGEAbQBpAGwAeQAgAEkAUAB2ADQAIAB8ACAAVwBoAGUAcgBlAC0ATwBiAGoAZQBjAHQAIAB7ACAAJABfAC4ASQBQAEEAZABkAHIAZQBzAHMAIAAtAG4AbwB0AGwAaQBrAGUAIAAiADEAMgA3AC4AKgAiACAALQBhAG4AZAAgACQAXwAuAFAAcgBlAGYAaQB4AE8AcgBpAGcAaQBuACAALQBuAGUAIAAiAFcAZQBsAGwASwBuAG8AdwBuACIAIAB9ACAAfAAgAFMAZQBsAGUAYwB0AC0ATwBiAGoAZQBjAHQAIAAtAEYAaQByAHMAdAAgADEAIAAtAEUAeABwAGEAbgBkAFAAcgBvAHAAZQByAHQAeQAgAEkAUABBAGQAZAByAGUAcwBzACkACgB9ACAAYwBhAHQAYwBoACAAewB9AAoAaQBmACgALQBuAG8AdAAgACQAaQBwACkAewAKACAAIAAkAGkAcAA9ACgARwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBOAGUAdAB3AG8AcgBrAEEAZABhAHAAdABlAHIAQwBvAG4AZgBpAGcAdQByAGEAdABpAG8AbgAgAC0ARgBpAGwAdABlAHIAIAAiAEkAUABFAG4AYQBiAGwAZQBkAD0AVAByAHUAZQAiACAAfAAgAEYAbwByAEUAYQBjAGgALQBPAGIAagBlAGMAdAAgAHsAIAAkAF8ALgBJAFAAQQBkAGQAcgBlAHMAcwAgAH0AIAB8ACAAVwBoAGUAcgBlAC0ATwBiAGoAZQBjAHQAIAB7ACAAJABfACAALQBtAGEAdABjAGgAIAAnAF4AXABkACsAXAAuAFwAZAArACcAIAAtAGEAbgBkACAAJABfACAALQBuAG8AdABsAGkAawBlACAAJwAxADIANwAuACoAJwAgAH0AIAB8ACAAUwBlAGwAZQBjAHQALQBPAGIAagBlAGMAdAAgAC0ARgBpAHIAcwB0ACAAMQApAAoAfQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGkAcAA9ACIAIAArACAAJABpAHAAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGMAcAB1AF8AbQBvAGQAZQBsAD0AIgAgACsAIAAkACgAaQBmACgAJABjAHAAdQApAHsAJABjAHAAdQAuAE4AYQBtAGUALgBUAHIAaQBtACgAKQB9AGUAbABzAGUAewAiACIAfQApACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBjAHAAdQBfAGMAbwByAGUAcwA9ACIAIAArACAAJAAoAGkAZgAoACQAYwBwAHUAKQB7ACQAYwBwAHUALgBOAHUAbQBiAGUAcgBPAGYATABvAGcAaQBjAGEAbABQAHIAbwBjAGUAcwBzAG8AcgBzAH0AZQBsAHMAZQBpAGYAKAAkAGMAcwApAHsAJABjAHMALgBOAHUAbQBiAGUAcgBPAGYATABvAGcAaQBjAGEAbABQAHIAbwBjAGUAcwBzAG8AcgBzAH0AZQBsAHMAZQB7ACIAIgB9ACkAKQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGMAcAB1AF8AbQBoAHoAPQAiACAAKwAgACQAKABpAGYAKAAkAGMAcAB1ACkAewAkAGMAcAB1AC4ATQBhAHgAQwBsAG8AYwBrAFMAcABlAGUAZAB9AGUAbABzAGUAewAiACIAfQApACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAYwBwAHUAXwBjAGEAYwBoAGUAPQAiAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAGMAcAB1AF8AYgBvAGcAbwBtAGkAcABzAD0AIgAKACQAbABvAGEAZAAgAD0AIABpAGYAKAAkAGMAcwAgAC0AYQBuAGQAIAAkAGMAcwAuAEwAbwBhAGQAUABlAHIAYwBlAG4AdABhAGcAZQAgAC0AbgBlACAAJABuAHUAbABsACkAewAgAFsAbQBhAHQAaABdADoAOgBSAG8AdQBuAGQAKABbAGQAbwB1AGIAbABlAF0AJABjAHMALgBMAG8AYQBkAFAAZQByAGMAZQBuAHQAYQBnAGUALAAxACkAIAB9ACAAZQBsAHMAZQAgAHsAIAAwACAAfQAKAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGMAcAB1AF8AYgB1AHMAeQA9ACIAIAArACAAJABsAG8AYQBkACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBjAHAAdQBfAHUAcwBlAHIAPQAiACAAKwAgACQAbABvAGEAZAApAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAGMAcAB1AF8AcwB5AHMAdABlAG0APQAiAAoAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAYwBwAHUAXwBpAGQAbABlAD0AIgAgACsAIAAoAFsAbQBhAHQAaABdADoAOgBSAG8AdQBuAGQAKAAxADAAMAAtACQAbABvAGEAZAAsADEAKQApACkACgBXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAYwBwAHUAXwBpAG8AdwBhAGkAdAA9ACIACgBpAGYAKAAkAG8AcwApAHsACgAgACAAJAB0AG8AdABhAGwAPQBbAGkAbgB0ADYANABdACQAbwBzAC4AVABvAHQAYQBsAFYAaQBzAGkAYgBsAGUATQBlAG0AbwByAHkAUwBpAHoAZQAKACAAIAAkAGYAcgBlAGUAPQBbAGkAbgB0ADYANABdACQAbwBzAC4ARgByAGUAZQBQAGgAeQBzAGkAYwBhAGwATQBlAG0AbwByAHkACgAgACAAJAB1AHMAZQBkAD0AWwBNAGEAdABoAF0AOgA6AE0AYQB4ACgAMAAsACQAdABvAHQAYQBsAC0AJABmAHIAZQBlACkACgAgACAAJABwAGMAdAAgAD0AIABpAGYAKAAkAHQAbwB0AGEAbAAgAC0AZwB0ACAAMAApAHsAIABbAGkAbgB0AF0AWwBtAGEAdABoAF0AOgA6AFIAbwB1AG4AZAAoACQAdQBzAGUAZAAqADEAMAAwAC4AMAAvACQAdABvAHQAYQBsACkAIAB9ACAAZQBsAHMAZQAgAHsAIAAwACAAfQAKACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBtAGUAbQBfAHAAYwB0AD0AIgAgACsAIAAkAHAAYwB0ACkACgAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAbQBlAG0AXwB1AHMAZQBkAF8AbQBiAD0AIgAgACsAIABbAGkAbgB0AF0AKAAkAHUAcwBlAGQALwAxADAAMgA0ACkAKQAKACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBtAGUAbQBfAHQAbwB0AGEAbABfAG0AYgA9ACIAIAArACAAWwBpAG4AdABdACgAJAB0AG8AdABhAGwALwAxADAAMgA0ACkAKQAKACAAIAAkAHMAdAA9AFsAaQBuAHQANgA0AF0AJABvAHMALgBUAG8AdABhAGwAVgBpAHIAdAB1AGEAbABNAGUAbQBvAHIAeQBTAGkAegBlAAoAIAAgACQAcwBmAD0AWwBpAG4AdAA2ADQAXQAkAG8AcwAuAEYAcgBlAGUAVgBpAHIAdAB1AGEAbABNAGUAbQBvAHIAeQAKACAAIAAkAHAAYQBnAGUAVABvAHQAYQBsAD0AWwBNAGEAdABoAF0AOgA6AE0AYQB4ACgAMAAsACQAcwB0AC0AJAB0AG8AdABhAGwAKQAKACAAIAAkAHAAYQBnAGUAVQBzAGUAZAA9AFsATQBhAHQAaABdADoAOgBNAGEAeAAoADAALAAoACQAcwB0AC0AJABzAGYAKQAtACgAJAB0AG8AdABhAGwALQAkAGYAcgBlAGUAKQApAAoAIAAgAGkAZgAoACQAcABhAGcAZQBUAG8AdABhAGwAIAAtAGcAdAAgADAAKQB7AAoAIAAgACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBzAHcAYQBwAF8AcABjAHQAPQAiACAAKwAgAFsAaQBuAHQAXQBbAG0AYQB0AGgAXQA6ADoAUgBvAHUAbgBkACgAJABwAGEAZwBlAFUAcwBlAGQAKgAxADAAMAAuADAALwAkAHAAYQBnAGUAVABvAHQAYQBsACkAKQAKACAAIAAgACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAoACIAcwB3AGEAcABfAHUAcwBlAGQAXwBtAGIAPQAiACAAKwAgAFsAaQBuAHQAXQAoACQAcABhAGcAZQBVAHMAZQBkAC8AMQAwADIANAApACkACgAgACAAIAAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAHMAdwBhAHAAXwB0AG8AdABhAGwAXwBtAGIAPQAiACAAKwAgAFsAaQBuAHQAXQAoACQAcABhAGcAZQBUAG8AdABhAGwALwAxADAAMgA0ACkAKQAKACAAIAB9ACAAZQBsAHMAZQAgAHsACgAgACAAIAAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBzAHcAYQBwAF8AcABjAHQAPQAwACIAOwAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBzAHcAYQBwAF8AdQBzAGUAZABfAG0AYgA9ADAAIgA7ACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAHMAdwBhAHAAXwB0AG8AdABhAGwAXwBtAGIAPQAwACIACgAgACAAfQAKAH0AIABlAGwAcwBlACAAewAKACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAbQBlAG0AXwBwAGMAdAA9ACIAOwAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBtAGUAbQBfAHUAcwBlAGQAXwBtAGIAPQAiADsAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACIAbQBlAG0AXwB0AG8AdABhAGwAXwBtAGIAPQAiAAoAIAAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBzAHcAYQBwAF8AcABjAHQAPQAwACIAOwAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAIgBzAHcAYQBwAF8AdQBzAGUAZABfAG0AYgA9ADAAIgA7ACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAiAHMAdwBhAHAAXwB0AG8AdABhAGwAXwBtAGIAPQAwACIACgB9AAoARwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBOAGUAdAB3AG8AcgBrAEEAZABhAHAAdABlAHIAIAB8ACAAVwBoAGUAcgBlAC0ATwBiAGoAZQBjAHQAIAB7ACAAJABfAC4ATgBlAHQARQBuAGEAYgBsAGUAZAAgAC0AZQBxACAAJAB0AHIAdQBlACAALQBhAG4AZAAgACQAXwAuAE0AQQBDAEEAZABkAHIAZQBzAHMAIAAtAGEAbgBkACAAJABfAC4ATgBhAG0AZQAgAC0AbgBvAHQAbQBhAHQAYwBoACAAJwBMAG8AbwBwAGIAYQBjAGsAfABWAGkAcgB0AHUAYQBsAEIAbwB4AHwAVgBNAHcAYQByAGUAfABIAHkAcABlAHIALQBWAHwAdgBFAHQAaABlAHIAbgBlAHQAfABCAGwAdQBlAHQAbwBvAHQAaAAnACAAfQAgAHwAIABGAG8AcgBFAGEAYwBoAC0ATwBiAGoAZQBjAHQAIAB7AAoAIAAgACQAbgBhAG0AZQAgAD0AIABpAGYAKAAkAF8ALgBOAGUAdABDAG8AbgBuAGUAYwB0AGkAbwBuAEkARAApAHsAIAAkAF8ALgBOAGUAdABDAG8AbgBuAGUAYwB0AGkAbwBuAEkARAAgAH0AIABlAGwAcwBlACAAewAgACQAXwAuAE4AYQBtAGUAIAB9AAoAIAAgACQAbQBhAGMAPQAkAF8ALgBNAEEAQwBBAGQAZAByAGUAcwBzAAoAIAAgACQAaQBmAGkAcAA9ACIAIgAKACAAIAB0AHIAeQAgAHsACgAgACAAIAAgACQAYwBmAGcAPQBHAGUAdAAtAEMAaQBtAEkAbgBzAHQAYQBuAGMAZQAgAFcAaQBuADMAMgBfAE4AZQB0AHcAbwByAGsAQQBkAGEAcAB0AGUAcgBDAG8AbgBmAGkAZwB1AHIAYQB0AGkAbwBuACAALQBGAGkAbAB0AGUAcgAgACgAIgBJAG4AZABlAHgAPQAiACAAKwAgACQAXwAuAEkAbgB0AGUAcgBmAGEAYwBlAEkAbgBkAGUAeAApAAoAIAAgACAAIABpAGYAKAAtAG4AbwB0ACAAJABjAGYAZwApAHsAIAAkAGMAZgBnAD0ARwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBOAGUAdAB3AG8AcgBrAEEAZABhAHAAdABlAHIAQwBvAG4AZgBpAGcAdQByAGEAdABpAG8AbgAgAC0ARgBpAGwAdABlAHIAIAAoACIASQBuAGQAZQB4AD0AIgAgACsAIAAkAF8ALgBEAGUAdgBpAGMAZQBJAEQAKQAgAH0ACgAgACAAIAAgAGkAZgAoACQAYwBmAGcAIAAtAGEAbgBkACAAJABjAGYAZwAuAEkAUABBAGQAZAByAGUAcwBzACkAewAgACQAaQBmAGkAcAA9ACgAJABjAGYAZwAuAEkAUABBAGQAZAByAGUAcwBzACAAfAAgAFcAaABlAHIAZQAtAE8AYgBqAGUAYwB0ACAAewAgACQAXwAgAC0AbQBhAHQAYwBoACAAJwBeAFwAZAArAFwALgBcAGQAKwAnACAALQBhAG4AZAAgACQAXwAgAC0AbgBvAHQAbABpAGsAZQAgACcAMQAyADcALgAqACcAIAB9ACAAfAAgAFMAZQBsAGUAYwB0AC0ATwBiAGoAZQBjAHQAIAAtAEYAaQByAHMAdAAgADEAKQAgAH0ACgAgACAAfQAgAGMAYQB0AGMAaAAgAHsAfQAKACAAIABXAHIAaQB0AGUALQBPAHUAdABwAHUAdAAgACgAIgBuAGUAdABfAHIAbwB3AD0AIgAgACsAIAAkAG4AYQBtAGUAIAArACAAIgBgAHQAIgAgACsAIAAkAGkAZgBpAHAAIAArACAAIgBgAHQAIgAgACsAIAAkAG0AYQBjACAAKwAgACIAYAB0ADAAYAB0ADAAIgApAAoAfQAKAGYAdQBuAGMAdABpAG8AbgAgAEYAbQB0ACgAWwBpAG4AdAA2ADQAXQAkAGIAKQB7AAoAIAAgAGkAZgAoACQAYgAgAC0AZwBlACAAMQBUAEIAKQB7ACAAcgBlAHQAdQByAG4AIAAoACIAewAwADoATgAxAH0AVAAiACAALQBmACAAKAAkAGIALwAxAFQAQgApACkAIAB9AAoAIAAgAGkAZgAoACQAYgAgAC0AZwBlACAAMQBHAEIAKQB7ACAAcgBlAHQAdQByAG4AIAAoACIAewAwADoATgAxAH0ARwAiACAALQBmACAAKAAkAGIALwAxAEcAQgApACkAIAB9AAoAIAAgAGkAZgAoACQAYgAgAC0AZwBlACAAMQBNAEIAKQB7ACAAcgBlAHQAdQByAG4AIAAoACIAewAwADoATgAxAH0ATQAiACAALQBmACAAKAAkAGIALwAxAE0AQgApACkAIAB9AAoAIAAgAHIAZQB0AHUAcgBuACAAKAAiAHsAMAA6AE4AMAB9AEsAIgAgAC0AZgAgACgAJABiAC8AMQBLAEIAKQApAAoAfQAKAEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8ATABvAGcAaQBjAGEAbABEAGkAcwBrACAALQBGAGkAbAB0AGUAcgAgACIARAByAGkAdgBlAFQAeQBwAGUAPQAzACIAIAB8ACAARgBvAHIARQBhAGMAaAAtAE8AYgBqAGUAYwB0ACAAewAKACAAIAAkAHMAaQB6AGUAPQBbAGkAbgB0ADYANABdACQAXwAuAFMAaQB6AGUAOwAgAGkAZgAoACQAcwBpAHoAZQAgAC0AbABlACAAMAApAHsAIAByAGUAdAB1AHIAbgAgAH0ACgAgACAAJABmAHIAZQBlAD0AWwBpAG4AdAA2ADQAXQAkAF8ALgBGAHIAZQBlAFMAcABhAGMAZQA7ACAAJAB1AHMAZQBkAD0AJABzAGkAegBlAC0AJABmAHIAZQBlAAoAIAAgACQAcABjAHQAPQBbAGkAbgB0AF0AWwBtAGEAdABoAF0AOgA6AFIAbwB1AG4AZAAoACQAdQBzAGUAZAAqADEAMAAwAC4AMAAvACQAcwBpAHoAZQApAAoAIAAgAFcAcgBpAHQAZQAtAE8AdQB0AHAAdQB0ACAAKAAiAGQAaQBzAGsAXwByAG8AdwA9ACIAIAArACAAJABfAC4ARABlAHYAaQBjAGUASQBEACAAKwAgACIAXABcACIAIAArACAAIgBgAHQAIgAgACsAIAAoAEYAbQB0ACAAJABzAGkAegBlACkAIAArACAAIgBgAHQAIgAgACsAIAAoAEYAbQB0ACAAJAB1AHMAZQBkACkAIAArACAAIgBgAHQAIgAgACsAIAAoAEYAbQB0ACAAJABmAHIAZQBlACkAIAArACAAIgBgAHQAIgAgACsAIAAoACQAcABjAHQALgBUAG8AUwB0AHIAaQBuAGcAKAApACAAKwAgACIAJQAiACkAIAArACAAIgBgAHQAIgAgACsAIAAkAF8ALgBGAGkAbABlAFMAeQBzAHQAZQBtACkACgB9AAoA
    exit 0
  fi
fi
echo "distro=${DISTRO:-}"
echo "kernel=`uname -r 2>/dev/null`"
echo "arch=`uname -m 2>/dev/null`"
if [ -f /proc/uptime ]; then
  U=`cut -d. -f1 /proc/uptime 2>/dev/null`
  D=`expr $U / 86400 2>/dev/null`
  H=`expr \\( $U % 86400 \\) / 3600 2>/dev/null`
  M=`expr \\( $U % 3600 \\) / 60 2>/dev/null`
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
    IP=`ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -v '^127\\.' | grep -E '^10\\.|^172\\.(1[6-9]|2[0-9]|3[0-1])\\.|^192\\.168\\.' | head -n1`
  fi
  if [ -z "$IP" ]; then
    IP=`ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -v '^127\\.' | head -n1`
  fi
fi
if [ -z "$IP" ]; then
  IP=`ifconfig 2>/dev/null | awk '/inet /{print $2}' | sed 's/addr://' | grep -v '^127\\.' | head -n1`
fi
echo "ip=${IP:-}"
CPU_MODEL=`awk -F: '/^model name/{gsub(/^[ \\t]+/,"",$2);print $2;exit} /^Hardware/{gsub(/^[ \\t]+/,"",$2);print $2;exit} /^cpu model/{gsub(/^[ \\t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
echo "cpu_model=${CPU_MODEL:-}"
CPU_CORES=`grep -c '^processor' /proc/cpuinfo 2>/dev/null`
if [ -z "$CPU_CORES" ] || [ "$CPU_CORES" = "0" ]; then CPU_CORES=`nproc 2>/dev/null`; fi
echo "cpu_cores=${CPU_CORES:-}"
CPU_MHZ=`awk -F: '/^cpu MHz/{gsub(/^[ \\t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
echo "cpu_mhz=${CPU_MHZ:-}"
CPU_CACHE=`awk -F: '/^cache size/{gsub(/^[ \\t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
echo "cpu_cache=${CPU_CACHE:-}"
CPU_BOGO=`awk -F: '/^[Bb]ogo[Mm][Ii][Pp][Ss]/{gsub(/^[ \\t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
echo "cpu_bogomips=${CPU_BOGO:-}"
S1=`grep '^cpu ' /proc/stat 2>/dev/null`
sleep 1
S2=`grep '^cpu ' /proc/stat 2>/dev/null`
if [ -n "$S1" ] && [ -n "$S2" ]; then
  set -- $S1
  U1=$2; N1=$3; SY1=$4; ID1=$5; IO1=$6; IRQ1=$7; SIRQ1=$8; ST1=$9
  set -- $S2
  U2=$2; N2=$3; SY2=$4; ID2=$5; IO2=$6; IRQ2=$7; SIRQ2=$8; ST2=$9
  awk -v u1=$U1 -v n1=$N1 -v s1=$SY1 -v i1=$ID1 -v w1=$IO1 -v q1=$IRQ1 -v r1=$SIRQ1 -v t1=$ST1 \\
      -v u2=$U2 -v n2=$N2 -v s2=$SY2 -v i2=$ID2 -v w2=$IO2 -v q2=$IRQ2 -v r2=$SIRQ2 -v t2=$ST2 '
  BEGIN{
    du=u2-u1; dn=n2-n1; ds=s2-s1; di=i2-i1; dw=w2-w1; dq=q2-q1; dr=r2-r1; dst=t2-t1
    tot = du+dn+ds+di+dw+dq+dr+dst
    if(tot<=0) tot=1
    printf "cpu_busy=%.1f\\n", (tot-di)*100/tot
    printf "cpu_user=%.1f\\n", (du+dn)*100/tot
    printf "cpu_system=%.1f\\n", ds*100/tot
    printf "cpu_idle=%.1f\\n", di*100/tot
    printf "cpu_iowait=%.1f\\n", dw*100/tot
  }'
else
  echo "cpu_busy="
  echo "cpu_user="
  echo "cpu_system="
  echo "cpu_idle="
  echo "cpu_iowait="
fi
if [ -f /proc/meminfo ]; then
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
      printf "mem_pct=%d\\n", pct
      printf "mem_used_mb=%d\\n", int(u/1024)
      printf "mem_total_mb=%d\\n", int(t/1024)
    } else {
      print "mem_pct="
      print "mem_used_mb="
      print "mem_total_mb="
    }
    if(st>0){
      su=st-sf; if(su<0) su=0
      sp=int(su*100/st+0.5)
      printf "swap_pct=%d\\n", sp
      printf "swap_used_mb=%d\\n", int(su/1024)
      printf "swap_total_mb=%d\\n", int(st/1024)
    } else {
      print "swap_pct=0"
      print "swap_used_mb=0"
      print "swap_total_mb=0"
    }
  }
' /proc/meminfo 2>/dev/null
else
  echo "mem_pct="; echo "mem_used_mb="; echo "mem_total_mb="
  echo "swap_pct=0"; echo "swap_used_mb=0"; echo "swap_total_mb=0"
fi
if [ -d /sys/class/net ]; then
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
  printf 'net_row=%s\\t%s\\t%s\\t%s\\t%s\\n' "$NAME" "${IFIP:-}" "${MAC:-}" "${RX:-0}" "${TX:-0}"
done
fi
df -h 2>/dev/null | awk 'NR>1 {
  fs=$1
  if(fs ~ /^(tmpfs|devtmpfs|sysfs|devfs|map)$/) next
  if($5 ~ /%$/){
    size=$2; used=$3; avail=$4; pct=$5; mnt=$6
    for(i=7;i<=NF;i++) mnt=mnt" "$i
  } else next
  print mnt"|"size"|"used"|"avail"|"pct"|"fs
}' | awk -F'|' '!seen[$1]++ {printf "disk_row=%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n", $1,$2,$3,$4,$5,$6}'
;;
esac
"""

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true; layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        card.rounded(Theme.radiusLg, bg: Theme.bg, border: Theme.borderStrong)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // 原来这里画了一组红/黄/绿假红绿灯，点了没任何反应；右侧已有真正的「关闭」按钮，去掉假的。
        let title = NSTextField(labelWithString: "系统信息"); title.font = Theme.ui(15, .semibold); title.textColor = Theme.text
        let refresh = PillButton("刷新", style: .secondary, hPad: 12, target: self, action: #selector(refreshAction))
        let close = PillButton("关闭", style: .secondary, hPad: 12, target: self, action: #selector(closeAction))
        let head = NSStackView(views: [title, NSView(), refresh, close]); head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false
        head.addGestureRecognizer(HeaderPanGesture(target: self, action: #selector(dragCard(_:))))

        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        grid.orientation = .vertical; grid.alignment = .leading; grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        scroll.documentView = doc

        card.addSubview(head); card.addSubview(scroll)
        cardX = card.centerXAnchor.constraint(equalTo: centerXAnchor)
        cardY = card.topAnchor.constraint(equalTo: topAnchor, constant: 40)
        NSLayoutConstraint.activate([
            cardX, cardY,
            card.widthAnchor.constraint(equalToConstant: 700),
            card.heightAnchor.constraint(equalToConstant: 600),
            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            doc.topAnchor.constraint(equalTo: scroll.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])

        showPlaceholder("采集中…")
    }
    @objc private func closeAction() { onClose?() }
    @objc private func refreshAction() { onRefresh?() }
    // 点遮罩(卡片外)关闭
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) { onClose?() } else { super.mouseDown(with: event) }
    }
    // Esc 关闭
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isHidden, event.keyCode == 53 { onClose?(); return true }
        return super.performKeyEquivalent(with: event)
    }
    @objc private func dragCard(_ g: NSPanGestureRecognizer) {
        let t = g.translation(in: self)
        cardX.constant += t.x; cardY.constant += t.y
        g.setTranslation(.zero, in: self)
    }

    // MARK: - 数据入口

    func show(_ text: String) {
        isHidden = false
        clearGrid()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "采集中…" {
            showPlaceholder("采集中…")
            return
        }
        let info = SysInfoParser.parse(text)
        buildCards(info)
    }

    private func clearGrid() { grid.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    private func showPlaceholder(_ text: String) {
        clearGrid()
        let l = NSTextField(labelWithString: text)
        l.font = Theme.ui(13); l.textColor = Theme.muted
        grid.addArrangedSubview(l)
    }

    // MARK: - 卡片构建

    private func buildCards(_ info: SysInfoParser.SysInfo) {
        addFullWidth(basicCard(info))
        addFullWidth(cpuCard(info))
        addFullWidth(memCard(info))
        if !info.net.isEmpty { addFullWidth(netCard(info.net)) }
        if !info.disks.isEmpty { addFullWidth(diskCard(info.disks)) }
    }

    /// 必须**先加入 grid**（建立共同父视图）再激活等宽约束；
    /// 否则 NSLayoutConstraint 会因"没有共同祖先"抛异常直接崩溃。
    private func addFullWidth(_ v: NSView) {
        grid.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
    }

    private func cardTitle(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = Theme.ui(13, .bold); l.textColor = Theme.text
        return l
    }
    private func labelRow(_ k: String, _ v: String) -> NSView {
        let kl = NSTextField(labelWithString: k); kl.font = Theme.ui(11.5); kl.textColor = Theme.muted
        kl.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let vl = NSTextField(labelWithString: v); vl.font = Theme.mono(11.5); vl.textColor = Theme.text
        vl.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [kl, vl]); row.orientation = .horizontal; row.alignment = .top; row.spacing = 8
        return row
    }
    private func str(_ v: String?) -> String { v?.isEmpty == false ? v! : "-" }

    private func card(_ views: [NSView]) -> NSView {
        let c = CardView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
        ])
        views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return c
    }

    private func basicCard(_ info: SysInfoParser.SysInfo) -> NSView {
        card([
            cardTitle("基本"),
            labelRow("主机名", str(info.hostname)),
            labelRow("发行版", str(info.distro)),
            labelRow("内核", str(info.kernel)),
            labelRow("架构", str(info.arch)),
            labelRow("运行时长", str(info.uptime)),
            labelRow("负载", str(info.load)),
            labelRow("主 IP", str(info.ip)),
        ])
    }

    private func cpuCard(_ info: SysInfoParser.SysInfo) -> NSView {
        let cpu = info.cpu
        var rows: [NSView] = [
            cardTitle("CPU"),
            labelRow("型号", str(cpu.model)),
            labelRow("核心数", cpu.cores.map(String.init) ?? "-"),
        ]
        if let mhz = cpu.mhz { rows.append(labelRow("频率", "\(mhz) MHz")) }
        if let cache = cpu.cache { rows.append(labelRow("缓存", cache)) }
        if let bogo = cpu.bogomips { rows.append(labelRow("BogoMIPS", bogo)) }
        if let busy = cpu.busyPct {
            rows.append(PillBar(pct: busy, kind: .cpu))
            let detail = [
                cpu.userPct.map { "用户 \(fmt1($0))%" },
                cpu.systemPct.map { "系统 \(fmt1($0))%" },
                cpu.idlePct.map { "空闲 \(fmt1($0))%" },
                cpu.iowaitPct.map { "等待 \(fmt1($0))%" },
            ].compactMap { $0 }.joined(separator: "  ")
            if !detail.isEmpty {
                let dl = NSTextField(labelWithString: detail); dl.font = Theme.mono(10.5); dl.textColor = Theme.muted
                rows.append(dl)
            }
        }
        return card(rows)
    }

    private func memCard(_ info: SysInfoParser.SysInfo) -> NSView {
        var rows: [NSView] = [cardTitle("内存 · 交换")]
        if let pct = info.memPct {
            rows.append(PillBar(pct: Double(pct), kind: .mem))
            rows.append(labelRow("内存", "\(info.memUsedMB ?? 0) / \(info.memTotalMB ?? 0) MB"))
        } else {
            rows.append(labelRow("内存", "-"))
        }
        if let spct = info.swapPct {
            rows.append(PillBar(pct: Double(spct), kind: .swap))
            rows.append(labelRow("交换", "\(info.swapUsedMB ?? 0) / \(info.swapTotalMB ?? 0) MB"))
        } else {
            rows.append(labelRow("交换", "-"))
        }
        return card(rows)
    }

    private func netCard(_ rows: [SysInfoParser.NetRow]) -> NSView {
        var views: [NSView] = [cardTitle("网卡")]
        views.append(tableHeader(["网卡", "IP", "MAC", "收/发"], widths: [70, 110, 130, 140]))
        for (i, r) in rows.enumerated() {
            let rx = SysInfoParser.formatBytes(r.rxBytes)
            let tx = SysInfoParser.formatBytes(r.txBytes)
            views.append(tableRow([r.name, str(r.ip), str(r.mac), "\(rx) / \(tx)"], widths: [70, 110, 130, 140], even: i % 2 == 1))
        }
        return card(views)
    }

    private func diskCard(_ rows: [SysInfoParser.DiskRow]) -> NSView {
        var views: [NSView] = [cardTitle("磁盘")]
        views.append(tableHeader(["挂载点", "容量", "已用", "可用", "使用率"], widths: [140, 70, 70, 70, 110]))
        for (i, r) in rows.enumerated() {
            let rowViews: [String] = [r.mount, str(r.size), str(r.used), str(r.avail)]
            let row = tableRow(rowViews, widths: [140, 70, 70, 70], even: i % 2 == 1)
            let bar = PillBar(pct: Double(r.pct ?? 0), kind: .disk)
            bar.widthAnchor.constraint(equalToConstant: 110).isActive = true
            row.addArrangedSubview(bar)
            views.append(row)
        }
        return card(views)
    }

    // MARK: - 小表格

    private func tableHeader(_ cols: [String], widths: [CGFloat]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.wantsLayer = true; row.layer?.backgroundColor = Theme.bg3.cgColor
        for (i, t) in cols.enumerated() {
            let l = NSTextField(labelWithString: t); l.font = Theme.ui(10.5, .semibold); l.textColor = Theme.muted
            l.widthAnchor.constraint(equalToConstant: widths[i]).isActive = true
            row.addArrangedSubview(l)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -4),
            row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
        ])
        return wrap
    }

    @discardableResult
    private func tableRow(_ cols: [String], widths: [CGFloat], even: Bool) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.wantsLayer = true; row.layer?.backgroundColor = (even ? Theme.bg3 : Theme.bg2).cgColor
        for (i, t) in cols.enumerated() {
            let l = NSTextField(labelWithString: t); l.font = Theme.mono(10.5); l.textColor = Theme.text
            l.lineBreakMode = .byTruncatingTail
            l.widthAnchor.constraint(equalToConstant: i < widths.count ? widths[i] : 80).isActive = true
            row.addArrangedSubview(l)
        }
        return row
    }
}

// MARK: - 药丸进度条（局部实现，照抄 MonitorSidebar.Bar 的观感，不改那个文件）

private final class PillBar: NSView {
    enum Kind { case cpu, mem, swap, disk }
    private let track = NSView()
    private let fillV = NSView()
    private let grad = CAGradientLayer()
    private let pctLabel = NSTextField(labelWithString: "0%")
    private var fillW: NSLayoutConstraint!

    init(pct: Double, kind: Kind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 14).isActive = true
        track.wantsLayer = true; track.layer?.cornerRadius = 7; track.layer?.backgroundColor = Theme.fill.cgColor
        track.layer?.borderColor = Theme.border.cgColor; track.layer?.borderWidth = 1
        track.translatesAutoresizingMaskIntoConstraints = false
        fillV.wantsLayer = true; fillV.layer?.cornerRadius = 7; fillV.layer?.masksToBounds = true
        fillV.translatesAutoresizingMaskIntoConstraints = false
        grad.startPoint = CGPoint(x: 0, y: 0.5); grad.endPoint = CGPoint(x: 1, y: 0.5)
        fillV.layer?.addSublayer(grad)
        track.addSubview(fillV)
        pctLabel.font = Theme.ui(9.5, .semibold); pctLabel.textColor = Theme.text
        pctLabel.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(pctLabel)
        addSubview(track)
        fillW = fillV.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            fillV.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fillV.topAnchor.constraint(equalTo: track.topAnchor),
            fillV.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillW,
            pctLabel.leadingAnchor.constraint(equalTo: track.leadingAnchor, constant: 6),
            pctLabel.centerYAnchor.constraint(equalTo: track.centerYAnchor),
        ])
        set(pct: pct, kind: kind)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); grad.frame = fillV.bounds; refreshFill() }

    private var lastPct: CGFloat = 0
    private func refreshFill() {
        let trackW = track.bounds.width
        guard trackW > 0 else { return }
        fillW.constant = trackW * lastPct
    }

    func set(pct: Double, kind: Kind) {
        let c = max(0, min(100, pct))
        lastPct = CGFloat(c / 100)
        pctLabel.stringValue = String(format: "%.0f%%", c)
        let colors: [NSColor]
        if c >= 90 { colors = [Theme.c("#ff9f0a"), Theme.c("#ff453a")] }
        else if c >= 75 { colors = [Theme.c("#ffd60a"), Theme.c("#ff9f0a")] }
        else {
            switch kind {
            case .cpu: colors = [Theme.c("#30d158"), Theme.c("#64d2ff")]
            case .mem: colors = [Theme.c("#64d2ff"), Theme.c("#0a84ff")]
            case .swap: colors = [Theme.c("#bf5af2"), Theme.c("#5e5ce6")]
            case .disk: colors = [Theme.c("#30d158"), Theme.c("#0a84ff")]
            }
        }
        grad.colors = colors.map { $0.cgColor }
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshFill()
            self.grad.frame = self.fillV.bounds
        }
    }
}

private func fmt1(_ d: Double) -> String { String(format: "%.1f", d) }
