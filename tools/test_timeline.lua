-- Pure test for Scripts/ad_timeline.lua (no game API): the store owns the count.
local TL = dofile("Scripts/ad_timeline.lua")
local n = 0
local function check(ok, why) assert(ok, why) n = n + 1 end
local function eq(a, b, why) check(a == b, why or (tostring(a) .. " ~= " .. tostring(b))) end

eq(TL.count(), 0, "empty store")
local row = { 0.5, "P" }
check(TL.addRow("GA_A", row) == row, "addRow returns the row")
eq(TL.count(), 1, "addRow counts a new ability")
eq(#TL.get("GA_A"), 1)
TL.addRow("GA_A", { 1.2, "D" })
eq(#TL.get("GA_A"), 2, "the second row lands in the owned list")
eq(TL.count(), 1, "an existing ability does not move the count")
check(not TL.removeRow("GA_MISSING", row), "unknown ability reports false")
check(TL.removeRow("GA_A", row), "removeRow reports true")
eq(#TL.get("GA_A"), 1, "one row left")
TL.removeRow("GA_A", TL.get("GA_A")[1])
eq(TL.get("GA_A"), nil, "an emptied ability is forgotten, not kept as an empty table")
eq(TL.count(), 0, "the count follows the removal")
check(not TL.removeRow("GA_A", row), "removing twice is not an error")
TL.put("GA_B", { { 0.1, "P" } }); eq(TL.count(), 1)
TL.put("GA_B", { { 0.2, "P" }, { 0.3, "P" } }); eq(TL.count(), 1, "put on an existing key keeps the count")
TL.add("GA_C"); eq(TL.count(), 2, "add counts once")
TL.add("GA_C"); eq(TL.count(), 2, "add is idempotent")
local seen = 0
TL.each(function() seen = seen + 1 end)
eq(seen, 2, "each walks every ability")
eq(TL.recount(), 2, "recount agrees with the maintained count")
print("TIMELINE PASS " .. n .. " assertions")