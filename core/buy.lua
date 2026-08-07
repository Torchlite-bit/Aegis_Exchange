-- Aegis: Exchange
-- core/buy.lua
--
-- Shopping engine: search the AH by name, page through the results, and
-- buy/bid. Unlike the scanner (which walks every page to feed the price DB),
-- the Buy tab browses ONE page at a time and keeps each listing's real "list"
-- index, because on 1.12 you can only bid/buyout an auction that is on the
-- currently loaded page.
--
-- 1.12 API used here (verified against the Turtle UI source):
--   QueryAuctionItems(name, minLevel, maxLevel, invType, class, subclass,
--                     page, isUsable, quality)         -- 9 args, page 0-indexed
--   GetNumAuctionItems("list")            -> numOnPage, totalAuctions
--   GetAuctionItemInfo("list", i)         -> 12 values (see CLAUDE.md)
--   PlaceAuctionBid("list", index, amount)  -- amount >= buyout => buyout,
--                                              otherwise a bid
--   CanSendAuctionQuery()                   -- gate before every query

local A = AegisExchange
A.buy = {}
local buy = A.buy
local util = A.util

buy.PAGE_SIZE   = 50
buy.QUERY_DELAY = 0.5    -- polite gap before (re)querying a page
buy.TIMEOUT     = 8      -- seconds to wait for a page reply before retrying

buy.state = {
    phase      = "idle",   -- idle | wait_query | wait_results
    name       = "",
    terms      = { { blizz = { name = "", minLevel = "", maxLevel = "" },
                      filter = function() return true end } },
    termIndex  = 1,        -- 1-based: which OR term (see Query language below)
    page       = 0,        -- 0-indexed current page, WITHIN the active term
    totalPages = 0,
    total      = 0,
    rows       = {},       -- current page's listings (sorted for display)
    cooldown   = 0,
    timeout    = 0,
    callbacks  = nil,      -- { onResults = fn(rows), onState = fn(phase) }
}

buy.driver = CreateFrame("Frame", "AegisExchangeBuyDriver")
buy.driver:Hide()

-- Another AH consumer (an actively-querying scan, or posting) is using the
-- query channel. A PAUSED scan is idle on the wire, so browsing is allowed --
-- you can pause a scan, check a price here, then Resume (or Stop).
function buy.IsBusy()
    return A.scan.IsRunning() or A.sell.PostingActive()
end

local function Notify()
    local st = buy.state
    if st.callbacks and st.callbacks.onState then
        st.callbacks.onState(st.phase)
    end
end

-- ---------------------------------------------------------------------------
-- Shopping lists + recent searches (persisted in AegisExchangeDB.shopping)
-- ---------------------------------------------------------------------------

local RECENT_MAX = 12

-- The persisted store, or nil before ADDON_LOADED. Callers guard on nil.
local function Store()
    return A.db and A.db.account and A.db.account.shopping
end

function buy.Lists()
    local s = Store()
    return s and s.lists or {}
end

function buy.Recent()
    local s = Store()
    return s and s.recent or {}
end

-- Push a search term to the front of the recent list (delete any duplicate).
function buy.PushRecent(term)
    local s = Store()
    if not s or not term or term == "" then return end
    local i = 1
    while i <= table.getn(s.recent) do
        if string.lower(s.recent[i]) == string.lower(term) then
            table.remove(s.recent, i)
        else
            i = i + 1
        end
    end
    table.insert(s.recent, 1, term)
    while table.getn(s.recent) > RECENT_MAX do
        table.remove(s.recent)
    end
end

-- Tab-autocomplete candidates for the search box: known item names (learned
-- from every scan, search, or AH browse -- db.account.names is fed from all
-- three) plus recent search terms, case-insensitive PREFIX match, deduped,
-- alphabetical.
function buy.AutocompleteCandidates(prefix)
    local out = {}
    if not prefix or prefix == "" then return out end
    local low = string.lower(prefix)
    local seen = {}
    local function consider(name)
        if not name or name == "" or seen[name] then return end
        if string.find(string.lower(name), low, 1, true) == 1 then
            seen[name] = true
            table.insert(out, name)
        end
    end
    local names = A.db and A.db.account and A.db.account.names
    if names then
        for name in pairs(names) do consider(name) end
    end
    local recent = buy.Recent()
    local i = 1
    while i <= table.getn(recent) do consider(recent[i]); i = i + 1 end
    table.sort(out)
    return out
end

function buy.AddList(name)
    local s = Store()
    if not s or not name or name == "" then return nil end
    local list = { name = name, items = {} }
    table.insert(s.lists, list)
    return list
end

function buy.RenameList(index, name)
    local s = Store()
    if not s or not name or name == "" then return end
    local list = s.lists[index]
    if list then list.name = name end
end

function buy.DeleteList(index)
    local s = Store()
    if s and s.lists[index] then table.remove(s.lists, index) end
end

-- Add an item name to a list (no duplicates). Returns true if newly added.
function buy.AddItemToList(index, itemName)
    local s = Store()
    if not s or not itemName or itemName == "" then return false end
    local list = s.lists[index]
    if not list then return false end
    local i = 1
    while i <= table.getn(list.items) do
        if string.lower(list.items[i]) == string.lower(itemName) then
            return false
        end
        i = i + 1
    end
    table.insert(list.items, itemName)
    return true
end

function buy.RemoveItemFromList(index, itemName)
    local s = Store()
    if not s then return end
    local list = s.lists[index]
    if not list then return end
    local i = 1
    while i <= table.getn(list.items) do
        if list.items[i] == itemName then
            table.remove(list.items, i)
        else
            i = i + 1
        end
    end
end

