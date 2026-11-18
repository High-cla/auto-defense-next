-- Pure contract test for planned Scripts/ad_seed.lua (no game API).
--
-- Frozen small API:
--   local seed = Seed.new(raw, opts)
--   local merged, added, candidates = seed:merge(ability, actorClass, distance, existing)
--
-- merge is stateless and copy-on-write.  It never owns an attack lifecycle: main.lua's
-- existing q.tapped/pairTimeline path remains responsible for the real on/frame/cancel
-- state.  Therefore a record/probe does not activate anything unless its caller adopts
-- the returned merged list, while a repeated on-path merge into that returned list is
-- idempotent.  Appended rows expose stable id/source/seed markers for that hand-off.
local Seed = dofile("Scripts/ad_seed.lua")
local n = 0
local function check(ok, why) assert(ok, why); n = n + 1 end
local function eq(a, b, why) check(a == b, why or (tostring(a) .. " ~= " .. tostring(b))) end

local raw = {
    { id = "twin-a", actor = "BP_Twin_A_C", ability = "GA_Twin_A_C", montage = "Twin_Shared_Montage",
        frame = 1.00, duration = 0.10, cancel = false },
    { id = "twin-a-alt", actor = "BP_Twin_A_C", ability = "GA_Twin_A_Alt_C", montage = "Twin_Shared_Montage",
        frame = 1.40, duration = 0.10, cancel = false },
    { id = "twin-b", actor = "BP_Twin_B_C", ability = "GA_Twin_B_C", montage = "Twin_Shared_Montage",
        frame = 2.00, duration = 0.10, cancel = false },
    { id = "near", actor = "BP_Near_C", ability = "GA_Near_C", montage = "Near_Montage",
        frame = 0.80, duration = 0.10, cancel = false },
    { id = "dedupe", actor = "BP_Dedupe_C", ability = "GA_Dedupe_C", montage = "Dedupe_Montage",
        frame = 1.00, duration = 0.10, cancel = false },
    { id = "known", actor = "BP_Known_C", ability = "GA_Known_C", montage = "Known_Montage",
        frame = 3.00, duration = 0.10, cancel = false },
    { id = "learned", actor = "BP_Learned_C", ability = "GA_Learned_C", montage = "Learned_Montage",
        frame = 4.00, duration = 0.10, cancel = false },
    { id = "cancelled", actor = "BP_Cancelled_C", ability = "GA_Cancelled_C", montage = "Cancelled_Montage",
        frame = 0.75, duration = 0.10, cancel = true },
}
local seed = Seed.new(raw, { maxDistance = 800, dedupe = 0.15 })
check(type(seed) == "table", "new returns a merger instance")

