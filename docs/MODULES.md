# Module layout (1.6.6)

Decision and execution order is unchanged. What moved is **where each concern lives**
and **which door every side effect goes through**. Behaviour changes are listed in the
CHANGELOG, not here.

| File | Lines | Owns |
| --- | ---: | --- |
| `Scripts/main.lua` | 5302 | hooks, tick orchestration, the decision chain (`tl.decide`), parry/dodge mechanics, ledger, perf, data loader |
| `Scripts/ad_query.lua` | 176 | read-only game queries: `valid/name/unwrap/num/prop/baseName/obj/tag/tagLibrary/component/ascOf/nowOf` (log injected); `tag` memoised, `baseName` is the one name rule |
| `Scripts/ad_compat.lua` | 61 | the runtime compat layer: `gc(mode)` / `atan(y, x)` / `version()` / `hasJit()` — the two Lua-5.4-only calls live here and nowhere else |
| `Scripts/ad_timeline.lua` | 60 | the learned timeline table **and** its count (`table/count/put/add/addRow/removeRow/get/recount/each`) |
| `Scripts/ad_policy.lua` | 47 | the shared rules: `ask(intent)` → allow/deny + reason, `who()`, per-reason counters |
| `Scripts/ad_input.lua` | 75 | the controlled entry: `pressGuard/releaseGuard/endStance/tag/inject` — asks the rules, then calls the registered mechanic; `stats()` |
| `Scripts/ad_inputstate.lua` | 110 | the game's own hold answer: `IsHolding`/`GetHoldTime` through the pawn's input component, `pick(held, keyHeld, injecting)` precedence, `read()` answers nil instead of guessing, and a self-revert (`dead`/`disable(why)`, 3 unfixable faults in a row or one manual call) after which `read` neither answers nor touches the game; readers injected, so the file has no game API and runs offline |
| `Scripts/ad_seed.lua` | 105 | pure, stateless no-frame seed index/merger: exact normalized actor + ability match, inclusive distance gate, ±0.15 s dedupe, copy-on-write rows marked `source="seed"`; malformed reference data is rejected and existing/player rows keep priority |
| `Scripts/ad_async.lua` | 104 | in-process read-only event bus + budgeted warm-up queue |
| `Scripts/ad_json.lua` / `Scripts/menu_config.lua` | 123 / 247 | strict flat JSON; native Mods Menu adapter (invariants, read-back, unknown-key naming) |
| `Scripts/ad_menu_bridge.lua` | 158 | the Mods Menu save-name shim: mirrors the menu's folded `pending-`/`saved-` names into the spelling the bridge watches and back; never writes the config |
| `Scripts/toast.lua` | 208 | the toast notifications: one Delayed Action per show (retriggerable where available), handle kept and cancelled; never a resident loop |
| `data/ad_data.lua` | 1.16 MB | frozen PBZAssist game-data snapshot, build=26367565, plus the separate provenance-bearing `reference_noframe` overlay. Existing PBZAssist tables remain the runtime data layer; regenerating them still needs the missing `Mods/PBZAssist/Scripts/enemy_data.lua`, while `tools/make_ad_data.lua` owns the additive reference overlay. |
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

- **Public surface**: `tl.api` lists the 29 names other code or tests may use; the count is
  logged at startup (`tl api: N public names of M fields`) so a growing API is visible.
  Everything else on `tl` is internal and may be renamed.
- **Reference seeds stay bounded**: `tl.seedRows(ability, actorClass, distance, existing)` is the only runtime seam. `off` and unavailable data are no-ops; `record` reports candidates but returns the original rows; `on` returns a copied merge. `ad_seed` owns no attack lifecycle state, never mutates `hitTimes`, and every seed row is dodge-only until a real ReceiveFrame pairs it.
- **Borrowed answers revert**: the game's hold answer is an optimisation, never a
  dependency. `tl.installInputState()` is idempotent (it returns the instance already
  installed) and latches a load failure in `tl.inputStateErr`, so a build where the field
  is unreadable costs one `dofile` attempt for the whole session. The adapter itself
  reverts after three "the API is not there" faults in a row (`no input component`,
  `no SGameInput`, `IsHolding failed`, wrong answer type) or on `o:disable(why)`; "no
  pawn yet" and "no action yet" are transient and never count. After a revert `tl.holdAsk`
  returns the key answer without calling the game again, and `stats()` still counts asks.
