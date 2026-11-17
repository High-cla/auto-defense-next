-- Scripts/toast.lua: one hide per show, native Delayed Actions first, and a
-- legacy 100 ms loop only when a build has nothing else - with the handle saved
-- and cancelled. No standing poll may be armed by Toast.new.
local calls = { mk = 0, retrig = 0, once = 0, loop = 0, cancel = 0 }
local holds = { retrigHandle = nil, onceHandle = nil, loopHandle = nil, lastCb = nil, lastDelay = nil, cancelled = {} }
local nextHandle = 100

local function newHandle() nextHandle = nextHandle + 1 return nextHandle end

-- the engine globals are installed instead of declared, so the std-global lint
-- sees a table write rather than a shadowed standard name
local function global(name, value) rawset(_G, name, value) end
global("FName", function(s) return s end)
global("FText", function(s) return s end)
global("MakeActionHandle", function() calls.mk = calls.mk + 1 return newHandle() end)
global("RetriggerableExecuteInGameThreadWithDelay", function(h, ms, fn)
    calls.retrig = calls.retrig + 1
    holds.retrigHandle, holds.lastCb, holds.lastDelay = h, fn, ms
    return h
end)
global("ExecuteInGameThreadWithDelay", function(ms, fn)
    calls.once = calls.once + 1
    holds.onceHandle, holds.lastCb, holds.lastDelay = newHandle(), fn, ms
    return holds.onceHandle
end)
global("LoopInGameThreadWithDelay", function(ms, fn)
    calls.loop = calls.loop + 1
    holds.loopHandle, holds.lastCb, holds.lastDelay = newHandle(), fn, ms
    return holds.loopHandle
end)
global("CancelDelayedAction", function(h)
    calls.cancel = calls.cancel + 1
    holds.cancelled[#holds.cancelled + 1] = h
    return true
end)

local Toast = dofile("Scripts/toast.lua")
local n = 0
local function ok(cond, why) assert(cond, why or "assertion failed"); n = n + 1 end
local function eq(a, b, why) assert(a == b, why or (tostring(a) .. " ~= " .. tostring(b))); n = n + 1 end

local vis, texts, failText = nil, {}, false
local function textObj()
    return { IsValid = function() return true end,
        SetText = function(_, s)
            if failText then error("SetText exploded") end
            texts[#texts + 1] = s
        end }
end
local function widgetObj()
    return { IsValid = function() return true end,
        IsInViewport = function() return true end,
        SetVisibility = function(_, v) vis = v end }
end
local function armed() return calls.retrig + calls.once + calls.loop end

-- 1. a new toast owns nothing
local t = Toast.new(10, 20)
eq(armed() + calls.mk, 0, "Toast.new schedules no action")
eq(t.handle, nil, "a new toast owns no handle")
eq(t.schedule, nil, "a new toast has no scheduler recorded")
t.widget, t.text = widgetObj(), textObj()

-- 2. the native debounce is preferred and re-used by the next show
eq(t:show("hello", 0.3), true, "show reports success")
eq(calls.retrig, 1, "the retriggerable delay is preferred")
eq(calls.mk, 1, "one action handle is created")
eq(holds.lastDelay, 300, "seconds become milliseconds")
eq(t.schedule, "retriggerable", "the chosen scheduler is recorded")
eq(texts[1], "hello", "the text reaches the widget")
eq(vis, 3, "the widget is made visible for the duration")
local h1, cb1 = holds.retrigHandle, holds.lastCb
eq(t.handle, h1, "the handle is saved for cancellation")
eq(t:show("again", 1), true, "a second show succeeds")
eq(calls.retrig, 2, "a second show re-triggers the same action")
eq(calls.mk, 1, "the handle is reused, not recreated")
eq(holds.retrigHandle, h1, "both shows own the same handle")

-- 3. a superseded callback is inert; the current one hides and rearms nothing
eq(cb1(), false, "a stale callback reports false")
eq(vis, 3, "a stale callback leaves the newer text on screen")
local before = armed()
eq(holds.lastCb(), false, "the due callback reports false")
eq(vis, 1, "the due callback collapses the text")
eq(armed(), before, "the due callback schedules nothing")
eq(t.handle, nil, "the handle is released once the toast is hidden")
eq(holds.lastCb(), false, "a late repeat of the callback is inert")
eq(vis, 1, "a late repeat does not change visibility")

-- 4. a build without the debounce: one shot plus an explicit cancel
global("RetriggerableExecuteInGameThreadWithDelay", nil)
local t2 = Toast.new(0, 0)
t2.widget, t2.text = widgetObj(), textObj()
calls.cancel = 0
eq(t2:show("a", 1), true, "the one-shot build shows the text")
eq(t2.schedule, "once", "the one-shot API is the second choice")
eq(calls.once, 1, "exactly one one-shot action is armed")
local firstOnce = holds.onceHandle
eq(t2:show("b", 1), true, "a second show on the one-shot build succeeds")
eq(calls.once, 2, "a second one-shot action is armed")
eq(holds.cancelled[#holds.cancelled], firstOnce, "the previous one-shot is cancelled first")
eq(t2.handle, holds.onceHandle, "the newest handle is the one saved")
eq(holds.lastCb(), false, "the one-shot deadline fires once")
eq(vis, 1, "the one-shot callback collapses the text")

-- 5. the legacy loop: saved handle, 100 ms steps, cancelled at the deadline
global("ExecuteInGameThreadWithDelay", nil)
local t3 = Toast.new(0, 0)
t3.widget, t3.text = widgetObj(), textObj()
calls.cancel = 0
eq(t3:show("old", 0.25), true, "the legacy build shows the text")
eq(t3.schedule, "loop", "the loop is the last resort")
eq(holds.lastDelay, 100, "the fallback polls every 100 ms")
local loopCb, loopHandle = holds.lastCb, holds.loopHandle
eq(t3.handle, loopHandle, "the loop handle is saved")
eq(loopCb(), false, "the first tick is before the deadline")
eq(vis, 3, "the text stays up on the first tick")
eq(loopCb(), false, "the second tick is before the deadline")
eq(vis, 3, "the text stays up on the second tick")
eq(loopCb(), false, "the third 100 ms tick is the deadline")
eq(vis, 1, "the loop collapses the text at the deadline")
eq(holds.cancelled[#holds.cancelled], loopHandle, "the loop cancels its own handle")
eq(t3.handle, nil, "the loop handle is released after hiding")

-- 6. a failed show disables the toast and arms nothing
local t4 = Toast.new(0, 0)
t4.widget, t4.text = widgetObj(), textObj()
failText = true
before = armed()
local shown, err = t4:show("boom", 1)
eq(shown, false, "a failing show returns false")
ok(err ~= nil, "a failing show reports why")
eq(t4.broken, true, "the toast is marked broken")
eq(armed(), before, "a failing show arms no action")
failText = false
local again, err2 = t4:show("boom", 1)
eq(again, false, "a broken toast refuses every later show")
ok(err2 ~= nil, "the refusal carries a reason")
eq(armed(), before, "a broken toast still arms nothing")
eq(t4.handle, nil, "a broken toast owns no handle")

print("TOAST PASS " .. n .. " assertions")
