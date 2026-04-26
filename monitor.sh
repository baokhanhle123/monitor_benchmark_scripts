#!/usr/bin/env bash
# monitor.sh - CPU/Memory monitoring for SOMET 2026 paper
#
# Reads /proc/[pid]/schedstat (nanosecond CPU time) and
# /proc/[pid]/status VmRSS (KB). Per-process cpu_pct is per-core
# (htop-style: 100% = one fully-busy core, multi-threaded processes
# can exceed 100%). System-wide cpu_pct is whole-machine (0-100%).

set -uo pipefail

HZ="$(getconf CLK_TCK)"
MEMTOTAL_KB="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"

now_ns() { date +%s%N; }

read_proc_cpu_ns() {
    local pid=$1
    [[ -d "/proc/$pid/task" ]] || return 1
    awk 'FNR==1 {sum += $1} END {print sum+0}' /proc/"$pid"/task/*/schedstat 2>/dev/null
}

read_proc_rss_kb() {
    local pid=$1
    [[ -r "/proc/$pid/status" ]] || return 1
    awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status"
}

read_proc_status_fields() {
    local pid=$1
    [[ -r "/proc/$pid/status" ]] || return 1
    awk '
        /^State:/   { state = $2 }
        /^VmRSS:/   { rss = $2 }
        /^VmPeak:/  { vmpeak = $2 }
        /^VmHWM:/   { vmhwm = $2 }
        /^Threads:/ { threads = $2 }
        END {
            if (state == "")   state = "?"
            print state, rss+0, vmpeak+0, vmhwm+0, threads+0
        }
    ' "/proc/$pid/status"
}

read_proc_uptime_s() {
    local pid=$1
    [[ -r "/proc/$pid/stat" ]] || return 1
    awk -v hz="$HZ" '
        FNR == NR {
            line = $0
            sub(/^.*\) /, "", line)
            split(line, a, " ")
            starttime = a[20]
            next
        }
        { sysup = $1 }
        END {
            if (hz <= 0) hz = 100
            printf "%.2f\n", sysup - (starttime / hz)
        }
    ' "/proc/$pid/stat" /proc/uptime
}

read_loadavg() {
    awk '{print $1, $2, $3; exit}' /proc/loadavg
}

read_system_cpu() {
    awk '/^cpu / {
        total=0
        for (i=2; i<=NF; i++) total += $i
        idle = $5 + $6
        print total, idle
        exit
    }' /proc/stat
}

read_system_mem() {
    awk '
        /^MemTotal:/    { total = $2 }
        /^MemAvailable:/ { avail = $2 }
        END             { print total, avail }
    ' /proc/meminfo
}

list_python_pids() {
    local pid comm
    for d in /proc/[0-9]*; do
        pid=${d##*/}
        comm=$(cat "$d/comm" 2>/dev/null) || continue
        if [[ "$comm" =~ ^python[0-9.]*$ ]]; then
            echo "$pid"
        fi
    done
}

cmd_system() {
    local t1 i1 t2 i2 mtotal mavail l1 l5 l15
    read -r t1 i1 < <(read_system_cpu)
    sleep 1
    read -r t2 i2 < <(read_system_cpu)
    read -r mtotal mavail < <(read_system_mem)
    read -r l1 l5 l15 < <(read_loadavg)
    awk -v t1="$t1" -v i1="$i1" -v t2="$t2" -v i2="$i2" \
        -v mt="$mtotal" -v ma="$mavail" \
        -v l1="$l1" -v l5="$l5" -v l15="$l15" \
        'BEGIN {
            dt = t2 - t1; di = i2 - i1
            cpu = (dt > 0) ? (1 - di/dt) * 100 : 0
            mem = (mt > 0) ? (1 - ma/mt) * 100 : 0
            mt_mb = int(mt / 1024)
            ma_mb = int(ma / 1024)
            fmt = "%-14s %s\n"
            printf fmt, "cpu_pct:",      sprintf("%.4f", cpu)
            printf fmt, "mem_pct:",      sprintf("%.4f", mem)
            printf fmt, "mem_total_mb:", mt_mb
            printf fmt, "mem_avail_mb:", ma_mb
            printf fmt, "load_1m:",      l1
            printf fmt, "load_5m:",      l5
            printf fmt, "load_15m:",     l15
        }'
}

