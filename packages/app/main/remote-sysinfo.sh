#!/bin/sh
# BusyBox/OpenWrt/ash-safe one-shot system info. KEY=value / KEY.n=value lines only.
# Mirrors classic SSH client "系统信息" panel fields (agentless /proc + uname).
echo ===sysinfo===

# ── identity ──
HN=`hostname 2>/dev/null || uname -n 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo -`
echo hostname=${HN:--}

# uname pieces (BusyBox supports -s -n -r -m -v -a)
echo kernel_name=`uname -s 2>/dev/null || echo Linux`
echo kernel_release=`uname -r 2>/dev/null || echo -`
echo kernel_version=`uname -v 2>/dev/null || echo -`
echo machine=`uname -m 2>/dev/null || echo -`
echo uname_a=`uname -a 2>/dev/null || echo -`

# ── OS release (OpenWrt /etc/openwrt_release, alpine, debian, redhat) ──
OS_PRETTY=
if [ -f /etc/os-release ]; then
  OS_PRETTY=`awk -F= '
    /^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; found=1}
    /^NAME=/{if(!n){gsub(/"/,"",$2); n=$2}}
    /^VERSION=/{if(!v){gsub(/"/,"",$2); v=$2}}
    END{ if(!found && n!=""){ if(v!="") print n" "v; else print n } }
  ' /etc/os-release 2>/dev/null`
  OS_ID=`awk -F= '/^ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null`
  OS_VER=`awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null`
  [ -n "$OS_ID" ] && echo os_id=$OS_ID
  [ -n "$OS_VER" ] && echo os_version=$OS_VER
fi
if [ -z "$OS_PRETTY" ] && [ -f /etc/openwrt_release ]; then
  OS_PRETTY=`awk -F"'" '/DISTRIB_DESCRIPTION/{print $2; exit}' /etc/openwrt_release 2>/dev/null`
  [ -z "$OS_PRETTY" ] && OS_PRETTY=`awk -F"'" '/DISTRIB_ID/{id=$2} /DISTRIB_RELEASE/{r=$2} END{if(id!="")print id" "r}' /etc/openwrt_release 2>/dev/null`
fi
if [ -z "$OS_PRETTY" ] && [ -f /etc/redhat-release ]; then
  OS_PRETTY=`head -n1 /etc/redhat-release 2>/dev/null`
fi
if [ -z "$OS_PRETTY" ] && [ -f /etc/issue ]; then
  OS_PRETTY=`head -n1 /etc/issue 2>/dev/null | sed 's/\\\\[a-z]//g' | tr -d '\r'`
fi
echo os_pretty=${OS_PRETTY:--}

# ── uptime ──
U=`cat /proc/uptime 2>/dev/null | cut -d. -f1`
if [ -n "$U" ]; then
  d=`expr $U / 86400 2>/dev/null || echo 0`
  h=`expr \( $U % 86400 \) / 3600 2>/dev/null || echo 0`
  m=`expr \( $U % 3600 \) / 60 2>/dev/null || echo 0`
  s=`expr $U % 60 2>/dev/null || echo 0`
  echo uptime_sec=$U
  echo uptime=${d}d${h}h${m}m
  echo uptime_human=${d} days, ${h} hours, ${m} minutes
else
  UU=`uptime 2>/dev/null | sed -n 's/.*up \([^,]*\).*/\1/p'`
  echo uptime_sec=
  echo uptime=${UU:--}
  echo uptime_human=${UU:--}
fi

# ── loadavg ──
L=`cat /proc/loadavg 2>/dev/null`
if [ -n "$L" ]; then
  set -- $L
  echo load=$1,$2,$3
  echo load_1=$1
  echo load_5=$2
  echo load_15=$3
  echo procs_running=$4
else
  L=`uptime 2>/dev/null | sed -n 's/.*load averages*: //p;s/.*load average: //p' | tr -d ','`
  set -- $L
  echo load=$1,$2,$3
  echo load_1=$1
  echo load_5=$2
  echo load_15=$3
fi

# ── CPU model / cores / bogomips (table rows like classic client) ──
NPROC=`grep -c '^processor' /proc/cpuinfo 2>/dev/null || nproc 2>/dev/null || echo 1`
echo cpu_count=${NPROC:-1}

