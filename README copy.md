# monitor.sh

A small Bash utility for measuring CPU and memory usage of processes on
Linux. Built to provide a reproducible, dependency-free measurement
methodology for a SOMET 2026 monitoring evaluation.

`monitor.sh` reads directly from `/proc` — no `psutil`, no `sysstat`,
no `htop` needed. CPU time is taken from `/proc/[pid]/task/*/schedstat`
(nanosecond resolution, summed across all threads) rather than
`/proc/[pid]/stat` (10 ms jiffy resolution), so trailing decimals on
the reported CPU% are real signal, not zero-padding.

## Requirements

- Linux with `/proc` (kernel 2.6+) and `CONFIG_SCHEDSTATS` enabled
- `bash` 4+, `awk`, `date`, `getconf` (all standard)

## Install

```sh
chmod +x monitor.sh
./monitor.sh --help
```

## Usage

```sh
./monitor.sh system                       # one-shot labeled (whole machine)
./monitor.sh pids                         # PIDs whose comm matches ^python[0-9.]*$
./monitor.sh proc <pid>                   # one-shot labeled (per process)
./monitor.sh sample <interval_s> <target> # streaming CSV to stdout
                                          # target: <pid> | --system | --all-python
```

## Output conventions

- **Per-process `cpu_pct`** is per-core, matching htop: `100%` = one
  fully-busy core. A multi-threaded CPU-bound process can exceed
  `100%` (e.g. an 8-thread process saturating an 8-core box reads
  ~`800%`). Computed as `Σ_threads(Δ schedstat_ns) / Δ wall_ns × 100`.
- **System `cpu_pct`** is whole-machine: `0–100%` of total capacity,
  computed from `/proc/stat` idle vs. total jiffies.
- **Per-process `mem_pct`** is `VmRSS / MemTotal × 100`, matching htop.
  Shared library pages are counted in full per process, so summing
  `mem_pct` across multiple processes can exceed `100%`.
- All percentages are printed with **4 decimal places**. RSS is in KB
  (page-aligned).

## Examples

One-shot whole-machine reading:

```
$ ./monitor.sh system
cpu_pct:       9.3284
mem_pct:       28.6921
mem_total_mb:  31539
mem_avail_mb:  22490
load_1m:       0.10
load_5m:       0.10
load_15m:      0.06
```

One-shot per-process reading:

```
$ ./monitor.sh proc 383140
pid:           383140
comm:          node
state:         S
cpu_pct:       0.0998
mem_pct:       2.0487
rss_kb:        661664
vm_hwm_kb:     759684
vm_peak_kb:    55026568
num_threads:   13
uptime_s:      5596.00
```

Stream a per-process CSV every second:

```
$ ./monitor.sh sample 1 383140 > run.csv
^C
$ head run.csv
timestamp_ns,pid,cpu_pct,mem_pct,rss_kb
1777185850350071637,383140,2.4405,2.0487,661676
1777185851356937274,383140,0.0290,2.0487,661676
1777185852363726573,383140,3.1121,2.0488,661680
```

Stream system-wide CSV:

```
$ ./monitor.sh sample 1 --system > sys.csv
$ head sys.csv
timestamp_ns,cpu_pct,mem_pct
1777185854352210815,0.7509,28.6896
1777185855358528304,0.6211,28.6905
1777185856364774556,0.9950,28.6901
```

Stream every running Python process at once (CSV with one row per pid per tick):

```
$ ./monitor.sh sample 1 --all-python > python.csv
$ head python.csv
timestamp_ns,pid,cpu_pct,mem_pct,rss_kb
...
```

The `sample <pid>` mode exits cleanly with status 0 when the target
process disappears, so it works for measuring fixed-duration workloads.

## Benchmarking workflow

End-to-end recipe for one experimental run:

```sh
# 1. Start the workload in the background
python my_workload.py &
PID=$!

# 2. Stream metrics to a CSV alongside the workload
#    (timeout caps the run at 5 min; sample also exits if PID dies)
timeout 300 ./monitor.sh sample 1 $PID > run1.csv

# 3. Wait for the workload to finish (if still running)
wait $PID 2>/dev/null

# 4. Post-process the CSV to compute summary statistics (snippet below)
python3 summarize.py run1.csv
```

