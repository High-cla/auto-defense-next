# Async observability + warm-up (1.6.1)

Scope: option C of the architecture assessment, plus the half of the "event bus"
proposal that is cheap and safe. **No decision path changed**: every hook below
is observation only, and `events = off` restores the 1.6.0 cost exactly.

## Files

| File | Role |
| --- | --- |
| `Scripts/ad_async.lua` | the whole mechanism: `M.events(cap)` ring bus, `M.warm()` budgeted queue. No game API. |
| `Scripts/main.lua` | install block after the `tl` literal (~L464); emits in `pressTap`/`dodge`; drain + warm step in `tl.main`; warm task near `tl.ALIVE_EVERY`. |
| `tools/test_async.lua` | 46 pure assertions (ring, drop policy, budget, broken subscriber, warm queue). |
| `tools/run_integration.sh` | runs the integration test in an isolated temp copy; the installed mod is never touched. |

## Bus contract

- `emit(kind, a, b, c)` — O(1), allocates nothing (fixed slot tables).
- Ring of 512 slots. A **full ring drops the newest** event and counts it: an
  undelivered record is never overwritten, so `stats().dropped > 0` is the budget alarm.
- A slot table is valid **only inside the callback**; it is cleared on delivery, so a
  consumer that keeps it gets `nil` instead of silently reading a later event.
- `drain(max)` — max 16 events per tick from the loop. Each subscriber runs under
  `pcall`; one that throws is removed, so a broken consumer costs one tick, not every tick.
- `events = off` (Mods Menu, hot) makes `tl.emit` return immediately: zero cost.

## Sink

`ad_events.txt` in the mod folder: `HH:MM:SS kind a b c`, written 8 lines or 2 s
apart, `f:flush()` per write, 4000-line cap then the file is recreated. Read-only:
the sink never feeds anything back into a decision.

## Warm-up

One task per tick after the loop starts, so the 69–77 ms load stays put. The single
task builds `tl.busIdx`: per-ability hit count, first/last hit, known-grab flag
(2316 abilities in the current hit_times). A failing task is recorded
(`tl.warm.failed()`, `tl.warm.lastError`) and skipped — it can never stop the loop.
**Honest limit:** no decision path reads `tl.busIdx` yet; it exists for replay
annotation and as the seam for a future budgeted precompute.

## Emitted events

| kind | when | fields |
| --- | --- | --- |
| `parry` | the guard key press was injected | h, now, 1 |
| `parry_fail` | inject returned false/error | h, now, 0 |
| `parry_yield` | `pressTap` was refused because PBZPerfectDefense owns the guard | h, now, 1 |
| `parry_noaction` | `IA_Deflect` did not resolve | h, now, 0 |
| `dodge` | dodge ability/key activated | kind (red/grab/…), h, ok |
| `dodge_defer` | dodge postponed until the guard is lowered | kind, h, 1 |
| `warm_done` | warm queue finished | failed count, dropped count |

## Verification

`luajit tools/test_async.lua` → 46; `luajit tools/test_menu_config.lua` → 61;
`bash tools/run_integration.sh` → 33 (isolated copy: full chunk load, config
mirroring, TXT immutability, bad-JSON safety, bus delivery, sink file, warm index).

main.lua SHA256 `9863fd727d48830c438f973aa817daf7d0d0830cae07ff5884579e6579fa89b6`,
backup `Scripts/main.lua.bak-1.6.1`.

## Limits

- The bus is **not** an arbiter: it cannot make PBZAssist or PBZPerfectDefense yield,
  and nothing here changes who presses what.
- Delivery is per tick, so an event is up to one frame late — fine for replay,
  useless as a press deadline.
- Nothing reads `tl.busIdx` in a decision yet (see above).

## Rollback

Restore `Scripts/main.lua.bak-1.6.1`; `Scripts/ad_async.lua`, `tools/test_async.lua`,
`tools/run_integration.sh` and the `events` config row can stay unused harmlessly.

## Incident: the 2000-line read limit

Rewriting `main.lua` from a `read` result truncated it to 957 lines: `read` refuses
`limit > 2000`, and a page-sized read was treated as the whole file. Recovered
byte-identical from the isolated integration copy (`/tmp/ad-int-*/Scripts/main.lua`,
4708 lines, md5 `31a319f4…`) before anything else wrote to it.

Rules that follow: never full-rewrite a file longer than one read page; use `edit`
with exact strings, or splice and verify `wc -l` + a backup hash before and after.