cmd_pids() {
    list_python_pids
}

cmd_proc() {
    local pid=${1:-}
    if [[ -z "$pid" ]]; then
        echo "Usage: $0 proc <pid>" >&2; exit 2
    fi
    local c1 c2 t1 t2 comm state rss vmpeak vmhwm threads uptime
    c1=$(read_proc_cpu_ns "$pid") || { echo "PID $pid not found" >&2; exit 1; }
    t1=$(now_ns)
    sleep 1
    c2=$(read_proc_cpu_ns "$pid") || { echo "PID $pid disappeared" >&2; exit 1; }
    t2=$(now_ns)
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || comm="?"
    if ! read -r state rss vmpeak vmhwm threads < <(read_proc_status_fields "$pid"); then
        state="?"; rss=0; vmpeak=0; vmhwm=0; threads=0
    fi
    uptime=$(read_proc_uptime_s "$pid" 2>/dev/null) || uptime="0.00"
    awk -v pid="$pid" -v comm="$comm" -v state="$state" \
        -v c1="$c1" -v c2="$c2" -v t1="$t1" -v t2="$t2" \
        -v rss="$rss" -v vmpeak="$vmpeak" -v vmhwm="$vmhwm" \
        -v threads="$threads" -v uptime="$uptime" -v mt="$MEMTOTAL_KB" \
        'BEGIN {
            dc = c2 - c1; dt = t2 - t1
            cpu = (dt > 0) ? (dc / dt) * 100 : 0
            mem = (mt > 0) ? (rss / mt) * 100 : 0
            fmt = "%-14s %s\n"
            printf fmt, "pid:",         pid
            printf fmt, "comm:",        comm
            printf fmt, "state:",       state
            printf fmt, "cpu_pct:",     sprintf("%.4f", cpu)
            printf fmt, "mem_pct:",     sprintf("%.4f", mem)
            printf fmt, "rss_kb:",      rss
            printf fmt, "vm_hwm_kb:",   vmhwm
            printf fmt, "vm_peak_kb:",  vmpeak
            printf fmt, "num_threads:", threads
            printf fmt, "uptime_s:",    uptime
        }'
}

sample_pid() {
    local interval=$1 pid=$2
    local c1 c2 t1 t2 rss
    c1=$(read_proc_cpu_ns "$pid") || { echo "PID $pid not found" >&2; exit 1; }
    t1=$(now_ns)
    echo "timestamp_ns,pid,cpu_pct,mem_pct,rss_kb"
    while true; do
        sleep "$interval"
        c2=$(read_proc_cpu_ns "$pid" 2>/dev/null) || break
        t2=$(now_ns)
        rss=$(read_proc_rss_kb "$pid" 2>/dev/null) || rss=0
        awk -v ts="$t2" -v pid="$pid" -v c1="$c1" -v c2="$c2" \
            -v t1="$t1" -v t2="$t2" -v rss="$rss" -v mt="$MEMTOTAL_KB" \
            'BEGIN {
                dc = c2 - c1; dt = t2 - t1
                cpu = (dt > 0) ? (dc / dt) * 100 : 0
                mem = (mt > 0) ? (rss / mt) * 100 : 0
                printf "%s,%s,%.4f,%.4f,%d\n", ts, pid, cpu, mem, rss
            }'
        c1=$c2; t1=$t2
    done
}