-- ---------------------------------------------------------------------------
-- Query language (ROADMAP Phase 2a)
--
-- The grammar is aux's, not a new Aegis-native dialect (decided in ROADMAP.md):
-- slash-delimited terms, semicolon-separated OR at the top level, keyword
-- modifiers. This is an ORIGINAL implementation of that known grammar shape --
-- no code from any reference addon.
--
-- Nothing about today's casual usage changes: typing a plain item name still
-- just searches by name, because a bare word with no recognized keyword is
-- exactly what it always was -- text appended to the name filter.
--
-- Recognized tokens (slash-delimited), case-insensitive:
--   exact              -- keep only rows whose AUCTION NAME matches the typed
--                          name exactly (not just "contains"). Post-filter.
--   usable             -- server-side isUsable flag.
--   quality/<n-or-name> or the fused form qualityN (e.g. "quality2") --
--                          server-side quality index. Names: poor, common,
--                          uncommon, rare, epic, legendary.
--   level/<n> or level/<min>-<max>, or the fused forms levelN / levelN-M --
--                          server-side level range.
--   buyout             -- exclude bid-only auctions. Post-filter.
--   stack              -- keep only fully-stacked listings (count == the
--                          item's max stack size). Post-filter.
--   <class name>       -- an auction CATEGORY, by its own localized name:
--                          "armor", "weapon", "container", "trade goods", ...
--   <subclass name>    -- a subcategory of whatever class was named earlier in
--                          the same term: "armor/leather", "container/bag".
--   <slot name>        -- an equip slot within the current class/subclass,
--                          e.g. "armor/plate/chest".
--   tooltip            -- everything AFTER this point in the term accumulates
--                          into a tooltip-substring search instead of the name
--                          (post-filter, scans the auction's tooltip lines).
--                          Concrete disambiguation case, both with class
--                          Container / subclass Bag consumed as categories:
--                            container/bag/tooltip/8  -> tooltip contains "8"
--                            container/bag/8          -> name contains "8"
--
-- DEFERRED (see ROADMAP.md): price/time-left/seller/rarity post-filter
-- primitives; prefix-notation and/or/not combinators (2d's territory -- this
-- slice's post-filters all apply together, an implicit AND).
--
-- NOTE on `exact`: aux's Filter Builder DISABLES the level/class/quality
-- controls when exact is ticked. We deliberately don't -- ours is a pure
-- post-filter on the name, so combining it with a category or level range is
-- both harmless and occasionally useful, and silently dropping filters someone
-- typed would be worse than honouring them.
-- ---------------------------------------------------------------------------

-- Quality names, keyed by the client's OWN localized strings first
-- (ITEM_QUALITY<n>_DESC is how the game names them, and is what aux reads),
-- with the English words kept as a fallback so the documented `quality/rare`
-- spelling works even somewhere the globals are missing.
buy.QUALITY_NAMES = {
    poor = 0, common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5,
}

local qualityByName
local function QualityNames()
    if qualityByName then return qualityByName end
    qualityByName = {}
    for word, idx in pairs(buy.QUALITY_NAMES) do qualityByName[word] = idx end
    local i = 0
    while i <= 5 do
        local desc = getglobal("ITEM_QUALITY" .. i .. "_DESC")
        if desc and desc ~= "" then qualityByName[string.lower(desc)] = i end
        i = i + 1
    end
    return qualityByName
end

-- "2" or "rare" -> a quality index, or nil if neither parses.
local function ParseQualityValue(tok)
    local named = QualityNames()[tok]
    if named then return named end
    local n = tonumber(tok)
    if n and n >= 0 and n <= 6 then return math.floor(n) end
    return nil
end

-- Fused "quality2" / "qualityrare" -> a quality index, or nil.
local function ParseFusedQuality(tok)
    local _, _, digits = string.find(tok, "^quality(%d+)$")
    if digits then return tonumber(digits) end
    local _, _, name = string.find(tok, "^quality(%a+)$")
    if name then return QualityNames()[name] end
    return nil
end

-- ---------------------------------------------------------------------------
-- Auction categories (class / subclass / slot)
--
-- Resolved from the client's OWN localized names, exactly as aux does:
-- GetAuctionItemClasses() -> class names, GetAuctionItemSubClasses(class) ->
-- its subclass names, GetAuctionInvTypes(class, subclass) -> GLOBAL KEY
-- strings ("INVTYPE_CHEST") whose _G lookup is the display name. Hard-coding
-- English would have made "armor/leather" a non-English-client-only feature.
--
-- Built lazily and cached: these APIs only answer once the AH is open, so
-- building at file scope would bake in an empty table forever.
-- ---------------------------------------------------------------------------

local categoryCache

local function BuildCategoryCache()
    local cache = { classes = {}, subclasses = {}, slots = {},
                    classNames = {}, subNames = {}, slotNames = {} }
    if not GetAuctionItemClasses then return cache end
    local cats = A.scan and A.scan.GetCategories and A.scan.GetCategories()
    if not cats then return cache end
    local ci = 1
    while ci <= table.getn(cats) do
        local cat = cats[ci]
        if cat.name then
            cache.classes[string.lower(cat.name)] = cat.class
            cache.classNames[cat.class] = cat.name
            local subs = cat.subs or {}
            local si = 1
            while si <= table.getn(subs) do
                local sub = subs[si]
                if sub.name then
                    -- Keyed by class: subclass names repeat across classes
                    -- ("Miscellaneous" lives under several), so a flat map
                    -- would resolve "armor/miscellaneous" to whichever class
                    -- happened to be built last.
                    local byClass = cache.subclasses[cat.class]
                    if not byClass then
                        byClass = {}
                        cache.subclasses[cat.class] = byClass
                    end
                    byClass[string.lower(sub.name)] = sub.subclass
                    -- Reverse map, for the Filter Builder: it has to render
                    -- the localized name for an index it holds.
                    cache.subNames[cat.class] = cache.subNames[cat.class] or {}
                    cache.subNames[cat.class][sub.subclass] = sub.name
                end
                si = si + 1
            end
        end
        ci = ci + 1
    end
    return cache
end

function buy.Categories()
    if not categoryCache then categoryCache = BuildCategoryCache() end
    return categoryCache
end

-- Look a typed word up in one of those name -> index maps.
--
-- Exact match is not enough on its own: the game's own category names are
-- PLURAL and often qualified ("Daggers", "One-Handed Swords", "Food & Drink"),
-- while people type the singular. `weapon/dagger` matched nothing, fell back
-- to name text, and returned every thrown weapon with "Dagger" in its name --
-- which is exactly how it got reported.
--
-- So: exact, then a unique prefix, then a unique substring. UNIQUE is the
-- whole safety property -- "sword" matches both One-Handed and Two-Handed
-- Swords, so it stays name text rather than silently picking one and
-- returning a confidently wrong page.
local function ResolveCategory(map, tok)
    if not map then return nil end
    local exact = map[tok]
    if exact then return exact end

    local found, count = nil, 0
    for name, index in pairs(map) do
        if string.find(name, tok, 1, true) == 1 then
            found, count = index, count + 1
        end
    end
    if count == 1 then return found end
    if count > 1 then return nil end   -- ambiguous prefix: do not guess

    found, count = nil, 0
    for name, index in pairs(map) do
        if string.find(name, tok, 1, true) then
            found, count = index, count + 1
        end
    end
    if count == 1 then return found end
    return nil
end

-- The AH session teaches us these names; drop the cache when it ends so a
-- different locale or a late-loading client can rebuild.
function buy.ResetCategories()
    categoryCache = nil
end

-- Reverse lookups: an index back to the localized name. The Filter Builder
-- holds indices (that is what the query carries) but must SHOW names.
function buy.ClassName(class)
    local c = buy.Categories()
    return class and c.classNames[class] or nil
end

function buy.SubclassName(class, subclass)
    local c = buy.Categories()
    local m = class and c.subNames[class]
    return m and subclass and m[subclass] or nil
end

-- Ordered { { value = index, text = name } } lists for the builder's dropdowns.
-- Sorted by index so the order matches the auction house's own dropdowns
-- rather than alphabetically by whatever the locale happens to call things.
local function OptionsFrom(nameMap)
    local out = {}
    if not nameMap then return out end
    for idx, name in pairs(nameMap) do
        table.insert(out, { value = idx, text = name })
    end
    table.sort(out, function(a, b) return a.value < b.value end)
    return out
end

function buy.ClassOptions()
    return OptionsFrom(buy.Categories().classNames)
end

function buy.SubclassOptions(class)
    if not class then return {} end
    return OptionsFrom(buy.Categories().subNames[class])
end

-- Equip slots for a given class/subclass, lazily per pair. GetAuctionInvTypes
-- is guarded: it is not present on every 1.12 build, and a nil call here would
-- take the whole parse down.
local function SlotsFor(class, subclass)
    local cache = buy.Categories()
    local key = tostring(class or 0) .. ":" .. tostring(subclass or 0)
    local found = cache.slots[key]
    if found then return found end
    found = {}
    if GetAuctionInvTypes then
        local ok, list = pcall(function()
            return { GetAuctionInvTypes(class or 0, subclass or 0) }
        end)
        if ok and list then
            local i = 1
            while i <= table.getn(list) do
                local globalKey = list[i]
                local label = globalKey and getglobal(globalKey)
                if label and label ~= "" then
                    found[string.lower(label)] = i
                    local names = cache.slotNames[key]
                    if not names then
                        names = {}
                        cache.slotNames[key] = names
                    end
                    names[i] = label
                end
                i = i + 1
            end
        end
    end
    cache.slots[key] = found
    return found
end

-- Slot options / name. Both force SlotsFor first so the reverse map exists --
-- it is only populated as a side effect of the forward lookup.
function buy.SlotOptions(class, subclass)
    if not class then return {} end
    SlotsFor(class, subclass)
    local key = tostring(class) .. ":" .. tostring(subclass or 0)
    local out = {}
    local names = buy.Categories().slotNames[key]
    if not names then return out end
    for idx, name in pairs(names) do
        table.insert(out, { value = idx, text = name })
    end
    table.sort(out, function(a, b) return a.value < b.value end)
    return out
end

function buy.SlotName(class, subclass, slot)
    if not class or not slot then return nil end
    SlotsFor(class, subclass)
    local key = tostring(class) .. ":" .. tostring(subclass or 0)
    local names = buy.Categories().slotNames[key]
    return names and names[slot] or nil
end

-- "20" or "20-30" (the VALUE half of a two-token "level/..." form) -> min, max.
local function ParseLevelValue(tok)
    local _, _, mn, mx = string.find(tok, "^(%d+)%-(%d+)$")
    if mn then return tonumber(mn), tonumber(mx) end
    local _, _, single = string.find(tok, "^(%d+)$")
    if single then local n = tonumber(single); return n, n end
    return nil
end

-- "stack20" and "stack 20" -> 20, or nil.
--
-- The spaced form matters because tokens are split on "/", so typing
-- "silk cloth/stack 20" hands the parser ONE token, "stack 20" -- it never
-- reaches the two-token "stack" branch. Supporting all three spellings means
-- the obvious thing to type works whichever way you reach for it.
local function ParseFusedStack(tok)
    local _, _, digits = string.find(tok, "^stack%s*(%d+)$")
    if digits then
        local n = tonumber(digits)
        if n and n >= 1 then return n end
    end
    return nil
end

-- Fused "level20" / "level20-30" -> min, max, or nil.
local function ParseFusedLevel(tok)
    local _, _, mn, mx = string.find(tok, "^level(%d+)%-(%d+)$")
    if mn then return tonumber(mn), tonumber(mx) end
    local _, _, single = string.find(tok, "^level(%d+)$")
    if single then local n = tonumber(single); return n, n end
    return nil
end

-- Parse ONE slash-delimited term (already split out of the semicolon OR list)
-- into its structured pieces. Never errors: an unrecognized token always falls
-- back to becoming literal name/tooltip text, so a query never "breaks".
function buy.ParseTerm(text)
    local term = {
        nameWords = {}, tooltipWords = {}, inTooltip = false,
        exact = false, usable = false, buyoutOnly = false, stackOnly = false,
        stackSize = nil,
        quality = nil, minLevel = nil, maxLevel = nil,
        class = nil, subclass = nil, slot = nil,
    }
    local function appendWord(word)
        if term.inTooltip then
            table.insert(term.tooltipWords, word)
        else
            table.insert(term.nameWords, word)
        end
    end

    local cats = buy.Categories()

    local tokens = util.Split(text, "/")
    local i, n = 1, table.getn(tokens)
    while i <= n do
        local raw = util.Trim(tokens[i])
        local tok = string.lower(raw)
        if tok == "exact" then
            term.exact = true
        elseif tok == "usable" then
            term.usable = true
        elseif tok == "buyout" then
            term.buyoutOnly = true
        elseif tok == "stack" then
            -- "stack/20" -- an EXPLICIT size. Needs no item data at all, which
            -- is the whole point: it works on the first search, for any item,
            -- however cold the client's cache is.
            local nxt = tokens[i + 1]
            local sz = nxt and tonumber(util.Trim(nxt))
            if sz and sz >= 1 then
                term.stackSize = math.floor(sz); i = i + 1
            else
                term.stackOnly = true
            end
        elseif tok == "tooltip" then
            term.inTooltip = true
        elseif tok == "quality" then
            local nxt = tokens[i + 1]
            local q = nxt and ParseQualityValue(string.lower(util.Trim(nxt)))
            if q then term.quality = q; i = i + 1
            else appendWord(raw) end
        elseif tok == "level" then
            -- NOT "nxt and ParseLevelValue(...)": `and` adjusts its right
            -- operand to a single value, which silently drops ParseLevelValue's
            -- second return (maxLevel) whenever it truncates. Caught by a test
            -- asserting level/20-30 keeps BOTH ends of the range.
            local nxt = tokens[i + 1]
            local mn, mx
            if nxt then mn, mx = ParseLevelValue(util.Trim(nxt)) end
            if mn then term.minLevel = mn; term.maxLevel = mx; i = i + 1
            else appendWord(raw) end
        else
            local q = ParseFusedQuality(tok)
            local sz = ParseFusedStack(tok)
            local mn, mx
            if not q and not sz then mn, mx = ParseFusedLevel(tok) end
            if q then
                term.quality = q
            elseif sz then
                term.stackSize = sz
            elseif mn then
                term.minLevel = mn; term.maxLevel = mx
            -- Categories, in the order they can be resolved. A subclass only
            -- means anything once its class is known, and a slot only once
            -- both are -- which is why "armor/leather" works and
            -- "leather/armor" leaves "leather" as name text. Never inside a
            -- tooltip clause: after `tooltip` every word is search text, so
            -- searching tooltips for the literal word "bag" still works.
            elseif not term.inTooltip and not term.class
                and ResolveCategory(cats.classes, tok) then
                term.class = ResolveCategory(cats.classes, tok)
            elseif not term.inTooltip and term.class and not term.subclass
                and ResolveCategory(cats.subclasses[term.class], tok) then
                term.subclass = ResolveCategory(cats.subclasses[term.class], tok)
            elseif not term.inTooltip and term.class and not term.slot
                and ResolveCategory(SlotsFor(term.class, term.subclass), tok) then
                term.slot = ResolveCategory(SlotsFor(term.class, term.subclass), tok)
            else
                appendWord(raw)
            end
        end
        i = i + 1
    end

    term.name = util.Trim(table.concat(term.nameWords, " "))
    if table.getn(term.tooltipWords) > 0 then
        term.tooltipText = util.Trim(table.concat(term.tooltipWords, " "))
    else
        term.tooltipText = nil
    end
    return term
end

-- ---------------------------------------------------------------------------
-- Query generation (ROADMAP 2b -- the Filter Builder's other direction)
-- ---------------------------------------------------------------------------

-- Turn a parsed-term-shaped table back into a query string.
--
-- ORDER MATTERS and is not cosmetic. ParseTerm resolves a token as a subclass
-- only once a class is known, and as a slot only after that -- so categories
-- must be emitted class, subclass, slot, in that sequence. The name goes FIRST
-- so its words are consumed as name text before any category token sets the
-- class and starts eating them.
--
-- Round-tripping is by VALUE, not by string: a name that is itself a category
-- word ("armor") re-parses into the same term with the tokens in a different
-- order. Compare parsed terms, never the strings.
function buy.TermToQuery(term)
    if not term then return "" end
    local parts = {}
    local function add(p)
        if p and p ~= "" then table.insert(parts, p) end
    end

    add(term.name)
    if term.exact then add("exact") end

    add(term.class and buy.ClassName(term.class))
    add(term.class and term.subclass
        and buy.SubclassName(term.class, term.subclass))
    add(term.class and term.slot
        and buy.SlotName(term.class, term.subclass, term.slot))

    if term.quality then add("quality/" .. term.quality) end
    if term.minLevel then
        if term.maxLevel and term.maxLevel ~= term.minLevel then
            add("level/" .. term.minLevel .. "-" .. term.maxLevel)
        else
            add("level/" .. term.minLevel)
        end
    end
    if term.usable then add("usable") end
    if term.buyoutOnly then add("buyout") end
    if term.stackSize then
        add("stack/" .. term.stackSize)
    elseif term.stackOnly then
        add("stack")
    end
    -- Tooltip LAST: everything after the keyword is swallowed as tooltip text,
    -- so anything emitted after it would silently stop being a filter.
    if term.tooltipText and term.tooltipText ~= "" then
        add("tooltip/" .. term.tooltipText)
    end

    return table.concat(parts, "/")
end

-- Two parsed terms mean the same search? Used by the builder's round-trip
-- check, and by its tests, because string equality is the wrong comparison
-- (see TermToQuery).
function buy.TermsEqual(a, b)
    if not a or not b then return false end
    local keys = { "name", "exact", "usable", "buyoutOnly", "stackOnly",
                   "stackSize", "quality", "minLevel", "maxLevel",
                   "class", "subclass", "slot", "tooltipText" }
    local i = 1
    while i <= table.getn(keys) do
        local k = keys[i]
        -- false and nil both mean "off" for the flags; normalise before
        -- comparing so an unset checkbox matches an absent field.
        local av, bv = a[k], b[k]
        if av == false then av = nil end
        if bv == false then bv = nil end
        if av ~= bv then return false end
        i = i + 1
    end
    return true
end

-- Split on the top-level semicolon OR, into an array of parsed terms. Always
-- returns at least one term (an all-blank query is one empty-name term, same
-- as browsing everything today).
function buy.ParseQuery(text)
    local groups = util.Split(text or "", ";")
    if table.getn(groups) == 0 then groups = { "" } end
    local terms = {}
    local i = 1
    while i <= table.getn(groups) do
        table.insert(terms, buy.ParseTerm(groups[i]))
        i = i + 1
    end
    return terms
end

-- Max stack size, via the shared util.ItemInfo normaliser (which is where the
-- "GetItemInfo's slots move between clients" problem is solved once, for every
-- caller -- see its comment).
local function StackCountFromItemInfo(link)
    local info = util.ItemInfo(link)
    local n = info and info.stackCount
    if n and n > 0 then return n end
    return nil
end
buy.StackCountFromItemInfo = StackCountFromItemInfo

-- Max stack size for an item, or nil if genuinely not known yet.
--
-- GetItemInfo only answers for items already in the client's local item cache
-- -- exactly the wrong behaviour for an auction house, where the items you
-- have never handled are the ones you are shopping for. sell.lua already
-- documents the same hazard.
--
-- So: check what we have LEARNED first, ask the client second, and persist
-- anything the client does tell us. Over a couple of sessions the DB fills in
-- and the filter stops guessing.
buy.stackCache = {}
function buy.MaxStackFor(itemId, link)
    if not itemId then return nil end
    local cached = buy.stackCache[itemId]
    if cached then return cached end
    local stored = A.db and A.db.GetMaxStack and A.db.GetMaxStack(itemId)
    if stored then
        buy.stackCache[itemId] = stored
        return stored
    end
    local stackCount = StackCountFromItemInfo(link)
    if stackCount then
        buy.LearnMaxStack(itemId, stackCount)
        return stackCount
    end
    return nil
end

-- Record a max stack we just learned, from wherever. Cheap and idempotent, so
-- every code path that happens to hold a good GetItemInfo result can call it.
function buy.LearnMaxStack(itemId, count)
    if not itemId or not count or count < 1 then return end
    buy.stackCache[itemId] = count
    if A.db and A.db.SetMaxStack then A.db.SetMaxStack(itemId, count) end
end

-- A dedicated, never-shown tooltip for reading an auction listing's tooltip
-- text (the "tooltip" post-filter).
--
-- Built LAZILY and read exactly the way sell.lua's IsAuctionable does it,
-- because that one demonstrably works on the real client and the first
-- version of this one did not:
--   * lazy, not file scope -- a templated frame built while core/buy.lua is
--     still loading is not reliably ready;
--   * SetOwner BEFORE ClearLines, then the Set* call (this order);
--   * bounded by NumLines(). GameTooltipTemplate reuses its TextLeftN
--     FontStrings, so they survive from whatever was shown last -- walking
--     until GetText() comes back nil either stops early on line 1 or reads
--     stale text from a previous, longer tooltip. NumLines() is the only
--     honest bound.
local function QueryTip()
    if not buy._queryTip then
        buy._queryTip = CreateFrame("GameTooltip", "AegisExchangeQueryTooltip",
            nil, "GameTooltipTemplate")
    end
    return buy._queryTip
end

local function TooltipContainsAt(index, needleLower)
    local tip = QueryTip()
    if not tip.SetAuctionItem then return false end
    tip:SetOwner(UIParent, "ANCHOR_NONE")
    tip:ClearLines()
    tip:SetAuctionItem("list", index)
    local n = tip:NumLines() or 0
    local i = 1
    while i <= n do
        local fs = getglobal("AegisExchangeQueryTooltipTextLeft" .. i)
        local text = fs and fs:GetText()
        if text and string.find(string.lower(text), needleLower, 1, true) then
            return true
        end
        i = i + 1
    end
    return false
end

-- Compile a parsed term into what the engine actually needs: the 1.12
-- QueryAuctionItems args (CLAUDE.md rule 9: strings for name/min/max, "" when
-- unused, never nil; flag/index args stay nil for "no filter") plus a
-- post-filter closure applied to each row as its page loads.
function buy.CompileTerm(term)
    local blizz = {
        name     = term.name or "",
        minLevel = term.minLevel and tostring(term.minLevel) or "",
        maxLevel = term.maxLevel and tostring(term.maxLevel) or "",
        isUsable = term.usable and true or nil,
        quality  = term.quality,
        class    = term.class,
        subclass = term.subclass,
        invType  = term.slot,
    }
    local exactName = term.exact and string.lower(term.name or "") or nil
    local tooltipNeedle = term.tooltipText and string.lower(term.tooltipText)
        or nil
    local buyoutOnly = term.buyoutOnly
    local stackOnly  = term.stackOnly
    local stackSize  = term.stackSize

    local function filter(row, stats)
        if buyoutOnly and not (row.buyout and row.buyout > 0) then
            return false
        end
        if exactName and string.lower(row.name or "") ~= exactName then
            return false
        end
        -- An EXPLICIT size needs no item data whatsoever -- just compare the
        -- listing's own count. This is the reliable form.
        if stackSize then
            if row.count ~= stackSize then return false end
        elseif stackOnly then
            -- Bare `stack` means "full stacks", which needs the item's maximum
            -- -- and GetItemInfo only knows that for items the client has
            -- cached. Rather than dead-end on "unknown", fall back to the
            -- largest count for that item ON THIS PAGE, which needs no item
            -- data at all and is a fair reading of "the big stacks". The
            -- caller is told which rule was used so the status line can say.
            local max = buy.MaxStackFor(row.itemId, row.link)
            if not max then
                max = stats and stats.pageMax and stats.pageMax[row.itemId]
                if max and stats then stats.usedPageMax = true end
            end
            if not max then
                if stats then stats.unknownStack = (stats.unknownStack or 0) + 1 end
                return false
            end
            if row.count ~= max then return false end
        end
        if tooltipNeedle and not TooltipContainsAt(row.index, tooltipNeedle) then
            return false
        end
        return true
    end

    return { blizz = blizz, filter = filter, raw = term }
end

function buy.CompileQuery(text)
    local terms = buy.ParseQuery(text)
    local compiled = {}
    local i = 1
    while i <= table.getn(terms) do
        table.insert(compiled, buy.CompileTerm(terms[i]))
        i = i + 1
    end
    return compiled
end

-- ---------------------------------------------------------------------------
-- Browsing engine
-- ---------------------------------------------------------------------------

-- Kick off a fresh search for `text` (plain name, or the query language above)
-- at term 1, page 0.
function buy.Search(text, callbacks)
    if buy.IsBusy() then
        return false, "The AH is busy (scan or posting in progress)."
    end
    local st = buy.state
    st.terms     = buy.CompileQuery(text)
    st.termIndex = 1
    st.name      = st.terms[1].blizz.name   -- kept for existing readers
    st.page      = 0
    st.callbacks = callbacks or st.callbacks
    st.phase     = "wait_query"
    st.cooldown  = 0
    st.timeout   = 0
    buy.PushRecent(util.Trim(text or ""))
    buy.driver:Show()
    Notify()
    return true
end

-- Re-query the current page (after a purchase, or to refresh).
function buy.Refresh()
    local st = buy.state
    if st.phase ~= "idle" then return end
    st.phase    = "wait_query"
    st.cooldown = buy.QUERY_DELAY
    buy.driver:Show()
    Notify()
end

function buy.GotoPage(page)
    if buy.IsBusy() then return end
    local st = buy.state
    if page < 0 then page = 0 end
    st.page     = page
    st.phase    = "wait_query"
    st.cooldown = buy.QUERY_DELAY
    buy.driver:Show()
    Notify()
end

-- Switch the active OR term (see the Query language section above) and query
-- its page 0.
function buy.GotoTerm(termIndex)
    if buy.IsBusy() then return end
    local st = buy.state
    local total = table.getn(st.terms)
    if termIndex < 1 then termIndex = 1 end
    if termIndex > total then termIndex = total end
    st.termIndex = termIndex
    st.name      = st.terms[termIndex].blizz.name   -- kept for existing readers
    st.page      = 0
    st.phase     = "wait_query"
    st.cooldown  = buy.QUERY_DELAY
    buy.driver:Show()
    Notify()
end

-- Past the last page of the active term, roll into the next OR term rather
-- than stopping -- a semicolon-separated query is meant to read as one
-- combined browse, not N separate searches you have to notice and re-run.
function buy.NextPage()
    local st = buy.state
    if st.page + 1 < st.totalPages then
        buy.GotoPage(st.page + 1)
    elseif st.termIndex < table.getn(st.terms) then
        buy.GotoTerm(st.termIndex + 1)
    end
end

-- Symmetric with NextPage, EXCEPT crossing a term boundary backwards lands on
-- that term's FIRST page rather than a deep link to its last one -- we don't
-- know its page count until we've queried it, and reaching back across an OR
-- boundary is rare enough that a second round trip to discover "the last
-- page" isn't worth the complexity.
function buy.PrevPage()
    local st = buy.state
    if st.page > 0 then
        buy.GotoPage(st.page - 1)
    elseif st.termIndex > 1 then
        buy.GotoTerm(st.termIndex - 1)
    end
end

local function SendQuery()
    local st = buy.state
    local b = st.terms[st.termIndex].blizz
    -- name/minLevel/maxLevel as strings (see CLAUDE.md rule 9); the index and
    -- flag args (invType, class, subclass, isUsable, quality) stay nil for
    -- "no filter".
    QueryAuctionItems(b.name, b.minLevel, b.maxLevel, b.invType, b.class,
        b.subclass, st.page, b.isUsable, b.quality)
    st.phase   = "wait_results"
    st.timeout = buy.TIMEOUT
    Notify()
end

function buy.OnUpdate(dt)
    local st = buy.state
    if st.phase == "wait_query" then
        st.cooldown = st.cooldown - dt
        if st.cooldown <= 0 and CanSendAuctionQuery() then
            SendQuery()
        end
    elseif st.phase == "wait_results" then
        st.timeout = st.timeout - dt
        if st.timeout <= 0 then
            st.phase    = "wait_query"    -- lost reply; retry the page
            st.cooldown = 1
        end
    end
end
buy.driver:SetScript("OnUpdate", function() buy.OnUpdate(arg1) end)

-- Read the currently visible "list" page into sorted rows. Each row keeps its
-- real `index` so a later bid/buyout targets the right auction.
function buy.ReadPage()
    local st = buy.state
    local term = st.terms[st.termIndex]
    local numOnPage, total = GetNumAuctionItems("list")
    st.total = total or 0
    st.totalPages = math.ceil(st.total / buy.PAGE_SIZE)
    if st.totalPages < 1 then st.totalPages = 1 end

    local me = UnitName and UnitName("player") or nil
    local rawRows = {}
    local i = 1
    while i <= numOnPage do
        local name, texture, count, quality, canUse, level, minBid, minInc,
              buyout, bidAmount, highBidder, owner = GetAuctionItemInfo("list", i)
        if name then
            count = count or 1
            local nextBid
            if bidAmount and bidAmount > 0 then
                nextBid = bidAmount + (minInc or 0)
            else
                nextBid = minBid or 0
            end
            local link = GetAuctionItemLink("list", i)
            table.insert(rawRows, {
                index   = i,
                name    = name,
                texture = texture,
                count   = count,
                quality = quality,
                canUse  = canUse,
                level   = level,
                buyout  = buyout or 0,
                unit    = (buyout and buyout > 0) and math.floor(buyout / count)
                          or nil,
                minBid  = minBid or 0,
                bidAmount = bidAmount or 0,
                nextBid = nextBid,
                owner   = owner,
                link    = link,
                itemId  = util.ItemIdFromLink(link),
                mine    = (owner and me and owner == me) and true or false,
            })
        end
        i = i + 1
    end

    -- NOTE: browsing DOES feed the price DB, but not from here. scan.lua's
    -- AUCTION_ITEM_LIST_UPDATE handler calls RecordVisiblePage() on every
    -- result page anyone looks at -- including this one, from the same event
    -- -- so a loop here would just record the identical values a second time.
    -- (This file used to do exactly that. Adding the post-filter below is what
    -- surfaced it: a sabotage that fed the DB from the FILTERED rows instead
    -- of the raw ones changed nothing observable, because scan.lua had already
    -- recorded every row regardless.)
    --
    -- The important consequence is worth stating: the post-filter narrows what
    -- is DISPLAYED and never what is learned. A "buyout only" or "exact"
    -- search still teaches the price DB what every listing on the page costs.

    -- A plain-text search (the common case) compiles to an always-true filter,
    -- so rows == rawRows and nothing about existing behaviour changes.
    -- Largest count per item on this page, computed BEFORE filtering so bare
    -- `stack` has something to fall back on when the client cannot tell us an
    -- item's real maximum.
    local pageMax = {}
    local pi = 1
    while pi <= table.getn(rawRows) do
        local r = rawRows[pi]
        if r.itemId and r.count then
            if not pageMax[r.itemId] or r.count > pageMax[r.itemId] then
                pageMax[r.itemId] = r.count
            end
        end
        pi = pi + 1
    end

    local stats = { unknownStack = 0, pageMax = pageMax }
    local rows = {}
    local ri = 1
    while ri <= table.getn(rawRows) do
        local r = rawRows[ri]
        -- Learn every max stack this page happens to expose, whether or not
        -- the row survives the filter -- the next search benefits either way.
        if r.itemId and r.link then
            local sc = StackCountFromItemInfo(r.link)
            if sc then buy.LearnMaxStack(r.itemId, sc) end
        end
        if term.filter(r, stats) then table.insert(rows, r) end
        ri = ri + 1
    end
    st.stats = stats

    -- Cheapest unit buyout first (bid-only auctions, unit = nil, sink to the
    -- bottom); the real `index` is preserved so buying still hits the right
    -- listing.
    table.sort(rows, function(a, b)
        if not a.unit and not b.unit then return false end
        if not a.unit then return false end   -- a is bid-only -> after b
        if not b.unit then return true end    -- b is bid-only -> a before
        return a.unit < b.unit
    end)

    st.rows  = rows
    st.phase = "idle"
    buy.driver:Hide()
    if st.callbacks and st.callbacks.onResults then
        st.callbacks.onResults(rows)
    end
    Notify()
end

-- The listing at `row.index` still matches what we displayed (guards against
-- the page shifting between read and click).
function buy.Verify(row)
    local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", row.index)
    return name == row.name and count == row.count
        and (buyout or 0) == row.buyout
end

-- Buy out `row`. Returns (true) or (false, reason). The refreshed page arrives
-- via the AUCTION_ITEM_LIST_UPDATE the purchase triggers.
function buy.Buyout(row)
    if not row then return false, "No auction selected." end
    if row.mine then return false, "That's your own auction." end
    if not row.buyout or row.buyout <= 0 then return false, "No buyout price." end
    if not buy.Verify(row) then
        return false, "Listing changed \226\128\148 search again."
    end
    -- Arm the re-read BEFORE bidding: the purchase's AUCTION_ITEM_LIST_UPDATE
    -- can arrive immediately, and we want our handler to pick it up.
    local st = buy.state
    st.phase   = "wait_results"
    st.timeout = buy.TIMEOUT
    buy.driver:Show()
    PlaceAuctionBid("list", row.index, row.buyout)
    return true
end

-- Place a bid of `amount` (defaults to the minimum next bid) on `row`.
function buy.Bid(row, amount)
    if not row then return false, "No auction selected." end
    if row.mine then return false, "That's your own auction." end
    amount = amount or row.nextBid
    if not amount or amount < row.nextBid then
        return false, "Bid is below the minimum."
    end
    if row.buyout > 0 and amount >= row.buyout then
        return buy.Buyout(row)      -- a bid at/above buyout IS a buyout
    end
    if not buy.Verify(row) then
        return false, "Listing changed \226\128\148 search again."
    end
    local st = buy.state
    st.phase   = "wait_results"
    st.timeout = buy.TIMEOUT
    buy.driver:Show()
    PlaceAuctionBid("list", row.index, amount)
    return true
end

function buy.GetResults()
    local st = buy.state
    return st.rows, st.page, st.totalPages, st.total, st.termIndex,
        table.getn(st.terms), st.stats
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- Read a page only when WE asked for it; otherwise stay out of the way (the
-- scanner's own handler still feeds the price DB from this same event).
A.RegisterEvent("AUCTION_ITEM_LIST_UPDATE", function()
    if buy.state.phase == "wait_results" then
        buy.ReadPage()
    end
end)

-- Walking away from the auctioneer ends any in-flight browse.
A.RegisterEvent("AUCTION_HOUSE_CLOSED", function()
    buy.state.phase = "idle"
    buy.driver:Hide()
    -- The category names came from the session that just ended; drop them so
    -- the next one rebuilds (they are only readable while the AH is open).
    buy.ResetCategories()
end)

-- ---------------------------------------------------------------------------
-- Crafting: recipes captured from the profession window (kept here so no new
-- file is added to the .toc -- a /reload is enough to pick this up)
-- ---------------------------------------------------------------------------

A.craft = {}
local craft = A.craft

local function CStore()
    return A.db and A.db.account and A.db.account.crafting
end

function craft.Projects()
    local s = CStore()
    return s and s.projects or {}
end

-- Add (or replace, by name) a captured recipe. Returns the stored project.
function craft.AddProject(project)
    local s = CStore()
    if not s or not project or not project.name then return nil end
    local i = 1
    while i <= table.getn(s.projects) do
        if s.projects[i].name == project.name then
            table.remove(s.projects, i)   -- refresh an existing entry
        else
            i = i + 1
        end
    end
    table.insert(s.projects, 1, project)
    return project
end

function craft.DeleteProject(index)
    local s = CStore()
    if s and s.projects[index] then table.remove(s.projects, index) end
end

-- Capture the recipe currently selected in the trade-skill window (most
-- professions). Returns a project table or (nil, reason).
function craft.CaptureTradeSkill()
    if not GetTradeSkillSelectionIndex then return nil, "No profession open." end
    local id = GetTradeSkillSelectionIndex()
    if not id or id < 1 then return nil, "Select a recipe first." end
    local name = GetTradeSkillInfo(id)
    if not name then return nil, "Could not read the recipe." end
    local itemId
    if GetTradeSkillItemLink then
        itemId = util.ItemIdFromLink(GetTradeSkillItemLink(id))
    end
    -- How many the recipe yields (for the profit estimate). Optional API on
    -- 1.12 -- default 1 when unavailable.
    local made = 1
    if GetTradeSkillNumMade then
        local minMade = GetTradeSkillNumMade(id)
        if minMade and minMade > 0 then made = minMade end
    end
    local reagents = {}
    local n = GetTradeSkillNumReagents(id) or 0
    local r = 1
    while r <= n do
        local rname, _, rcount = GetTradeSkillReagentInfo(id, r)
        local rid
        if GetTradeSkillReagentItemLink then
            rid = util.ItemIdFromLink(GetTradeSkillReagentItemLink(id, r))
        end
        if rname then
            table.insert(reagents,
                { name = rname, count = rcount or 1, itemId = rid })
        end
        r = r + 1
    end
    return { name = name, itemId = itemId, made = made, reagents = reagents }
end

-- Faction consignment cut applied to a sale on Turtle (see CLAUDE.md).
craft.AH_CUT = 0.05

-- Resolve a stored reagent/product to an itemId, using the captured link id
-- first and the name->id map (filled by scans/searches) as a fallback.
local function ResolveId(itemId, name)
    if itemId then return itemId end
    if name and A.db and A.db.IdFromName then return A.db.IdFromName(name) end
    return nil
end

-- Total cost to buy this recipe's reagents at the best known unit price.
-- Returns (copperTotal, complete, missingNames): complete is false (and the
-- name is listed in missingNames) when a reagent has no recorded price yet.
function craft.CostOf(project)
    local total, complete, missing = 0, true, {}
    if not project or not project.reagents then return 0, false, missing end
    local i = 1
    while i <= table.getn(project.reagents) do
        local r = project.reagents[i]
        local id = ResolveId(r.itemId, r.name)
        local unit = id and A.db.BestUnit(id)
        if unit then
            total = total + unit * (r.count or 1)
        else
            complete = false
            table.insert(missing, r.name)
        end
        i = i + 1
    end
    return total, complete, missing
end

-- Best known sale value of the crafted item (× quantity made). Returns
-- (copper, known). Enchanting crafts have no item, so known is false.
function craft.ValueOf(project)
    if not project then return nil, false end
    local id = ResolveId(project.itemId, project.name)
    local unit = id and A.db.BestUnit(id)
    if not unit then return nil, false end
    return unit * (project.made or 1), true
end

-- Estimated net if you buy the mats, craft, and resell: sale value minus the
-- AH cut, minus reagent cost. Returns (net, complete) where complete means
-- both sides were fully priced.
function craft.NetOf(project)
    local cost, costComplete = craft.CostOf(project)
    local value, valueKnown = craft.ValueOf(project)
    if not (costComplete and valueKnown) then return nil, false end
    return math.floor(value * (1 - craft.AH_CUT) - cost), true
end

-- Capture the recipe selected in the craft window (Enchanting).
function craft.CaptureCraft()
    if not GetCraftSelectionIndex then return nil, "No profession open." end
    local id = GetCraftSelectionIndex()
    if not id or id < 1 then return nil, "Select a recipe first." end
    local name = GetCraftInfo(id)
    if not name then return nil, "Could not read the recipe." end
    local reagents = {}
    local n = GetCraftNumReagents(id) or 0
    local r = 1
    while r <= n do
        local rname, _, rcount = GetCraftReagentInfo(id, r)
        local rid
        if GetCraftReagentItemLink then
            rid = util.ItemIdFromLink(GetCraftReagentItemLink(id, r))
        end
        if rname then
            table.insert(reagents,
                { name = rname, count = rcount or 1, itemId = rid })
        end
        r = r + 1
    end
    return { name = name, reagents = reagents }
end

-- The recipe currently selected in whichever profession window is OPEN, as a
-- transient project (NOT stored). Used by the live profit line on the
-- profession window. Returns a project or (nil, reason). Craft (Enchanting)
-- takes priority when its window is the visible one.
function craft.Current()
    if CraftFrame and CraftFrame.IsVisible and CraftFrame:IsVisible() then
        return craft.CaptureCraft()
    end
    if TradeSkillFrame and TradeSkillFrame.IsVisible
        and TradeSkillFrame:IsVisible() then
        return craft.CaptureTradeSkill()
    end
    return nil, "No profession open."
end
