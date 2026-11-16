# Module layout (1.6.2)

Decision and execution order is unchanged. What moved is **where each concern
lives** and **which door every side effect goes through**.

| File | Lines | Owns |
| --- | ---: | --- |
| `Scripts/main.lua` | 4706 | hooks, tick orchestration, timeline decisions, parry/dodge mechanics, ledger/perf |
| `Scripts/ad_query.lua` | 72 | read-only game queries: `valid/name/unwrap/obj/tag/tagLibrary/component/ascOf/nowOf` (log injected) |
| `Scripts/ad_timeline.lua` | 26 | the learned timeline table **and** its count (`table/count/put/add/get/addCount/each`) |
| `Scripts/ad_policy.lua` | 47 | the shared rules: `ask(intent)` → allow/deny + reason, `who()`, per-reason counters |
| `Scripts/ad_input.lua` | 60 | the controlled entry: `pressGuard/releaseGuard/endStance/tag` — asks the rules, then calls the registered mechanic |
| `Scripts/ad_async.lua` | 102 | in-process read-only event bus + budgeted warm-up queue |
| `Scripts/ad_json.lua` / `menu_config.lua` | 122 / 212 | strict flat JSON, native Mods Menu adapter |
| `data/ad_data.lua` + `ad_data_core.lua` | 1.36 MB | generated game-data snapshot |

## Intents and rules

| intent | rule today | note |
| --- | --- | --- |
| `guard_press` | deny `parry_off`, deny `pd_guard` | identical to the previous inline gates |
| `perfect_tag` | deny `pd_guard` | the perfect result belongs to the other mod when it runs |
| `guard_release` | allow | today AD releases even while another mod holds the guard |
| `stance_end` | allow | same; flip these two rules to `pd_guard` to make it exclusive |
| `dodge_press` | allow | dodge was never gated by the other mod |

`main.lua` replaces `tl.pressTap`, `tl.releaseHeldKey` and `endStance` with the choke
after installing it, so every existing call site keeps working while the door is single.
Installation is `pcall`-guarded: a failure leaves the plain functions in place.

## Contract notes

- Plain dot calls (`bus.drain(16)`, `warm.step(1)`): a colon call would pass the table as
  the first argument, so both now normalise it instead of failing mid-frame.
- Lua string escapes: a path written as `"Scriptsad_query.lua"` becomes `a` (bell).
  Paths in `dofile` use `/`, which Windows accepts — no escape layer to get wrong.

## Verification

`tests`: policy 28, async 46, menu 61, integration 37 (isolated copy). `main.lua`
SHA256 `014e0fa5…d18150`, backup `Scripts/main.lua.bak-1.6.2`.

## Not moved yet

The data loader (the ~287-line block that builds `tl.dat` and hands back an API) still
lives in `main.lua`; the generated tables it reads are already separate files. Moving
the loader is mechanical but touches every data-derived decision, so it gets its own
reviewed step rather than riding along with this one.
