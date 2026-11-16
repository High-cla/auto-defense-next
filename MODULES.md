# Module layout (1.6.4)

Decision and execution order is unchanged. What moved is **where each concern lives**
and **which door every side effect goes through**. The audit that produced this release
is in `AUDIT-2026-11-16.md`; behaviour changes are listed there, not here.

| File | Lines | Owns |
| --- | ---: | --- |
| `Scripts/main.lua` | 4854 | hooks, tick orchestration, timeline decisions, parry/dodge mechanics, ledger, perf, data loader |
| `Scripts/ad_query.lua` | 107 | read-only game queries: `valid/name/unwrap/num/prop/baseName/obj/tag/tagLibrary/component/ascOf/nowOf` (log injected) |
| `Scripts/ad_timeline.lua` | 60 | the learned timeline table **and** its count (`table/count/put/add/addRow/removeRow/get/recount/each`) |
| `Scripts/ad_policy.lua` | 47 | the shared rules: `ask(intent)` → allow/deny + reason, `who()`, per-reason counters |
| `Scripts/ad_input.lua` | 75 | the controlled entry: `pressGuard/releaseGuard/endStance/tag/inject` — asks the rules, then calls the registered mechanic; `stats()` |
| `Scripts/ad_async.lua` | 104 | in-process read-only event bus + budgeted warm-up queue |
| `Scripts/ad_json.lua` / `menu_config.lua` | 123 / 246 | strict flat JSON; native Mods Menu adapter (invariants, read-back, unknown-key naming) |
| `Scripts/ad_menu_bridge.lua` | 158 | the Mods Menu save-name shim: mirrors the menu's folded `pending-`/`saved-` names into the spelling the bridge watches and back; never writes the config |
| `Scripts/toast.lua` | 80 | the toast notifications (UE4SS module path, loaded with `require`) |
| `data/ad_data.lua` | 1.16 MB | generated game-data snapshot (the runtime data layer), build=26367565. Regenerating it also rewrites `data/ad_data_meta.txt`, but the source (`Mods/PBZAssist/Scripts/enemy_data.lua`) is gone as of 2026-11-16: the snapshot is frozen and still valid, a new one needs a PBZAssist install. |
| `tools/out/ad_data_core.lua` + `ad_data_meta.txt` | 199 KB | reduced snapshot and its build/count meta for tooling and audit only - not loaded at runtime |

## Intents and rules

| intent | rule today | note |
| --- | --- | --- |
| `guard_press` | deny `parry_off`, deny `pd_guard` | identical to the previous inline gates |
| `perfect_tag` | deny `pd_guard` | the perfect result belongs to the other mod when it runs |
| `guard_release` | allow | today AD releases even while another mod holds the guard |
| `stance_end` | allow | same; flip these two rules to `pd_guard` to make it exclusive |
| `dodge_press` | allow | now actually asked: `tl.input.inject("dodge_press", action)` is the only dodge door |

`main.lua` replaces `tl.pressTap`, `tl.releaseHeldKey` and `endStance` with the choke after
installing it, so every existing call site keeps working while the door is single.
Installation is `pcall`-guarded: a failure leaves the plain functions in place, and
`tl.input` is still replaced by a pass-through so it is never `nil`.

## Contract notes

- **Public surface**: `tl.api` lists the 23 names other code or tests may use; the count is
  logged at startup (`tl api: N public names of M fields`) so a growing API is visible.
  Everything else on `tl` is internal and may be renamed.
- **Growable caches** register in `tl.prunable`; `tl.pruneHandles()` is the only place that
  clears them (`parried`, `dodged`, `warned` today).
- Plain dot calls (`bus.drain(16)`, `warm.step(1)`): a colon call passes the table as the
  first argument, so both normalise it instead of failing mid-frame.
- Lua string escapes: a path written as `"Scripts\ad_query.lua"` becomes `\a` (bell).
  Paths in `dofile` use `/`, which Windows accepts.
- The log keeps its counter, cap (3000) and stamp in one `logState` table, exposed as
  `tl.logState` with `tl.log` so the cap is testable.

## Verification

`bash tools/run_all.sh` → POLICY 35, ASYNC 46, TIMELINE 18, MENU 69, BRIDGE 115,
INTEGRATION 44 assertions; `selene` 0 errors / 3 warnings (three documented unwired
diagnostics). `main.lua` SHA256 `37317350163613d7af9ac47abddd98173f854344972c82e8f2f10c66ea6fc777`.
The repository's pre-commit hook runs the same gate.

## Not moved yet

The data loader (the block that builds `tl.dat`) still lives in `main.lua`: it is
mechanical but touches every data-derived decision, so it gets its own reviewed step.
The same holds for guard/shachi/movement extraction out of the single large do-block.
