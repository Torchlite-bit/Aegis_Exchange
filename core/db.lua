-- Aegis: Exchange
-- core/db.lua
--
-- SavedVariables price database, modeled on aux-addon's historical-value
-- scheme: per item we keep a daily MINIMUM unit buyout, and derive market
-- value as a time-weighted median of the last ~11 daily values.
--
-- Declared in Aegis_Exchange.toc:
--   AegisExchangeDB      -- account-wide. Turtle's AH is CROSS-FACTION (one
--                           shared economy), so prices are NOT split by
--                           faction.
--   AegisExchangeCharDB  -- per-character. UI state, last scan info.
--
-- On-disk shape (kept compact — a 50+ page scan touches thousands of items):
--   AegisExchangeDB.items[itemID] = {
--       daily  = { [dayNumber] = minUnitBuyout },  -- pruned to KEEP_DAYS
--       seen   = count,                            -- auctions ever recorded
--       vendor = sellPrice,                        -- per unit, when known
--   }
--   AegisExchangeDB.names[itemName] = itemID       -- for link-less tooltips
--                                                  -- (mail inbox on 1.12)
--
-- IMPORTANT: both globals are nil until ADDON_LOADED fires for
-- "Aegis_Exchange". db.Init is queued via A.OnLoad and runs exactly then.

local A = AegisExchange
A.db = {}
local db = A.db

-- Bump when the on-disk shape changes so we can migrate old data.
local DB_VERSION = 2

-- Daily entries retained per item; also the window MarketValue medians over.
local KEEP_DAYS = 11

-- Per-day downweight applied to older daily values in the market median.
-- 0.95^10 ~= 0.60, so a value from 10 days ago still carries real weight —
-- "lightly downweighted", not discarded.
local DECAY = 0.95

-- Days are plain integers so daily tables stay tiny in SavedVariables.
function db.Day()
    return math.floor(time() / 86400)
end

-- Default shape of the account-wide DB.
local function DefaultAccountDB()
    return {
        version = DB_VERSION,
        items = {},   -- itemID -> { daily, seen, vendor }
        names = {},   -- itemName -> itemID
        -- Shopping (Buy tab): saved lists + recent searches, account-wide so
        -- every character shares them.
        shopping = {
            lists  = {},   -- array of { name = "...", items = { "Silk Cloth", ... } }
            recent = {},   -- recent search terms, most-recent first (capped)
        },
    }
end

-- Default shape of the per-character DB.
local function DefaultCharDB()
    return {
        version  = DB_VERSION,
        ui       = {},    -- window position, open tab, column widths, ...
        lastScan = nil,   -- { when = epoch, pages = n, auctions = n }
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
    elseif (AegisExchangeDB.version or 0) < DB_VERSION then
        -- v1 scaffolding carried no real price data; keep its name map (was
        -- `nameToId`) and rebuild the rest.
        local old = AegisExchangeDB
        AegisExchangeDB = DefaultAccountDB()
        if type(old.nameToId) == "table" then
            AegisExchangeDB.names = old.nameToId
        end
    end
    ApplyDefaults(AegisExchangeDB, DefaultAccountDB())
    AegisExchangeDB.version = DB_VERSION

    if AegisExchangeCharDB == nil then
        AegisExchangeCharDB = DefaultCharDB()
    end
    ApplyDefaults(AegisExchangeCharDB, DefaultCharDB())
    AegisExchangeCharDB.version = DB_VERSION

    db.account = AegisExchangeDB
    db.char    = AegisExchangeCharDB
end

-- Drop daily entries beyond the KEEP_DAYS most recent so records stay small.
local function PruneDaily(rec)
    local days = {}
    for d in pairs(rec.daily) do
        table.insert(days, d)
    end
    if table.getn(days) <= KEEP_DAYS then return end
    table.sort(days, function(a, b) return a > b end)   -- newest first
    for i = KEEP_DAYS + 1, table.getn(days) do
        rec.daily[days[i]] = nil
    end
end

-- Record one observed auction: fold `unitBuyout` (copper, per unit) into
-- today's daily minimum. Called for EVERY auction seen on ANY result page —
-- ordinary browsing feeds the DB, not just full scans. `itemName` is optional
-- and keeps the name->id map fresh.
function db.RecordAuction(itemId, unitBuyout, itemName)
    if not db.account then return end   -- pre-ADDON_LOADED safety
    if not itemId or not unitBuyout or unitBuyout <= 0 then return end
    local rec = db.account.items[itemId]
    if not rec then
        rec = { daily = {}, seen = 0 }
        db.account.items[itemId] = rec
    end
    local today = db.Day()
    local cur = rec.daily[today]
    if not cur or unitBuyout < cur then
        rec.daily[today] = unitBuyout
        PruneDaily(rec)
    end
    rec.seen = rec.seen + 1
    if itemName then
        db.account.names[itemName] = itemId
    end
end

-- Most recent daily minimum unit buyout, or nil if never seen.
function db.MinBuyout(itemId)
    if not db.account then return nil end
    local rec = db.account.items[itemId]
    if not rec then return nil end
    local newest = nil
    for d in pairs(rec.daily) do
        if not newest or d > newest then newest = d end
    end
    if not newest then return nil end
    return rec.daily[newest]
end

-- Market value: time-weighted MEDIAN of up to the last KEEP_DAYS daily
-- minima. Each value's weight decays by DECAY per day of age, so recent days
-- dominate slightly but a run of old data still counts. Returns nil if the
-- item has never been seen.
function db.MarketValue(itemId)
    if not db.account then return nil end
    local rec = db.account.items[itemId]
    if not rec then return nil end

    local today = db.Day()
    local samples = {}
    for d, v in pairs(rec.daily) do
        table.insert(samples, { value = v, weight = DECAY ^ (today - d) })
    end
    local n = table.getn(samples)
    if n == 0 then return nil end

    -- Weighted median: sort by value, walk cumulative weight to the halfway
    -- point.
    table.sort(samples, function(a, b) return a.value < b.value end)
    local total = 0
    for i = 1, n do
        total = total + samples[i].weight
    end
    local half = total / 2
    local cum = 0
    for i = 1, n do
        cum = cum + samples[i].weight
        if cum >= half then
            return samples[i].value
        end
    end
    return samples[n].value
end

-- Vendor sell price (per unit), collected opportunistically from tooltip
-- money while at a merchant (1.12's GetItemInfo has no sell price).
function db.SetVendor(itemId, copper)
    if not db.account then return end
    if not itemId or not copper or copper <= 0 then return end
    local rec = db.account.items[itemId]
    if not rec then
        rec = { daily = {}, seen = 0 }
        db.account.items[itemId] = rec
    end
    rec.vendor = copper
end

function db.GetVendor(itemId)
    if not db.account then return nil end
    local rec = db.account.items[itemId]
    return rec and rec.vendor
end

-- Resolve an item name to an itemID (for tooltips with no link, e.g. the
-- 1.12 mail inbox).
function db.IdFromName(name)
    if not db.account or not name then return nil end
    return db.account.names[name]
end

-- Number of distinct items with any recorded price data.
function db.ItemCount()
    if not db.account then return 0 end
    local n = 0
    for _ in pairs(db.account.items) do
        n = n + 1
    end
    return n
end

-- Per-character record of the last completed full scan.
function db.SetLastScan(pages, auctions, full)
    if not db.char then return end
    db.char.lastScan = {
        when = time(), pages = pages, auctions = auctions, full = full,
    }
end

function db.GetLastScan()
    return db.char and db.char.lastScan
end

-- Register the bootstrap with the load queue.
A.OnLoad(db.Init)