# Emit one cpu_row per logical processor when model lines exist; else one summary
awk '
  BEGIN{ n=0; model=""; mhz=""; cache=""; bogo=""; vendor=""; impl="" }
  /^processor[ \t]*:/{
    if(n>0){
      printf "cpu_row=%d\t%s\t%s\t%s\t%s\n", n-1, model, mhz, cache, bogo
    }
    n++; model=""; mhz=""; cache=""; bogo=""
  }
  /^model name[ \t]*:/{ sub(/^[^:]*:[ \t]*/,""); model=$0 }
  /^Hardware[ \t]*:/{ if(model==""){ sub(/^[^:]*:[ \t]*/,""); model=$0 } }
  /^cpu model[ \t]*:/{ if(model==""){ sub(/^[^:]*:[ \t]*/,""); model=$0 } }
  /^cpu MHz[ \t]*:/{ sub(/^[^:]*:[ \t]*/,""); mhz=$0 }
  /^BogoMIPS[ \t]*:/{ sub(/^[^:]*:[ \t]*/,""); bogo=$0 }
  /^bogomips[ \t]*:/{ sub(/^[^:]*:[ \t]*/,""); bogo=$0 }
  /^cache size[ \t]*:/{ sub(/^[^:]*:[ \t]*/,""); cache=$0 }
  /^CPU part[ \t]*:/{ }
  END{
    if(n>0){
      printf "cpu_row=%d\t%s\t%s\t%s\t%s\n", n-1, model, mhz, cache, bogo
    }
  }
' /proc/cpuinfo 2>/dev/null | head -n 64

# first model as summary
CPU_MODEL=`awk -F: '
  /^model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}
  /^Hardware/{gsub(/^[ \t]+/,"",$2); print $2; exit}
  /^cpu model/{gsub(/^[ \t]+/,"",$2); print $2; exit}
' /proc/cpuinfo 2>/dev/null`
echo cpu_model=${CPU_MODEL:--}

# ── CPU time breakdown (user/nice/system/idle/iowait/irq/softirq/steal) ──
awk '/^cpu /{
  u=$2+0; ni=$3+0; sy=$4+0; id=$5+0; io=0; irq=0; sirq=0; st=0;
  if(NF>=6) io=$6+0;
  if(NF>=7) irq=$7+0;
  if(NF>=8) sirq=$8+0;
  if(NF>=9) st=$9+0;
  t=u+ni+sy+id+io+irq+sirq+st;
  if(t<=0) t=1;
  printf "cpu_user=%.1f\n", u*100/t;
  printf "cpu_nice=%.1f\n", ni*100/t;
  printf "cpu_system=%.1f\n", sy*100/t;
  printf "cpu_idle=%.1f\n", id*100/t;
  printf "cpu_iowait=%.1f\n", io*100/t;
  printf "cpu_irq=%.1f\n", irq*100/t;
  printf "cpu_softirq=%.1f\n", sirq*100/t;
  printf "cpu_steal=%.1f\n", st*100/t;
  busy=100-id*100/t; if(busy<0)busy=0; if(busy>100)busy=100;
  printf "cpu_busy=%.1f\n", busy;
  exit
}' /proc/stat 2>/dev/null

# ── memory / swap (KB + human) ──
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
      printf "mem_total_kb=%d\n", t
      printf "mem_used_kb=%d\n", u
      printf "mem_free_kb=%d\n", f
      printf "mem_available_kb=%d\n", a
      printf "mem_buffers_kb=%d\n", b
      printf "mem_cached_kb=%d\n", c
      printf "mem_pct=%d\n", pct
      printf "mem=%d %d %d\n", pct, int(u/1024), int(t/1024)
    } else {
      print "mem=0 0 0"
      print "mem_pct=0"
    }
    if(st>0){
      su=st-sf; if(su<0) su=0
      sp=int(su*100/st+0.5)
      printf "swap_total_kb=%d\n", st
      printf "swap_used_kb=%d\n", su
      printf "swap_free_kb=%d\n", sf
      printf "swap_pct=%d\n", sp
      printf "swap=%d %d %d\n", sp, int(su/1024), int(st/1024)
    } else {
      print "swap=0 0 0"
      print "swap_pct=0"
      print "swap_total_kb=0"
      print "swap_used_kb=0"
    }
  }
' /proc/meminfo 2>/dev/null

# ── network interfaces (name, ipv4, mac, rx_bytes, tx_bytes) ──
# /proc/net/dev columns: iface rx_bytes ... tx_bytes at field 10 after split
awk -F'[: ]+' 'NR>2{
  gsub(/:/,"",$1)
  if($1=="" || $1=="lo" || $1 ~ /^lo/) next
  # skip virtual noise but keep eth/en/wlan/br-lan/pppoe common router ifaces
  printf "net_row=%s\t%s\t%s\n", $1, $2, $10
}' /proc/net/dev 2>/dev/null | head -n 24

