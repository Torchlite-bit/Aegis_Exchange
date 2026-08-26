-- Aegis: Exchange
-- core/db.lua
--
-- SavedVariables price database, modeled on aux-addon's historical-value
-- scheme: per item we keep a daily MINIMUM unit buyout, and derive market
-- value as a time-weighted median of the last ~30 daily values.
--
-- Declared in Aegis_Exchange.toc:
--   AegisExchangeDB      -- account-wide. Turtle's AH is CROSS-FACTION (one
--                           shared economy), so prices are NOT split by
--                           faction.
--   AegisExchangeCharDB  -- per-character. UI state, last scan info.
--
-- On-disk shape (kept compact — a 50+ page scan touches thousands of items):
--   AegisExchangeDB.realms[realmName].items[itemID] = {
--       daily = { [dayNumber] = minUnitBuyout },   -- pruned to KEEP_DAYS
--       seen  = count,                             -- auctions ever recorded
--   }
--   AegisExchangeDB.vendors[itemID] = sellPrice    -- per unit, when known
--   AegisExchangeDB.names[itemName] = itemID       -- for link-less tooltips
--                                                  -- (mail inbox on 1.12)
--
-- WHY PRICES ARE KEYED BY REALM. `## SavedVariables` is account-wide across
-- every realm, so before v3 a character on Octo WoW and one on Capy WoW folded
-- their buyouts into the SAME daily minimum — two unrelated economies blended
-- into one median. Turtle's AH being cross-faction (a CLAUDE.md hard rule)
-- means there is no FACTION split to make, but there is very much a REALM one.
-- So market data hangs off `realms[realmName]`, while everything that is a
-- game constant rather than an economy fact stays account-wide and shared:
--   * vendors -- an NPC's sell price is identical on every realm; siloing it
--                per realm would make you re-learn it server by server.
--   * names   -- itemName -> itemID is a property of the game, not the market.
--   * shopping / crafting / settings / ledger / vendorMarks -- user data that
--                should follow you everywhere.
--
-- IMPORTANT: both globals are nil until ADDON_LOADED fires for
-- "Aegis_Exchange". db.Init is queued via A.OnLoad and runs exactly then.

local A = AegisExchange
A.db = {}
local db = A.db

-- Bump when the on-disk shape changes so we can migrate old data.
--   v2 -> v3: price data moved from a single account-wide `items` table to
--             `realms[realmName].items`, and vendor prices moved out to their
--             own account-wide `vendors` table. See MigrateToRealms.
local DB_VERSION = 3

-- Daily entries retained per item; also the window MarketValue medians over.
--
-- These two were audited against their stated intent — "recent days weighted
-- more, decreasing effect past roughly a month" — and neither half held. The
-- window was 11 days, so nothing survived to a month for its effect to
-- decrease; and at 0.95 per day the oldest retained value still carried 57% of
-- today's weight, which made the "time-weighted" median return the same answer
-- as an UNWEIGHTED one in 93% of cases. It was a flat 11-day median wearing a
-- decay curve's name.
--
-- 30 days at 0.85 was picked because it costs nothing to get:
--
--   age       today    3d    7d   14d   21d   30d
--   weight     100%   61%   32%   10%    3%    1%
--
--   * a step change (100 -> 200 and stays there) is tracked in 5 days —
--     IDENTICAL to the old setting, so nothing got less responsive in trade;
--   * the weighting now changes the answer in 88% of cases instead of 7%;
--   * outlier rejection is untouched — one day at 5c, or at 50x, still moves a
--     steady series by nothing, which is the whole reason this is a median;
--   * and it fixes casual scanning. In an 11-day window someone scanning weekly
--     had ONE sample, and a weighted median of one sample is just that sample.
--     Thirty days gives them four.
--
-- Existing databases hold at most 11 days, so they ramp up to the new window
-- over the following three weeks rather than changing under anyone at once.
local KEEP_DAYS = 30

-- Per-day downweight applied to older daily values in the market median.
local DECAY = 0.85

-- Days are plain integers so daily tables stay tiny in SavedVariables.
function db.Day()
    return math.floor(time() / 86400)
end

