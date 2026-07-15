-- Aegis: Exchange
-- core/db.lua
--
-- SavedVariables scaffolding for the price database.
--
-- Declared in Aegis_Exchange.toc:
--   AegisExchangeDB      -- account-wide. Turtle's AH is CROSS-FACTION (one
--                           shared economy), so prices are NOT split by
--                           faction here.
--   AegisExchangeCharDB  -- per-character. UI state, last scan time, etc.
--
-- IMPORTANT: both globals are nil until ADDON_LOADED fires for
-- "Aegis_Exchange". All access goes through db.Init(), which is queued on the
-- init.lua OnLoad list and therefore runs at exactly the right moment.

local A = AegisExchange
A.db = {}
local db = A.db

-- Bump when the on-disk shape changes so we can migrate old data.
local DB_VERSION = 1

-- Default shape of the account-wide DB.
local function DefaultAccountDB()
    return {
        version = DB_VERSION,
        -- itemId -> { min = copper, market = copper, seen = time, count = n }
        prices = {},
        -- itemName -> itemId, to resolve names from tooltips / item links.
        nameToId = {},
    }
end

-- Default shape of the per-character DB.
local function DefaultCharDB()
    return {
        version  = DB_VERSION,
        ui       = {},    -- window position, open tab, column widths, ...
        lastScan = nil,   -- server time of the last completed full scan
    }
end

-- Fill in any missing default keys on `target` without clobbering existing
-- values. Copies one level of nested default tables.
local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                local inner = {}
                for k2, v2 in pairs(v) do
                    inner[k2] = v2
                end
                target[k] = inner
            else
                target[k] = v
            end
        end
    end
end

-- Runs after ADDON_LOADED (queued via A.OnLoad below). The SavedVariables
-- globals exist by now: either a saved table, an empty table on first login,
-- or nil which we replace with defaults.
function db.Init()
    if AegisExchangeDB == nil then
        AegisExchangeDB = DefaultAccountDB()
    else
        ApplyDefaults(AegisExchangeDB, DefaultAccountDB())
    end

    if AegisExchangeCharDB == nil then
        AegisExchangeCharDB = DefaultCharDB()
    else
        ApplyDefaults(AegisExchangeCharDB, DefaultCharDB())
    end

    db.account = AegisExchangeDB
    db.char    = AegisExchangeCharDB
end

-- Return the stored price record for an itemId, or nil. Scaffolding only — no
-- scan data is written yet.
function db.GetPrice(itemId)
    if not db.account then return nil end
    return db.account.prices[itemId]
end

-- Store / replace a price record for an itemId. Scaffolding only.
function db.SetPrice(itemId, record)
    if not db.account then return end
    db.account.prices[itemId] = record
end

-- Register the bootstrap with the load queue.
A.OnLoad(db.Init)
