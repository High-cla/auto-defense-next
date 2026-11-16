-- The learned timeline store: ability name -> hit rows, plus its count.
-- It owns the table AND every change to it: another file that appends to the
-- table directly would have to keep the count in step by hand, which is how the
-- count and the table drifted apart (audit P0-4). The parser and the readers
-- stay where the decisions are.
local M = {}
local hits, n = {}, 0

function M.table() return hits end
function M.count() return n end

local function count()
    local c = 0
    for _ in pairs(hits) do c = c + 1 end
    n = c
    return n
end

-- put replaces or inserts a whole row list; the count only moves on a new key
function M.put(k, v)
    if hits[k] == nil then n = n + 1 end
    hits[k] = v
    return v
end

-- add returns the row list for k, creating it (and counting it) when new
function M.add(k)
    local v = hits[k]
    if v then return v end
    n = n + 1
    v = {}
    hits[k] = v
    return v
end

-- addRow uses that list: the row always lands in the owned table
function M.addRow(k, row)
    local v = M.add(k)
    v[#v + 1] = row
    return row
end

-- removeRow drops one row and forgets an emptied key, so a removed lesson
-- cannot keep the count (and the TL.count() gates) up
function M.removeRow(k, row)
    local v = hits[k]
    if not v then return false end
    for i = #v, 1, -1 do
        if v[i] == row then table.remove(v, i) break end
    end
    if #v == 0 then hits[k] = nil n = math.max(0, n - 1) end
    return true
end

function M.get(k) return hits[k] end
-- recount repairs a count written by an older version; returns the new value
function M.recount() return count() end
function M.each(fn) for k, v in pairs(hits) do fn(k, v) end end

return M