-- Default shape of the account-wide DB.
local function DefaultAccountDB()
    return {
        version = DB_VERSION,
        -- Market data, per realm: realmName -> { items = { [id] = {daily,seen} } }.
        -- Two realms are two economies; see the header note.
        realms  = {},
        -- Game constants, shared by every realm (see header note).
        vendors = {},   -- itemID   -> vendor sell price, per unit
        names   = {},   -- itemName -> itemID
        -- Item FACTS harvested from the client's own cache: quality, required
        -- level and equip slot, per item id. Account-wide for the same reason
        -- as vendors -- these are properties of the item, identical on every
        -- realm. See db.HarvestStep for where they come from and why the
        -- sweep that fills this is safe.
        facts   = {},   -- itemID   -> { q = quality, r = minLevel, e = equipLoc }
        -- Max stack size per item (20 for Mageweave, 10 for Copper Ore, ...).
        -- Account-wide because it is a property of the ITEM, identical on
        -- every realm -- same reasoning as vendor prices above.
        --
        -- Persisted because the only 1.12 source, GetItemInfo, answers ONLY
        -- for items already in the client's local cache. An auction for
        -- something you have never handled returns nil, so anything that asks
        -- at browse time gets nil for exactly the items it most needs. We
        -- learn opportunistically (bags, browsing, any successful lookup) and
        -- keep it forever.
        stacks  = {},   -- itemID   -> max stack size
        -- Shopping (Buy tab): saved lists + recent searches, account-wide so
        -- every character shares them.
        shopping = {
            lists  = {},   -- array of { name = "...", items = { "Silk Cloth", ... } }
            recent = {},   -- recent search terms, most-recent first (capped)
            -- Saved Searches: queries you promoted out of `recent`. An ORDERED
            -- array, not a set -- the order is the user's, maintained by the
            -- favorite's Move Up / Move Down menu, so it must survive a save.
            favorites = {},
        },
        -- Crafting (Crafting tab): recipes captured from the profession window,
        -- each with its reagents, so you can shop the mats at the AH.
        crafting = {
            projects = {},  -- { { name, itemId, reagents = { {name,count,itemId} } } }
        },
        -- User settings (Aegis tab). Values are read through db.Setting, which
        -- falls back to SETTING_DEFAULTS, so a save missing a key still works.
        settings = {},
        -- Sales & income history (History tab): a capped list of transactions,
        -- plus dedup keys so a mailbox sale is only logged once.
        ledger     = {},   -- array of { t, kind = "sale"|"buy", item, amount, id }
        ledgerSeen = {},   -- dedup key -> true (AH sale mails)
        -- Items you've marked to sell at a vendor (Sell tab -> Vendor list).
        -- The merchant window then offers to sell them all in one click.
        vendorMarks = {},  -- itemId -> true
    }
end

-- Cap on retained transactions so SavedVariables stays small.
local LEDGER_MAX = 500

-- Defaults for every user setting. db.Setting falls back to these, so adding a
-- new setting here is enough -- no migration of old saves needed.
local SETTING_DEFAULTS = {
    duration       = 480,       -- default post duration, minutes (120/480/1440)
    -- Default pricing: undercut the lowest competitor by a FLAT 1 copper. That
    -- is the behaviour most sellers want out of the box -- just enough to be
    -- cheapest without giving away margin.
    undercutMode   = "flat",    -- "pct" (percent) or "flat" (fixed copper)
    undercutPct    = 5,         -- percent below the reference (pct mode)
    undercutAmount = 1,         -- copper below the reference (flat mode)
    sellDefault    = "undercut", -- slot prefill: "undercut"|"market"|"none"
    tooltip        = true,      -- master switch for Aegis price lines
    -- Which lines the tooltip shows, all on by default so the behaviour is
    -- unchanged for anyone who never opens these. Only consulted when the
    -- master `tooltip` switch is on.
    tipMarket      = true,      -- "Aegis Market" (time-weighted median)
    tipMinBuyout   = true,      -- "Aegis Min Buyout" (most recent daily low)
    tipVendor      = true,      -- "Aegis Vendor Price"
    -- Stack totals -- "(x20 = 24g)" after a unit price. false = always show,
    -- true = only while Shift is held, which is how aux does it and keeps the
    -- tooltip short on a bank full of stacks.
    tipStackShift  = false,
    profLine       = true,      -- show the profit line on profession windows
    pfSkin         = true,      -- match pfUI's look when pfUI is installed
    -- Query pacing between scan pages:
    --   "auto" -- let the client's CanSendAuctionQuery() gate decide. Vanilla
    --            keeps it shut ~5s; the AuctionQueryThrottle DLL clears it as
    --            soon as the reply lands, so scans speed up automatically.
    --   "safe" -- always keep the fixed 4s floor as well.
    queryThrottle  = "auto",
    -- Ask before cancelling an auction. Off = cancel on the first click, which
    -- is what you want when clearing a lot of undercuts by hand.
    confirmCancel  = true,
    -- Ask before posting an auction. Off = post on the first click, which is
    -- what you want when relisting a stack at a time.
    confirmPost    = true,
    -- After posting, keep any REMAINING items of the same type in the sell
    -- slot at the same price, so the leftover stack can go straight out. Off
    -- clears the slot, which is what you want when posting one thing at a
    -- time and picking the next from the bags yourself.
    keepLeftovers  = true,
    -- Expected disenchant value on tooltips. Only ever appears for an item we
    -- can actually answer for, so leaving it on costs nothing on the rest.
    tipDisenchant  = true,
    -- The material breakdown under the disenchant value. ON by default.
    --
    -- It was off, and that was wrong. The split is a fact about the ITEM --
    -- required level gives the band, the band gives the probabilities -- and it
    -- needs no market data at all. So it is exactly what is left to show when
    -- the VALUE cannot be computed, which is most items until a scan has run.
    -- Defaulting it off meant the common case showed a bare "?" while the one
    -- thing Aegis actually knew about the item sat behind a checkbox nobody
    -- had been told about.
    tipDisenchantRows = true,
}