Repeat the run N times with different seeds / configurations, write each
output to `run<i>.csv`, and aggregate across runs in your analysis
notebook. Keep the raw CSVs — they are the primary measurement record.

## Post-processing example

Compute mean, median, std, p95, and p99 from a sample CSV using pandas.
Drop a few warm-up samples to focus on steady state:

```python
# summarize.py
import sys
import pandas as pd

df = pd.read_csv(sys.argv[1])

# Drop warm-up samples (tune for your workload)
df = df.iloc[2:]

stats = df[["cpu_pct", "mem_pct"]].agg(
    ["mean", "median", "std",
     lambda s: s.quantile(0.95),
     lambda s: s.quantile(0.99)]
)
stats.index = ["mean", "median", "std", "p95", "p99"]
print(stats.to_string(float_format=lambda x: f"{x:.4f}"))
```

Example output:

```
        cpu_pct  mem_pct
mean     1.3365   2.0488
median   1.2705   2.0488
std      1.3389   0.0000
p95      2.7920   2.0488
p99      2.8014   2.0488
```

For the paper, **report the raw summary statistics** (mean ± std, median,
p95) computed from the CSV — do **not** apply smoothing during
collection. Smoothing is information-destroying, hides variance (which is
itself a result), and makes the reported number depend on a hidden
window-size parameter.

## Methodology notes

| Metric | Source | Resolution |
|---|---|---|
| Per-process CPU time | `/proc/[pid]/task/*/schedstat` field 1, summed across threads | nanoseconds |
| Per-process RSS | `/proc/[pid]/status` `VmRSS:` | KB (page-aligned) |
| Per-process memory % | `VmRSS / MemTotal × 100` | KB-derived |
| Whole-machine CPU | `/proc/stat` first line (idle + iowait vs. total jiffies) | jiffies (10 ms) |
| Whole-machine memory | `/proc/meminfo` `MemTotal`, `MemAvailable` | KB |
| Process uptime | `/proc/[pid]/stat` starttime vs. `/proc/uptime` | clock ticks |

Per-process CPU formula (sample window `Δt_wall_ns`):

```
cpu_pct = Σ_threads(Δ schedstat_ns) / Δt_wall_ns × 100
```

The sum across `task/*/schedstat` is required because schedstat is
recorded per task (per thread) — for multi-threaded processes, reading
only the tgid's schedstat misses every worker thread. This is the
difference between `0%` and `100%` for a Python process whose main
thread blocks on `time.sleep` while a worker thread burns CPU.

Per-process memory formula:

```
mem_pct = VmRSS_kb / MemTotal_kb × 100
```

`VmRSS` includes shared library pages counted in full, matching htop and
`top`. For single-process workloads (the typical paper scenario) this is
the accepted convention. For multi-process workloads where summing
`mem_pct` would matter, switch to PSS (`/proc/[pid]/smaps_rollup` `Pss:`)
to avoid double-counting shared pages.

## Methodology blurb for the paper

Copy-pasteable paragraph for the Methodology section:

> CPU and memory usage of the workload process are sampled at 1 Hz using
> a custom Bash utility that reads `/proc` directly, avoiding any
> instrumentation overhead from third-party libraries. Per-process CPU
> time is the sum of `sum_exec_runtime` (field 1 of
> `/proc/[pid]/task/*/schedstat`) across all threads of the target
> process, expressed in nanoseconds; CPU utilization is computed as
> `Δ CPU time / Δ wall time × 100` and reported per-core in the htop
> convention (`100%` = one fully-busy core). Per-process memory
> utilization is `VmRSS / MemTotal × 100`, where `VmRSS` is read from
> `/proc/[pid]/status` and `MemTotal` from `/proc/meminfo`. Raw 1 Hz
> samples are written to CSV with nanosecond timestamps; summary
> statistics (mean, median, standard deviation, 95th and 99th
> percentiles) are computed in post-processing over the steady-state
> phase of each run. We report the underlying raw statistics rather
> than smoothed values to preserve information about workload variance.

## License

MIT.
