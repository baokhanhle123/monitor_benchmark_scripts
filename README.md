# process_spawner

Tooling for the SOMET 2026 process-monitoring evaluation. The repo ships
two independent utilities: [`spawner`](spawner.cpp), a C++ workload
generator that produces a known number of PIDs for a known time window,
and [`monitor.sh`](monitor.sh), a general-purpose Bash script that
measures CPU and memory usage from `/proc`. Either tool is useful on its
own.

## Spawner

Small C++ utility to benchmark process-monitoring tools. Parent forks a
configurable number of children (flat tree), each child sleeps for a fixed
duration and exits cleanly. Parent waits for every child synchronously.

No CPU or memory load — the goal is to let a monitoring tool observe a known
number of PIDs for a known time window.

### Build

```
make
```

Produces `./spawner`.

### Usage

```
./spawner --num N --duration S [--quiet]
```

- `--num N` — number of children to fork, `1..10000`.
- `--duration S` — seconds each child sleeps before exit, `>= 1`.
- `--quiet` — suppress per-step parent logs.

### Examples

Smoke test (5 children, 3 seconds):

```
./spawner --num 5 --duration 3
```

Benchmark, 5-minute window, 100 children:

```
./spawner --num 100 --duration 300
```

Benchmark, 10-minute window, 500 children:

```
./spawner --num 500 --duration 600
```

### Notes

- Parent puts itself into its own process group (`setpgid`). On `SIGINT` /
  `SIGTERM` it signals the whole group with `SIGTERM` so children are torn
  down without leaving zombies.
- If `fork()` fails partway (e.g. `RLIMIT_NPROC`), the parent logs a warning,
  stops spawning, and still waits on the children it did create — the run
  produces partial but usable data for benchmarking.
- Exit code: `0` if every child exited cleanly and no fork failed; `2`
  otherwise. `1` is reserved for argument errors.

## Monitor

A small Bash utility for measuring CPU and memory usage of Python processes
on Linux. Built to provide a reproducible, dependency-free measurement
methodology for a SOMET 2026 monitoring evaluation.

`monitor.sh` reads directly from `/proc` — no `psutil`, no `sysstat`,
no `htop` needed. CPU time is taken from `/proc/[pid]/task/*/schedstat`
(nanosecond resolution, summed across all threads) rather than
`/proc/[pid]/stat` (10 ms jiffy resolution), so trailing decimals on
the reported CPU% are real signal, not zero-padding.

### Requirements

- Linux with `/proc` (kernel 2.6+)
- `bash` 4+, `awk`, `nproc`, `date` (all standard)

### Install

```sh
chmod +x monitor.sh
./monitor.sh --help
```

### Usage

```sh
./monitor.sh system                       # one-shot: cpu_pct mem_pct (whole machine)
./monitor.sh pids                         # PIDs whose comm matches ^python[0-9.]*$
./monitor.sh proc <pid>                   # one-shot: cpu_pct rss_kb for a PID
./monitor.sh sample <interval_s> <target> # streaming CSV to stdout
                                          # target: <pid> | --system | --all-python
```

CPU% is normalized to **0–100% of total machine capacity** (`nproc` cores).
A single saturated thread on an 8-core machine therefore reads ~12.5%, not 100%.
Memory is RSS in KB (per process) or % of `MemTotal` (whole machine).
Both are printed with 4 decimal places.

### Examples

One-shot whole-machine reading:

```sh
$ ./monitor.sh system
8.3437 32.5089
```

List your Python processes and read one of them:

```sh
$ ./monitor.sh pids
347594
$ ./monitor.sh proc 347594
12.4914 9764
```

Stream a CSV log of every Python process every second:

```sh
$ ./monitor.sh sample 1 --all-python > log.csv
^C
$ head log.csv
timestamp_ns,pid,cpu_pct,rss_kb
1777142243839231466,348528,12.5468,9724
1777142243839231466,348529,0.3454,9676
1777142245047857479,348528,12.4743,9724
...
```

Stream system-wide CSV:

```sh
$ ./monitor.sh sample 1 --system > sys.csv
$ head sys.csv
timestamp_ns,cpu_pct,mem_pct
1777142249644008716,13.5169,32.5504
...
```

The `sample <pid>` mode exits cleanly with status 0 when the target
process disappears, so it works for measuring fixed-duration workloads.

### Methodology notes

| Metric | Source | Resolution |
|---|---|---|
| Per-process CPU time | `/proc/[pid]/task/*/schedstat` field 1, summed | nanoseconds |
| Per-process RSS | `/proc/[pid]/status` `VmRSS:` | KB (page-aligned) |
| Whole-machine CPU | `/proc/stat` first line (idle + iowait vs. total jiffies) | jiffies |
| Whole-machine memory | `/proc/meminfo` `MemTotal`, `MemAvailable` | KB |

Per-process CPU formula (sample window of `Δt_wall_ns`):

```
cpu_pct = Σ_threads(Δschedstat_ns) / (Δt_wall_ns × nproc) × 100
```

The sum across `task/*/schedstat` is required because schedstat is recorded
per task (per thread) — for multi-threaded processes, reading only the
tgid's schedstat misses every worker thread. This is the difference
between "0%" and "12.5%" for a Python process whose main thread blocks
on `time.sleep` while worker threads burn CPU.

### License

MIT.
