#!/bin/sh
# BusyBox/OpenWrt/ash/macOS-safe remote metrics. KEY=value lines only.
# CPU uses two /proc/stat samples so bar is instantaneous, not since-boot average.
echo ===mon===

# ── load ──
L=`cat /proc/loadavg 2>/dev/null`
if [ -n "$L" ]; then
  set -- $L
  echo load=$1,$2,$3
else
  # macOS / BSD fallback
  L=`uptime 2>/dev/null | sed -n 's/.*load averages*: //p;s/.*load average: //p' | tr -d ','`
  if [ -n "$L" ]; then
    set -- $L
    echo load=$1,$2,$3
  else
    echo load=-
  fi
fi

# ── uptime ──
U=`cat /proc/uptime 2>/dev/null | cut -d. -f1`
if [ -n "$U" ]; then
  d=`expr $U / 86400 2>/dev/null || echo 0`
  h=`expr \( $U % 86400 \) / 3600 2>/dev/null || echo 0`
  m=`expr \( $U % 3600 \) / 60 2>/dev/null || echo 0`
  echo uptime=${d}d${h}h${m}m
else
  # macOS: sysctl kern.boottime is awkward; show uptime string short
  UU=`uptime 2>/dev/null | sed -n 's/.*up \([^,]*\).*/\1/p'`
  echo uptime=${UU:--}
fi

# ── CPU: prefer two samples; on failure fall back without hanging ──
# fields: user nice system idle iowait irq softirq steal guest ...
read_cpu() {
  awk '/^cpu /{
    idle=$5+0; if(NF>=6) idle+=$6+0;
    t=0; for(i=2;i<=NF;i++) t+=$i+0;
    printf "%s %s\n", idle, t; exit
  }' /proc/stat 2>/dev/null
}
CPU1=`read_cpu`
# short sleep — busybox may only have sleep 1; NEVER hang forever
# use `sleep 1` max once; skip if sleep missing
if command -v sleep >/dev/null 2>&1; then
  sleep 1 2>/dev/null || true
fi
CPU2=`read_cpu`
if [ -n "$CPU1" ] && [ -n "$CPU2" ]; then
  set -- $CPU1
  i1=$1; t1=$2
  set -- $CPU2
  i2=$1; t2=$2
  di=`expr $i2 - $i1 2>/dev/null || echo 0`
  dt=`expr $t2 - $t1 2>/dev/null || echo 0`
  if [ -n "$dt" ] && [ "$dt" -gt 0 ] 2>/dev/null; then
    CPU=`awk -v di="$di" -v dt="$dt" 'BEGIN{
      idle=di*100/dt;
      if(idle<0) idle=0; if(idle>100) idle=100;
      busy=100-idle;
      if(busy<0) busy=0; if(busy>100) busy=100;
      printf "%.1f", busy
    }' 2>/dev/null`
  fi
fi
# fallback: since-boot average if delta failed (no second sample)
if [ -z "$CPU" ]; then
  CPU=`awk '/^cpu /{
    idle=$5+0; if(NF>=6) idle+=$6+0;
    t=0; for(i=2;i<=NF;i++) t+=$i+0;
    if(t>0){ busy=100-idle*100/t; if(busy<0)busy=0; if(busy>100)busy=100; printf "%.1f", busy }
    else print 0
  }' /proc/stat 2>/dev/null`
fi
# macOS fallback via top (one sample) — BSD awk has no match(..., a)
if [ -z "$CPU" ] || [ "$CPU" = "" ]; then
  CPU=`top -l 1 -n 0 2>/dev/null | sed -n 's/.* \([0-9.][0-9.]*\)% idle.*/\1/p' | head -n1 | awk '{ if(NF){ b=100-$1; if(b<0)b=0; if(b>100)b=100; printf "%.1f", b } }'`
fi
if [ -z "$CPU" ]; then
  CPU=0
fi
echo cpu=${CPU:-0}

# ── memory ──
# Linux /proc/meminfo → mem=pct usedMB totalMB
MEM_LINE=`awk '
  /^MemTotal:/{t=$2+0}
  /^MemAvailable:/{a=$2+0}
  /^MemFree:/{f=$2+0}
  /^Buffers:/{b=$2+0}
  /^Cached:/{c=$2+0}
  /^SReclaimable:/{s=$2+0}
  END{
    if(t>0){
      if(a<=0) a=f+b+c+s
      u=t-a; if(u<0) u=0
      pct=int(u*100/t+0.5)
      printf "mem=%d %d %d\n", pct, int(u/1024), int(t/1024)
    }
  }' /proc/meminfo 2>/dev/null`
if [ -n "$MEM_LINE" ]; then
  echo "$MEM_LINE"
else
  # macOS vm_stat (pages)
  PAGE=`pagesize 2>/dev/null || echo 4096`
  VM=`vm_stat 2>/dev/null`
  if [ -n "$VM" ]; then
    echo "$VM" | awk -v ps="$PAGE" '
      /Pages free/{gsub(/\./,"",$3); free=$3+0}
      /Pages active/{gsub(/\./,"",$3); act=$3+0}
      /Pages inactive/{gsub(/\./,"",$3); ina=$3+0}
      /Pages speculative/{gsub(/\./,"",$3); sp=$3+0}
      /Pages wired/{gsub(/\./,"",$4); wir=$4+0}
      /Pages occupied by compressor/{gsub(/\./,"",$5); comp=$5+0}
      END{
        usedp=act+wir+comp; freep=free+sp+ina
        totalp=usedp+freep
        if(totalp>0){
          ub=usedp*ps/1024/1024; tb=totalp*ps/1024/1024
          pct=int(ub*100/tb+0.5)
          printf "mem=%d %d %d\n", pct, int(ub), int(tb)
        } else print "mem=0 0 0"
      }'
  else
    echo mem=0 0 0
  fi