-- Read a user setting, falling back to its default when unset.
function db.Setting(key)
    local s = db.account and db.account.settings
    local v = s and s[key]
    if v == nil then return SETTING_DEFAULTS[key] end
    return v
end

-- Write a user setting (account-wide).
function db.SetSetting(key, value)
    if not db.account then return end
    if not db.account.settings then db.account.settings = {} end
    db.account.settings[key] = value
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

-- Which realm's price bucket we're reading. Cached at Init: GetRealmName is
-- stable for the session, and this is on the hot path of every scanned auction.
function db.RealmKey()
    local name = GetRealmName and GetRealmName() or nil
    if not name or name == "" then return "?" end
    return name
end

-- The current realm's item table, created on demand. Every price read/write
-- goes through here rather than touching db.account directly, so the realm
-- split lives in exactly one place.
function db.Items()
    if not db.account then return nil end
    local realms = db.account.realms
    if not realms then realms = {}; db.account.realms = realms end
    local key = db.realmKey or db.RealmKey()
    local bucket = realms[key]
    if not bucket then bucket = {}; realms[key] = bucket end
    if not bucket.items then bucket.items = {} end
    return bucket.items
end

-- Observed disenchant results for the current realm, created on demand.
--
-- Realm-scoped for the same reason prices are: what an item breaks into is
-- SERVER behaviour, and this addon's whole reason for learning it is that
-- Turtle adds items the shipped table has never heard of. Pooling two servers'
-- observations would be pooling two rulesets.
function db.Disenchanted()
    if not db.account then return nil end
    local realms = db.account.realms
    if not realms then realms = {}; db.account.realms = realms end
    local key = db.realmKey or db.RealmKey()
    local bucket = realms[key]
    if not bucket then bucket = {}; realms[key] = bucket end
    if not bucket.disenchants then bucket.disenchants = {} end
    return bucket.disenchants
end

-- Record ONE observed disenchant: `itemId` produced `quantity` of `matId`.
--
-- OBSERVATIONS ONLY. Nothing derived is ever written here -- not a band, not
-- an item level, not a guess from required level. A derived value stored
-- beside real observations becomes indistinguishable from one a month later,
-- and there is no way back from that. Everything above this reads these counts
-- and derives at call time, every time.
function db.RecordDisenchant(itemId, matId, quantity)
    if not itemId or not matId then return end
    quantity = tonumber(quantity) or 1
    if quantity < 1 then return end
    local all = db.Disenchanted()
    if not all then return end
    local rec = all[itemId]
    if not rec then rec = {}; all[itemId] = rec end
    local m = rec[matId]
    if not m then m = { n = 0, total = 0 }; rec[matId] = m end
    m.n = m.n + 1
    m.total = m.total + quantity
end

-- What we have seen `itemId` break into: { [matId] = { n = , total = } }, or
-- nil when it has never been disenchanted on this realm.
function db.Disenchants(itemId)
    if not itemId then return nil end
    local all = db.Disenchanted()
    if not all then return nil end
    return all[itemId]
end

-- v2 -> v3. Old saves pooled EVERY realm's prices into one account-wide
-- `items` table, with the vendor price stored inside each item record.
--
-- Vendor prices lift out cleanly -- they're a game constant, so they stay
-- account-wide and nothing is lost. The daily buyouts are the awkward part:
-- they carry no realm tag, so there is no way to know which realm each came
-- from. We attribute the whole set to the realm you first log in on after
-- upgrading. For the common single-realm user that preserves everything; for a
-- multi-realm user one realm inherits some foreign dailies, and that
-- self-corrects within KEEP_DAYS as fresh scans age the old values out. The
-- alternative -- discarding price history on upgrade -- is worse for everyone.
-- Bumped whenever a change makes previously HARVESTED facts wrong.
--
-- The harvest copies fields straight out of util.ItemInfo, so a bug in how
-- that tuple is read is written into SavedVariables and outlives the fix. That
-- happened: v1.44.0 through v1.46.2 recorded facts through an anchor that
-- misread four fields on clients returning a trailing value, so `r` held the
-- stack size instead of the required level. Thousands of records per player,
-- all quietly wrong, and de.Resolve reads them whenever the client's own cache
-- comes up empty -- which is exactly when they get used.
--
-- Fixing the reader does not fix the records. Bumping this discards them and
-- lets the sweep refill from the corrected reader.
local FACTS_VERSION = 2

