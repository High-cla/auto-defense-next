-- selene: allow(incorrect_standard_library_use)
-- 1.6.16: the guard-release paths ask the passive for a release at most once per
-- press (give mode) and once per sprint hold, not every tick. The 12:24 session
-- wrote 14,829 "guard release (give: press over): ok" lines in 7.7 minutes because
-- the passive latches Stance Key Down until the next tap: the condition stayed
-- true forever and the mod hammered On Stance Key Release ~32 times a second,
-- which the player saw as the guard flickering up and down.
local src = assert(io.open("Scripts/main.lua", "rb")):read("*a")
local n = 0
local function has(needle, why)
    assert(src:find(needle, 1, true), why)
    n = n + 1
end
local function count(needle)
    local index, found = 1, 0
    while true do
        local at = src:find(needle, index, true)
        if not at then return found end
        found, index = found + 1, at + #needle
    end
end

has("local pressed = math.max(lastTapAt or 0, tl.keyDownAt or 0)",
    "the release is keyed on the press it follows")
has("tl.giveReleasedFor ~= pressed", "one give-mode release per press")
has("tl.giveReleasedFor = pressed", "and the press is remembered")
has("tl.sprintReleasedFor ~= sprintDownAt", "one sprint release per hold")
has("tl.sprintReleasedFor = sprintDownAt", "and the hold is remembered")
assert(count('release(pawn, "give: press over")') == 1,
    "exactly one give-mode release site")
assert(count('release(pawn, "sprint held")') == 1,
    "exactly one sprint release site")
n = n + 2

-- the guard is the passive's until the key goes up: a release that did not take
-- must not be retried in a loop
has("keyDown(ps) and tl.giveReleasedFor ~= pressed",
    "the give-mode release is behind the press guard")
has("and not (lastTapAt and os.clock() - lastTapAt < SPRINT_QUIET)",
    "the sprint release still waits for the tap to age")

print(string.format("GUARD_RELEASE PASS %d assertions", n))
