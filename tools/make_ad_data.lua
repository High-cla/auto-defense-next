-- PBZAssist 解包数据 → pbz-auto-defense 精简快照
-- 用法: luajit tools/make_ad_data.lua [PBZAssist/Scripts] [data]
-- 只导出防守用得到的表；缺表就不导出（= 不知道），调用方必须保留非数据退路。
local SRC = arg and arg[1] or "D:/steam/steamapps/common/PBZ/platform/steam/ue4ss/Mods/PBZAssist/Scripts"
local OUT = arg and arg[2] or (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\\\]tools[/\\\\]") or ".") .. "/data"
local KEEP = {
    "build", "grab", "proj", "bfx", "winv", "multi", "mhit_req", "ns", "mhit", "dhit", "hit",
    "endu", "endure", "parent", "montage", "ts0", "mspd", "dreach", "hit_aim", "precise_defense",
    "hit_timeline", "laser_emitters", "laser_montage_timeline", "stun", "names", "boss",
}
local function ser(v)
    local t = type(v)
    if t == "number" then
        if v % 1 == 0 and math.abs(v) < 2 ^ 31 then return tostring(math.floor(v)) end
        return string.format("%.6g", v)
    elseif t == "string" then return string.format("%q", v)
    elseif t == "boolean" then return tostring(v)
    elseif t ~= "table" then return "nil" end
    local n, keys = 0, {}
    for k in pairs(v) do n = n + 1; keys[#keys + 1] = k end
    if n == 0 then return "{}" end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {"{"}
    for _, k in ipairs(keys) do
        out[#out + 1] = "[" .. ser(k) .. "]=" .. ser(v[k]) .. ","
    end
    out[#out + 1] = "}"
    return table.concat(out)
end
local okd, d = pcall(dofile, SRC .. "/enemy_data.lua")
if not okd or type(d) ~= "table" then print("ENEMY DATA FAILED: " .. tostring(d)) os.exit(1) end
local parts, counts, sizes = {}, {}, {}
for _, k in ipairs(KEEP) do
    local v = d[k]
    if v ~= nil then
        local s = ser(v)
        parts[#parts + 1] = string.format("[%q]=%s", k, s)
        counts[k] = (type(v) == "table") and (function() local n = 0 for _ in pairs(v) do n = n + 1 end return n end)() or 1
        sizes[k] = #s
    end
end
-- 额外：special_hazards 的爆炸半径、mechanics 的武器限制
local okh, hz = pcall(dofile, SRC .. "/special_hazards.lua")
if okh and type(hz) == "table" and type(hz.zones) == "table" then
    local z = {}
    for k, v in pairs(hz.zones) do if type(v) == "table" and v.r then z[k] = v.r end end
    local s = ser(z)
    parts[#parts + 1] = string.format("[%q]=%s", "zone_r", s)
    counts.zone_r, sizes.zone_r = (function() local n = 0 for _ in pairs(z) do n = n + 1 end return n end)(), #s
end
local body = "-- 自动生成，别手改。来源: PBZAssist/Scripts/enemy_data.lua，生成器 tools/make_ad_data.lua\n"
    .. "-- 只读快照：缺键 = 不知道，调用方必须保留非数据退路。\nreturn {" .. table.concat(parts, ",\n") .. "}\n"
io.write("OUT " .. OUT .. "\n")
local f = assert(io.open(OUT .. "/ad_data.lua", "wb"))
f:write(body) f:close()
local meta = {}
for k, v in pairs(counts) do meta[#meta + 1] = string.format("%s=%d(%dB)", k, v, sizes[k] or 0) end
table.sort(meta)
local m = assert(io.open(OUT .. "/ad_data_meta.txt", "wb"))
m:write(string.format("build=%s\nsource=%s\nbytes=%d\n", tostring(d.build), SRC, #body))
m:write("tables: " .. table.concat(meta, " ") .. "\n")
m:close()
print(string.format("written %d bytes, %d tables", #body, #parts))
