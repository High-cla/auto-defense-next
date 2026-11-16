-- Controlled entry points: nothing in the mod presses, releases or ends a guard
-- except through here, and here the shared rules are asked first. The mechanics
-- are still the functions main.lua registers, so the decision/execution chain is
-- unchanged; only the door is now single.
local M = {}
local B = {}

function M.attach(bindings)
    B = bindings or {}
    return M
end

function M.setPolicy(p)
    B.policy = p
    return M
end

local function ask(intent)
    M.asked = (M.asked or 0) + 1
    local p = B.policy
    if not p then return true end
    local ok, why = p.ask(intent)
    if not ok then M.denied = (M.denied or 0) + 1 end
    return ok, why
end
local function emit(...)
    local e = B.emit
    if e then e(...) end
end

function M.pressGuard(h, now)
    local ok, why = ask("guard_press")
    if not ok then emit("parry_denied", h or -1, now or 0, why or "denied") return false end
    local f = B.pressRaw
    if not f then return false end
    return f(h, now)
end

function M.releaseGuard(why)
    local ok, whyNot = ask("guard_release")
    if not ok then emit("release_denied", 0, 0, whyNot or "denied") return false end
    local f = B.release
    if not f then return false end
    return f(why)
end

function M.endStance(pawn, why)
    local ok, whyNot = ask("stance_end")
    if not ok then emit("stance_denied", 0, 0, whyNot or "denied") return false end
    local f = B.endStance
    if not f then return false end
    return f(pawn, why)
end

-- tag writes (perfect window, debug tags) take the same door
function M.tag(intent, fn)
    local ok, why = ask(intent)
    if not ok then emit("tag_denied", 0, 0, why or "denied") return false end
    return fn()
end

-- every injection (dodge key, dodge hold, perfect tag) takes the same door: the
-- intent decides, then the registered mechanic runs (audit P1-4)
function M.inject(intent, action)
    local ok, why = ask(intent)
    if not ok then emit("inject_denied", 0, 0, why or "denied") return false end
    local f = B.inject
    if not f then return false end
    return f(action)
end

function M.stats() return M.asked or 0, M.denied or 0 end

function M.bound() return B end
return M
