# Observability: async event bus, warm-up, perf, errors (1.6.3)

Observation only. No decision path depends on anything here: `events = off` and
`perf = off` restore the cost of the previous version exactly, and the sink files are
never read back into a decision.

## Files

| File | Role |
| --- | --- |
| `Scripts/ad_async.lua` | the mechanism: `M.events(cap)` ring bus, `M.warm()` budgeted queue. No game API. |
| `Scripts/main.lua` | install block after the `tl` literal; emits in `pressTap`/`dodge`/the choke; drain + one warm step per tick in `tl.main`; `tl.err`; `tl.perfLabel`/`tl.perfTick` |
| `tools/test_async.lua` | 46 pure assertions (ring, drop policy, budget, broken subscriber, warm queue) |
| `tools/test_timeline.lua` | 18 pure assertions for the store the warm-up indexes |
| `tools/run_all.sh` | every suite plus the linter in one command (also the pre-commit gate) |

## Bus contract

- `emit(kind, a, b, c)` — O(1), allocates nothing (fixed slot tables).
- Ring of 512 slots. A **full ring drops the newest** event and counts it, so
  `stats().dropped > 0` is the budget alarm; an undelivered record is never overwritten.
- A slot table is valid **only inside the callback**; it is cleared on delivery, so a
  consumer that keeps it reads `nil` instead of a later event's fields.
- `drain(max)` — at most 16 events per tick. Every subscriber runs under `pcall`; one that
  throws is removed, so a broken consumer costs one tick, not every tick.
- `events = off` (Mods Menu, hot) makes `tl.emit` return immediately.

## Sink

`ad_events.txt`: `HH:MM:SS kind a b c`, written 8 lines or 2 s apart, `f:flush()` per
write, 4000-line cap (the file is recreated with a header).

## Emitted events (the table is generated from the code)

| kind | when | fields |
| --- | --- | --- |
| `parry` | the guard key press was injected | h, now, 1 |
| `parry_fail` | the injection returned false or raised | h, now, 0 |
| `parry_denied` | the shared rules refused the guard press | h, now, reason |
| `parry_noaction` | `IA_Deflect` did not resolve | h, now, 0 |
| `dodge` | dodge ability/key activated | kind (red/grab/...), h, ok |
| `dodge_defer` | dodge postponed until the guard is lowered | kind, h, 1 |
| `inject_denied` | a dodge injection was refused by the rules | 0, 0, reason |
| `release_denied` / `stance_denied` / `tag_denied` | the same door, other intents | 0, 0, reason |
| `error` | any hook install or guarded stage failed | what, count, 0 |
| `warm_done` | the warm queue finished | failed count, dropped count |

## Errors and metrics

`tl.err(what, err)` is the single error channel: the first three failures per `what` are
logged (the first with `debug.traceback`), each is emitted as `error`, and a stage that
keeps failing is paused for 2^n s (cap 60 s) by `guarded` instead of burning every tick.
Every 5 s the alive branch logs one metrics line:

`metrics: drop=<bus dropped> asked=<door asks> denied=<door refusals> lua=<KB>`

## Perf log

`perf = on` writes `perf_log.txt` every 10 s: one tick line with avg/p50/p95/p99/max,
the hitch count (gaps over 40 ms are counted, the last three kept as samples) and one
`stage <name> n= avg p50 p95 p99 max` row per instrumented stage (the `guarded` stages).
Percentiles come from a 256-sample ring per stage, so a spike shows up instead of being
averaged away. The data load logs its own `read in %.1f ms` once at startup.

## Warm-up

One task per tick after the loop starts, so the 70-80 ms load stays put. The single task
builds `tl.busIdx`: per-ability hit count, first/last hit, known-grab flag (2316 abilities
in the current `hit_times.txt`). A failing task is recorded (`tl.warm.failed()`,
`tl.warm.lastError`) and skipped; it can never stop the loop.
**Honest limit:** no decision path reads `tl.busIdx` yet. It is the seam for a future
budgeted precompute, not a timing change.

## Verification

`bash tools/run_all.sh` → POLICY 35, ASYNC 46, TIMELINE 18, MENU 69, INTEGRATION 44
(the last one in an isolated temp copy: complete chunk load, config mirroring, TXT
immutability, bad-JSON safety, bus delivery, sink file, warm index, log cap, api list),
plus `selene` 0 errors / 3 warnings.

## Limits

- The bus is **not** an arbiter: it cannot make PBZAssist or PBZPerfectDefense yield.
- Delivery is per tick, so an event is up to one frame late: fine for replay, useless as a
  press deadline.
- Nothing reads `tl.busIdx` in a decision yet.
- No p95 exists until someone plays one session with `perf = on`.

## Rollback

Restore `backup/main.lua.bak-1.6.3` (this release) or `backup/main.lua.bak-1.6.2` (the
state before the audit); the modules, tests and the `events`/`perf` config rows can stay
unused harmlessly.

## Incident: the 2000-line read limit

Rewriting `main.lua` from a `read` result truncated it to 957 lines: `read` refuses
`limit > 2000`, and a page-sized read was treated as the whole file. It was recovered
byte-identical from the isolated integration copy (`/tmp/ad-int-*/Scripts/main.lua`, 4708
lines, md5 `31a319f4…`) before anything else wrote to it. Rules that follow: never
full-rewrite a file longer than one read page; use `edit` with exact strings and verify
`wc -l` plus a hash before and after.