-- Throw away harvested facts written by an older, wronger reader.
local function MigrateFacts(acct)
    if not acct then return end
    if acct.factsVersion == FACTS_VERSION then return end
    acct.facts = {}
    acct.factsVersion = FACTS_VERSION
end

local function MigrateToRealms(acct, realmKey)
    if type(acct.items) ~= "table" then return end
    if not acct.realms then acct.realms = {} end
    if not acct.vendors then acct.vendors = {} end
    local bucket = acct.realms[realmKey]
    if not bucket then bucket = {}; acct.realms[realmKey] = bucket end
    if not bucket.items then bucket.items = {} end
    for id, rec in pairs(acct.items) do
        if type(rec) == "table" then
            if rec.vendor and not acct.vendors[id] then
                acct.vendors[id] = rec.vendor
            end
            if type(rec.daily) == "table" then
                local existing = bucket.items[id]
                if existing then
                    -- Re-running the migration must not lose data: keep the
                    -- lower buyout per day, the way RecordAuction would.
                    for d, v in pairs(rec.daily) do
                        local cur = existing.daily[d]
                        if not cur or v < cur then existing.daily[d] = v end
                    end
                    existing.seen = (existing.seen or 0) + (rec.seen or 0)
                else
                    bucket.items[id] = { daily = rec.daily, seen = rec.seen or 0 }
                end
            end
        end
    end
    acct.items = nil   -- drop the v2 table so it can't be read again
end

-- Runs after ADDON_LOADED (queued via A.OnLoad below). The SavedVariables
-- globals exist by now: either a saved table, an empty table on first login,
-- or nil which we replace with defaults.
function db.Init()
    db.realmKey = db.RealmKey()

    if AegisExchangeDB == nil then
        AegisExchangeDB = DefaultAccountDB()
    elseif (AegisExchangeDB.version or 0) < 2 then
        -- v1 scaffolding carried no real price data; keep its name map (was
        -- `nameToId`) and rebuild the rest.
        local old = AegisExchangeDB
        AegisExchangeDB = DefaultAccountDB()
        if type(old.nameToId) == "table" then
            AegisExchangeDB.names = old.nameToId
        end
    end
    -- v2 saves carry real price history, so this migrates rather than rebuilds.
    -- Keyed off the presence of `items` too, not just the version number, so a
    -- save that was half-written by an older build still gets converted.
    if (AegisExchangeDB.version or 0) < 3 or AegisExchangeDB.items then
        MigrateToRealms(AegisExchangeDB, db.realmKey)
    end
    ApplyDefaults(AegisExchangeDB, DefaultAccountDB())
    AegisExchangeDB.version = DB_VERSION
    -- Discard harvested facts from a reader that got the tuple wrong. Placed
    -- here rather than in the sweep so it runs exactly once per session, before
    -- anything can read a stale record.
    MigrateFacts(AegisExchangeDB)

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
    local items = db.Items()
    if not items then return end
    local rec = items[itemId]
    if not rec then
        rec = { daily = {}, seen = 0 }
        items[itemId] = rec
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
    local items = db.Items()
    local rec = items and items[itemId]
    if not rec then return nil end
    local newest = nil
    for d in pairs(rec.daily) do
        if not newest or d > newest then newest = d end
    end
    if not newest then return nil end
    return rec.daily[newest]
end

-- How many distinct DAYS we hold a price for. The confidence figure behind
-- every market number: one day's data and thirty days' data produce the same
-- kind of answer from db.MarketValue and are not the same kind of fact.
--
-- Days, not auctions. A day contributes exactly one value (its minimum), so
-- counting sightings would report the size of one busy afternoon rather than
-- the breadth of the history.
function db.DayCount(itemId)
    if not db.account then return 0 end
    local items = db.Items()
    local rec = items and items[itemId]
    if not rec or type(rec.daily) ~= "table" then return 0 end
    return A.util.CountKeys(rec.daily)
end

-- Best "buy it now" unit price for estimates: the most recent daily minimum
-- buyout, falling back to the market median when today's data is thin. Used by
-- the crafting profit estimate.
function db.BestUnit(itemId)
    return db.MinBuyout(itemId) or db.MarketValue(itemId)
