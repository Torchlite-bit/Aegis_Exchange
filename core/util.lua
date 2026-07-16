-- Aegis: Exchange
-- core/util.lua
--
-- Lua 5.0 / vanilla 1.12 safe helpers.
--   * money formatting + gold/silver/copper parsing
--   * string split via string.gfind  (NOT string.gmatch)
--   * small table helpers
--
-- Reminder of the constraints exercised here:
--   * no "%" operator          -> math.mod(a, b)
--   * no "#" length operator   -> table.getn(t)
--   * no string.match/gmatch   -> string.find (with captures) / string.gfind

local A = AegisExchange
A.util = {}
local util = A.util

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD   = 10000   -- 100 * 100

-- ---------------------------------------------------------------------------
-- Money
-- ---------------------------------------------------------------------------

-- Split a copper amount into (gold, silver, copper). Uses math.mod and
-- math.floor because Lua 5.0 has neither the "%" operator nor integer div.
function util.MoneyParts(copper)
    copper = copper or 0
    if copper < 0 then copper = -copper end
    copper = math.floor(copper)
    local gold   = math.floor(copper / COPPER_PER_GOLD)
    local silver = math.floor(math.mod(copper, COPPER_PER_GOLD) / COPPER_PER_SILVER)
    local cop    = math.mod(copper, COPPER_PER_SILVER)
    return gold, silver, cop
end

-- Format a copper amount as a compact string like "12g 34s 56c". Leading zero
-- denominations are dropped, but copper is always shown when the total is
-- under one silver. Pass `colored` = true for WoW color escape codes.
function util.FormatMoney(copper, colored)
    local g, s, c = util.MoneyParts(copper)
    local parts = {}
    if colored then
        if g > 0 then table.insert(parts, "|cffffd700" .. g .. "g|r") end
        if s > 0 then table.insert(parts, "|cffc7c7cf" .. s .. "s|r") end
        if c > 0 or table.getn(parts) == 0 then
            table.insert(parts, "|cffeda55f" .. c .. "c|r")
        end
    else
        if g > 0 then table.insert(parts, g .. "g") end
        if s > 0 then table.insert(parts, s .. "s") end
        if c > 0 or table.getn(parts) == 0 then
            table.insert(parts, c .. "c")
        end
    end
    return table.concat(parts, " ")
end

-- Parse a money string like "12g 34s 56c" (units case-insensitive, spaces
-- optional) into total copper. Returns nil when nothing parseable is found.
-- Uses string.gfind (Lua 5.0) with a captured pattern; NOT string.gmatch.
function util.ParseMoney(str)
    if type(str) ~= "string" then return nil end
    local total = 0
    local found = false
    -- Each iteration yields a "<digits>" amount and a single unit letter.
    for amount, unit in string.gfind(str, "(%d+)%s*([gscGSC])") do
        local n = tonumber(amount)
        if n then
            unit = string.lower(unit)
            if unit == "g" then
                total = total + n * COPPER_PER_GOLD
            elseif unit == "s" then
                total = total + n * COPPER_PER_SILVER
            else
                total = total + n
            end
            found = true
        end
    end
    if not found then return nil end
    return total
end

-- ---------------------------------------------------------------------------
-- Strings
-- ---------------------------------------------------------------------------

-- Split `str` on a single separator character `sep` (default: whitespace) into
-- an array of non-empty tokens. Returns the array and its length. Uses
-- string.gfind so it stays Lua 5.0 safe. `sep` is expected to be a plain
-- (non-magic) character; the default handles spaces/tabs.
function util.Split(str, sep)
    local out = {}
    if type(str) ~= "string" then return out, 0 end
    local pattern
    if sep == nil or sep == " " then
        pattern = "[^%s]+"
    else
        pattern = "[^" .. sep .. "]+"
    end
    for token in string.gfind(str, pattern) do
        table.insert(out, token)
    end
    return out, table.getn(out)
end

-- Trim leading/trailing whitespace. Uses string.gsub (fine in 5.0) with an
-- anchored capture; NOT string.match.
function util.Trim(str)
    if type(str) ~= "string" then return str end
    local result = string.gsub(str, "^%s*(.-)%s*$", "%1")
    return result   -- discard gsub's 2nd return (substitution count)
end

-- Pull the numeric itemID out of an item link or item string
-- ("|Hitem:2589:0:0:0|h..." or "item:2589:0:0:0"). Returns nil when the
-- argument is not a link. string.find with a capture; NOT string.match.
function util.ItemIdFromLink(link)
    if type(link) ~= "string" then return nil end
    local _, _, id = string.find(link, "item:(%d+)")
    return tonumber(id)
end

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

-- Format a duration in seconds compactly: "42s", "38m", "2h 14m".
function util.FormatDuration(sec)
    sec = math.floor(sec or 0)
    if sec < 0 then sec = 0 end
    if sec < 60 then
        return sec .. "s"
    elseif sec < 3600 then
        return math.ceil(sec / 60) .. "m"
    end
    local h = math.floor(sec / 3600)
    local m = math.floor(math.mod(sec, 3600) / 60)
    return h .. "h " .. m .. "m"
end

-- Format "how long ago": "just now", "5m ago", "2h 14m ago", "3d ago".
function util.FormatAgo(sec)
    sec = math.floor(sec or 0)
    if sec < 60 then
        return "just now"
    elseif sec < 3600 then
        return math.floor(sec / 60) .. "m ago"
    elseif sec < 86400 then
        local h = math.floor(sec / 3600)
        local m = math.floor(math.mod(sec, 3600) / 60)
        return h .. "h " .. m .. "m ago"
    end
    return math.floor(sec / 86400) .. "d ago"
end

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Shallow copy of an array or hash table.
function util.CopyTable(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

-- Look for `value` in array `t`. Returns (true, index) or (false, nil).
function util.ArrayContains(t, value)
    local n = table.getn(t)
    local i = 1
    while i <= n do
        if t[i] == value then return true, i end
        i = i + 1
    end
    return false, nil
end

-- Count entries in a hash table via pairs, since table.getn only measures the
-- contiguous array part.
function util.CountKeys(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end
