---
name: host-safety
description: >-
  Keep a host that several Claude Code sessions share usable: one heavy command at a time
  through the shared slot pool, Node heap below guaranteed RAM, no load generators, no image
  builds, no privileged containers or host-global kernel state, waiters and kills by exact
  PID instead of patterns, detached runs for commands longer than the tool timeout, and
  checks after a restart. Use this before running lint, typecheck, coverage, builds, e2e,
  docker, stress or load tools, sysctl or anything privileged, pkill or pgrep, or a long
  background job on a shared machine; when the host is slow or something was "Killed"; and
  when setting a heap size or a lane count.
---

# Host safety

On a shared host, your command competes with every other session's. A memory spike kills
other sessions' timers and watchers; a kernel change breaks every program on the box. The
default answer to "can I run this heavy thing here?" is "through the pool, or elsewhere".

## Settings

Read `.claude/agent-practice.local.md`, then `~/.claude/agent-practice.md`. Uses `pool_command`
(none), `mem_floor_gb` (`6`), `durable_dir` (`~/.local/state/agent-practice`), `orchestrator_name`.

## 1. One heavy thing at a time

- **Run every heavy command through the shared slot**: full lint, typecheck, build, coverage,
  e2e stacks, database suites. If `pool_command` is set, prefix it. The
  bitc runner (the `using-bitc` skill) is one implementation; read its docs for pools,
  groups, the memory floor and exit codes.
- **Prefer changed-file scope locally.** Full-repo lint and typecheck belong in CI or on remote
  capacity; a full type-aware lint can take about 8 GB.
- **Respect the exit-code contract** if your pool has one. In bitc's: **75 = starved or
  transient, wait and retry**; **64 = refused, fix the call**; **69 = unavailable, stop and
  report**. Never answer a 75 by running the command bare. The `using-bitc` skill has the rest.
- **Don't start big-memory work below `mem_floor_gb` available.** Check
  `grep MemAvailable /proc/meminfo` (and the cgroup limit, if any).
- **Never edit the pool's config.** Changes go through whoever owns it, announced to all sessions.
- **Don't point a session at a private pool state** without the coordinator's OK; it leaves
  the shared accounting.

## 2. Things you don't run on a shared host

| Don't | Why | Instead |
|---|---|---|
| Load generators (`stress`, `stress-ng`, busy loops "for a few seconds") | Agents don't time-box them, and an unbounded load generator can take a shared host to many times its core count. | Plain loops at a low test-worker count, or remote capacity. |
| `docker build` / `buildx` | Steps run inside the daemon, outside any slot's cap; one build is 8 GB-class and uses every core. | Build on the platform's remote builder or CI; measure with a plain framework build. If unavoidable: a capped builder (`--driver-opt memory=6g,cpuset-cpus=0-3`), alone. |
| `--privileged` containers, `sysctl -w`, `modprobe`, writes to `/proc/sys`, binfmt handlers | That state is shared with the host: an executable-format handler or a kernel setting changed from a container changes it for every process on the box. | Test against a fake `/proc` tree; real root tests rootless, on a disposable VM, or on a hosted CI runner. Say so in every privileged-test prompt. |
| A second full gate while one runs | Two big-memory jobs is how hosts go critical. | Wait for the slot. |

## 3. Memory: heap versus physical RAM

- **The V8 heap cap must sit below guaranteed physical memory.** V8 collects lazily up to its
  cap; above real RAM, the kernel OOM-killer fires first and you get a bare `Killed`.
- On a VM that balloons memory, count only the floor the host can't reclaim, not the ceiling.
- Rough sizing for Node and TypeScript tooling: about 2 GB per parallel worker.
- Set the heap per pool or per command, never a hard-coded 8 GB everywhere. Check for wrappers
  that clear `NODE_OPTIONS`.
- Add swap; it turns an OOM kill into a slowdown. Don't lint or typecheck while coverage runs.

## 4. Processes, waiters and kills

- **Kill by exact PID or process group** (`kill -- -<pgid>`), never `pkill -f <pattern>`. A
  pattern matches other sessions' jobs and can match your own shell, whose command line holds
  the pattern.
- **Wait on a PID, not on `pgrep -f`.** Two waiters polling for each other's quoted command
  lines each see the other and wait forever. Pick the one PID, then
  `while kill -0 <pid> 2>/dev/null; do sleep 15; done`.
- **Queue work as one command** (one lander with all PRs) rather than chained waiters.
- **Detach long jobs fully** and log the exit code; tool calls have a timeout and
  background children can die with the calling shell:

  ```bash
  setsid nohup bash -c '<cmd>; echo "__EXIT__ $?"' > "<durable_dir>/<name>.log" 2>&1 < /dev/null &
  ```

  Then poll the log in bounded calls, and check a few seconds later that the job is alive.
- **Per-job scratch paths only.** A fixed `/tmp/task.patch` gets clobbered by a parallel lane.
- **Every Bash call runs `cd <worktree> && ...` with absolute paths**, and every `gh` call has
  `-R <owner/repo>`; the working directory resets between calls.

## 5. When the host is slow

1. `uptime; grep -E 'MemAvailable|SwapFree' /proc/meminfo`
2. `ps -eo pid,pgid,etimes,pcpu,rss,args --sort=-pcpu | head -20`: look for heavy commands
   running outside the pool, load tools, image builds.
3. Tell the coordinator what you see. Stop only your own jobs; ask owners of others.
4. Hold new heavy work until memory recovers.

## 6. How many lanes

Memory sets the lane count, not CPU or tokens. A workable rule: add one lane per check while
load is low and available memory is well above the floor; pause the newest when either crosses
its back-off line; launch nothing during a local heavy fallback. Write your thresholds down.

## 7. After a restart

`/tmp` is gone, and mutation tests may have left mutants in source. Follow the
`crash-recovery` skill before running anything. Keep scripts in `durable_dir`, not `/tmp`.