end

-- Market value: time-weighted MEDIAN of up to the last KEEP_DAYS daily
-- minima. Each value's weight decays by DECAY per day of age, so recent days
-- dominate but a run of old data still counts. Returns nil if the item has
-- never been seen.
--
-- A MEDIAN, not a mean, and that is the point: it returns one of the observed
-- daily values rather than an average of them, so a single absurd listing
-- cannot drag the number anywhere. The weights only decide WHICH observed
-- value gets picked — which is exactly why a decay curve that is nearly flat
-- across the window does nothing at all. See the KEEP_DAYS / DECAY note above.
function db.MarketValue(itemId)
    if not db.account then return nil end
    local items = db.Items()
    local rec = items and items[itemId]
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

-- Vendor sell price (per unit), collected opportunistically. TWO sources feed
-- this, and both are the client stating a fact rather than us deriving one:
--   * tooltip money while at a merchant (ui/tooltip.lua), and
--   * the auction house SELL SLOT (sell.LearnVendorFromSlot), which costs the
--     player nothing because posting is what they came to do.
-- The merchant figure is the more exact of the two -- see the charge-item note
-- above sell.VendorUnitFromSlot -- and a later write simply wins, so walking
-- past a merchant corrects anything the slot rounded.
--
-- Account-wide, NOT per realm: an NPC's sell price is the same on every server,
-- so learning it once should cover all of them.
function db.SetVendor(itemId, copper)
    if not db.account then return end
    if not itemId or not copper or copper <= 0 then return end
    if not db.account.vendors then db.account.vendors = {} end
    db.account.vendors[itemId] = copper
end

-- What a merchant pays for one of these, and where the number came from.
--
-- Returns value, source -- "client" or "merchant", or nil, nil.
--
-- The CLIENT's own figure outranks anything we learned, because it is not a
-- learned figure at all: 1.12 populates a sell price on every sellable item
-- and never displays it, so where a mod exposes that field it is simply the
-- answer. What we recorded at a merchant stays as the fallback for players
-- with no such mod, and as a cross-check where there is one.
--
-- The extra return is additive: seven call sites read only the first value
-- and are unaffected. It exists because a price the client stated and a price
-- we watched a merchant offer are different KINDS of fact, and advising
-- someone to destroy an item -- the one feature still unbuilt -- will have to
-- tell them apart.
-- `info` is optional and is only ever a util.ItemInfo the caller ALREADY had.
-- Nothing here fetches one: see the note above util.ClientSellPrice for what
-- that cost when it did.
function db.GetVendor(itemId, info)
    local known = A.util and A.util.ClientSellPrice
        and A.util.ClientSellPrice(itemId, info)
    if known then return known, "client" end
    if not db.account or not db.account.vendors then return nil end
    local learned = db.account.vendors[itemId]
    if learned then return learned, "merchant" end
    return nil
end

-- Max stack size, learned opportunistically. See the `stacks` note in
-- DefaultAccountDB for why this has to be persisted rather than asked for on
-- demand.
function db.SetMaxStack(itemId, count)
    if not db.account or not itemId then return end
    if not count or count < 1 then return end
    if not db.account.stacks then db.account.stacks = {} end
    db.account.stacks[itemId] = count
end

function db.GetMaxStack(itemId)
    if not db.account or not db.account.stacks or not itemId then return nil end
    return db.account.stacks[itemId]
end

-- Resolve an item name to an itemID (for tooltips with no link, e.g. the
-- 1.12 mail inbox).
function db.IdFromName(name)
    if not db.account or not name then return nil end
    return db.account.names[name]
end

-- Wipe recorded price data for THIS REALM (keeps the name->id map, which is
-- harmless and useful for link-less tooltips, and keeps vendor prices, which
-- are game constants). Driven by the Aegis tab's "Clear price data".
--
-- Deliberately realm-scoped: the Aegis tab shows this realm's item count, so
-- Clear wipes exactly what it reports. Another realm's history isn't visible
-- from here and shouldn't be destroyed from here either.
function db.ClearItems()
    if not db.account then return end
    if not db.account.realms then return end
    local key = db.realmKey or db.RealmKey()
    db.account.realms[key] = nil
end

-- ---------------------------------------------------------------------------
-- Sales & income ledger (History tab)
-- ---------------------------------------------------------------------------