-- Actor + ability is the identity.  Montage is useful evidence, but a montage shared
-- by several actors/abilities must never authorize a fuzzy or cross-line match.
local original = {}
local aRows, aAdded, aCandidates = seed:merge("GA_Twin_A_C", "BP_Twin_A_C", 300, original)
eq(#original, 0, "record/probe leaves the caller's existing rows untouched")
check(type(aRows) == "table", "merge returns a row list")
check(aRows ~= original, "merge is copy-on-write")
eq(aAdded, 1, "exact actor + ability adds its seed")
eq(#aCandidates, 1, "one exact candidate reported")
eq(aCandidates[1].id, "twin-a")
eq(#aRows, 1)
eq(aRows[1][1], 1.00, "the exact ability gets its own frame")
eq(aRows[1].id, "twin-a", "the output carries a stable seed id")
eq(aRows[1].source, "seed", "the output identifies its source")
eq(aRows[1].seed, true, "the output is explicitly marked as seeded")
eq(aRows[1].frame, 1.00, "the real source frame is preserved")
eq(aRows[1].cancel, false, "the real non-cancel source state is preserved")

local altRows, altAdded, altCandidates = seed:merge("GA_Twin_A_Alt_C", "BP_Twin_A_C", 300, {})
eq(altAdded, 1, "a second ability on the same actor selects independently")
eq(altRows[1][1], 1.40, "shared montage does not collapse candidate abilities")
eq(altCandidates[1].id, "twin-a-alt")
local bRows, bAdded, bCandidates = seed:merge("GA_Twin_B_C", "BP_Twin_B_C", 300, {})
eq(bAdded, 1, "the other actor selects independently")
eq(bRows[1][1], 2.00, "shared montage does not cross actor lines")
eq(bCandidates[1].id, "twin-b")

local wrongRows, wrongAdded, wrongCandidates = seed:merge("GA_Twin_A_C", "BP_Twin_B_C", 300, {})
eq(wrongAdded, 0, "a montage match cannot repair a wrong actor + ability pair")
eq(#wrongRows, 0)
eq(#wrongCandidates, 0, "wrong-pair candidates fail closed")
local unknownRows, unknownAdded = seed:merge("GA_Twin_A_C", "BP_Unknown_C", 300, {})
eq(unknownAdded, 0, "unknown actor never falls back through montage")
eq(#unknownRows, 0)

-- Distance is an inclusive safety gate.
local _, edgeAdded = seed:merge("GA_Near_C", "BP_Near_C", 800, {})
eq(edgeAdded, 1, "distance exactly at the gate is eligible")
local _, farAdded = seed:merge("GA_Near_C", "BP_Near_C", 800.01, {})
eq(farAdded, 0, "distance beyond the gate is rejected")

-- The on-path adopts the merged list once; replaying the same event is idempotent.
-- No token or attack state is retained by this pure module.
local onRows, onAdded = seed:merge("GA_Near_C", "BP_Near_C", 250, {})
eq(onAdded, 1, "the first real on-path merge adds once")
local replayRows, replayAdded, replayCandidates = seed:merge("GA_Near_C", "BP_Near_C", 250, onRows)
eq(replayAdded, 0, "repeated on-path merge is idempotent")
eq(#replayRows, 1, "replay never appends twice")
eq(replayRows[1].id, onRows[1].id, "replay keeps the stable seed row")
eq(#replayCandidates, 1, "candidate reporting remains diagnostic on replay")

-- Any row within +/-0.15 s wins.  A farther row permits the seed.
local nearExisting = { { 1.14, 0.10 } }
local nearRows, nearAdded = seed:merge("GA_Dedupe_C", "BP_Dedupe_C", 100, nearExisting)
eq(nearAdded, 0, "an existing row within 0.15 s suppresses the seed")
eq(#nearRows, 1, "dedupe leaves the preferred existing row alone")
eq(#nearExisting, 1, "dedupe does not mutate the input list")
local farExisting = { { 1.16, 0.10 } }
local farRows2, farAdded2 = seed:merge("GA_Dedupe_C", "BP_Dedupe_C", 100, farExisting)
eq(farAdded2, 1, "a row beyond 0.15 s does not suppress the seed")
eq(#farRows2, 2)
eq(farRows2[2][1], 1.00)

-- Shipped rows and player-learned rows both outrank a nearby seed.
local knownRows, knownAdded, knownCandidates = seed:merge("GA_Known_C", "BP_Known_C", 100, { { 2.95, 0.10 } })
eq(knownAdded, 0, "an existing shipped row has priority")
eq(#knownRows, 1)
eq(#knownCandidates, 1, "the suppressed source stays visible for diagnostics")
local learnedRows, learnedAdded = seed:merge("GA_Learned_C", "BP_Learned_C", 100,
    { { 3.97, 0.10, learned = true, source = "player" } })
eq(learnedAdded, 0, "a player-learned row has priority")
eq(#learnedRows, 1)
eq(learnedRows[1].source, "player", "the player row is retained verbatim")

-- A source captured in real cancel state is not an activation seed.  Cancellation of
-- a live attack remains main.lua's q.tapped/pairTimeline responsibility, not hidden
-- mutable state in this pure merger.
local cancelledRows, cancelledAdded, cancelledCandidates = seed:merge("GA_Cancelled_C", "BP_Cancelled_C", 100, {})
eq(cancelledAdded, 0, "a cancelled source cannot add a hit")
eq(#cancelledRows, 0)
eq(#cancelledCandidates, 0, "cancelled records are not eligible candidates")

-- Bad exports, bad rows, NaN frames and nonsensical cancel values fail closed.
local malformed = {
    "not a row",
    { id = "missing-frame", actor = "BP_Bad_C", ability = "GA_Bad_C", cancel = false },
    { id = "nan", actor = "BP_NaN_C", ability = "GA_NaN_C", frame = 0 / 0, cancel = false },
    { id = "bad-flag", actor = "BP_Flag_C", ability = "GA_Flag_C", frame = 1.0, cancel = "no" },
    { id = {}, actor = "BP_Id_C", ability = "GA_Id_C", frame = 1.0, cancel = false },
}
local ok, badSeed = pcall(Seed.new, malformed, { maxDistance = "far", dedupe = -1 })
check(ok, "malformed seed rows never raise during construction")
check(type(badSeed) == "table", "malformed construction still returns a safe instance")
local okMerge, badRows, badAdded, badCandidates = pcall(function()
    return badSeed:merge("GA_Bad_C", "BP_Bad_C", 1, "not rows")
end)
check(okMerge, "malformed merge never raises")
eq(badAdded, 0, "malformed merge adds nothing")
eq(#badRows, 0, "malformed existing rows safely become empty")
eq(#badCandidates, 0, "malformed candidates are ignored")
local okEmpty, emptySeed = pcall(Seed.new, nil, nil)
check(okEmpty, "nil input never raises")
check(type(emptySeed) == "table", "nil input returns a safe empty instance")
local emptyRows, emptyAdded, emptyCandidates = emptySeed:merge(nil, nil, nil, nil)
eq(emptyAdded, 0, "empty instance adds nothing")
eq(#emptyRows, 0)
eq(#emptyCandidates, 0)

-- The generated snapshot carries only the approved provenance namespace: three
-- semantic facts expanded to five exact actor/ability rows. Existing PBZAssist
-- tables stay outside this overlay and remain authoritative.
local shipped = dofile("data/ad_data.lua")
local ref = shipped.reference_noframe
eq(shipped.build, 26367565, "the frozen PBZAssist build is unchanged")
check(type(ref) == "table", "reference namespace exists")
eq(ref.source, "AutoPerfectDefense 1.1.4")
eq(ref.cluster_gap, 0.15); eq(ref.distance_margin, 150); eq(#ref.rows, 5)
local actual = Seed.new(ref)
local bomb, bombAdded = actual:merge("GA_BombMan_Skill_01_C", "BP_Monster_BombManRespawn_C", 500, {})
eq(bombAdded, 2); eq(bomb[1][1], 0.820); eq(bomb[2][1], 2.270)
local noLock, noLockAdded = actual:merge("GA_BombMan_Skill_01_NoLock_C", "BP_Monster_BombManRespawn_C", 500, {})
eq(noLockAdded, 2); eq(noLock[1][1], 0.820); eq(noLock[2][1], 2.270)
local yan, yanAdded = actual:merge("GA_YanQianSui_Skill_05_C", "BP_Monster_YanQianSui_C", 390, {})
eq(yanAdded, 1); eq(yan[1][1], 3.441)
local _, sharedWrong = actual:merge("GA_YanQianSui_Skill_05_C", "BP_Monster_QinNv_C", 100, {})
eq(sharedWrong, 0, "the shared montage cannot cross actor classes")
local _, bombFar = actual:merge("GA_BombMan_Skill_01_C", "BP_Monster_BombManRespawn_C", 510.01, {})
eq(bombFar, 0, "observed distance plus the recorded margin is the inclusive cap")

print("SEED PASS " .. n .. " assertions")
