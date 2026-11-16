-- Flat JSON for native Mods Menu configs; deliberately rejects nested values.
-- Standalone Lua 5.4 / LuaJIT, no dependency on another mod's Lua state.
local M = { NULL = {} }
local escape = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
local quoted = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function utf8code(c)
    if c < 128 then return string.char(c) end
    if c < 2048 then return string.char(192 + math.floor(c / 64), 128 + c % 64) end
    if c < 65536 then return string.char(224 + math.floor(c / 4096), 128 + math.floor(c / 64) % 64, 128 + c % 64) end
    return string.char(240 + math.floor(c / 262144), 128 + math.floor(c / 4096) % 64, 128 + math.floor(c / 64) % 64, 128 + c % 64)
end
local function parse(text)
    local p = text:sub(1, 3) == '\239\187\191' and 4 or 1
    local function fail(why) error(why .. ' at byte ' .. p, 0) end
    local function skip() p = text:find('[^ \t\r\n]', p) or #text + 1 end
    local function hex(at)
        local s = text:sub(at, at + 3)
        if not s:match('^%x%x%x%x$') then fail('invalid Unicode escape') end
        return tonumber(s, 16)
    end
    local function str()
        local parts, i = {}, p + 1
        while true do
            local j = text:find('["\\%z\1-\31]', i)
            if not j then fail('unclosed string') end
            parts[#parts + 1] = text:sub(i, j - 1)
            local c = text:sub(j, j)
            if c == '"' then p = j + 1 return table.concat(parts) end
            if c ~= '\\' then fail('control character in string') end
            local e = text:sub(j + 1, j + 1)
            if e == 'u' then
                local code = hex(j + 2)
                i = j + 6
                if code >= 0xD800 and code <= 0xDBFF then
                    if text:sub(i, i + 1) ~= '\\u' then fail('unpaired surrogate') end
                    local low = hex(i + 2)
                    if low < 0xDC00 or low > 0xDFFF then fail('invalid surrogate pair') end
                    code, i = 65536 + (code - 0xD800) * 1024 + low - 0xDC00, i + 6
                elseif code >= 0xDC00 and code <= 0xDFFF then fail('unpaired surrogate') end
                parts[#parts + 1] = utf8code(code)
            elseif escape[e] then parts[#parts + 1], i = escape[e], j + 2
            else fail('unknown escape') end
        end
    end
    local function value()
        local c = text:sub(p, p)
        if c == '"' then return str() end
        for _, v in ipairs({ { 'true', true }, { 'false', false }, { 'null', M.NULL } }) do
            if text:sub(p, p + #v[1] - 1) == v[1] then p = p + #v[1] return v[2] end
        end
        local whole = text:match('^-?%d+', p)
        if not whole or whole:match('^-?0%d') then fail('invalid number or non-flat value') end
        local start = p
        p = p + #whole
        local frac = text:match('^%.%d+', p)
        if frac then p = p + #frac end
        local exp = text:match('^[eE][-+]?%d+', p)
        if exp then p = p + #exp end
        local n = tonumber(text:sub(start, p - 1))
        if not n or n == math.huge or n == -math.huge then fail('nonfinite number') end
        return n
    end
    skip()
    if text:sub(p, p) ~= '{' then fail('expected flat JSON object') end
    p = p + 1
    local out, count = {}, 0
    skip()
    if text:sub(p, p) == '}' then p = p + 1
    else
        while true do
            skip()
            if text:sub(p, p) ~= '"' then fail('expected string key') end
            local key = str()
            skip()
            if text:sub(p, p) ~= ':' then fail('expected colon') end
            p = p + 1
            skip()
            out[key] = value()
            count = count + 1
            if count > 256 then fail('too many keys') end
            skip()
            local c = text:sub(p, p)
            p = p + 1
            if c == '}' then break end
            if c ~= ',' then fail('expected comma or closing brace') end
        end
    end
    skip()
    if p <= #text then fail('trailing text') end
    return out
end
function M.decode(text)
    if type(text) ~= 'string' or #text > 65536 then return nil, 'missing or oversized JSON' end
    local ok, v = pcall(parse, text)
    if ok then return v end
    return nil, tostring(v)
end
local function quote(s)
    return '"' .. s:gsub('["\\%z\1-\31]', function(c) return quoted[c] or string.format('\\u%04x', c:byte()) end) .. '"'
end
function M.encode(object)
    local keys, lines = {}, {}
    for k in pairs(object) do
        if type(k) ~= 'string' then return nil, 'non-string key' end
        keys[#keys + 1] = k
    end
    if #keys > 256 then return nil, 'too many keys' end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = object[k]
        local lit
        if v == M.NULL then lit = 'null'
        elseif type(v) == 'string' then lit = quote(v)
        elseif type(v) == 'boolean' then lit = tostring(v)
        elseif type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then lit = string.format('%.17g', v)
        else return nil, 'non-flat or nonfinite value: ' .. k end
        lines[#lines + 1] = '  ' .. quote(k) .. ': ' .. lit
    end
    local text = '{\n' .. table.concat(lines, ',\n') .. '\n}\n'
    if #text > 65536 then return nil, 'oversized JSON' end
    return text
end
return M