-- Append a transaction. kind is "sale" (money in) or "buy" (money out).
function db.RecordTxn(kind, item, amount, itemId)
    if not db.account then return end
    if not amount or amount <= 0 then return end
    local led = db.account.ledger
    if not led then led = {}; db.account.ledger = led end
    table.insert(led, { t = time(), kind = kind, item = item or "?",
        amount = amount, id = itemId })
    -- Prune oldest beyond the cap.
    while table.getn(led) > LEDGER_MAX do
        table.remove(led, 1)
    end
end

function db.Ledger()
    return (db.account and db.account.ledger) or {}
end

-- Has this mail-sale dedup key been logged already?
function db.WasSeen(key)
    return db.account and db.account.ledgerSeen and db.account.ledgerSeen[key]
        and true or false
end

function db.MarkSeen(key)
    if not db.account then return end
    if not db.account.ledgerSeen then db.account.ledgerSeen = {} end
    db.account.ledgerSeen[key] = true
end

-- ---------------------------------------------------------------------------
-- Companion-addon integration surface (Aegis: Courier)
-- ---------------------------------------------------------------------------
--
-- Everything a companion addon needs lives in this block. It is THE contract:
-- Courier calls these and never touches AegisExchangeDB's internal shape, so
-- our tables can keep changing as long as these signatures hold.
--
-- Data flows Courier -> Aegis, one direction only. We never read Courier's
-- SavedVariables.

-- Bump when a signature or payload field below changes meaning. Courier reads
-- this and can refuse to integrate (rather than silently miscount) on a
-- mismatch.
--   1 -- RecordExternalTxn(txn), MailTxnKey(), ClaimMailScanning()
A.INTEGRATION_VERSION = 1

-- Dedup key for an auction-house mail, built the way Aegis's own mail scanner
-- has always built it.
--
-- Exposed deliberately: a user who ran Aegis alone for a while already has
-- those mails in the ledger under THESE keys. If Courier invented its own key
-- scheme it would re-report mail Aegis had already logged and double-count it
-- on the day Courier is installed. Generating the key through here makes the
-- handover seamless.
--
-- `daysLeft` is the mail's remaining lifetime from GetInboxHeaderInfo. Arrival
-- epoch is stable as daysLeft falls and `now` rises; bucketing to the hour
-- gives a key that survives relogins.
function A.MailTxnKey(subject, money, daysLeft)
    local arrival = math.floor((time() - (daysLeft or 0) * 86400) / 3600)
    return tostring(subject) .. "|" .. tostring(money) .. "|" .. arrival
end

-- Record a transaction observed by a companion addon.
--
-- txn = {
--   kind   = "sale" | "buy",   -- required; money in / money out
--   item   = "Silk Cloth",     -- required; display name
--   amount = 12345,            -- required; copper, > 0. For a sale this should
--                              -- be NET proceeds (after the 5% cut), because
--                              -- that is what actually arrived in the mail.
--   itemId = 4306,             -- optional
--   key    = "...",            -- optional dedup key; use A.MailTxnKey for AH
--                              -- mail. Repeats with the same key are ignored,
--                              -- so re-scanning a mailbox is safe.
-- }
--
-- Returns true on success, or false plus a short reason. Courier can surface
-- the reason rather than failing silently.
function A.RecordExternalTxn(txn)
    if type(txn) ~= "table" then return false, "payload must be a table" end
    if txn.kind ~= "sale" and txn.kind ~= "buy" then
        return false, "kind must be 'sale' or 'buy'"
    end
    if type(txn.amount) ~= "number" or txn.amount <= 0 then
        return false, "amount must be a positive number of copper"
    end
    if not db.account then return false, "Aegis DB not loaded yet" end
    if txn.key then
        if db.WasSeen(txn.key) then return false, "duplicate" end
        db.MarkSeen(txn.key)
    end
    db.RecordTxn(txn.kind, txn.item or "?", txn.amount, txn.itemId)
    return true
end

-- Mail-scanning ownership.
--
-- Aegis has scanned the mailbox for "Auction successful" mail since 0.17.0. If
-- Courier is installed it owns that job -- it reads mail far more thoroughly --
-- and Aegis must stand down, or a user running both gets two hooks racing over
-- the same inbox and sales counted twice.
--
-- Preferred handshake: Courier calls A.ClaimMailScanning("Aegis: Courier") from
-- its own ADDON_LOADED. Explicit beats sniffing, and it works whatever the
-- addon ends up being called.
function A.ClaimMailScanning(who)
    A.mailScanOwner = who or "external"
    return true
end

function A.ReleaseMailScanning()
    A.mailScanOwner = nil
    return true
end

-- The global we also accept as proof a Courier is present, for the case where
-- it loads without calling ClaimMailScanning.
--
-- Confirmed against Aegis: Courier's own core/init.lua, which declares
-- `AegisCourier = {}`. NOT "Aegis_Courier" -- that is the addon folder and
-- .toc name, and is never a global. The explicit claim above is the contract;
-- this is only a safety net for a Courier that never got round to claiming.
local COURIER_GLOBAL = "AegisCourier"