- **Test seams** (only inside a copy carrying the `.ad-menu-test-only` marker):
  `_G.__TL/__HK/__S`, `_G.__DECIDE` (= `tl.decide(p, deflect, input, now)`),
  `_G.__CHECK_RELEASE`, `_G.__QUEUE_TIMELINE`, `_G.__RUNTIME` (`version`/`jit`/`compat`). A normal install
  exposes no globals.
- **Error channel**: every action call site goes through `tl.try(what, fn, ...)`; a failure is
  logged the first 3 times per `what` (traceback on the first) and emitted as `error` on the
  bus. Read probes keep plain `pcall` on purpose — they are "try to read, fall back", not actions.
- **Hot path**: named `RT.*` accessors instead of `pcall(function() ... end)`, one reusable
  `RT.out` frame table, constant kind tables in `RT`, one name rule (`RT.bname` →
  `Q.baseName`). Nothing in the per-tick path allocates a closure.
- **Hooks**: UE4SS returns **two** ids per hook (pre and post) and has exactly one removal form,
  `UnregisterHook(path, preId, postId)`, which returns nothing. `RT.rememberHook(key, path, pre,
  post)` stores all three in `tl.hookIds`; `RT.unhook(key)` calls the 3-arg form through pcall,
  hands the engine's error text to `tl.err` and **keeps the record** when it throws (an id thrown
  away can never be removed later). There is no id-only overload and no global unregister helper.
- **Is a hook installed?** `RT.installed(key)` — the record is the only answer. Installers check it
  instead of a separate boolean, so a teardown that deletes the record lets a re-armed mod install
  again; without it `hookAttacks` added a new id pair every tick and the old pair leaked.
- **Teardown**: `tl.teardown(reason)` is the one place that undoes what the mod installed, in this
  order (the order is the contract): set `tl.stopped` **first** → cancel this mod's delayed actions
  (`loopHandle`, `loopStale`) → `ClearAllDelayedActions()` as a backstop → unregister every hook →
  `toast:hide()` → flush the ledger and the event sink, then **seal** the sink → drop state and the
  install budget (`activationTries`). It is idempotent (second call returns false); every hook
  wrapper starts with `if tl.stopped then return end` because unregistering is deferred; the
  automatic "main loop dead" branch calls teardown instead of leaving hooks firing.
  `tl.check(true)` (a human hotkey) re-arms the mod, re-opens the sink and logs one line. Key binds
  cannot be unregistered by the API, so a torn-down mod's hotkeys re-arm it rather than act.
- **Growable caches** register in `tl.prunable`; `tl.pruneHandles()` is the only place that
  clears them (`parried`, `dodged`, `warned` today).
- Plain dot calls (`bus.drain(16)`, `warm.step(1)`): a colon call passes the table as the
  first argument, so both normalise it instead of failing mid-frame.
- Lua string escapes: a path written as `"Scripts\ad_query.lua"` becomes `\a` (bell).
  Paths in `dofile` use `/`, which Windows accepts.
- The log keeps its counter, cap (3000) and stamp in one `logState` table, exposed as
  `tl.logState` with `tl.log` so the cap is testable.

## Verification

`bash tools/run_all.sh` is the single source of truth for counts: it prints one line per suite
(with its assertion count), the python suites, `check_std`, `check_docs`, the optional Lua 5.4
compile smoke and the `selene` verdict. This file deliberately no longer copies those numbers or
a file hash — they rotted every release, and `tools/check_docs.py` now fails the gate when any
number stated here disagrees with the disk. The repository's pre-commit hook runs the same gate.

## Not moved yet

The data loader (the block that builds `tl.dat`) still lives in `main.lua`: it is
mechanical but touches every data-derived decision, so it gets its own reviewed step.
The same holds for guard/shachi/movement extraction out of the single large do-block.

## Release conventions

- **Store docs carry no version string.** `README.md`, `openmods.md` and `openmods.json`
  must not mention `vX.Y.Z`: they are edited directly on GitHub, so a version there
  would force a hand edit on every release. The version lives in exactly three places —
  `tl.VERSION` (main.lua), the descriptor's `"version"` field and `CHANGELOG.md`.
- **Never bump a version inside the docs during a merge.** When `origin/main` has moved
  (store text rewritten on GitHub), run `git merge origin/main` and keep their text
  byte-for-byte; only code, tests and CHANGELOG are ours to change.
- **Publishing is manual and explicit.** `tools/package.sh` + tag + release happen only
  when the user asks for a release, never as part of a fix.
