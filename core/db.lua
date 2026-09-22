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
        -- What a merchant CHARGES for an item, per unit, learned by scanning
        -- merchant inventories. A different fact from `vendors` above, which is
        -- what a merchant PAYS -- the two are never the same number and must
        -- never share a table. `l` records limited stock; see db.MergeVendorBuy
        -- for why that flag outranks the price itself.
        vendorBuy = {}, -- itemID   -> { p = unit copper, l = 1 when limited }
        -- Deposit calibration. Both entries are MEASURED, which is the whole
        -- point of them: `ratio` is our formula against the client's own
        -- CalculateAuctionDeposit, `charge` is the client's figure against the
        -- money that actually left the bags. See core/sell.lua.
        deposit = {},   -- { ratio, ratioN, charge, chargeN }
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
    -- THE ITEM-FACT SWEEP, AND IT IS OFF.
    --
    -- It walked ids 1..120000 asking the client about each one. On 1.12 a
    -- cache miss is not free -- it puts an item query on the wire, and the
    -- server answers with GET_ITEM_INFO_RECEIVED. A probe on a real client
    -- caught that event arriving ~25 times a SECOND, continuously, and a Lua
    -- heap of 222 MB climbing ~9 MB over the sample.
    --
    -- 1.12 IS A 32-BIT PROCESS. Every answer also grows the client's own item
    -- cache, which is C-side and therefore invisible to gcinfo() -- so the
    -- measured Lua figure is the SMALLER half of the cost. A steady climb
    -- toward the address-space ceiling is a crash to desktop, and it is a
    -- climb rather than a spike, which is why nothing showed in Task Manager.
    --
    -- The addon already learns item facts OPPORTUNISTICALLY -- from bags, from
    -- browsing, from any successful lookup -- and that path costs nothing
    -- because the client had the data anyway. The sweep only ever bought us
    -- facts about items the player has never seen and may never see.
    --
    -- Off by default. `/aex sweep on` for anyone who wants it back.
    harvest        = false,
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
    tipVendor      = true,      -- "Sell to Vendor" (what a merchant PAYS)
    tipVendorBuy   = true,      -- "Buy from Vendor" (what a merchant CHARGES)
    -- "Inventory": how many you own and where, per character. The longest
    -- block on the tooltip, so it gets its own switch like every other line.
    tipInventory   = true,
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
    -- Pop the shopping list up when you open a merchant.
    --
    -- The list is only useful where you can ACT on it, and a vendor is one of
    -- the two places that is true (the auction house being the other, where
    -- the Crafting tab already has it). On by default because a player who
    -- tracked a recipe has already said they intend to buy its reagents.
    shopAtMerchant = true,
    -- "Display on Character": clicking a result tries it on, the way the
    -- stock auction house does. OFF by default, because it opens a window
    -- over the game world and a feature that does that uninvited is one
    -- people turn off rather than find.
    dressUpOnClick = false,
    -- Keep paging when a post-filter empties a page, instead of showing a
    -- blank one and waiting to be clicked.
    --
    -- ON by default, because the alternative is what shipped and it reads as a
    -- broken search: the server picks the page order, so a rare match --
    -- anything found by /vendor-profit, /tooltip or a price cap -- lands
    -- wherever it lands, and page 0 is just the first 50 rows the server had,
    -- not the 50 most interesting. See the sweep block in core/buy.lua.
    sweepEmptyPages = true,
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

-- ---------------------------------------------------------------------------
-- The posting book: what this character put up, so a sale can say how many
--
-- WHY THIS EXISTS. A sale's quantity cannot be read from the mailbox. It is
-- not in the invoice (GetInboxInvoiceInfo returns a name and prices, no stack
-- size), not in the subject line, and a sold auction's mail has no attachment
-- to count -- the buyer got the items. The only place the number ever exists
-- is the moment we posted it.
--
-- PER CHARACTER, because that is who posted and who the mail comes to. The
-- ledger is account-wide; this is not.
--
-- THE MATCH IS BY NAME, NOT BY IDENTITY. There is no auction id on 1.12, so
-- "which of my three stacks sold" is unanswerable -- and it is also the wrong
-- question. If every outstanding posting of an item is the same size, that
-- size is the answer whichever one sold. If they are NOT all the same size,
-- the honest answer is that we do not know, and db.RecordTxn already treats
-- absent as unknown rather than as one. Same reasoning as the batch buyout's
-- fingerprints: identity is unobtainable and a multiset is sufficient.
-- ---------------------------------------------------------------------------

-- 72h is the longest auction Turtle allows, and mail then sits for up to 30
-- days. A posting older than the two together cannot still be waiting on a
-- sale mail, so it is a leak rather than a record.
db.POSTED_KEEP = 33 * 86400
-- ...and a cap, because "one per posted stack" is unbounded for a player who
-- posts all day and never opens their mail.
db.POSTED_MAX  = 500

function db.Postings()
    if not db.char then return {} end
    if not db.char.posted then db.char.posted = {} end
    return db.char.posted
end

-- Drop postings too old to be waiting on anything, and trim to the cap.
-- OLDEST FIRST on the trim: the newest are the ones a sale is most likely to
-- be about.
function db.PrunePostings(now)
    now = now or time()
    local book = db.Postings()
    local i = 1
    while i <= table.getn(book) do
        local p = book[i]
        if not p.t or (now - p.t) > db.POSTED_KEEP then
            table.remove(book, i)
        else
            i = i + 1
        end
    end
    while table.getn(book) > db.POSTED_MAX do
        table.remove(book, 1)
    end
end

-- Remember that `qty` of `name` went up for auction.
function db.RecordPosting(name, itemId, qty, now)
    if not db.char or not name or name == "" then return false end
    local n = tonumber(qty)
    if not n or n < 1 then return false end
    local book = db.Postings()
    table.insert(book, { name = name, id = itemId, qty = math.floor(n),
                         t = now or time() })
    db.PrunePostings(now)
    return true
end

-- How many were in the stack that just sold, or nil when we cannot say.
--
-- CONSUMES ONE POSTING on a confident answer and NONE otherwise. Consuming on
-- an ambiguous match would be picking a stack size at random and then throwing
-- away the evidence that we had guessed.
function db.MatchPosting(name, now)
    if not db.char or not name then return nil end
    db.PrunePostings(now)
    local book = db.Postings()
    local firstAt, qty, mixed = nil, nil, false
    local i = 1
    while i <= table.getn(book) do
        local p = book[i]
        if p.name == name then
            if not firstAt then firstAt = i end
            if qty == nil then qty = p.qty
            elseif p.qty ~= qty then mixed = true end
        end
        i = i + 1
    end
    if not firstAt or mixed then return nil end
    table.remove(book, firstAt)
    return qty
end

-- An auction that came BACK unsold is not waiting on a sale mail either, and
-- leaving it in the book is what turns a book of one stack size into a mixed
-- one -- which costs the NEXT sale its quantity. Same consume rule: only on an
-- unambiguous match.
function db.ExpirePosting(name, now)
    return db.MatchPosting(name, now)
end

-- ---------------------------------------------------------------------------
-- The book, reconciled against what the SERVER says is up
-- ---------------------------------------------------------------------------
--
-- WHY THE BOOK ALONE IS NOT ENOUGH. db.RecordPosting only knows about stacks
-- it watched go up. A stack posted before this character's book existed, or
-- from the stock UI, or through any path this addon did not drive, is invisible
-- to it -- and every one of those sales lands in the ledger with an unknown
-- quantity, which is exactly how it was reported: "sold a Silverleaf and it
-- doesn't populate any data". The owner sweep already walks every page of your
-- own auctions on every AH visit, so the server's own answer to "what is up,
-- and in what stack sizes" is already in hand. This folds it in.
--
-- ADDITIVE, NEVER SUBTRACTIVE, and that is the whole design. A stack that sold
-- ten minutes ago is already gone from the server's list while its sale mail
-- sits unread in the mailbox; dropping the book entry the sweep can no longer
-- see would cost that sale the quantity it was about to claim -- turning a
-- feature that works into one that breaks whenever you check the AH before the
-- mailbox. Entries leave the book exactly two ways: consumed by a sale or an
-- expiry, or dropped by age.
--
-- TOPS UP TO A COUNT rather than appending, because this runs on every single
-- AH visit. Three stacks of five up and three already in the book is nothing to
-- do; a naive append would make it six, then nine, then a book whose entries
-- outnumber the auctions they stand for -- and since every one of those is the
-- same size, MatchPosting would happily keep answering "five" long after the
-- last one sold.

-- Fold a list of { name = , qty = } into counts[name][qty] = howMany.
-- Shared by both sides of the reconcile so the two are counted the same way.
function db.PostingTally(list)
    local t = {}
    local i = 1
    while i <= table.getn(list or {}) do
        local e = list[i]
        local n = e and e.name
        local q = tonumber(e and e.qty)
        if n and n ~= "" and q and q >= 1 then
            q = math.floor(q)
            if not t[n] then t[n] = {} end
            t[n][q] = (t[n][q] or 0) + 1
        end
        i = i + 1
    end
    return t