-- Is something else responsible for reading the mailbox?
function A.MailScanningExternal()
    if A.mailScanOwner then return true end
    return type(getglobal(COURIER_GLOBAL)) == "table"
end

-- Income / spend / count over transactions at or after `sinceEpoch` (nil = all).
function db.LedgerTotals(sinceEpoch)
    local income, spend, n = 0, 0, 0
    local led = db.Ledger()
    local i = 1
    while i <= table.getn(led) do
        local e = led[i]
        if not sinceEpoch or (e.t and e.t >= sinceEpoch) then
            if e.kind == "sale" then income = income + (e.amount or 0)
            elseif e.kind == "buy" then spend = spend + (e.amount or 0) end
            n = n + 1
        end
        i = i + 1
    end
    return income, spend, n
end

function db.ClearLedger()
    if not db.account then return end
    db.account.ledger = {}
    db.account.ledgerSeen = {}
end

-- ---- vendor marks (items flagged to sell at a merchant) -----------------

function db.IsVendorMarked(itemId)
    if not db.account or not itemId then return false end
    local m = db.account.vendorMarks
    return (m and m[itemId]) and true or false
end

function db.SetVendorMark(itemId, on)
    if not db.account or not itemId then return end
    if not db.account.vendorMarks then db.account.vendorMarks = {} end
    if on then
        db.account.vendorMarks[itemId] = true
    else
        db.account.vendorMarks[itemId] = nil
    end
end

function db.ClearVendorMarks()
    if not db.account then return end
    db.account.vendorMarks = {}
end

-- What this item has actually SOLD for (from the mailbox ledger, matched by
-- name since AH sale mails carry no item link). Returns (median, count, last)
-- of the whole-mail amounts, or nil when we've never sold it.
function db.SaleHistory(itemName)
    if not itemName then return nil, 0 end
    local amounts, last = {}, nil
    local led = db.Ledger()
    local i = 1
    while i <= table.getn(led) do
        local e = led[i]
        if e.kind == "sale" and e.item == itemName and e.amount then
            table.insert(amounts, e.amount)
            last = e.amount           -- ledger is chronological; keep the newest
        end
        i = i + 1
    end
    local n = table.getn(amounts)
    if n == 0 then return nil, 0 end
    table.sort(amounts)
    local median
    if math.mod(n, 2) == 1 then
        median = amounts[(n + 1) / 2]
    else
        median = math.floor((amounts[n / 2] + amounts[n / 2 + 1]) / 2)
    end
    return median, n, last
end

-- Spread of an item's recorded daily minimum buyouts: (days, low, high).
-- Pairs with db.MarketValue (the time-weighted median) on the Sell tab.
function db.PriceSpread(itemId)
    if not db.account or not itemId then return 0 end
    local items = db.Items()
    local rec = items and items[itemId]
    if not rec then return 0 end
    local days, low, high = 0, nil, nil
    for _, v in pairs(rec.daily) do
        days = days + 1
        if not low or v < low then low = v end
        if not high or v > high then high = v end
    end
    return days, low, high
end

-- Number of distinct items with recorded price data ON THIS REALM.
function db.ItemCount()
    if not db.account then return 0 end
    local items = db.Items()
    if not items then return 0 end
    local n = 0
    for _ in pairs(items) do
        n = n + 1
    end
    return n
end

-- Per-character record of the last completed full scan.
-- ---------------------------------------------------------------------------
-- The item-fact harvest
-- ---------------------------------------------------------------------------
--
-- WHAT THIS IS FOR. Answering "what does this disenchant into" needs an item's
-- quality, equip slot and required level. On 1.12 the only source is
-- GetItemInfo, which answers ONLY for items already in the client's local
-- cache -- so the disenchant line, and the disenchant search filters, go blank
-- for every auction row whose item the client has not happened to see.
--
-- The client's cache is also not ours: it is evicted, it varies by machine, and
-- a fresh install starts empty. Copying what it knows into SavedVariables as we
-- go turns coverage from a snapshot into a curve that only ever grows.
--
-- WHY THE SWEEP IS SAFE, which is the part worth reading before editing it.
-- GetItemInfo for an item the client has NOT cached returns nil and does
-- nothing else -- it does not ask the server. The call that DOES force a fetch
-- is a tooltip SetHyperlink, which is why aux, whose design this follows, uses
-- GetItemInfo as the probe and SetHyperlink only in a separate, explicit,
-- opt-in command. We do not have that command and are not adding one: a sweep
-- that fetches would be thousands of server round trips.
--
-- (An earlier release of this addon asserted the opposite -- that GetItemInfo
-- queries the server -- and shipped a throttle for it. That was wrong, and the
-- correction matters here more than anywhere: it is the difference between
-- this sweep being free and being unshippable.)