# IPv4 per iface (ip or ifconfig)
if command -v ip >/dev/null 2>&1; then
  ip -o -4 addr show 2>/dev/null | awk '{
    iface=$2; split($4,a,"/");
    if(iface=="lo") next;
    printf "net_ip=%s\t%s\n", iface, a[1]
  }' | head -n 24
else
  # BusyBox ifconfig: "inet addr:x" or "inet x"
  ifconfig 2>/dev/null | awk '
    /^[a-zA-Z0-9]/{ if(iface!="" && ip!="") printf "net_ip=%s\t%s\n", iface, ip; iface=$1; gsub(/:/,"",iface); ip="" }
    /inet /{
      for(i=1;i<=NF;i++){
        if($i ~ /^addr:/){ split($i,a,":"); ip=a[2] }
        else if($i=="inet" && $(i+1) !~ /^addr/ && $(i+1) !~ /^6/){ ip=$(i+1) }
      }
    }
    END{ if(iface!="" && ip!="" && iface!="lo") printf "net_ip=%s\t%s\n", iface, ip }
  ' | head -n 24
fi

# MAC per iface
if [ -d /sys/class/net ]; then
  for d in /sys/class/net/*; do
    [ -d "$d" ] || continue
    name=`basename "$d"`
    [ "$name" = "lo" ] && continue
    mac=`cat "$d/address" 2>/dev/null`
    [ -n "$mac" ] && [ "$mac" != "00:00:00:00:00:00" ] && echo mac=$name	$mac
  done | head -n 24
fi

# primary IP
IP=`ip -4 -o addr show scope global 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1`
if [ -z "$IP" ]; then
  IP=`ifconfig 2>/dev/null | awk '/inet /{print $2}' | sed 's/addr://' | awk '$0 !~ /^127\./ && $0 != "0.0.0.0" {print; exit}'`
fi
echo ip=${IP:-}

# ── disks: prefer POSIX df -P (1K-blocks) then humanize — works BusyBox/Linux ──
df -P 2>/dev/null | awk 'NR>1 {
  fs=$1
  blocks=$2+0; used=$3+0; avail=$4+0; pct=$5
  mnt=$6; for(i=7;i<=NF;i++) mnt=mnt" "$i
  if(fs=="" || fs=="map" || fs ~ /^(tmpfs|devtmpfs|devfs|efivarfs|proc|sysfs|cgroup|autofs)$/) next
  if(mnt ~ /^\/dev$|^\/run|^\/sys|^\/proc|^\/System\/Volumes\/(Preboot|VM|Update)/) next
  if(mnt=="" || mnt=="/dev") next
  # humanize KiB → G/M (no user functions — BusyBox awk)
  hsz=""; hused=""; havail=""
  for(kind=1; kind<=3; kind++){
    v = (kind==1?blocks:(kind==2?used:avail))
    if(v>=1048576){ s=sprintf("%.1fG", v/1048576); gsub(/\.0G/,"G",s) }
    else if(v>=1024){ s=sprintf("%.1fM", v/1024); gsub(/\.0M/,"M",s) }
    else s=sprintf("%dK", v)
    if(kind==1) hsz=s; else if(kind==2) hused=s; else havail=s
  }
  if(pct !~ /%$/) pct=pct"%"
  printf "disk=%s\t%s\t%s\t%s\t%s\t%s\n", mnt, hsz, hused, havail, pct, fs
  printf "disk_p=%s\t%d\t%d\t%d\t%s\t%s\n", mnt, blocks, used, avail, pct, fs
}' | head -n 40

# Fallback: human df -h when df -P missing (rare)
if ! df -P >/dev/null 2>&1; then
  df -h 2>/dev/null | awk 'NR>1 {
    fs=$1
    # Linux: Size Used Avail Use% Mounted
    if($5 ~ /%$/){
      size=$2; used=$3; avail=$4; pct=$5; mnt=$6
      for(i=7;i<=NF;i++) mnt=mnt" "$i
    } else if($9!=""){
      # Darwin-style extra inode cols
      size=$2; used=$3; avail=$4; pct=$5; mnt=$NF
    } else next
    if(fs ~ /^(tmpfs|devtmpfs|devfs|map)$/) next
    printf "disk=%s\t%s\t%s\t%s\t%s\t%s\n", mnt, size, used, avail, pct, fs
  }' | head -n 20
fi


echo ===end===