fi

# ── swap ──
SWAP_LINE=`awk '
  /^SwapTotal:/{t=$2+0}
  /^SwapFree:/{f=$2+0}
  END{
    if(t>0){ u=t-f; if(u<0)u=0; printf "swap=%d %d %d\n", int(u*100/t+0.5), int(u/1024), int(t/1024) }
    else print "swap=0 0 0"
  }' /proc/meminfo 2>/dev/null`
if [ -n "$SWAP_LINE" ]; then
  echo "$SWAP_LINE"
else
  # macOS sysctl
  ST=`sysctl -n vm.swapusage 2>/dev/null`
  if [ -n "$ST" ]; then
    echo "$ST" | awk '{
      # total = 2048.00M used = 123.00M free = ...
      for(i=1;i<=NF;i++){
        if($i=="total"){gsub(/M/,"",$(i+2)); t=$(i+2)+0}
        if($i=="used"){gsub(/M/,"",$(i+2)); u=$(i+2)+0}
      }
      if(t>0) printf "swap=%d %d %d\n", int(u*100/t+0.5), int(u), int(t)
      else print "swap=0 0 0"
    }'
  else
    echo swap=0 0 0
  fi
fi

# ── IP (prefer non-loopback) ──
IP=`ip -4 -o addr show scope global 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1`
if [ -z "$IP" ]; then
  IP=`ip -4 addr 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | awk '$0 !~ /^127\./ && $0 != "0.0.0.0" {print; exit}'`
fi
if [ -z "$IP" ]; then
  IP=`ifconfig 2>/dev/null | awk '/inet /{print $2}' | sed 's/addr://' | awk '$0 !~ /^127\./ && $0 != "0.0.0.0" {print; exit}'`
fi
if [ -z "$IP" ]; then
  IP=`hostname -I 2>/dev/null | tr ' ' '\n' | awk '$0 !~ /^127\./ && $0 != "" {print; exit}'`
fi
echo ip=${IP:-}

# ── netdev: first non-lo interface bytes ──
awk -F'[: ]+' 'NR>2{
  gsub(/:/,"",$1)
  if($1!="" && $1!="lo" && $1!~/^lo/ && $1!="docker0" && $1!~/^veth/ && $1!~/^br-/){
    print "net="$1" "$2" "$10; exit
  }
}' /proc/net/dev 2>/dev/null

# ── disks ──
df -h 2>/dev/null | awk 'NR>1 && $1 !~ /tmpfs|devtmpfs|overlay|ubi|shm|efivarfs|squashfs/ {
  if(NF>=6) print "disk="$6"\t"$2"\t"$3"\t"$4"\t"$5
  else if(NF>=5) print "disk="$NF"\t"$2"\t"$3"\t"$4"\t"$5
}' | head -n 12

# ── processes: mem \t cpu \t cmd ──
if ps aux >/dev/null 2>&1; then
  ps aux 2>/dev/null | awk 'NR>1 {
    cpu=$3+0; rss=$6+0; pmem=$4+0; cmd=""
    for(i=11;i<=NF;i++) cmd=cmd (i==11?"":" ") $i
    if(cmd=="") cmd=$11
    if (rss>0) mb=sprintf("%.1fM", rss/1024)
    else if (pmem>0) mb=sprintf("%.1f%%", pmem)
    else mb="-"
    # keep one decimal on cpu so 0.3 is not lost as 0
    printf "proc=%s\t%.1f\t%s\n", mb, cpu, cmd
  }' | sort -t'	' -k2 -nr 2>/dev/null | head -n 12
elif ps -axo rss,pcpu,command >/dev/null 2>&1; then
  ps -axo rss,pcpu,command 2>/dev/null | awk 'NR>1 {
    rss=$1+0; cpu=$2+0; cmd=""
    for(i=3;i<=NF;i++) cmd=cmd (i==3?"":" ") $i
    if(rss>0) mb=sprintf("%.1fM", rss/1024); else mb="-"
    printf "proc=%s\t%.1f\t%s\n", mb, cpu, cmd
  }' | sort -t'	' -k2 -nr 2>/dev/null | head -n 12
else
  ps w 2>/dev/null | awk 'NR>1 {
    cmd=""; for(i=5;i<=NF;i++) cmd=cmd (i==5?"":" ") $i
    printf "proc=-\t-\t%s\n", cmd
  }' | head -n 12
fi

# ── ping default gateway (optional; skip if no GW — never hang connect) ──
GW=`ip route 2>/dev/null | awk '/default/{print $3; exit}'`
if [ -z "$GW" ]; then
  GW=`route -n 2>/dev/null | awk '/^0.0.0.0/{print $2; exit}'`
fi
if [ -z "$GW" ]; then
  GW=`route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'`
fi
if [ -n "$GW" ]; then
  # -W 1 / -w 1 / -t 1 : hard cap; if ping missing, leave empty
  P=`ping -c 1 -W 1 $GW 2>/dev/null | sed -n 's/.*time[=:]\([0-9.][0-9.]*\).*/\1/p' | head -n1`
  if [ -z "$P" ]; then
    P=`ping -c 1 -w 1 $GW 2>/dev/null | sed -n 's/.*time[=:]\([0-9.][0-9.]*\).*/\1/p' | head -n1`
  fi
  if [ -z "$P" ]; then
    P=`ping -c 1 -t 1 $GW 2>/dev/null | sed -n 's/.*time[=:]\([0-9.][0-9.]*\).*/\1/p' | head -n1`
  fi
  echo ping_ms=$P
  echo ping_target=$GW
else
  echo ping_ms=
  echo ping_target=
fi
echo ===end===