sample_system() {
    local interval=$1
    local t1 i1 t2 i2 mtotal mavail ts
    read -r t1 i1 < <(read_system_cpu)
    echo "timestamp_ns,cpu_pct,mem_pct"
    while true; do
        sleep "$interval"
        read -r t2 i2 < <(read_system_cpu)
        read -r mtotal mavail < <(read_system_mem)
        ts=$(now_ns)
        awk -v ts="$ts" -v t1="$t1" -v i1="$i1" -v t2="$t2" -v i2="$i2" \
            -v mt="$mtotal" -v ma="$mavail" \
            'BEGIN {
                dt = t2 - t1; di = i2 - i1
                cpu = (dt > 0) ? (1 - di/dt) * 100 : 0
                mem = (mt > 0) ? (1 - ma/mt) * 100 : 0
                printf "%s,%.4f,%.4f\n", ts, cpu, mem
            }'
        t1=$t2; i1=$i2
    done
}

sample_all_python() {
    local interval=$1
    declare -A prev_cpu
    local prev_t curr_t pid c1 c2 rss
    echo "timestamp_ns,pid,cpu_pct,mem_pct,rss_kb"
    prev_t=$(now_ns)
    while read -r pid; do
        c1=$(read_proc_cpu_ns "$pid" 2>/dev/null) || continue
        prev_cpu[$pid]=$c1
    done < <(list_python_pids)
    while true; do
        sleep "$interval"
        curr_t=$(now_ns)
        while read -r pid; do
            c2=$(read_proc_cpu_ns "$pid" 2>/dev/null) || continue
            rss=$(read_proc_rss_kb "$pid" 2>/dev/null) || continue
            c1=${prev_cpu[$pid]:-$c2}
            awk -v ts="$curr_t" -v pid="$pid" -v c1="$c1" -v c2="$c2" \
                -v t1="$prev_t" -v t2="$curr_t" -v rss="$rss" \
                -v mt="$MEMTOTAL_KB" \
                'BEGIN {
                    dc = c2 - c1; dt = t2 - t1
                    cpu = (dt > 0) ? (dc / dt) * 100 : 0
                    mem = (mt > 0) ? (rss / mt) * 100 : 0
                    printf "%s,%s,%.4f,%.4f,%d\n", ts, pid, cpu, mem, rss
                }'
            prev_cpu[$pid]=$c2
        done < <(list_python_pids)
        prev_t=$curr_t
    done
}

cmd_sample() {
    local interval=${1:-}
    local target=${2:-}
    if [[ -z "$interval" || -z "$target" ]]; then
        echo "Usage: $0 sample <interval_s> <pid|--system|--all-python>" >&2
        exit 2
    fi
    case "$target" in
        --system)     sample_system "$interval" ;;
        --all-python) sample_all_python "$interval" ;;
        *)            sample_pid "$interval" "$target" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $0 <subcommand> [args]

Subcommands:
  system                          One-shot, labeled (whole machine):
                                    cpu_pct, mem_pct, mem_total_mb, mem_avail_mb,
                                    load_1m, load_5m, load_15m
  pids                            List python PIDs (comm matches ^python[0-9.]*\$)
  proc <pid>                      One-shot, labeled (per process):
                                    pid, comm, state, cpu_pct, mem_pct,
                                    rss_kb, vm_hwm_kb, vm_peak_kb,
                                    num_threads, uptime_s
  sample <interval_s> <target>    Continuous CSV to stdout (Ctrl+C to stop)
                                  target: <pid> | --system | --all-python

Per-process cpu_pct is per-core (htop convention): 100% = one fully-busy
core; multi-threaded processes can exceed 100%. System cpu_pct is
whole-machine (0-100%). CPU is read from /proc/[pid]/schedstat
(nanosecond resolution). Per-process mem_pct = VmRSS / MemTotal * 100
(htop convention; shared pages counted in full per process). Memory is
RSS in KB (per-process) or % of MemTotal (system).
EOF
}

case "${1:-}" in
    system)       shift; cmd_system "$@" ;;
    pids)         shift; cmd_pids "$@" ;;
    proc)         shift; cmd_proc "$@" ;;
    sample)       shift; cmd_sample "$@" ;;
    -h|--help|"") usage ;;
    *)            usage; exit 2 ;;
esac