-- The top of the id range. Vanilla stops near 25000; Turtle's custom items run
-- far higher, so a vanilla-sized bound would skip exactly the items nothing
-- else can answer for.
db.HARVEST_MAX_ID = 120000

-- Ids examined per step. Paced on ids EXAMINED, not ids recorded -- aux paces
-- on recorded, which means a cold cache walks its whole range in one frame.
db.HARVEST_BUDGET = 500

-- What we keep, and nothing else: three fields that answer the disenchant
-- question. Names, textures and stack sizes have their own tables already.
function db.SetItemFacts(itemId, quality, minLevel, equipLoc)
    if not db.account or not itemId then return end
    if not db.account.facts then db.account.facts = {} end
    -- equipLoc "" is meaningful (a trade good), quality 0 is meaningful (grey).
    -- Only a missing quality makes the record useless.
    if type(quality) ~= "number" then return end
    db.account.facts[itemId] = {
        q = quality,
        r = (type(minLevel) == "number") and minLevel or 0,
        e = equipLoc or "",
    }
end

function db.ItemFacts(itemId)
    if not db.account or not db.account.facts or not itemId then return nil end
    return db.account.facts[itemId]
end

function db.HarvestCount()
    if not db.account or not db.account.facts then return 0 end
    return A.util.CountKeys(db.account.facts)
end

-- Examine `budget` ids starting at `fromId`, recording whatever the client
-- already knows. Returns the next id to resume from and how many were recorded.
--
-- Split out from the driver so the pacing arithmetic is testable without a
-- frame: "does it stop at the budget", "does it resume where it left off",
-- "does it skip what it already has" are all questions about this function.
function db.HarvestStep(fromId, budget)
    local id = fromId or 1
    budget = budget or db.HARVEST_BUDGET
    local recorded, examined = 0, 0
    while examined < budget and id <= db.HARVEST_MAX_ID do
        if not db.ItemFacts(id) then
            -- The bare id, not a link: GetItemInfo takes either, and an id
            -- cannot be mis-formatted. nil here means "the client has never
            -- seen this item", which is the common case and costs nothing.
            local info = A.util.ItemInfo(id)
            if info and type(info.quality) == "number" then
                db.SetItemFacts(id, info.quality, info.minLevel, info.equipLoc)
                recorded = recorded + 1
            end
        end
        examined = examined + 1
        id = id + 1
    end
    if id > db.HARVEST_MAX_ID then return nil, recorded end
    return id, recorded
end

function db.SetLastScan(pages, auctions, full)
    if not db.char then return end
    db.char.lastScan = {
        when = time(), pages = pages, auctions = auctions, full = full,
    }
end

function db.GetLastScan()
    return db.char and db.char.lastScan
end

-- The driver. One frame, one accumulator, and it stops for good when the sweep
-- reaches the top of the range -- so the steady state is a hidden frame with no
-- OnUpdate, not a permanent tick.
--
-- Deliberately NOT started from db.Init: a fresh login has plenty else to do,
-- and the harvest is the least urgent thing in the addon. It waits.
local harvester = CreateFrame("Frame", "AegisExchangeHarvester")
harvester:Hide()
db.harvestAt = 1

local HARVEST_DELAY = 0.5

harvester:SetScript("OnUpdate", function()
    harvester.accum = (harvester.accum or 0) + arg1
    if harvester.accum < HARVEST_DELAY then return end
    harvester.accum = 0
    local nextId = db.HarvestStep(db.harvestAt, db.HARVEST_BUDGET)
    if not nextId then
        db.harvestAt = nil
        harvester:Hide()
        harvester:SetScript("OnUpdate", nil)
        return
    end
    db.harvestAt = nextId
end)

-- Begin (or resume) the sweep. Idempotent.
function db.StartHarvest()
    if not db.harvestAt then return false end
    -- A NEGATIVE accumulator is the initial delay. Login is the busiest the
    -- client ever is, and this is the least urgent thing in the addon, so the
    -- first step lands about six seconds in rather than half a second.
    harvester.accum = -5
    harvester:Show()
    return true
end

function db.StopHarvest()
    harvester:Hide()
end

function db.HarvestRunning()
    return harvester:IsShown() and true or false
end

-- Register the bootstrap with the load queue.
A.OnLoad(db.Init)

-- ...and the harvest after it, so db.account exists before the first step.
A.OnLoad(function() db.StartHarvest() end)