end

-- `stacks` is one entry per auction currently UP: { name = , id = , qty = }.
-- Returns how many entries were added, which is 0 on the common visit where
-- the book already agrees with the server.
function db.ReconcilePostings(stacks, now)
    if not db.char then return 0 end
    now = now or time()
    local want = db.PostingTally(stacks)
    local have = db.PostingTally(db.Postings())
    -- An id per name, so a topped-up entry carries what the sweep knew. The
    -- name is what a sale mail matches on, so a row the client could not
    -- identify is still worth recording -- it just records without an id.
    local ids = {}
    local i = 1
    while i <= table.getn(stacks or {}) do
        local e = stacks[i]
        if e and e.name and e.id and not ids[e.name] then ids[e.name] = e.id end
        i = i + 1
    end
    local added = 0
    for name, sizes in pairs(want) do
        local mine = have[name] or {}
        for qty, n in pairs(sizes) do
            local short = n - (mine[qty] or 0)
            local k = 1
            while k <= short do
                if db.RecordPosting(name, ids[name], qty, now) then
                    added = added + 1
                end
                k = k + 1
            end
        end
    end
    return added
end

-- Default shape of the per-character DB.
local function DefaultCharDB()
    return {
        version  = DB_VERSION,
        ui       = {},    -- window position, open tab, column widths, ...
        lastScan = nil,   -- { when = epoch, pages = n, auctions = n }
        -- What this character has up for auction, so a sale mail can say how
        -- many were in the stack -- the mailbox cannot. See db.RecordPosting.
        posted   = {},
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

-- ---------------------------------------------------------------------------
-- Inventory: how many of an item you own, and where
-- ---------------------------------------------------------------------------

-- The four places an item can be. Ordered, because the tooltip prints them in
-- this order and a second list of the same four is how they drift apart.
db.INVENTORY_BUCKETS = { "bags", "bank", "ah", "mail" }

-- The current realm's per-character inventory, created on demand.
--
-- REALM-SCOPED, which is the opposite of vendor prices and deliberately so. A
-- vendor's price is a fact about the game and is the same everywhere; twenty
-- Silk Cloth on a character you cannot reach from here is not stock you have,
-- it is stock somebody else has. Same accessor discipline as db.Items -- the
-- realm split lives in one place.
function db.Inventories()
    if not db.account then return nil end
    local realms = db.account.realms
    if not realms then realms = {}; db.account.realms = realms end
    local key = db.realmKey or db.RealmKey()
    local bucket = realms[key]
    if not bucket then bucket = {}; realms[key] = bucket end
    if not bucket.inventory then bucket.inventory = {} end
    return bucket.inventory
end

function db.CharKey()
    local name = UnitName and UnitName("player") or nil
    if not name or name == "" then return nil end
    return name
end

-- Record one bucket for the CURRENT character, with the moment it was read.
--
-- The timestamp is the point. Only bags can be read on demand; bank, auctions
-- and mail are readable exactly while you are standing at them, so every one
-- of those numbers is a memory of a visit and has to carry its age. See
-- tooltip.Extend, which says so on screen rather than in a settings tooltip
-- nobody opens.
--
-- The CLASS token is stored beside them because nothing on 1.12 can ask what
-- class an offline character is. It is one string, written whenever that
-- character plays, and it is the only way the tooltip can colour a name.
function db.SetInventoryBucket(bucket, counts, class)
    local inv = db.Inventories()
    local who = db.CharKey()
    if not inv or not who or not bucket then return nil end
    local rec = inv[who]
    if not rec then rec = { t = {} }; inv[who] = rec end
    if not rec.t then rec.t = {} end
    rec[bucket] = counts or {}
    rec.t[bucket] = time()
    if class and class ~= "" then rec.class = class end
    return rec
end

-- Does this answer cover ONLY the character you are on?
--
-- A character is left out of the block entirely when it holds none of the item
-- -- which is right, and which makes "no other character has ever been seen"
-- indistinguishable from "no other character has any". The first of those
-- deserves a word on screen, because it is the state a fresh install is in for
-- every alt, and without it the whole account-wide feature reads as broken.
--
-- Pure: rows in, boolean out.
function db.InventoryOnlyYou(rows)
    local n = table.getn(rows or {})
    if n ~= 1 then return false end
    return rows[1].you and true or false
end

-- How many of `itemId` each character on this realm holds, and where.
--
-- Returns rows, total. Each row is
--   { name, class, you, bags, bank, ah, mail, total, oldest }
-- where `you` marks the character you are logged in as and `oldest` is the
-- age in seconds of the stalest bucket that actually contributed a count --
-- so a row whose whole answer came from a two-day-old bank snapshot can say
-- so, and one that is all live bags does not have to.
--
-- `liveBags` (optional) is the current character's bag counts read just now.
-- Passing them in rather than reading containers here keeps this file free of
-- container code -- and bags are the ONE bucket that can be exact, so the
-- caller that can be exact supplies them.
--
-- Characters holding none of the item are left out entirely. A tooltip listing
-- every alt you have ever logged in on, most of them saying zero, is a worse
-- answer than a short list.
function db.InventoryRows(itemId, liveBags)
    local rows, total = {}, 0
    local inv = db.account and db.Inventories()
    if not itemId or not inv then return rows, total end
    local me = db.CharKey()
    local now = time()
    -- The character you are ON gets a row whether or not anything has ever
    -- been STORED for them.
    --
    -- Without this, a player who has not opened a bank since installing the
    -- addon has no record at all, so the loop below finds nobody and their own
    -- bags -- the one bucket that is exact and always available -- are
    -- invisible. That is the common case on a fresh install, and it presents
    -- as the block never appearing.
    local seed = inv
    if me and liveBags and (liveBags[itemId] or 0) > 0 and not inv[me] then
        seed = { [me] = { t = {} } }
        for who, rec in pairs(inv) do seed[who] = rec end
    end
    for who, rec in pairs(seed) do
        local row = { name = who, class = rec.class, you = (who == me),
                      total = 0 }
        local oldest = nil
        local i = 1
        while i <= table.getn(db.INVENTORY_BUCKETS) do
            local b = db.INVENTORY_BUCKETS[i]
            local n
            if b == "bags" and who == me and liveBags then
                n = liveBags[itemId]        -- exact, read a moment ago
            else
                n = rec[b] and rec[b][itemId]
                if n and n > 0 then
                    local when = rec.t and rec.t[b]
                    local age = when and (now - when) or nil
                    if age and (not oldest or age > oldest) then oldest = age end
                end
            end
            n = n or 0
            row[b] = n
            row.total = row.total + n
            i = i + 1
        end
        row.oldest = oldest
        if row.total > 0 then
            table.insert(rows, row)
            total = total + row.total
        end
    end
    -- You first, then the biggest holdings. Your own row is the one you are
    -- acting on; the rest are context for it.
    table.sort(rows, function(a, b)
        if a.you ~= b.you then return a.you end
        if a.total ~= b.total then return a.total > b.total end
        return (a.name or "") < (b.name or "")
    end)
    return rows, total
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

-- How many auctions we have ever recorded for this item.
--
-- Sightings, not days: this is the "seen 18 times at auction total" figure, and
-- it answers a different question from db.DayCount. One busy afternoon and a
-- month of quiet trading can produce the same day count and wildly different
-- sighting counts, and it is the sighting count a reader reads as confidence.
function db.SeenCount(itemId)
    if not db.account then return 0 end
    local items = db.Items()
    local rec = items and items[itemId]
    return (rec and rec.seen) or 0
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

-- What a listing is worth buying and selling straight to a merchant.
--
-- Returns (perUnit, total), or nil when there is no profit in it.
--
-- NO CUT ON EITHER SIDE, and that is worth stating because almost every other
-- money figure in this addon carries one: the 5% consignment cut is taken from
-- a SALE at the auction house. Buying costs the buyout and a vendor pays its
-- price, so the margin here is the whole difference.
--
-- BOTH FIGURES PER UNIT, which is the only comparison that means anything
-- across different stack sizes -- and the total is then the per-unit margin
-- times the stack, because you have to buy the whole stack to get it.
--
-- Zero is not a margin. An item a vendor pays exactly the buyout for is a
-- wash, and listing it would be telling somebody to spend gold to stand still.
function db.VendorFlip(unitBuyout, vendorUnit, count)
    if not unitBuyout or unitBuyout <= 0 then return nil end
    if not vendorUnit or vendorUnit <= 0 then return nil end
    local per = vendorUnit - unitBuyout
    if per <= 0 then return nil end
    local n = count or 1
    if n < 1 then n = 1 end
    return per, per * n
end

-- ---------------------------------------------------------------------------
-- Vendor BUY prices -- what a merchant CHARGES
-- ---------------------------------------------------------------------------

-- The merge rule, as a PURE function, so it can be tested without a DB and so
-- there is exactly one statement of it.
--
-- The rule is aux's, and the interesting half is that LIMITED STOCK OUTRANKS
-- PRICE. A vendor selling three Elixirs of Fortitude for 40s each is not a
-- source of Elixirs of Fortitude; a vendor selling them forever at 60s is. So
-- an unlimited price replaces a limited one even when it is dearer, and only
-- once both readings agree about availability does the cheaper win.
--
-- "Limited" is `stock >= 0` from GetMerchantItemInfo's 5th return, which is
-- backwards from how it reads: the client uses -1 for "unlimited", so any
-- number at all -- including 0, a vendor sold out right now -- means the
-- supply is finite.
--
-- Returns the winning (copper, limited).
function db.MergeVendorBuy(oldCopper, oldLimited, newCopper, newLimited)
    if not oldCopper or oldCopper <= 0 then return newCopper, newLimited end
    if not newCopper or newCopper <= 0 then return oldCopper, oldLimited end
    if oldLimited and not newLimited then return newCopper, newLimited end
    if newLimited and not oldLimited then return oldCopper, oldLimited end
    if newCopper < oldCopper then return newCopper, newLimited end
    return oldCopper, oldLimited
end

-- Record a merchant's asking price, per unit. Account-wide for the same reason
-- as the sell price: what an NPC charges is a property of the game, not of the
-- realm you happened to see it on.
function db.SetVendorBuy(itemId, copper, limited)
    if not db.account then return end
    if not itemId or not copper or copper <= 0 then return end
    if not db.account.vendorBuy then db.account.vendorBuy = {} end
    local rec = db.account.vendorBuy[itemId]
    local price, lim = db.MergeVendorBuy(rec and rec.p, rec and rec.l == 1,
        copper, limited)
    db.account.vendorBuy[itemId] = { p = price, l = lim and 1 or nil }
end

-- What a merchant charges for one of these, and whether the stock was limited.
-- Returns copper, limited -- or nil.
function db.GetVendorBuy(itemId)
    if not db.account or not db.account.vendorBuy or not itemId then
        return nil
    end
    local rec = db.account.vendorBuy[itemId]
    if not rec or not rec.p then return nil end
    return rec.p, rec.l == 1
end

-- How many items we have a merchant asking price for. For /aex diag, so
-- "the line never shows" can be told apart from "no merchant has been opened".
function db.VendorBuyCount()
    if not db.account or not db.account.vendorBuy then return 0 end
    local n = 0
    for _ in pairs(db.account.vendorBuy) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Deposit calibration
-- ---------------------------------------------------------------------------

-- How many readings a learned ratio averages over. Capped so an early sample
-- stops dominating, and so a single odd one can never take the number over.
local RATIO_SAMPLES_MAX = 20

local function RecordRatio(rec, meanKey, countKey, value)
    if not value then return nil end
    local n = (rec[countKey] or 0) + 1
    if n > RATIO_SAMPLES_MAX then n = RATIO_SAMPLES_MAX end
    local old = rec[meanKey]
    if old == nil then
        rec[meanKey] = value
    else
        rec[meanKey] = old + (value - old) / n
    end
    rec[countKey] = n
    return rec[meanKey], n
end

local function DepositRec()
    if not db.account then return nil end
    if not db.account.deposit then db.account.deposit = {} end
    return db.account.deposit
end

-- Our formula's answer against the client's own, for the same item and
-- duration. See sell.DepositRatio for where the number comes from.
function db.RecordDepositRatio(ratio)
    local rec = DepositRec()
    if not rec then return nil end
    return RecordRatio(rec, "ratio", "ratioN", ratio)
end

function db.DepositRatio()
    local rec = db.account and db.account.deposit
    if not rec or not rec.ratio then return nil end
    return rec.ratio, rec.ratioN or 0
end

-- The client's figure against what actually left the bags when a post went
-- through. This is the only measurement in the addon of what the SERVER
-- charges, which is what sell.TURTLE_DEPOSIT_FACTOR had been guessing at.
function db.RecordDepositCharge(ratio)
    local rec = DepositRec()
    if not rec then return nil end
    return RecordRatio(rec, "charge", "chargeN", ratio)
end

function db.DepositCharge()
    local rec = db.account and db.account.deposit
    if not rec or not rec.charge then return nil end
    return rec.charge, rec.chargeN or 0
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
--
-- STAMPED WITH THE CHARACTER, so the History chart can break the ledger down
-- by who earned and who spent. `who` is the character the entry was recorded
-- on, not the one that posted the auction -- a sale arrives as mail wherever
-- you happen to be standing, and pretending otherwise would attribute it to
-- whoever opened the mailbox anyway.
--
-- ENTRIES WRITTEN BEFORE v1.53.7 HAVE NO `who` AT ALL, and there is no way to
-- recover it. Every reader has to treat a missing one as unknown rather than
-- as any particular character; see db.LedgerByChar.
function db.RecordTxn(kind, item, amount, itemId, qty)
    if not db.account then return end
    if not amount or amount <= 0 then return end
    local led = db.account.ledger
    if not led then led = {}; db.account.ledger = led end
    -- QUANTITY IS OPTIONAL AND ABSENT MEANS UNKNOWN, NEVER ONE. Every entry
    -- written before v1.54.6 has none, and so does every sale logged from
    -- mail -- the 1.12 inbox does not say how many were in the stack. A reader
    -- that substitutes 1 turns "I do not know" into a number it can average,
    -- which is the Ledger table's whole failure mode (ROADMAP 3.4). Same rule
    -- `who` already carries; see db.LedgerByChar.
    --
    -- Stored only when it is a sane positive count, so a nil, a zero or a
    -- string cannot become a divisor later.
    local n = tonumber(qty)
    if n and n > 0 then n = math.floor(n) else n = nil end
    table.insert(led, { t = time(), kind = kind, item = item or "?",
        amount = amount, id = itemId, qty = n, who = db.CharKey() })
    -- Prune oldest beyond the cap.
    while table.getn(led) > LEDGER_MAX do
        table.remove(led, 1)
    end
end

function db.Ledger()
    return (db.account and db.account.ledger) or {}
end

-- Where ledger READS come from.
--
-- db.Ledger is the STORE and stays the write target; this is the seam demo
-- mode substitutes at. Keeping the two apart is what makes it impossible for
-- generated trading to reach a player's SavedVariables -- a transaction logged
-- while the demo is on still lands in the real ledger, and nothing invented
-- ever leaves this function. Same arrangement db.PurseRows has with
-- db.DemoRows, and the reason is the same one: a substitute READER cannot
-- write, and a seeded writer permanently could.
function db.LedgerSource()
    if db.demo then return db.DemoLedger() end
    return db.Ledger()
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
-- What every character on this realm is carrying in COIN
-- ---------------------------------------------------------------------------
--
-- 1.12 HAS ONE MONEY CALL AND IT ANSWERS FOR YOU. `GetMoney()` is the
-- character you are logged in as, and there is nothing that will tell you what
-- an alt has. So an account total is necessarily a sum of REMEMBERED figures,
-- each as fresh as the last time that character played, and it has to say so
-- rather than present itself as a live balance.
--
-- This is the same shape Bagshui uses on this client (Components/Character.lua
-- -> `Character:UpdateMoney`, stored per character in SavedVariables and
-- totalled in Catalog.lua as though coin were one more item): read GetMoney on
-- the money events, write it against the character, sum across characters when
-- asked. We differ in two deliberate ways.
--
--   * REALM-SCOPED, like db.Inventories and unlike Bagshui's catalog. Gold on a
--     character you cannot reach from here is not gold you can spend here, and
--     the same argument already settled the inventory block.
--   * WE KEEP A HISTORY, not just the current figure. Bagshui only needs "how
--     much does this character have"; the History chart needs "how much did the
--     account have last Tuesday", and that cannot be recovered from a single
--     number per character.
--
-- The history is one sample per HOUR per character -- the resolution the 24h
-- chart wants, and coarse enough that a day of trading is 24 numbers rather
-- than one per transaction. A second change inside the same hour overwrites
-- that hour rather than appending.
-- TWO RESOLUTIONS IN ONE TABLE, which is how a 3-month chart costs the same
-- SavedVariables as the old 33-day one.
--
-- Every sample starts as an hourly one. Once it falls outside the fine window
-- it is COMPACTED: all but the last sample of each day is dropped, and the
-- survivor is that day's closing figure -- which is exactly the right one to
-- keep, because db.MoneySeries carries the last known figure forward anyway.
--
-- The arithmetic: 96 hourly samples covers four days at full detail, and the
-- remaining ~800 daily ones reach back about two years. Hourly for two years
-- would have been 17,000 numbers per character, written out as Lua source on
-- every logout.
db.MONEY_FINE_HOURS  = 96     -- keep every hour for this long
db.MONEY_SAMPLES_MAX = 900    -- total samples per character, both resolutions

-- The hour a timestamp falls in. The bucket key, and the whole reason the
-- history does not grow with the number of transactions.
function db.MoneyHour(t)
    return math.floor((t or 0) / 3600)
end

-- The day an HOUR key falls in. Compaction keys off this.
function db.MoneyDayOf(hour)
    return math.floor((hour or 0) / 24)
end

-- Thin the history: full detail inside the fine window, one closing figure a
-- day outside it, and the oldest dropped if it is still over the cap.
--
-- Returns the number of samples dropped, so a test can see it did something
-- rather than only that the result is small enough.
--
-- IT KEEPS THE LAST SAMPLE OF EACH DAY, not the first. The series reader
-- carries the last known figure forward, so a day is represented by what you
-- went to bed with -- keeping the first would report the morning's figure for
-- the whole of the following day.
--
-- Called only when the cap is exceeded, so its walk is amortised across
-- hundreds of writes and the PLAYER_MONEY handler stays O(1).
function db.CompactMoney(rec, now)
    if not rec or not rec.keys or not rec.hours then return 0 end
    local cutoff = db.MoneyHour(now or time()) - db.MONEY_FINE_HOURS
    local keep, dropped = {}, 0
    local n = table.getn(rec.keys)
    local i = 1
    while i <= n do
        local k = rec.keys[i]
        local nxt = rec.keys[i + 1]
        -- Inside the fine window, or the last sample this side of a day
        -- boundary. `nxt` nil means this is the newest sample there is.
        if k > cutoff or not nxt or db.MoneyDayOf(nxt) ~= db.MoneyDayOf(k) then
            table.insert(keep, k)
        else
            rec.hours[k] = nil
            dropped = dropped + 1
        end
        i = i + 1
    end
    -- Still over? Drop from the oldest end, which is the only end where losing
    -- a sample costs nothing anyone is looking at.
    while table.getn(keep) > db.MONEY_SAMPLES_MAX do
        local old = table.remove(keep, 1)
        rec.hours[old] = nil
        dropped = dropped + 1
    end
    rec.keys = keep
    return dropped
end

-- The current realm's per-character coin records, created on demand.
-- Each is { now = copper, t = epoch, hours = { [hourKey] = copper } }.
function db.Purses()
    if not db.account then return nil end
    local realms = db.account.realms
    if not realms then realms = {}; db.account.realms = realms end
    local key = db.realmKey or db.RealmKey()
    local bucket = realms[key]
    if not bucket then bucket = {}; realms[key] = bucket end
    if not bucket.purses then bucket.purses = {} end
    return bucket.purses
end

-- Record what the character you are on is carrying. Returns the record.
--
-- O(1) AND IT HAS TO BE: the caller is a PLAYER_MONEY handler, which fires for
-- every copper the player earns, spends, loots or is mailed. A table write, a
-- compare and at most one array append -- see HARD RULE 16.
function db.SetCharMoney(copper, now)
    local purses = db.Purses()
    local who = db.CharKey()
    if not purses or not who or not copper or copper < 0 then return nil end
    now = now or time()
    local rec = purses[who]
    if not rec then rec = { hours = {}, keys = {} }; purses[who] = rec end
    if not rec.hours then rec.hours = {} end
    if not rec.keys then rec.keys = {} end
    rec.now = copper
    rec.t = now
    local hour = db.MoneyHour(now)
    -- The KEY LIST is what makes the prune bounded. `hours` is keyed by hour,
    -- so it has no order of its own and no length -- finding the oldest would
    -- be a walk of the whole table on every write. The list is append-only and
    -- in order by construction, so the oldest is always its first element.
    if rec.hours[hour] == nil then
        table.insert(rec.keys, hour)
        -- ONLY WHEN OVER THE CAP. Compaction is a walk of the key list, and
        -- this runs from PLAYER_MONEY -- which fires for every copper. Doing
        -- it on every write would be the exact shape HARD RULE 16 forbids;
        -- doing it once every few hundred writes is free.
        if table.getn(rec.keys) > db.MONEY_SAMPLES_MAX then
            db.CompactMoney(rec, now)
        end
    end
    rec.hours[hour] = copper
    return rec
end

-- ---------------------------------------------------------------------------
-- Demo data for the gold chart
-- ---------------------------------------------------------------------------
--
-- WHY THIS EXISTS. The chart needs months of trading to look like anything,
-- and a new character or a fresh install has hours. Judging a layout -- is the
-- gradient banding, do the labels collide, does the line read at this width --
-- against one vertical spike is not judging it at all.
--
-- NOTHING IS EVER WRITTEN. `db.demo` is a SESSION flag and these functions are
-- consulted INSTEAD of the store while it is set, so there is no path by which
-- generated gold reaches a player's SavedVariables -- not by logging out, not
-- by crashing, not by forgetting it was on. A /reload clears it. That is the
-- whole reason this is a substitute reader rather than a seeded writer, which
-- would have been half the code and permanently dangerous.
--
-- DETERMINISTIC, because a chart that redraws differently every frame cannot
-- be looked at. The same window always produces the same shape.
db.DEMO_CHARS = { "Ashvane", "Corvid", "Marrowlight", "Tessaly" }

-- Park-Miller. THE MULTIPLIER IS SMALL ON PURPOSE and it is a named constant
-- so the reason can be checked rather than trusted: Lua 5.0 numbers are
-- doubles, exact only to 2^53, and the usual LCG multipliers (1103515245 and
-- friends) reach ~2.4e18 against a 2^31 modulus. That does not error -- it
-- quietly stops being arithmetic. 2147483647 * 16807 is about 3.6e13,
-- comfortably inside it, and the suite asserts that product directly.
db.DEMO_MOD  = 2147483647
db.DEMO_MULT = 16807

function db.DemoNext(seed)
    return math.mod((seed or 1) * db.DEMO_MULT, db.DEMO_MOD)
end

-- A stable seed for a name. Position-weighted, so two characters whose names
-- are anagrams do not draw the same line.
function db.DemoSeed(name)
    local seed = 7
    local i = 1
    while i <= string.len(name or "") do
        seed = math.mod(seed * 31 + string.byte(name, i) * i, db.DEMO_MOD)
        i = i + 1
    end
    if seed <= 0 then seed = 1 end
    return seed
end

-- The phases a demo purse moves through, and how long one lasts.
--
-- REGIMES, NOT NOISE, and that is the whole difference between this chart and
-- the one it replaced. An independent draw per bucket averages out into a
-- straight line with fuzz on it; a walk that stays in one regime for twenty
-- buckets gives the shape a real purse has -- a long climb, a cliff, a
-- plateau. It is what makes the reference chart worth copying.
db.DEMO_PHASES = {
    { drift =  0.020, noise = 0.010 },   -- grow: the ordinary week
    { drift =  0.070, noise = 0.020 },   -- boom: a good run
    { drift = -0.090, noise = 0.030 },   -- bust: the cliff
    { drift =  0.000, noise = 0.008 },   -- flat: the plateau
}
db.DEMO_PHASE_MIN  = 8     -- shortest a regime lasts, in buckets
db.DEMO_PHASE_SPAN = 26    -- ...and how much longer it can run
-- A purse below this is broke, and earns a wage until it is not.
db.DEMO_POOR = 40000
db.DEMO_WAGE = 9000
-- The one flat cost -- a mount, an epic, a stack of bars.
db.DEMO_BIG_BUY = 400000

-- One character's gold across `n` buckets.
--
-- A RANDOM WALK THAT LOOKS LIKE TRADING: phases of growth, of loss and of
-- nothing much, with noise inside each and an occasional large purchase. A
-- pure upward line would exercise none of the things worth looking at -- the
-- fill's gradient over a varying height, the axis labels at different
-- magnitudes, the hover readout on a slope.
--
-- THE BIG PURCHASE IS A FLAT COST, not a fraction of the purse, and that is
-- deliberate: a fraction can never take you below zero, so the floor
-- underneath would be a guard nothing could reach -- worse than no guard at
-- all. It is the only thing in here that can drive a purse to the floor, which
-- is what makes `if held < 0` a branch the suite actually exercises.
--
-- AND A BROKE PURSE EARNS ITS WAY BACK. Without that, a purse that reaches the
-- floor stays on it: every phase is multiplicative and a percentage of nothing
-- is nothing. That is not a hypothetical -- the version before this one spent
-- five of seven days flat on zero, which is exactly the variety a demo exists
-- to have.
--
-- Never negative: gold held cannot be, and a chart drawn from data its own
-- reader could not produce is testing the wrong thing.
function db.DemoSeries(from, step, n, who)
    local out = {}
    n = n or 0
    local names = db.DEMO_CHARS
    if who then names = { who } end
    local phases = table.getn(db.DEMO_PHASES)
    local ci = 1
    while ci <= table.getn(names) do
        local seed = db.DemoSeed(names[ci])
        -- A different starting purse per character, so the account total is
        -- not four copies of one line.
        local held = 20000 + math.mod(seed, 900000)
        local phase, left = 1, 0
        local b = 1
        while b <= n do
            seed = db.DemoNext(seed)
            local r = seed / db.DEMO_MOD
            if left <= 0 then
                seed = db.DemoNext(seed)
                phase = math.mod(seed, phases) + 1
                left = db.DEMO_PHASE_MIN
                       + math.mod(math.floor(seed / 97), db.DEMO_PHASE_SPAN)
                -- A broke purse does not enter a bust. It has nothing left to
                -- lose and the line would sit on the floor for the length of
                -- the regime.
                if held < db.DEMO_POOR then phase = 1 end
            end
            local ph = db.DEMO_PHASES[phase]
            held = held + held * (ph.drift + (r - 0.5) * ph.noise)
            if r < 0.01 then held = held - db.DEMO_BIG_BUY end
            -- ...and it CAN go below zero, which is why this is here.
            if held < 0 then held = 0 end
            if held < db.DEMO_POOR then held = held + db.DEMO_WAGE end
            left = left - 1
            out[b] = (out[b] or 0) + math.floor(held)
            b = b + 1
        end
        ci = ci + 1
    end
    local i = 1
    while i <= n do out[i] = out[i] or 0; i = i + 1 end
    return out, true
end

-- The demo characters as purse rows, so the picker lists them.
function db.DemoRows()
    local rows, total = {}, 0
    local i = 1
    while i <= table.getn(db.DEMO_CHARS) do
        local name = db.DEMO_CHARS[i]
        local vals = db.DemoSeries(0, 3600, 1, name)
        local copper = vals[1] or 0
        table.insert(rows, { name = name, you = (i == 1), copper = copper,
                             age = (i == 1) and nil or (i * 3600) })
        total = total + copper
        i = i + 1
    end
    return rows, total
end

-- What each character on this realm is carrying, and the total.
--
-- Returns rows, total. Each row is { name, you, copper, age } where `age` is
-- how long ago that figure was read, in seconds, and is nil for the character
-- you are on -- theirs was read this frame.
--
-- `live` (optional) is GetMoney() for the current character, passed in rather
-- than read here so this file stays free of client calls and the caller that
-- can be exact is the one that supplies it. Same arrangement db.InventoryRows
-- has with bags.
function db.PurseRows(live)
    -- CONSULTED INSTEAD OF THE STORE, never merged with it. See db.DemoSeries:
    -- the substitution is what makes it impossible for generated gold to reach
    -- a real save.
    if db.demo then return db.DemoRows() end
    local rows, total = {}, 0
    local purses = db.account and db.Purses()
    if not purses then return rows, total end
    local me = db.CharKey()
    local now = time()
    local seededMe = false
    for who, rec in pairs(purses) do
        local copper, age = rec.now or 0, nil
        if who == me and live then
            copper = live                 -- exact, read a moment ago
            seededMe = true
        elseif rec.t then
            age = now - rec.t
        end
        table.insert(rows, { name = who, you = (who == me), copper = copper,
                             age = age })
        total = total + copper
    end
    -- The character you are ON gets a row whether or not anything has ever been
    -- stored for them -- the fresh-install case, and without this their own
    -- coin, the one figure that is exact, is the one missing from the total.
    if me and live and not seededMe then
        table.insert(rows, { name = me, you = true, copper = live })
        total = total + live
    end
    table.sort(rows, function(a, b)
        if a.you ~= b.you then return a.you end
        return (a.copper or 0) > (b.copper or 0)
    end)
    return rows, total
end

-- The ACCOUNT's coin over time: one figure per bucket, summed across every
-- character on the realm.
--
-- THE SUM IS OF LAST-KNOWN FIGURES, which is the only honest way to build it.
-- At any point on the x axis a character contributes the most recent sample it
-- had taken AT OR BEFORE that moment -- an alt that has not played since Monday
-- holds Monday's figure across the rest of the week, because that is genuinely
-- what is known. A character with no sample before the bucket contributes
-- nothing rather than its later figure: back-filling would draw gold into the
-- past.
--
-- `from` and `step` come from ui.HistBuckets, so the chart's two series line up
-- bucket for bucket. Returns an array of n copper figures.
-- The earliest moment any character's coin was recorded, or nil.
--
-- What "all time" means for the chart: a window starting at the epoch is one
-- flat line jammed against the right-hand edge.
function db.OldestMoney()
    -- Demo mode has to answer this too, or "All" is a window with no span and
    -- the chart the demo exists to show falls back to a day.
    if db.demo then return time() - 180 * 86400 end
    local purses = db.account and db.Purses()
    if not purses then return nil end
    local oldest = nil
    for _, rec in pairs(purses) do
        local k = rec.keys and rec.keys[1]
        if k then
            local t = k * 3600
            if not oldest or t < oldest then oldest = t end
        end
    end
    return oldest
end

-- `who` (optional) narrows it to ONE character. Returns the series and
-- whether anything was found for them at all -- a character with no samples
-- in the window is a real state and deserves to be told apart from one
-- holding nothing.
function db.MoneySeries(from, step, n, who)
    if db.demo then return db.DemoSeries(from, step, n, who) end
    local out, seen = {}, false
    local i = 1
    while i <= (n or 0) do out[i] = 0; i = i + 1 end
    local purses = db.account and db.Purses()
    if not purses or not from or not step or step <= 0 then return out, seen end
    for name, rec in pairs(purses) do
      if not who or name == who then
        local hours, keys = rec.hours, rec.keys
        if hours and keys then
            -- One walk per character, in order, carrying the last figure
            -- forward. A search per bucket would be n x samples.
            --
            -- `held` STARTS AT ZERO AND THAT IS THE ANTI-BACK-FILL RULE. A
            -- character contributes nothing until its first sample has been
            -- passed; seeding it from the earliest known figure instead would
            -- draw gold into the past, showing the account holding money it
            -- had not earned yet. There is no separate "have we seen one"
            -- flag because zero already says it.
            local ki, held = 1, 0
            local nk = table.getn(keys)
            local b = 1
            while b <= n do
                local edge = from + b * step
                while ki <= nk and (keys[ki] * 3600) < edge do
                    local v = hours[keys[ki]]
                    if v then held = v; seen = true end
                    ki = ki + 1
                end
                out[b] = out[b] + held
                b = b + 1
            end
        end
      end
    end
    return out, seen
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
    -- QUANTITY PASSED THROUGH. A.RecordExternalTxn used to drop every field it
    -- did not name, and Courier is the thorough mail reader -- so widening the
    -- ledger without widening this would have left the new field reachable
    -- only from Aegis's own header-only path, which is the one path that
    -- cannot see it. Additive, so an older Courier keeps working unchanged.
    db.RecordTxn(txn.kind, txn.item or "?", txn.amount, txn.itemId, txn.qty)
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
    local led = db.LedgerSource()
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

-- Who is in the ledger, over the window starting at `sinceEpoch`.
--
-- Returns an array of names, sorted, plus whether any entry had no character
-- recorded. The flag is the point: history from before v1.53.7 carries no name
-- and neither does a transaction booked by a companion addon that did not
-- supply one, so a per-character breakdown has to be able to say "and some of
-- this is not attributable" instead of quietly dropping it.
function db.LedgerByChar(sinceEpoch)
    local seen, names, anon = {}, {}, false
    local led = db.LedgerSource()
    local i = 1
    while i <= table.getn(led) do
        local e = led[i]
        if not sinceEpoch or (e.t and e.t >= sinceEpoch) then
            if e.who and e.who ~= "" then
                if not seen[e.who] then
                    seen[e.who] = true
                    table.insert(names, e.who)
                end
            else
                anon = true
            end
        end
        i = i + 1
    end
    table.sort(names)
    return names, anon
end

-- ---------------------------------------------------------------------------
-- The History tab's figures
-- ---------------------------------------------------------------------------

-- The denominator for a per-day average.
--
-- `from` is the window's start (nil for "all time"), `oldest` the earliest
-- entry that actually exists, `now` the present.
--
-- THE SPAN STARTS AT WHICHEVER IS LATER, and that is the whole judgement in
-- this function. A one-year window over three days of history divided by 365
-- is not an average, it is a rounding error wearing a label: the other 362
-- days are not days you earned nothing, they are days the addon was not
-- installed. And an "all time" window has no start of its own, so the data's
-- own beginning is the only honest one available.
--
-- NEVER ZERO. Everything recorded in the last hour is a span of ONE day, not
-- of none -- the caller divides by this, and a chart that errors is worse than
-- one that rounds.
function db.WindowDays(from, oldest, now)
    now = now or time()
    local start = from
    if not start or (oldest and oldest > start) then start = oldest end
    if not start or start > now then return 1 end
    local days = math.floor((now - start) / 86400) + 1
    if days < 1 then return 1 end
    return days
end

-- A per-day average. Separate from the division only because `days` is the
-- interesting half and deserves to be wrong in one place rather than four.
function db.PerDay(total, days)
    if not days or days < 1 then days = 1 end
    return (total or 0) / days
end

-- Everything the History tab's figure row and stat blocks need, in ONE pass.
--
-- Returns a table:
--   income, spend, net          copper over the window
--   saleN, buyN                 how many transactions of each kind
--   days                        the denominator above
--   oldest                      epoch of the earliest entry in the window
--   topSale, topBuy             the biggest SINGLE transaction of each kind,
--                               as { item, itemId, amount }
--   topSaleItem, topBuyItem     the item with the biggest SUMMED amount,
--                               as { item, itemId, total }
--
-- TOP SALE AND TOP ITEM ARE DIFFERENT QUESTIONS and the names have to keep
-- saying so. One is "the best thing that ever happened once"; the other is
-- "what actually earns here". A single 500g sale of a rare and 400 sales of
-- Linen Cloth are the same money and only one of them is a business.
--
-- ITEMS ARE KEYED BY NAME, NOT BY ID, and that is deliberate. The obvious
-- choice -- id where there is one, name otherwise -- SPLITS an item whose
-- history straddles the point where ids started being recorded: the same Linen
-- Cloth arrives as key 2589 from one entry and as "Linen Cloth" from another,
-- and its total lands in two buckets, neither of which reaches the top spot.
-- `item` is set on every entry (db.RecordTxn defaults it to "?"), `id` is not,
-- so the name is the only key every row can offer. The id is carried alongside
-- ---------------------------------------------------------------------------
-- The demo LEDGER
-- ---------------------------------------------------------------------------
--
-- WHY THIS REPLACED A SECOND SET OF FIGURES. The History tab used to invent
-- its stats directly -- an income, a spend, a top item -- while everything
-- that reads the LEDGER (the item table, the transaction list, the IN/OUT/NET
-- row) read the real store, which in demo mode holds nothing. So the Ledger
-- window, the one screen with the most to show, opened empty, and the figures
-- above it were answers to a question no visible data had asked.
--
-- A generated ledger fixes both at once. Every reader computes from it through
-- the SAME arithmetic it runs on real data, so the demo exercises the real
-- paths rather than a parallel set, and every number on screen agrees with
-- every other one.
--
-- REAL ITEMS, CHECKED, NOT REMEMBERED. Names, ids, qualities and stack sizes
-- come from the CMaNGOS Classic-DB dump of the 1.12.1 `item_template`, not
-- from memory -- which was wrong about four of them in this very table: Fiery
-- Core and Lava Core are RARE on this patch, and Sulfuron Ingot and Nexus
-- Crystal are EPIC. The tooltip these arm is the client's own, so an id that
-- is not what it claims shows a tooltip for the wrong item, which is exactly
-- the failure demo mode exists to make visible.
--
-- EACH CARRIES ITS QUALITY, and that is not redundancy. ui.CraftQualityOf asks
-- the CLIENT, and the client only answers for items it has cached -- which for
-- an item the player has never seen or linked is none of them. So the names
-- drew in the default colour, which is the honest answer to "I do not know"
-- and the wrong one for data we made up ourselves and do know.
--
-- THE PRICES ARE OURS. No server dump can state what an auction house charges,
-- so the unit prices are invented -- plausible, in copper, and the only part
-- of this table that is not a checked fact.
--
-- WHAT THE SHAPE IS FOR. It is one trader's six months, and it is arranged so
-- every path through the renderers has something to draw:
--
--   * All four quality tiers, so the colouring is visible without hovering.
--   * TOP SALE and TOP ITEM are different items -- one Sulfuron Hammer is the
--     biggest thing that ever happened, Black Dragonscale Boots is what
--     actually earns. db.LedgerStats has always drawn that distinction and
--     nothing ever demonstrated it.
--   * Items traded BOTH ways (an average profit), SOLD only and BOUGHT only
--     (an em dash where there is no other side).
--   * Sales with no quantity, for the reason real ones have none. See below.
db.DEMO_LEDGER_ITEMS = {
    { item = "Sulfuron Hammer", itemId = 17193, quality = 4, qty = 1,
      buy = nil, buys = 0, sell = 11000000, sales = 1 },
    { item = "Black Dragonscale Boots", itemId = 16984, quality = 4, qty = 1,
      buy = nil, buys = 0, sell = 4200000, sales = 6 },
    { item = "Sulfuron Ingot", itemId = 17203, quality = 4, qty = 1,
      buy = 900000, buys = 3, sell = nil, sales = 0 },
    { item = "Nexus Crystal", itemId = 20725, quality = 4, qty = 1,
      buy = 240000, buys = 5, sell = 310000, sales = 5 },
    { item = "Arcanite Reaper", itemId = 12784, quality = 3, qty = 1,
      buy = 2600000, buys = 9, sell = 3300000, sales = 4 },
    { item = "Dal\'Rend\'s Sacred Charge", itemId = 12940, quality = 3, qty = 1,
      buy = 2900000, buys = 2, sell = 3400000, sales = 1 },
    { item = "Fiery Core", itemId = 17010, quality = 3, qty = 2,
      buy = 210000, buys = 6, sell = 268000, sales = 6 },
    { item = "Lava Core", itemId = 17011, quality = 3, qty = 2,
      buy = 195000, buys = 6, sell = 245000, sales = 6 },
    { item = "Large Brilliant Shard", itemId = 14344, quality = 3, qty = 3,
      buy = 78000, buys = 8, sell = 99000, sales = 8 },
    { item = "Arcanite Bar", itemId = 12360, quality = 2, qty = 5,
      buy = 98000, buys = 10, sell = 126000, sales = 10 },
    { item = "Arcane Crystal", itemId = 12363, quality = 2, qty = 2,
      buy = 145000, buys = 7, sell = 181000, sales = 7 },
    { item = "Blood of the Mountain", itemId = 11382, quality = 2, qty = 2,
      buy = 160000, buys = 5, sell = 205000, sales = 5 },
    { item = "Essence of Fire", itemId = 7078, quality = 2, qty = 5,
      buy = 31000, buys = 8, sell = 39500, sales = 8 },
    { item = "Greater Eternal Essence", itemId = 16203, quality = 2, qty = 5,
      buy = 22000, buys = 9, sell = 29000, sales = 9 },
    { item = "Dark Iron Bar", itemId = 11371, quality = 1, qty = 10,
      buy = 14500, buys = 9, sell = 19000, sales = 9 },
    { item = "Thorium Bar", itemId = 12359, quality = 1, qty = 20,
      buy = 5200, buys = 12, sell = 7100, sales = 12 },
    { item = "Black Dragonscale", itemId = 15416, quality = 1, qty = 4,
      buy = 42000, buys = 7, sell = 56000, sales = 7 },
    { item = "Enchanted Leather", itemId = 12810, quality = 1, qty = 5,
      buy = 28000, buys = 6, sell = 36000, sales = 6 },
    { item = "Illusion Dust", itemId = 16204, quality = 1, qty = 10,
      buy = 9500, buys = 10, sell = 13000, sales = 10 },
    { item = "Dense Grinding Stone", itemId = 12644, quality = 1, qty = 5,
      buy = 12000, buys = 5, sell = 16500, sales = 5 },
    { item = "Rune Thread", itemId = 14341, quality = 1, qty = 5,
      buy = 4800, buys = 4, sell = nil, sales = 0 },
    { item = "Runecloth", itemId = 14047, quality = 1, qty = 20,
      buy = 1900, buys = 14, sell = 2650, sales = 14 },
    { item = "Mageweave Cloth", itemId = 4338, quality = 1, qty = 20,
      buy = 1400, buys = 10, sell = 1950, sales = 10 },
    { item = "Silk Cloth", itemId = 4306, quality = 1, qty = 20,
      buy = 900, buys = 9, sell = 1320, sales = 9 },
    { item = "Linen Cloth", itemId = 2589, quality = 1, qty = 20,
      buy = 180, buys = 8, sell = 310, sales = 8 },
    { item = "Rugged Leather", itemId = 8170, quality = 1, qty = 20,
      buy = 2100, buys = 9, sell = 2900, sales = 9 },
    { item = "Thick Leather", itemId = 4304, quality = 1, qty = 20,
      buy = 1250, buys = 7, sell = 1750, sales = 7 },
    { item = "Dreamfoil", itemId = 13463, quality = 1, qty = 20,
      buy = 2400, buys = 11, sell = 3350, sales = 11 },
    { item = "Mountain Silversage", itemId = 13465, quality = 1, qty = 20,
      buy = 2600, buys = 9, sell = 3600, sales = 9 },
    { item = "Golden Sansam", itemId = 13464, quality = 1, qty = 20,
      buy = 2200, buys = 8, sell = 3100, sales = 8 },
    { item = "Peacebloom", itemId = 2447, quality = 1, qty = 20,
      buy = 110, buys = 6, sell = 190, sales = 6 },
    { item = "Silverleaf", itemId = 765, quality = 1, qty = 20,
      buy = 120, buys = 6, sell = 205, sales = 6 },
    { item = "Earthroot", itemId = 2449, quality = 1, qty = 20,
      buy = 140, buys = 5, sell = 240, sales = 5 },
    { item = "Briarthorn", itemId = 2450, quality = 1, qty = 20,
      buy = 260, buys = 5, sell = 410, sales = 5 },
}

-- How far back the demo trades. Matches db.OldestMoney's demo answer, so the
-- chart and the ledger cover the same ground.
db.DEMO_LEDGER_DAYS = 180

-- How far back a SALE still knows its quantity. The posting book that answers
-- "how many were in that stack" only exists from v1.54.7, so older sales have
-- no count and never will -- db.RecordTxn treats absent as unknown and
-- ui.CountText renders it as "?". That is a real, permanent property of
-- anyone's history and the demo shows it rather than pretending otherwise.
--
-- WHERE THE LINE SITS IS A PRESENTATION CHOICE, not a claim about any real
-- install: it puts roughly a quarter of the demo's sales on the unknown side.
-- Enough that the "?" is plainly there to be seen and asked about, few enough
-- that the column still reads as a column of counts rather than as a table
-- that failed to load.
db.DEMO_QTY_KNOWN_DAYS = 90

-- ...and one recent sale in this many still cannot say, because this character
-- had several stacks of that item up at different sizes. See db.MatchPosting:
-- there is no auction id on 1.12 to ask which one sold.
db.DEMO_QTY_MIXED = 9

-- The quality of a demo item, by id, or nil for anything else.
--
-- Consulted by db.LedgerStats and db.LedgerItems so the rows they hand the
-- renderers carry a colour the client cannot supply.
function db.DemoQuality(itemId)
    -- GATED ON DEMO MODE, and that is not belt-and-braces. Twenty-one of the
    -- pool's items are ordinary trade goods a real player really trades, so
    -- an ungated lookup would state a quality for a REAL Linen Cloth row and
    -- override the client -- which is the one source that is actually
    -- authoritative. A suite caught exactly that.
    if not db.demo then return nil end
    if not itemId then return nil end
    local pool = db.DEMO_LEDGER_ITEMS
    local i = 1
    while i <= table.getn(pool) do
        if pool[i].itemId == itemId then return pool[i].quality end
        i = i + 1
    end
    return nil
end

-- Build the demo's ledger: one array of transactions in exactly the shape
-- db.RecordTxn writes, so every reader is none the wiser.
--
-- DETERMINISTIC. The same call always produces the same ledger -- a table
-- whose figures changed between two repaints of the same window could not be
-- read, and a seed taken from the clock looks perfectly stable to anything
-- that checks twice in a row.
function db.BuildDemoLedger(now)
    now = now or time()
    local rows = {}
    local seed = db.DemoSeed("ledger")
    local span  = db.DEMO_LEDGER_DAYS * 86400
    local known = db.DEMO_QTY_KNOWN_DAYS * 86400
    local chars = db.DEMO_CHARS
    local nChars = table.getn(chars)
    local pool = db.DEMO_LEDGER_ITEMS
    local p = 1
    while p <= table.getn(pool) do
        local it = pool[p]
        local k = 1
        while k <= 2 do
            local kind, unit, count
            if k == 1 then kind, unit, count = "buy", it.buy, it.buys
            else            kind, unit, count = "sale", it.sell, it.sales end
            local j = 1
            while unit and unit > 0 and j <= (count or 0) do
                seed = db.DemoNext(seed)
                -- WEIGHTED TOWARD THE PRESENT (r squared). Six months of
                -- trading spread evenly leaves the Day and Week periods --
                -- the two a player actually checks -- with nothing in them.
                local r = seed / db.DEMO_MOD
                local age = math.floor(span * r * r)
                seed = db.DemoNext(seed)
                local qty = it.qty or 1
                if qty > 1 then
                    qty = qty + math.mod(math.floor(seed / 131), qty)
                end
                -- Plus or minus 15%, so a column of identical figures does
                -- not read as a table that failed to load.
                local amount =
                    math.floor(unit * qty * (0.85 + (seed / db.DEMO_MOD) * 0.30))
                if amount < 1 then amount = 1 end
                seed = db.DemoNext(seed)
                local who = chars[math.mod(math.floor(seed / 17), nChars) + 1]
                local q = qty
                if kind == "sale" then
                    -- A BUY HAS ALWAYS KNOWN ITS COUNT; a sale has to learn it
                    -- from the posting book. See db.DEMO_QTY_KNOWN_DAYS.
                    if age > known then
                        q = nil
                    elseif math.mod(math.floor(seed / 7), db.DEMO_QTY_MIXED) == 0
                    then
                        q = nil
                    end
                end
                table.insert(rows, { t = now - age, kind = kind,
                                     item = it.item, amount = amount,
                                     id = it.itemId, qty = q, who = who })
                j = j + 1
            end
            k = k + 1
        end
        p = p + 1
    end
    -- CHRONOLOGICAL, because that is the order a real ledger is appended in
    -- and the transaction list's default sort reverses it. The tiebreaks are
    -- not decoration: `pairs` is unordered and table.sort is not stable, so
    -- two entries sharing a second would otherwise swap between repaints.
    table.sort(rows, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        if a.item ~= b.item then return a.item < b.item end
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.amount < b.amount
    end)
    return rows
end

-- The built ledger, once per session.
--
-- CACHED because it is read several times per repaint -- the blocks, the
-- strip, the item table and the transaction list all walk it -- and rebuilding
-- five hundred rows behind every period button is work nobody asked for.
-- Cleared when demo mode is toggled, so a second /aex demo re-anchors it to
-- the current time rather than leaving a history that ends hours ago.
db.demoLedger = nil

function db.DemoLedger()
    if not db.demoLedger then db.demoLedger = db.BuildDemoLedger() end
    return db.demoLedger
end

-- for quality colouring, where a missing one costs nothing.
function db.LedgerStats(sinceEpoch, now)
    now = now or time()
    local st = {
        income = 0, spend = 0, net = 0,
        saleN = 0, buyN = 0,
        oldest = nil, days = 1,
    }
    local saleBy, buyBy = {}, {}

    local led = db.LedgerSource()
    local i = 1
    while i <= table.getn(led) do
        local e = led[i]
        local t = e.t
        if not sinceEpoch or (t and t >= sinceEpoch) then
            local amount = e.amount or 0
            if amount > 0 then
                if t and (not st.oldest or t < st.oldest) then st.oldest = t end
                local key = e.item or "?"
                local bucket, top, topName
                if e.kind == "sale" then
                    st.income = st.income + amount
                    st.saleN  = st.saleN + 1
                    bucket = saleBy
                    if not st.topSale or amount > st.topSale.amount then
                        st.topSale = { item = e.item, itemId = e.id,
                                       amount = amount }
                    end
                elseif e.kind == "buy" then
                    st.spend = st.spend + amount
                    st.buyN  = st.buyN + 1
                    bucket = buyBy
                    if not st.topBuy or amount > st.topBuy.amount then
                        st.topBuy = { item = e.item, itemId = e.id,
                                      amount = amount }
                    end
                end
                if bucket then
                    local rec = bucket[key]
                    if not rec then
                        rec = { item = e.item, itemId = e.id, total = 0 }
                        bucket[key] = rec
                    end
                    -- An id learned on a LATER entry backfills the record, so
                    -- an item whose early history predates id recording still
                    -- gets its colour from whichever entry carried one.
                    if not rec.itemId and e.id then rec.itemId = e.id end
                    -- ...and failing that, the name->id map, which every scan,
                    -- search and browse feeds. EVERY mail-logged sale before
                    -- v1.54.3 stored a name and no id, so without this the
                    -- Sales and Profit blocks could never colour or hover
                    -- their Top item while the Expenses block -- fed by the
                    -- Buy tab, which knows the id -- always could.
                    if not rec.itemId then
                        rec.itemId = db.IdFromName(rec.item)
                    end
                    rec.total = rec.total + amount
                end
            end
        end
        i = i + 1
    end

    -- The biggest SINGLE transaction of each kind gets the same backfill, for
    -- the same reason: it is displayed by name and hovered by id.
    if st.topSale and not st.topSale.itemId then
        st.topSale.itemId = db.IdFromName(st.topSale.item)
    end
    if st.topBuy and not st.topBuy.itemId then
        st.topBuy.itemId = db.IdFromName(st.topBuy.item)
    end
    st.net  = st.income - st.spend
    st.days = db.WindowDays(sinceEpoch, st.oldest, now)
    st.topSaleItem = db.TopOf(saleBy)
    st.topBuyItem  = db.TopOf(buyBy)
    -- A QUALITY THE CLIENT CANNOT ANSWER FOR. A real ledger row records none
    -- and does not need to: ui.CraftQualityOf asks the client, which has the
    -- item cached because the player traded it. A DEMO item the player has
    -- never seen or linked is not cached, so without this the invented epics
    -- drew in the ordinary text colour. Nil outside demo mode, which leaves
    -- the renderers on their usual path.
    local q = 1
    local tops = { st.topSale, st.topBuy, st.topSaleItem, st.topBuyItem }
    while q <= 4 do
        local rec = tops[q]
        if rec and not rec.quality then rec.quality = db.DemoQuality(rec.itemId) end
        q = q + 1
    end
    return st
end

-- The highest-`total` record in a keyed table, or nil when it is empty.
--
-- TIES GO TO THE LOWER KEY, sorted as a string, so the answer does not change
-- between two repaints of the same data. `pairs` has no order, and a figure
-- that flickers between two items on a timer is a bug somebody will chase for
-- ---------------------------------------------------------------------------
-- The ledger, per ITEM rather than per transaction
-- ---------------------------------------------------------------------------

-- An average unit price, or nil when there is nothing to divide by.
function db.AvgUnit(money, units)
    if not units or units <= 0 then return nil end
    return math.floor((money or 0) / units)
end

-- Roll the ledger up by item: what you sold, what you paid, and what the
-- difference was per unit.
--
-- MONEY AND UNITS ARE SUMMED OVER THE SAME TRANSACTIONS, and that is the whole
-- care in this function. A sale logged before v1.54.7 has no quantity, and so
-- does one this character could not match to a posting -- so summing ALL the
-- money over only the countable units would divide a bigger number by a
-- smaller one and report an average that is simply too high. Every unknown
-- transaction is excluded from BOTH sums and counted separately, so the
-- average is right for the subset it covers and the caller can say how much it
-- does not cover.
--
-- Returns an array of:
--   item, itemId
--   sold,   soldMoney,   soldTxns,   soldUnknown
--   bought, boughtMoney, boughtTxns, boughtUnknown
--
-- KEYED BY NAME, for the reason db.LedgerStats is: keying by id-or-name splits
-- an item whose history straddles the release where ids started being
-- recorded, and neither half is then the whole item.
function db.LedgerItems(sinceEpoch, now)
    local byName, order = {}, {}
    local led = db.LedgerSource()
    local i = 1
    while i <= table.getn(led) do
        local e = led[i]
        local t = e.t
        if not sinceEpoch or (t and t >= sinceEpoch) then
            local amount = e.amount or 0
            if amount > 0 and (e.kind == "sale" or e.kind == "buy") then
                local key = e.item or "?"
                local rec = byName[key]
                if not rec then
                    rec = { item = e.item or "?", itemId = e.id,
                            sold = 0, soldMoney = 0, soldTxns = 0,
                            soldUnknown = 0,
                            bought = 0, boughtMoney = 0, boughtTxns = 0,
                            boughtUnknown = 0 }
                    byName[key] = rec
                    table.insert(order, rec)
                end
                if not rec.itemId and e.id then rec.itemId = e.id end
                local qty = e.qty
                if e.kind == "sale" then
                    rec.soldTxns = rec.soldTxns + 1
                    if qty and qty > 0 then
                        rec.sold = rec.sold + qty
                        rec.soldMoney = rec.soldMoney + amount
                    else
                        rec.soldUnknown = rec.soldUnknown + 1
                    end
                else
                    rec.boughtTxns = rec.boughtTxns + 1
                    if qty and qty > 0 then
                        rec.bought = rec.bought + qty
                        rec.boughtMoney = rec.boughtMoney + amount
                    else
                        rec.boughtUnknown = rec.boughtUnknown + 1
                    end
                end
            end
        end
        i = i + 1
    end

    -- Failing an id off the transactions, the name map -- every scan, search
    -- and browse feeds it, and it is what lets a row be quality-coloured and
    -- hovered. Same lookup of last resort db.LedgerStats makes.
    local r = 1
    while r <= table.getn(order) do
        local rec = order[r]
        if not rec.itemId then rec.itemId = db.IdFromName(rec.item) end
        -- Same reason db.LedgerStats states one: the client has never seen a
        -- demo item, so it cannot colour the name. Nil on real data.
        if not rec.quality then rec.quality = db.DemoQuality(rec.itemId) end
        rec.avgSell   = db.AvgUnit(rec.soldMoney, rec.sold)
        rec.avgBuy    = db.AvgUnit(rec.boughtMoney, rec.bought)
        -- PER UNIT, and only when BOTH sides are known. An item you have only
        -- sold has no purchase price to subtract, and an item whose sales all
        -- predate quantities has no per-unit sale price at all.
        if rec.avgSell and rec.avgBuy then
            rec.avgProfit = rec.avgSell - rec.avgBuy
        end
        -- HOW MANY YOU ACTUALLY TURNED OVER: you cannot resell more than you
        -- bought, nor more than you sold.
        if rec.sold > 0 and rec.bought > 0 then
            rec.resold = rec.sold
            if rec.bought < rec.resold then rec.resold = rec.bought end
        end
        r = r + 1
    end
    return order
end

-- The footer: how many units were turned over, what that made, and how many
-- rows could not be counted.
--
-- THE SKIPPED COUNT IS RETURNED, NOT SWALLOWED. A total summed over the rows
-- it could do and silent about the rest is a number nobody can reconcile
-- against their own history -- which is the whole failure this table's
-- quantity work exists to avoid.
function db.LedgerItemTotals(rows)
    local resold, profit, skipped = 0, 0, 0
    local i = 1
    while i <= table.getn(rows or {}) do
        local rec = rows[i]
        if rec.resold and rec.avgProfit then
            resold = resold + rec.resold
            profit = profit + rec.avgProfit * rec.resold
        elseif (rec.soldTxns or 0) > 0 and (rec.boughtTxns or 0) > 0 then
            -- Traded both ways but not countable: exactly the row a total
            -- would otherwise drop without saying.
            skipped = skipped + 1
        end
        i = i + 1
    end
    return resold, math.floor(profit), skipped
end

-- an hour before realising it is the iteration.
function db.TopOf(bucket)
    local best, bestKey = nil, nil
    for key, rec in pairs(bucket or {}) do
        local k = tostring(key)
        if not best or rec.total > best.total
            or (rec.total == best.total and k < bestKey) then
            best, bestKey = rec, k
        end
    end
    return best
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
--
-- NOT CALLED, and not tested -- same standing as db.PriceSpread below.
function db.SaleHistory(itemName)
    if not itemName then return nil, 0 end
    local amounts, last = {}, nil
    local led = db.LedgerSource()
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
--
-- NOT CALLED, and not tested. It was written for a Sell-tab readout that was
-- never built, and the comment here claimed the pairing as if it existed.
-- Kept because it is the only implementation of the idea and the History
-- graph in ROADMAP Phase 3 wants exactly this shape -- but nothing reaches
-- it today, so treat it as unverified when something finally does.
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
--
-- WAS 500 EVERY 0.5s -- a thousand GetItemInfo calls a second, from login to
-- id 120000, for about two minutes, every session, whatever else was going on.
--
-- The comment inside db.HarvestStep said a nil return "is the common case and
-- costs nothing". THAT WAS ASSERTED, NOT MEASURED, and it is the same shape of
-- mistake as believing 1.12 routes shift-clicks through ChatEdit_InsertLink:
-- on this client GetItemInfo for an item the cache has never seen does not
-- simply return nil, it puts an item query on the wire. A thousand a second is
-- not free, and it is invisible to Task Manager because the cost is in the
-- client's item-cache and network path rather than in Lua.
--
-- 50 per second instead. The sweep takes longer to finish and nothing else
-- changes: it is the least urgent thing in the addon and it says so.
db.HARVEST_BUDGET = 50

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

-- Throw away every harvested fact.
--
-- TURNING THE SWEEP OFF DOES NOT SHRINK WHAT IT ALREADY COLLECTED. `facts`
-- lives in SavedVariables, so it is deserialised back into Lua at EVERY login
-- and stays there for the session -- a sweep that ran for an hour last week is
-- still costing memory today. Stopping the growth and undoing it are two
-- different actions and the player needs both.
--
-- Safe to lose: every fact here is re-learnable from the item itself, and the
-- opportunistic path relearns the ones that matter as you play.
function db.PurgeFacts()
    local n = db.HarvestCount()
    if db.account then db.account.facts = {} end
    db.harvestAt = 1
    return n
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
            -- seen this item" -- the common case, and NOT free: see the note
            -- on db.HARVEST_BUDGET for why this is paced the way it is.
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

local HARVEST_DELAY = 1.0

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
    if not db.Setting("harvest") then return false end
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

-- The sweep YIELDS to the auction house, and this is the whole point of it
-- being pausable.
--
-- HARD RULE 10 is about not flooding the client's auction path; a background
-- sweep firing item queries into the same client while a scan is paging is the
-- same flood by another door -- and it lands exactly when the player is
-- watching, because they opened the auction house to do something.
--
-- db.StopHarvest existed and NOTHING CALLED IT. The housekeeping pass flagged
-- it as unreachable and kept it on the grounds that it was the only
-- implementation of its idea. It was: this is the caller it was waiting for.
A.RegisterEvent("AUCTION_HOUSE_SHOW", function() db.StopHarvest() end)
A.RegisterEvent("AUCTION_HOUSE_CLOSED", function() db.StartHarvest() end)

function db.HarvestRunning()
    return harvester:IsShown() and true or false
end

-- Register the bootstrap with the load queue.
A.OnLoad(db.Init)

-- ...and the harvest after it, so db.account exists before the first step.
A.OnLoad(function() db.StartHarvest() end)
