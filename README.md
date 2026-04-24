# process_spawner

Small C++ utility to benchmark process-monitoring tools. Parent forks a
configurable number of children (flat tree), each child sleeps for a fixed
duration and exits cleanly. Parent waits for every child synchronously.

No CPU or memory load — the goal is to let a monitoring tool observe a known
number of PIDs for a known time window.

## Build

```
make
```

Produces `./spawner`.

## Usage

```
./spawner --num N --duration S [--quiet]
```

- `--num N` — number of children to fork, `1..10000`.
- `--duration S` — seconds each child sleeps before exit, `>= 1`.
- `--quiet` — suppress per-step parent logs.

## Examples

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

## Notes

- Parent puts itself into its own process group (`setpgid`). On `SIGINT` /
  `SIGTERM` it signals the whole group with `SIGTERM` so children are torn
  down without leaving zombies.
- If `fork()` fails partway (e.g. `RLIMIT_NPROC`), the parent logs a warning,
  stops spawning, and still waits on the children it did create — the run
  produces partial but usable data for benchmarking.
- Exit code: `0` if every child exited cleanly and no fork failed; `2`
  otherwise. `1` is reserved for argument errors.
