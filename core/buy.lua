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

-- ---- Favorites (saved searches) ----------------------------------------
--
-- An ordered list of query strings. Order is the user's, so every mutator
-- here preserves it -- promoting appends rather than sorting, and moving is
-- an explicit swap.

function buy.Favorites()
    local s = Store()
    if not s then return {} end
    -- Databases saved before this existed have no `favorites` key.
    s.favorites = s.favorites or {}
    return s.favorites
end

-- Promote a query to Favorites. Deduped case-insensitively, and it does NOT
-- reorder an existing entry: re-favouriting something you already saved
-- should be a no-op, not a jump to the bottom of your own list.
-- Returns true when it was actually added.
function buy.AddFavorite(q)
    local s = Store()
    if not s or not q or util.Trim(q) == "" then return false end
    q = util.Trim(q)
    local favs = buy.Favorites()
    local i = 1
    while i <= table.getn(favs) do
        if string.lower(favs[i]) == string.lower(q) then return false end
        i = i + 1
    end
    table.insert(favs, q)
    return true
end

function buy.RemoveFavorite(index)
    local favs = buy.Favorites()
    if favs[index] then table.remove(favs, index); return true end
    return false
end

-- Move a favorite one place up (dir -1) or down (dir +1). Returns the new
-- index, or nil when it could not move (already at the end).
function buy.MoveFavorite(index, dir)
    local favs = buy.Favorites()
    local to = index + dir
    if not favs[index] or not favs[to] then return nil end
    favs[index], favs[to] = favs[to], favs[index]
    return to
end

-- SHOPPING LISTS: the engine is GONE, the saved data is NOT.
--
-- buy.Lists / AddList / RenameList / DeleteList / AddItemToList /
-- RemoveItemFromList lived here after the Advanced redesign removed the
-- sidebar that was their only caller. They were kept on the reasoning that
-- re-homing the feature would then cost a UI rather than a rewrite -- but the
-- Crafting tab's tracked recipes ARE that feature's shape, and they were built
-- on `crafting`, not on these. Nothing is coming back to them.
--
-- `account.shopping.lists` in core/db.lua STAYS. A player who used the sidebar
-- before the redesign still has their lists in SavedVariables, and dropping
-- the field would delete them on the next save -- which is a migration a
-- player cannot upgrade into, i.e. the one thing MAJOR is reserved for. An
-- unread table costs nothing; deleted data cannot be got back.

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
-- Component names that are accepted by the parser but not yet implemented by
-- CompileOperand. Kept next to the parser so the two lists cannot drift.
local PENDING_COMPONENT = { ["item"] = true }

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

-- ---------------------------------------------------------------------------
-- What each post-filter component's VALUE is
-- ---------------------------------------------------------------------------

-- Time left is 1..4, exactly as GetAuctionItemTimeLeft reports it.
--
-- The English keys ARE the query language and do not vary by locale: a saved
-- search has to mean the same thing on a German client, so `left/short` is
-- spelled the same everywhere. The client's own localized strings are
-- accepted on the way IN as a convenience -- the same courtesy QualityNames()
-- extends to ITEM_QUALITY*_DESC -- but never emitted.
local TIME_LEFT_KEY = { "short", "medium", "long", "very long" }
local timeLeftByName
local function TimeLeftNames()
    if timeLeftByName then return timeLeftByName end
    timeLeftByName = {}
    local i = 1
    while i <= 4 do
        timeLeftByName[TIME_LEFT_KEY[i]] = i
        local desc = getglobal("AUCTION_TIME_LEFT" .. i)
        if desc and desc ~= "" then timeLeftByName[string.lower(desc)] = i end
        i = i + 1
    end
    timeLeftByName["verylong"] = 4      -- typed without the space
    return timeLeftByName
end

-- "short" or "2" -> 1..4, or nil if neither parses.
local function ParseTimeLeftValue(tok)
    local named = TimeLeftNames()[tok]
    if named then return named end
    local n = tonumber(tok)
    if n and n >= 1 and n <= 4 then return math.floor(n) end
    return nil
end

-- THE one table that says what a component's value is made of. Four readers
-- ask it and none of them keeps its own copy: buy.ParseTerm reads the value,
-- buy.TermToQuery writes it back, the Filter Builder's Enter key validates
-- what was typed, and the Post Filter list draws it.
--
-- Four hand-written copies of "min-level takes a number" is the shape that
-- produced the Saved-vs-Builder drift in 1.19.3. `tooltip` is deliberately
-- absent: it has its own parse branch (the run-on) and its own draw branch.
local COMPONENT_VALUE = {
    ["min-level"]     = "number",
    ["max-level"]     = "number",
    ["rarity"]        = "quality",
    ["seller"]        = "text",
    ["left"]          = "timeleft",
    ["max-unit-buy"]  = "money",
    ["min-unit-buy"]  = "money",
    ["percent"]       = "percent",
    ["vendor-profit"] = "money",
    ["disenchant-profit"]  = "money",
    ["disenchant-percent"] = "percent",
}

-- "number" | "quality" | "timeleft" | "money" | "text", or nil for a token
-- that is not a valued post-filter component.
function buy.ComponentValueKind(kind)
    if not kind then return nil end
    if PENDING_COMPONENT[kind] then return "text" end
    return COMPONENT_VALUE[kind]
end

-- Raw typed text -> the value the term stores, or nil when it does not parse.
--
-- Storing the PARSED value (3, not "rare") is what makes the round trip work
-- by value rather than by spelling, which is the rule this file already
-- follows for quality and level.
function buy.ParseComponentValue(kind, raw)
    raw = util.Trim(raw or "")
    if raw == "" then return nil end
    local vk = buy.ComponentValueKind(kind)
    if vk == "number" then
        local n = tonumber(raw)
        if n and n >= 0 then return math.floor(n) end
        return nil
    elseif vk == "quality" then
        return ParseQualityValue(string.lower(raw))
    elseif vk == "timeleft" then
        return ParseTimeLeftValue(string.lower(raw))
    elseif vk == "money" then
        local m = util.ParseMoney(raw)
        if m and m > 0 then return m end
        return nil
    elseif vk == "percent" then
        -- A trailing "%" is what people type, so take it and drop it. Stored
        -- as a plain number because that is what the comparison needs; the
        -- sign is punctuation, not data.
        local body = raw
        local _, _, stripped = string.find(body, "^(.-)%%$")
        if stripped then body = stripped end
        local n = tonumber(util.Trim(body))
        if n and n > 0 then return n end
        return nil
    elseif vk == "text" then
        return raw
    end
    return nil
end

-- The value written back into a query string. Money and time left both have a
-- spelling that is not their stored form -- 50000 is not "5g", and `left/1`
-- means nothing to a reader.
--
-- Quality is NOT named here: it goes back as its index, matching the
-- `quality/2` the server-side filter already emits. One spelling for one
-- concept beats a prettier one that disagrees with its neighbour.
function buy.ComponentValueText(kind, value)
    local vk = buy.ComponentValueKind(kind)
    if vk == "money" then return util.FormatMoney(value) end
    if vk == "timeleft" then return TIME_LEFT_KEY[value] or tostring(value) end
    return tostring(value)
end

-- What to say when the Builder cannot make sense of what was typed. Phrased
-- as an example, because "invalid value" tells you only that you were wrong.
function buy.ComponentValueHint(kind)
    local vk = buy.ComponentValueKind(kind)
    if vk == "number"   then return "a level, like 40" end
    if vk == "percent"  then return "a percentage, like 80" end
    if vk == "quality"  then return "a quality, like rare or 3" end
    if vk == "timeleft" then return "a time left, like short or 2" end
    if vk == "money"    then return "a price, like 5g or 50s" end
    return "a value"
end

-- Every token the term loop below recognises as something other than free
-- text and that takes no leading value of its own. Kept as a table because
-- buy.IsTermKeyword has to ask "is this word spoken for?" without running the
-- loop's side effects.
local BARE_KEYWORD = {
    ["exact"] = true, ["usable"] = true, ["buyout"] = true, ["stack"] = true,
    ["tooltip"] = true, ["and"] = true, ["or"] = true, ["not"] = true,
    ["quality"] = true, ["level"] = true,
    ["max-unit-buy"] = true, ["min-unit-buy"] = true,
}

-- Would `tok` (already lowercased and trimmed) be recognised by buy.ParseTerm
-- as something OTHER than free text, given the categories `term` has resolved
-- so far?
--
-- ONE function, TWO readers, and that is the point. The tooltip run-on in
-- ParseTerm stops at the first keyword, and buy.TermToQuery asks the same
-- question before it dares emit a needle in the short form. Written twice
-- they would drift, and the drift would be silent: a query that round-trips
-- into a DIFFERENT search.
--
-- The category half has to be asked in term order, because the loop resolves
-- a subclass only once a class is known and a slot only after that -- so the
-- same word is a keyword in one position and free text in another.
function buy.IsTermKeyword(tok, term)
    if not tok or tok == "" then return false end
    if BARE_KEYWORD[tok] then return true end
    if PENDING_COMPONENT[tok] then return true end
    if COMPONENT_VALUE[tok] then return true end
    if ParseFusedQuality(tok) then return true end
    if ParseFusedStack(tok) then return true end
    if ParseFusedLevel(tok) then return true end

    term = term or {}
    local cats = buy.Categories()
    if not term.class then
        return ResolveCategory(cats.classes, tok) ~= nil
    end
    if not term.subclass
        and ResolveCategory(cats.subclasses[term.class], tok) then
        return true
    end
    if not term.slot
        and ResolveCategory(SlotsFor(term.class, term.subclass), tok) then
        return true
    end
    return false
end

-- Parse ONE slash-delimited term (already split out of the semicolon OR list)
-- into its structured pieces. Never errors: an unrecognized token always falls
-- back to becoming literal name/tooltip text, so a query never "breaks".
function buy.ParseTerm(text)
    local term = {
        nameWords = {},
        exact = false, usable = false, buyoutOnly = false, stackOnly = false,
        stackSize = nil,
        quality = nil, minLevel = nil, maxLevel = nil,
        class = nil, subclass = nil, slot = nil,
        -- Ordered post-filter entries. Each is either an operand
        -- ({ kind = "tooltip", value = "+3 stamina" }) or a combinator
        -- ({ kind = "and" | "or" | "not" }). Consecutive operands with no
        -- combinator between them are ANDed -- see buy.CompilePost.
        post = {},
    }
    local function appendWord(word)
        table.insert(term.nameWords, word)
    end
    local function addPost(kind, value)
        table.insert(term.post, { kind = kind, value = value })
    end

    local cats = buy.Categories()

    local tokens = util.Split(text, "/")
    local i, n = 1, table.getn(tokens)
    while i <= n do
        local raw = util.Trim(tokens[i])
        local tok = string.lower(raw)
        -- [Bracketed] is the SAME THING as /exact, written the way a player
        -- can read it back. `/exact` has always been in the query language;
        -- brackets are what a right-click can put in the search box, and what
        -- somebody can type from memory without knowing the language exists.
        --
        -- string.find with a capture, not string.match -- Lua 5.0.
        local _, _, bracketed = string.find(raw, "^%[(.+)%]$")
        if bracketed then
            term.exact = true
            appendWord(util.Trim(bracketed))
        elseif tok == "exact" then
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
            -- One token per NEEDLE -- never the rest of the term.
            --
            -- It used to switch into a sticky mode that swallowed everything
            -- after it, which made a second tooltip clause impossible:
            -- "tooltip/+3 stam/tooltip/+3 agi" parsed as the single string
            -- "+3 stam tooltip +3 agi". Tokens split on "/" ONLY, so a
            -- multi-word value like "tooltip/+3 stamina" is still one token
            -- and still works -- and "container/bag/tooltip/8" is unaffected.
            local nxt = tokens[i + 1]
            if nxt and util.Trim(nxt) ~= "" then
                addPost("tooltip", util.Trim(nxt)); i = i + 1
                -- RUN-ON. Further plain tokens are more needles for the same
                -- filter, so two stats read as
                --     wristbands/tooltip/+3 stam/+3 agi
                -- instead of repeating the keyword. Consecutive operands with
                -- no combinator between them are ANDed (see buy.CompilePost),
                -- which is exactly what the repeated spelling already meant --
                -- so the two spellings parse to the SAME term, and every saved
                -- search written the long way keeps working untouched.
                --
                -- It stops at the first token ParseTerm itself would claim,
                -- which is what keeps "container/bag/tooltip/8" and
                -- "cloak/tooltip/stamina/exact" meaning what they always did.
                --
                -- THE TRADE, plainly: a needle that IS a keyword can no longer
                -- be written bare. "tooltip/Stamina/Weapon" filters tooltips
                -- for Stamina and searches the Weapon CLASS. Repeat the
                -- keyword to say otherwise --
                --     tooltip/Stamina/tooltip/Weapon
                -- -- which is the permanent escape hatch, and the form
                -- buy.TermToQuery falls back to on its own.
                while i < n do
                    local more = util.Trim(tokens[i + 1])
                    if more == ""
                        or buy.IsTermKeyword(string.lower(more), term) then
                        break
                    end
                    addPost("tooltip", more); i = i + 1
                end
            else
                appendWord(raw)
            end
        elseif tok == "and" or tok == "or" or tok == "not" then
            addPost(tok)
        elseif COMPONENT_VALUE[tok] then
            -- Every valued post-filter component reads exactly ONE token, the
            -- way quality and level do, and what that token means is decided
            -- by COMPONENT_VALUE rather than by a branch per component --
            -- `min-level/40`, `rarity/rare`, `seller/Bob`, `left/short`,
            -- `max-unit-buy/5g` all arrive here.
            --
            -- A value that does not parse leaves the component as NAME TEXT
            -- rather than becoming a clause that cannot mean anything. That
            -- is what `quality` and `level` already do, and the reason is the
            -- same: a filter quietly matching nothing is the worst outcome
            -- available, and this addon has shipped it twice.
            local nxt = tokens[i + 1]
            local v = nxt and buy.ParseComponentValue(tok, nxt)
            if v ~= nil then
                addPost(tok, v); i = i + 1
            else
                appendWord(raw)
            end
        elseif PENDING_COMPONENT[tok] then
            -- Reserved component names. They parse and round-trip so a query
            -- containing one survives an edit, but they narrow nothing yet --
            -- CompileOperand returns "always true" for them and the builder
            -- draws them as inert. Emitting them silently as NAME text would
            -- be worse: the search would quietly become a name search.
            local nxt = tokens[i + 1]
            if nxt and util.Trim(nxt) ~= "" then
                addPost(tok, util.Trim(nxt)); i = i + 1
            else
                addPost(tok, "")
            end
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
            -- "leather/armor" leaves "leather" as name text.
            --
            -- No tooltip guard is needed any more: `tooltip` consumes its own
            -- value token, so a category word can never be reached while
            -- "inside" a tooltip clause. Searching tooltips for the literal
            -- word "bag" still works -- it is the tooltip token's value.
            elseif not term.class
                and ResolveCategory(cats.classes, tok) then
                term.class = ResolveCategory(cats.classes, tok)
            elseif term.class and not term.subclass
                and ResolveCategory(cats.subclasses[term.class], tok) then
                term.subclass = ResolveCategory(cats.subclasses[term.class], tok)
            elseif term.class and not term.slot
                and ResolveCategory(SlotsFor(term.class, term.subclass), tok) then
                term.slot = ResolveCategory(SlotsFor(term.class, term.subclass), tok)
            else
                appendWord(raw)
            end
        end
        i = i + 1
    end

    term.name = util.Trim(table.concat(term.nameWords, " "))
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
    -- Post-filter entries, in the order the user assembled them. Order is
    -- load-bearing here: the combinators sit BETWEEN operands, so re-ordering
    -- would change the meaning rather than just the spelling.
    --
    -- These no longer have to come last. `tooltip` consumes exactly one token
    -- now, so nothing after it can be swallowed -- which is what made the old
    -- "tooltip must be emitted last" rule necessary.
    local pi = 1
    while pi <= table.getn(term.post or {}) do
        local e = term.post[pi]
        if e.kind == "and" or e.kind == "or" or e.kind == "not" then
            add(e.kind)
        elseif e.kind == "tooltip" then
            -- SHORT FORM for a run-on: a needle that follows another needle
            -- with no combinator between them is emitted bare, so what you
            -- typed is what you get back out of the builder and the saved
            -- search list.
            --
            -- Two guards, and both are load-bearing. A needle that reads as a
            -- keyword must keep its own "tooltip/" or the round trip would
            -- quietly turn a filter into a class search -- and the previous
            -- entry has to be a tooltip OPERAND, not a combinator, because
            -- "tooltip/A/or/B" would leave B as name text.
            --
            -- The keyword question is asked against `term` because the
            -- categories are emitted ABOVE this loop: whatever class,
            -- subclass and slot the term carries are exactly what will be
            -- resolved by the time a re-parse reaches this token.
            local v = tostring(e.value)
            local prev = term.post[pi - 1]
            if v ~= "" and prev and prev.kind == "tooltip"
                and not buy.IsTermKeyword(string.lower(v), term) then
                add(v)
            else
                add("tooltip/" .. v)
            end
        elseif e.value ~= nil and e.value ~= "" then
            -- The value's spelling comes from the SAME table the parser read
            -- it with, so a component cannot be written in a form its own
            -- parser will not take back.
            add(e.kind .. "/" .. buy.ComponentValueText(e.kind, e.value))
        else
            add(e.kind)
        end
        pi = pi + 1
    end

    return table.concat(parts, "/")
end

-- Do two post-filter lists mean the same thing? Element-wise, in order.
local function PostEqual(a, b)
    a, b = a or {}, b or {}
    if table.getn(a) ~= table.getn(b) then return false end
    local i = 1
    while i <= table.getn(a) do
        if a[i].kind ~= b[i].kind then return false end
        -- Money values are numbers, tooltip values strings; compare as
        -- written, but case-insensitively for text so "+3 Int" and "+3 int"
        -- are the same filter (the matcher lowercases anyway).
        local av, bv = a[i].value, b[i].value
        if type(av) == "string" and type(bv) == "string" then
            if string.lower(av) ~= string.lower(bv) then return false end
        elseif av ~= bv then
            return false
        end
        i = i + 1
    end
    return true
end

-- Two parsed terms mean the same search? Used by the builder's round-trip
-- check, and by its tests, because string equality is the wrong comparison
-- (see TermToQuery).
function buy.TermsEqual(a, b)
    if not a or not b then return false end
    if not PostEqual(a.post, b.post) then return false end
    local keys = { "name", "exact", "usable", "buyoutOnly", "stackOnly",
                   "stackSize", "quality", "minLevel", "maxLevel",
                   "class", "subclass", "slot" }
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

-- ---------------------------------------------------------------------------
-- Post-filter compilation (ROADMAP 2i)
-- ---------------------------------------------------------------------------

-- Stat abbreviations people actually type, and the words tooltips actually
-- use. Typing either form finds both, so "+3 agi" and "+3 Agility" are the
-- same search.
--
-- The pairs are checked FULL-FIRST on purpose: "int" is a substring of
-- "intellect", so expanding short->full without that check would turn
-- "+3 intellect" into "+3 intellectellect". Same trap for spi/spirit.
local STAT_FORMS = {
    { short = "stam", full = "stamina" },
    { short = "agi",  full = "agility" },
    { short = "str",  full = "strength" },
    { short = "int",  full = "intellect" },
    { short = "spi",  full = "spirit" },
}

-- Every spelling of `text` worth looking for, lowercased. Always includes the
-- text as typed; adds the other form of any stat word it recognises.
--
-- Expansion only ever ADDS needles, so a false recognition ("printer" ->
-- "printellect") costs nothing: the extra needle simply never matches.
function buy.TooltipNeedles(text)
    local out = {}
    if not text or text == "" then return out end
    local low = string.lower(text)
    table.insert(out, low)
    local i = 1
    while i <= table.getn(STAT_FORMS) do
        local f = STAT_FORMS[i]
        -- gsub returns (string, count). Passing it straight to table.insert
        -- hands over THREE arguments and Lua reads the count as the position
        -- -- "bad argument #2 to 'insert' (number expected, got string)".
        -- Bind it to a single local first. Same family as the `and`
        -- truncation trap noted in ROADMAP 2a.
        local alt
        if string.find(low, f.full, 1, true) then
            alt = string.gsub(low, f.full, f.short)
        elseif string.find(low, f.short, 1, true) then
            alt = string.gsub(low, f.short, f.full)
        end
        if alt then table.insert(out, alt) end
        i = i + 1
    end
    return out
end

-- Turn one post-filter entry into a predicate(row, stats).
-- A component could not JUDGE this row, which is not the same as the row not
-- matching: the data it needs is not there.
--
-- The row is dropped -- a positive filter cannot honestly keep what it cannot
-- verify -- but never SILENTLY. Counted here, confessed by the status line
-- through buy.UnansweredSummary. An unexplained empty page is
-- indistinguishable from a broken filter, which is precisely how bare `stack`
-- got reported, and the same confession is why that report was actionable.
--
-- Returns false so a predicate can end with `return Unanswered(...)`.
local function Unanswered(stats, kind)
    if not stats then return false end
    stats.unanswered = stats.unanswered or {}
    stats.unanswered[kind] = (stats.unanswered[kind] or 0) + 1
    return false
end

-- What actually FIXES each kind of ignorance. Getting this wrong is worse
-- than saying nothing: telling someone to search again for a vendor price
-- sends them round a loop that cannot succeed, because 1.12's GetItemInfo has
-- no sell price and the only source is standing at a merchant.
local UNANSWERED_FIX = {
    ["seller"]        = "search again",
    ["left"]          = "search again",
    ["percent"]       = "scan to learn its price",
    ["vendor-profit"] = "learned at a merchant, seen in the sell slot, or install ClassicAPI",
    -- Two causes, one remedy line. A disenchant value needs the item's LEVEL
    -- (which a disenchant teaches) and its materials' PRICES (which a scan
    -- teaches), and the filter cannot tell a caller which half it was missing
    -- without inventing a component name for it. Naming both is honest; the
    -- two strings are identical so the two components still combine into one
    -- sentence rather than tripping the mixed-causes guard.
    ["disenchant-profit"]  = "install ClassicAPI, disenchant one, or scan"
                             .. " its materials",
    ["disenchant-percent"] = "install ClassicAPI, disenchant one, or scan"
                             .. " its materials",
}

-- How many rows were dropped for want of data, which components could not
-- answer, and what would fix it -- "3", "seller", "search again" for a page
-- whose owner names have not resolved yet.
--
-- Returns 0, "" when everything could be judged, so the caller appends
-- nothing in the ordinary case. The component names are sorted, so the same
-- page always produces the same sentence rather than one that reshuffles on
-- every repaint.
--
-- The advice is only offered when every unanswered component wants the SAME
-- remedy. Two kinds of ignorance with two different cures cannot be summed up
-- in one clause, and picking either one would be telling half the people
-- reading it to do the wrong thing.
function buy.UnansweredSummary(stats)
    local counts = stats and stats.unanswered
    if not counts then return 0, "" end
    local total, names, fix, mixed = 0, {}, nil, false
    for kind, n in pairs(counts) do
        if n and n > 0 then
            total = total + n
            table.insert(names, kind)
            local f = UNANSWERED_FIX[kind]
            if fix and f ~= fix then mixed = true end
            fix = f or fix
        end
    end
    if total == 0 then return 0, "" end
    table.sort(names)
    if mixed then fix = nil end
    return total, table.concat(names, "/"), fix
end

local function CompileOperand(e)
    if e.kind == "tooltip" then
        local needles = buy.TooltipNeedles(e.value)
        return function(row)
            local n = 1
            while n <= table.getn(needles) do
                if TooltipContainsAt(row.index, needles[n]) then return true end
                n = n + 1
            end
            return false
        end
    elseif e.kind == "max-unit-buy" then
        local cap = e.value
        return function(row) return row.unit and row.unit <= cap end
    elseif e.kind == "min-unit-buy" then
        local floorV = e.value
        return function(row) return row.unit and row.unit >= floorV end

    -- ---- filters over data the page already carries ---------------------
    -- Every one of these reads a field buy.ReadPage captured from
    -- GetAuctionItemInfo (plus GetAuctionItemTimeLeft). No item query, no
    -- price DB, no client cache -- so they answer on the first search for any
    -- item, however cold the client is, and they cost nothing per row.
    --
    -- The `level` and `quality` the SERVER filters on are still there and
    -- still preferable when they will do. These exist because a server-side
    -- filter is part of the query and cannot be OR'd or negated: only a
    -- post-filter can say "level 40 or over, but not epics".
    elseif e.kind == "min-level" then
        local floorV = e.value
        return function(row, stats)
            if not row.level then return Unanswered(stats, "min-level") end
            return row.level >= floorV
        end
    elseif e.kind == "max-level" then
        local cap = e.value
        return function(row, stats)
            if not row.level then return Unanswered(stats, "max-level") end
            return row.level <= cap
        end
    elseif e.kind == "rarity" then
        -- EXACTLY this quality, not "this or better".
        --
        -- The server-side `quality/N` is already the minimum -- it is the
        -- form's own "Min Quality" -- so a post-filter minimum would be a
        -- second way to say a thing that already had one. Exact is what you
        -- cannot otherwise express: "rares, and not the epics above them".
        local want = e.value
        return function(row, stats)
            if not row.quality then return Unanswered(stats, "rarity") end
            return row.quality == want
        end
    elseif e.kind == "seller" then
        -- Case-insensitive SUBSTRING, so a partial name works the way the
        -- name search does. Plain find (the 4th arg), never a pattern: a
        -- seller called "Mr.X" would otherwise be a regex.
        local needle = string.lower(tostring(e.value or ""))
        return function(row, stats)
            -- owner is nil until the name resolves -- CLAUDE.md rule 8. That
            -- is a "cannot answer", not a "does not match".
            if not row.owner or row.owner == "" then
                return Unanswered(stats, "seller")
            end
            return string.find(string.lower(row.owner), needle, 1, true) ~= nil
        end
    -- ---- filters that need the PRICE DB ---------------------------------
    -- These two are the first components that can be defeated by our own
    -- ignorance rather than by the auction. A row we have no market value or
    -- no vendor price for is not a row that fails the test -- it is a row we
    -- cannot test -- so it goes through Unanswered and gets confessed.
    --
    -- A BID-ONLY row is a different case and is NOT confessed. It has no unit
    -- price because the seller did not set a buyout, which is a fact about
    -- the auction that is visible on the row itself and that no amount of
    -- scanning will change. Counting those would put the note on nearly every
    -- search and it would stop meaning anything. Same treatment max-unit-buy
    -- has always given them.
    elseif e.kind == "percent" then
        -- AT MOST this percentage of market value, so `percent/80` is
        -- "a fifth under the going rate or better". A ceiling rather than a
        -- band, for the same reason `left` is a bound: it answers the
        -- question people actually have, and `not/percent/80` still gives
        -- the other side of it.
        local cap = e.value
        return function(row, stats)
            if not row.unit then return false end       -- bid-only
            local m = row.itemId and A.db.MarketValue(row.itemId)
            if not m or m <= 0 then return Unanswered(stats, "percent") end
            return (row.unit / m) * 100 <= cap
        end
    elseif e.kind == "vendor-profit" then
        -- AT LEAST this much per item over what a merchant pays, so
        -- `vendor-profit/50s` finds what you can buy and vendor for 50s each.
        -- Both figures are per unit, which is the only comparison that means
        -- anything across different stack sizes.
        --
        -- Vendor prices are learned by standing at a merchant -- 1.12's
        -- GetItemInfo has no sell price -- so an item you have never seen
        -- sold is genuinely unanswerable, and re-scanning the auction house
        -- will not help. The status line says so separately.
        local floorV = e.value
        return function(row, stats)
            if not row.unit then return false end       -- bid-only
            local v = row.itemId and A.db.GetVendor(row.itemId)
            if not v or v <= 0 then
                return Unanswered(stats, "vendor-profit")
            end
            return (v - row.unit) >= floorV
        end
    -- ---- filters that need the DISENCHANT rule --------------------------
    -- These cost one GetItemInfo per row, which nothing else in this list
    -- does -- the rest read page data the client already holds. That is
    -- affordable because it happens only when one of these components is in
    -- the term, on a page the user explicitly asked to filter this way, and
    -- because the `tooltip` component beside them already scans a whole
    -- tooltip per row. It is not affordable to make it unconditional, so do
    -- not "helpfully" hoist it into ReadPage.
    --
    -- A row we cannot value is UNANSWERED, never a zero. Treating an unknown
    -- disenchant value as nothing would make `disenchant-profit/1g` quietly
    -- reject every item Aegis has not learned yet, which looks exactly like
    -- "there is nothing profitable" -- the most misleading answer available.
    elseif e.kind == "disenchant-profit" then
        -- AT LEAST this much per item over the buyout, so
        -- `disenchant-profit/50s` finds what you can buy, break, and come out
        -- 50s ahead on. Both figures are per unit: a disenchant value is per
        -- ITEM (each break rolls the table again), and row.unit is per item,
        -- so they are already the same currency.
        local floorV = e.value
        return function(row, stats)
            if not row.unit then return false end       -- bid-only
            local value = row.itemId
                and A.de and A.de.ValueOf(row.itemId, A.de.MarketPrice)
            if not value then
                return Unanswered(stats, "disenchant-profit")
            end
            return (value - row.unit) >= floorV
        end
    elseif e.kind == "disenchant-percent" then
        -- AT MOST this percentage of what it disenchants for, mirroring
        -- `percent` against market value: `disenchant-percent/70` is "costs
        -- at most 70% of what breaking it yields".
        local cap = e.value
        return function(row, stats)
            if not row.unit then return false end       -- bid-only
            local value = row.itemId
                and A.de and A.de.ValueOf(row.itemId, A.de.MarketPrice)
            if not value or value <= 0 then
                return Unanswered(stats, "disenchant-percent")
            end
            return (row.unit / value) * 100 <= cap
        end
    elseif e.kind == "left" then
        -- AT MOST this much time left: `left/short` is what is about to
        -- expire, `left/long` is everything except the freshly posted.
        --
        -- A bound rather than an exact match because the question people
        -- actually have is "what is ending soon", and because a bound
        -- composes -- exactly-medium is still reachable as
        -- `left/medium/not/left/short`.
        local cap = e.value
        return function(row, stats)
            -- Guarded in ReadPage, so a server that does not answer
            -- GetAuctionItemTimeLeft costs the filter, not the scan.
            if not row.timeLeft then return Unanswered(stats, "left") end
            return row.timeLeft <= cap
        end
    end
    -- Unknown component: never narrows the search. Refusing to match would
    -- empty the page for a token we simply do not implement yet.
    return function() return true end
end

-- Compile an ordered post-filter list into ONE predicate, or nil when empty.
--
-- Semantics, decided with the owner and mirrored by the builder UI:
--   * consecutive operands are ANDed -- stacking two tooltip lines means one
--     item carrying BOTH, which is the common case and needs no typing;
--   * an explicit `and` / `or` between operands overrides that;
--   * `not` is unary and applies to the operand that follows it;
--   * evaluation is strictly LEFT TO RIGHT with no precedence, so
--     "A or B and C" is "(A or B) and C". No precedence table means nothing
--     to remember, and the builder shows the list in the order it applies.
--
-- Parsed ONCE here, not per row: TooltipContainsAt is the expensive call in
-- this addon and a page can hold 50 rows.
function buy.CompilePost(entries)
    entries = entries or {}
    if table.getn(entries) == 0 then return nil end

    local ops = {}          -- { { join = "and"|"or", neg = bool, fn = pred } }
    local i, n = 1, table.getn(entries)
    local pendingJoin = nil
    while i <= n do
        local e = entries[i]
        if e.kind == "and" or e.kind == "or" then
            pendingJoin = e.kind
            i = i + 1
        elseif e.kind == "not" then
            -- Collect a run of `not`s; two cancel.
            local neg = false
            while i <= n and entries[i].kind == "not" do
                neg = not neg
                i = i + 1
            end
            if i <= n then
                table.insert(ops, { join = pendingJoin or "and", neg = neg,
                                    fn = CompileOperand(entries[i]) })
                pendingJoin = nil
                i = i + 1
            end
        else
            table.insert(ops, { join = pendingJoin or "and", neg = false,
                                fn = CompileOperand(e) })
            pendingJoin = nil
            i = i + 1
        end
    end
    if table.getn(ops) == 0 then return nil end

    return function(row, stats)
        local acc = nil
        local k = 1
        while k <= table.getn(ops) do
            local o = ops[k]
            -- Short-circuit: skip the operand entirely when the running
            -- result already decides it. This is what keeps an `or` chain
            -- from running a tooltip scan it does not need.
            local skip = (acc == true and o.join == "or")
                or (acc == false and o.join == "and")
            if not skip then
                local v = o.fn(row, stats) and true or false
                if o.neg then v = not v end
                if acc == nil then
                    acc = v
                elseif o.join == "or" then
                    acc = acc or v
                else
                    acc = acc and v
                end
            end
            k = k + 1
        end
        if acc == nil then return true end
        return acc
    end
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
        -- 1 or nil -- NEVER a boolean, and never 0.
        --
        -- This shipped as `and true or nil` and the Usable box did nothing.
        -- The flag args are not booleans on 1.12: a CheckButton reports 1 or
        -- nil, and the stock browse UI passes GetChecked() straight into this
        -- slot, so `true` is a shape the client is never handed. It is
        -- perfectly legal Lua, which is why nothing noticed.
        --
        -- 0 is NOT the way to say "off", however natural it looks next to a 1.
        -- 0 is TRUTHY in Lua, so a client reading this slot as a flag rather
        -- than a number would take it as "usable only" and silently narrow
        -- EVERY search -- results that still look plausible, which is worse
        -- than the bug being fixed. nil is right under either reading, it is
        -- what CLAUDE.md rule 9 requires of every index/flag arg, and it is
        -- what the stock UI and Auctionator both send.
        isUsable = term.usable and 1 or nil,
        quality  = term.quality,
        class    = term.class,
        subclass = term.subclass,
        invType  = term.slot,
    }
    -- Exact only means something when there IS a name. Guarding the empty
    -- string matters because "" is truthy in Lua: `term.exact and
    -- lower(term.name or "")` yields exactName == "" for a nameless term, and
    -- since no listing is named "", that filtered out EVERY row on EVERY page
    -- -- an Exact checkbox ticked with an empty Name field could never return
    -- a single result, whatever else the form said.
    local exactName
    if term.exact and term.name and term.name ~= "" then
        exactName = string.lower(term.name)
    end
    local post = buy.CompilePost(term.post)
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
        if post and not post(row, stats) then return false end
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
            -- Time left is NOT one of GetAuctionItemInfo's 12 values; it has
            -- its own call, which stock 1.12.1 FrameXML makes on the very next
            -- line after GetAuctionItemInfo in AuctionFrameBrowse_Update.
            -- Returns 1..4, rendered through AUCTION_TIME_LEFT1..4.
            --
            -- This is page data the client already holds, not an item-cache
            -- lookup, so it adds no per-item query to a loop that is already
            -- state-gated (HARD RULE 16). Guarded anyway: a server that does
            -- not answer it should cost the column, not the scan.
            local timeLeft
            if GetAuctionItemTimeLeft then
                local okT, v = pcall(GetAuctionItemTimeLeft, "list", i)
                if okT then timeLeft = v end
            end
            table.insert(rawRows, {
                index   = i,
                name    = name,
                texture = texture,
                count   = count,
                quality = quality,
                canUse  = canUse,
                level   = level,
                timeLeft = timeLeft,
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

    -- A batch buyout advances HERE, once the page the purchase invalidated has
    -- been re-read -- never straight after PlaceAuctionBid. Stepping earlier
    -- would pick an index out of the page we already know is stale, which is
    -- the whole bug the batch exists to avoid.
    if buy.batch and buy.batch.active then
        buy.BatchStep()
    end
end

-- The listing at `row.index` still matches what we displayed (guards against
-- the page shifting between read and click).
function buy.Verify(row)
    local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", row.index)
    return name == row.name and count == row.count
        and (buyout or 0) == row.buyout
end

-- ---------------------------------------------------------------------------
-- Batch buyout
--
-- THE PROBLEM. 1.12 has no bulk buy. Each buyout is PlaceAuctionBid against an
-- INDEX into the page the client currently holds, and a successful purchase
-- removes that auction and re-sends the page -- so every index after it shifts
-- down by one. Walking a list of captured indices therefore buys the WRONG
-- auctions from the second purchase onward. That is the worst bug this addon
-- could have: it spends real gold on something nobody chose.
--
-- WHY MATCHING BY IDENTITY IS THE WRONG GOAL. There is no auction ID on 1.12.
-- The obvious fix -- re-find "the same auction" after each purchase -- cannot
-- be done, and chasing it leads to the trap in the live screenshot: eleven
-- Linen Bandage auctions at 8c each are INDISTINGUISHABLE from one another.
--
-- WHAT IS ACTUALLY REQUIRED. The buyer does not care which of eleven identical
-- 8c auctions they get. They care that they never pay for something they did
-- not pick. So the safety property is not identity, it is:
--
--     every purchase matches the (name, count, buyout) of a ticked row,
--     and no more than the ticked COUNT of each such fingerprint is bought.
--
-- That is satisfiable, and it is what this implements: the batch is a multiset
-- of fingerprints with remaining counts. Each step re-reads the CURRENT page,
-- finds any index whose fingerprint is still owed, buys exactly that index,
-- decrements, and waits for the page to settle before the next step. Nothing
-- is ever bought against a stale index -- the index is re-derived from the
-- live page every single time.
--
-- Anything unexpected ABORTS rather than guessing: a fingerprint that is owed
-- but no longer present (someone else bought it, or the page moved) stops the
-- batch and reports what completed. Partial completion is fine and expected;
-- silent substitution is not.
-- ---------------------------------------------------------------------------

-- A fingerprint identifies a KIND of auction, not an instance. Deliberately
-- the same three fields buy.Verify compares, so a row that passes Verify at
-- its own index also matches its own fingerprint.
function buy.Fingerprint(row)
    return (row.name or "") .. "\001" .. (row.count or 1)
        .. "\001" .. (row.buyout or 0)
end

-- Scan the CURRENT page for an index whose fingerprint is `fp`. Returns the
-- index, or nil. This is what replaces trusting a captured index.
function buy.FindByFingerprint(fp)
    local n = GetNumAuctionItems("list")
    local i = 1
    while i <= (n or 0) do
        local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
        if name then
            local here = name .. "\001" .. (count or 1) .. "\001" .. (buyout or 0)
            if here == fp then return i end
        end
        i = i + 1
    end
    return nil
end

buy.batch = { active = false }

-- Total cost of `rows`, and whether the player can cover it.
function buy.BatchCost(rows)
    local total, n = 0, 0
    local i = 1
    while i <= table.getn(rows) do
        local r = rows[i]
        if r.buyout and r.buyout > 0 and not r.mine then
            total = total + r.buyout
            n = n + 1
        end
        i = i + 1
    end
    return total, n
end

-- Start a batch buyout of `rows`. Returns (true) or (false, reason).
-- The search text that means "this item and nothing else".
--
-- BRACKETS, because the box has to show something a person can read and retype.
-- `/exact/Greater Mana Potion` says the same to the parser and nothing at all
-- to somebody who has not read the docs.
--
-- An empty name gives an empty term rather than "[]", which would parse as a
-- name search for a literal pair of brackets and quietly match nothing -- the
-- exact failure the exact-filter guard at buy.CompileTerm exists to avoid.
function buy.ExactTerm(name)
    name = util.Trim(name or "")
    if name == "" then return "" end
    return "[" .. name .. "]"
end

-- ---------------------------------------------------------------------------
-- Grouping a page of listings into one row per item
-- ---------------------------------------------------------------------------

-- Aggregate listings into ONE ROW PER ITEM, each carrying the listings that
-- make it up.
--
-- Returned in the order items were FIRST SEEN, not sorted: the caller sorts
-- for display and the two jobs do not belong in one function -- ui.SortResults
-- already owns the second one.
--
-- KEYED BY ITEM ID WHEN THERE IS ONE, and by name only when there is not.
-- Different items can share a name on this client -- a recipe and the thing it
-- teaches, most obviously -- and merging those totals two separate markets
-- into one price. The id is authoritative; the name is the fallback for a row
-- whose link has not resolved yet, which is a real state on 1.12 and not an
-- error.
--
-- `low` is the lowest UNIT BUYOUT, which is the lowest price you can actually
-- pay to take one home. A bid-only auction still counts as a LISTING -- it is
-- on the auction house and the parent row says how many are -- but it cannot
-- set the lowest available price, because there is no price at which you can
-- have it. Counting it would quote a number nobody can buy at.
function buy.GroupListings(rows)
    local groups, byKey = {}, {}
    local i = 1
    while i <= table.getn(rows or {}) do
        local r = rows[i]
        local key = r.itemId and ("i" .. r.itemId) or ("n" .. (r.name or "?"))
        local g = byKey[key]
        if not g then
            g = { key = key, name = r.name, itemId = r.itemId,
                  texture = r.texture, quality = r.quality, level = r.level,
                  listings = 0, units = 0, low = nil, rows = {} }
            byKey[key] = g
            table.insert(groups, g)
        end
        g.listings = g.listings + 1
        g.units = g.units + (r.count or 1)
        if r.unit and r.unit > 0 then
            if not g.low or r.unit < g.low then g.low = r.unit end
        end
        table.insert(g.rows, r)
        i = i + 1
    end
    return groups
end

-- ---------------------------------------------------------------------------
-- What you have bought this session
-- ---------------------------------------------------------------------------

-- Auction house purchases since login, by item.
--
-- IN MEMORY ONLY, and that IS the definition of "this session": it lives from
-- login to logout and is never written to SavedVariables. The History ledger
-- is the durable record of what was spent; this is the scratch number that
-- answers "how many have I got so far" while you are still shopping, and a
-- persisted one would answer that question wrongly the next day.
--
-- It deliberately does NOT reset when the auction house closes. Buying out a
-- crafting run takes several trips to the auctioneer, and a counter that
-- cleared on the way out would clear in the middle of the thing it counts --
-- the same reasoning that made the crafting tally manual-only.
--
-- COUNTS UNITS, NOT AUCTIONS. Buying a stack of twenty Fine Thread is twenty
-- thread. "How many have I bought" is a question about items, and answering it
-- with a number of auctions is the kind of wrong that looks right.
buy.session = {}   -- itemId -> { n = units, spent = copper, name = "..." }

-- Book one purchase.
--
-- Called from the ENGINE, at the two places an auction is actually bought,
-- rather than from the UI beside the ledger write. The engine holds every fact
-- this needs -- the id, the stack size, the price -- and a purchase made
-- through a path that forgot to book it would be counted by neither. It also
-- means the tally is reachable from a suite, which ui/frame.lua is not.
function buy.RecordPurchase(itemId, name, stack, copper)
    if not itemId then return nil end
    stack = stack or 1
    if stack < 1 then stack = 1 end
    local rec = buy.session[itemId]
    if not rec then
        rec = { n = 0, spent = 0, name = name }
        buy.session[itemId] = rec
    end
    rec.n     = rec.n + stack
    rec.spent = rec.spent + (copper or 0)
    if name then rec.name = name end
    return rec.n, rec.spent
end

-- Units and copper bought this session for one item. ALWAYS two numbers, so no
-- caller has to branch on nil to render a zero.
function buy.SessionBought(itemId)
    local rec = itemId and buy.session[itemId]
    if not rec then return 0, 0 end
    return rec.n, rec.spent
end

function buy.ClearSession()
    buy.session = {}
end

-- The one item a result set is about, or nil when it is about several.
--
-- The status line NAMES an item, so it may only do that when there is one to
-- name. A search for "cloth" returns Linen, Wool and Silk; reporting one of
-- their tallies beside all three would be a true number attached to the wrong
-- thing, which is worse than no number.
function buy.SoleItemId(rows)
    local id = nil
    local i = 1
    while i <= table.getn(rows or {}) do
        local r = rows[i]
        if r.itemId then
            if id and r.itemId ~= id then return nil end
            id = r.itemId
        end
        i = i + 1
    end
    return id
end

function buy.StartBatch(rows, onDone, onStep)
    if buy.batch.active then return false, "A buyout is already running." end
    if not rows or table.getn(rows) == 0 then
        return false, "Nothing selected."
    end
    local total, n = buy.BatchCost(rows)
    if n == 0 then return false, "Nothing selected has a buyout price." end
    if GetMoney and total > (GetMoney() or 0) then
        return false, "Not enough gold for the whole selection."
    end
    -- Collapse to a multiset: fingerprint -> how many of that kind to buy.
    local owed, order = {}, {}
    local i = 1
    while i <= table.getn(rows) do
        local r = rows[i]
        if r.buyout and r.buyout > 0 and not r.mine then
            local fp = buy.Fingerprint(r)
            if not owed[fp] then
                -- `stack` and `itemId` ride along for the session tally. Safe
                -- to keep on the bucket rather than per row: the fingerprint
                -- keys on name, stack size and price, so everything collapsed
                -- into one bucket is the same item at the same stack size.
                owed[fp] = { count = 0, price = r.buyout, name = r.name,
                             itemId = r.itemId, stack = r.count or 1 }
                table.insert(order, fp)
            end
            owed[fp].count = owed[fp].count + 1
        end
        i = i + 1
    end
    buy.batch = {
        active = true, owed = owed, order = order,
        bought = 0, spent = 0, want = n, total = total,
        onDone = onDone, onStep = onStep,
    }
    return buy.BatchStep()
end

function buy.AbortBatch(reason)
    local b = buy.batch
    if not b.active then return end
    b.active = false
    if b.onDone then b.onDone(b.bought, b.want, b.spent, reason) end
end

-- One purchase. Called to start the batch and again each time the page
-- settles after a buy.
function buy.BatchStep()
    local b = buy.batch
    if not b.active then return false, "No batch running." end

    -- Find the next fingerprint still owed that is actually ON the page now.
    local fp, info, index
    local oi = 1
    while oi <= table.getn(b.order) do
        local f = b.order[oi]
        local rec = b.owed[f]
        if rec and rec.count > 0 then
            local at = buy.FindByFingerprint(f)
            if at then fp, info, index = f, rec, at; break end
            -- Owed but gone: someone else took it, or the page moved under
            -- us. Stop -- do NOT fall through to a different auction.
            buy.AbortBatch("A selected auction is no longer available.")
            return false, "gone"
        end
        oi = oi + 1
    end
    if not fp then
        b.active = false
        if b.onDone then b.onDone(b.bought, b.want, b.spent, nil) end
        return true
    end

    -- Gold is re-checked before EVERY purchase, not just at the start. The
    -- opening check can be stale by now: mail, repairs and other windows all
    -- move money while an auction house is open.
    if GetMoney and info.price > (GetMoney() or 0) then
        buy.AbortBatch("Ran out of gold partway through.")
        return false, "gold"
    end

    info.count = info.count - 1
    b.bought = b.bought + 1
    b.spent = b.spent + info.price

    local st = buy.state
    st.phase   = "wait_results"
    st.timeout = buy.TIMEOUT
    buy.driver:Show()
    PlaceAuctionBid("list", index, info.price)
    buy.RecordPurchase(info.itemId, info.name, info.stack, info.price)
    -- Reported per PURCHASE, with what was bought, so the caller can book each
    -- one as it happens. Booking the whole batch at the end would lose
    -- everything bought before an abort -- and an abort is the case where an
    -- accurate ledger matters most.
    if b.onStep then b.onStep(b.bought, b.want, info.name, info.price) end
    return true
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
    buy.RecordPurchase(row.itemId, row.name, row.count, row.buyout)
    -- ...AND THE LEDGER, here rather than in the caller. ui.DoBuyout used to
    -- own this line, so the OTHER way into this function -- a bid that the
    -- server would treat as a buyout -- spent the gold and never appeared in
    -- History at all. One writer beside the session tally it has to agree
    -- with; the batch path books its own per purchase and never comes
    -- through here.
    if A.db and A.db.RecordTxn then
        A.db.RecordTxn("buy", row.name, row.buyout, row.itemId)
    end
    return true
end

-- Would a bid of `amount` on `row` actually BUY it?
--
-- Pure, and deliberately separate from buy.Bid, because the UI has to be able
-- to ask this BEFORE it puts a dialog on screen. The whole fault this exists
-- for was a dialog that asked one question and performed another.
function buy.BidIsBuyout(row, amount)
    if not row then return false end
    local out = row.buyout or 0
    if out <= 0 then return false end
    amount = amount or row.nextBid or 0
    return amount >= out
end

-- Place a bid of `amount` (defaults to the minimum next bid) on `row`.
--
-- IT REFUSES TO BUY. On 1.12, PlaceAuctionBid with an amount at or above the
-- buyout is not a bid -- the server sells you the item. This function used to
-- notice that and quietly call buy.Buyout, so the dialog said "Bid on Meat
-- Cleaver? bid 1g 99s 98c", the player pressed Bid, and 1g 99s 98c left the
-- bag as a purchase.
--
-- It is not a rare corner. An auction posted with its start bid equal to its
-- buyout has nextBid == buyout, which is an ordinary posting and exactly what
-- our own Sell tab produces when both prices are set the same -- so on those
-- listings the Bid button was a second Buy button.
--
-- The engine now says no and names the reason; the CALLER decides whether to
-- offer the buyout, and asks the question it is actually going to perform.
-- See ui.ConfirmBid.
function buy.Bid(row, amount)
    if not row then return false, "No auction selected." end
    if row.mine then return false, "That's your own auction." end
    amount = amount or row.nextBid
    if not amount or amount < row.nextBid then
        return false, "Bid is below the minimum."
    end
    if buy.BidIsBuyout(row, amount) then
        return false,
            "That is at or above the buyout \226\128\148 it would buy it outright."
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

-- Recipes for demo mode. See db.DemoSeries for the discipline: consulted
-- INSTEAD of the store, never written to it, so nothing generated can reach a
-- real save.
--
-- REAL ITEM IDS, so the client colours the names by quality and shows the
-- icons it has cached -- a demo drawn from made-up ids is a demo of the "item
-- not cached" path, which is not the path anyone wants to look at.
--
-- CHOSEN TO EXERCISE THE LIST, not just to fill it. Bolt of Linen Cloth is
-- both a project AND a reagent of the Linen Bag above it, which is the
-- sub-reagent expansion; Coarse Thread and Empty Vial are vendor-sold, so the
-- shopping list has to pick a source for each line; and the quantities differ
-- enough that the shortfall arithmetic has something to do.
craft.DEMO_PROJECTS = {
    { name = "Linen Bag", itemId = 4238, want = 4, reagents = {
        { name = "Bolt of Linen Cloth", itemId = 2996, count = 3 },
        { name = "Coarse Thread",       itemId = 2320, count = 1 },
    } },
    { name = "Bolt of Linen Cloth", itemId = 2996, want = 2, reagents = {
        { name = "Linen Cloth", itemId = 2589, count = 2 },
    } },
    { name = "Elixir of Fortitude", itemId = 3825, want = 5, reagents = {
        { name = "Wild Steelbloom", itemId = 3355, count = 1 },
        { name = "Stranglekelp",    itemId = 3820, count = 1 },
        { name = "Empty Vial",      itemId = 3371, count = 1 },
    } },
    { name = "Mithril Casing", itemId = 10561, want = 3, reagents = {
        { name = "Mithril Bar", itemId = 3860, count = 3 },
    } },
}

-- What demo mode pretends you are already carrying, by item id.
--
-- SOME OF EACH, NOT ALL AND NOT NONE. A list where every line reads 0 / 12 is
-- a list with no progress on it, and the "12 / 42" a reagent row exists to
-- show is the thing worth looking at.
craft.DEMO_HAVE = {
    [2589] = 14,     -- Linen Cloth
    [2996] = 5,      -- Bolt of Linen Cloth
    [2320] = 2,      -- Coarse Thread
    [3355] = 3,      -- Wild Steelbloom
    [3860] = 4,      -- Mithril Bar
}

function craft.Projects()
    if A.db and A.db.demo then return craft.DEMO_PROJECTS end
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

-- What it costs to CRAFT one of `itemId`, from the recipes captured on the
-- Crafting tab. Returns copper-per-unit, or nil when nothing captured makes
-- this item.
--
-- PER UNIT, not per craft: a recipe that makes four costs a quarter as much per
-- item, and the tooltip sits beside per-unit auction prices. Comparing a
-- four-stack craft cost against one item's buyout is the mistake this divide
-- exists to prevent.
--
-- Only answers when EVERY reagent is priced. A partial total is smaller than
-- the real one, and a crafting cost that reads low is the direction that loses
-- money -- so an incomplete answer is no answer.
--
-- Takes the cheapest where several recipes make the same thing.
function craft.CostForItem(itemId)
    if not itemId then return nil end
    local list = craft.Projects()
    local best, i = nil, 1
    while i <= table.getn(list) do
        local p = list[i]
        if ResolveId(p.itemId, p.name) == itemId then
            local total, complete = craft.CostOf(p)
            if complete and total > 0 then
                local unit = math.floor(total / (p.made or 1))
                if not best or unit < best then best = unit end
            end
        end
        i = i + 1
    end
    return best
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

-- ---------------------------------------------------------------------------
-- How many to make, and what that costs in reagents
-- ---------------------------------------------------------------------------

-- Upper bound on the quantity stepper. Not a game limit -- a guard, so a stuck
-- key or a bad saved value cannot ask for a reagent total that overflows the
-- column it is drawn in.
craft.WANT_MAX = 999

-- How many of the finished item this project is set to make. Defaults to one,
-- so a recipe captured before the stepper existed reads as "one of these".
function craft.Want(project)
    local n = project and project.want
    if not n or n < 1 then return 1 end
    if n > craft.WANT_MAX then return craft.WANT_MAX end
    return n
end

-- Set it, clamped, and persist. Returns the value actually stored.
function craft.SetWant(index, n)
    local s = CStore()
    local p = s and s.projects[index]
    if not p then return nil end
    n = math.floor(tonumber(n) or 1)
    if n < 1 then n = 1 end
    if n > craft.WANT_MAX then n = craft.WANT_MAX end
    p.want = n
    return n
end

-- Nudge it by `delta` and persist. The stepper's whole job.
function craft.StepWant(index, delta)
    local s = CStore()
    local p = s and s.projects[index]
    if not p then return nil end
    return craft.SetWant(index, craft.Want(p) + (delta or 0))
end

-- CRAFTS needed to produce `wanted` finished items from a recipe that yields
-- `made` per craft.
--
-- THE CEIL IS THE WHOLE FUNCTION. The stepper counts finished ITEMS, which is
-- how anyone says it out loud, and for most recipes that is also the number of
-- crafts. They diverge the moment a recipe makes more than one: wanting five of
-- something made in twos is 2.5 crafts, and a truncated 2 shops you one item
-- short EVERY time. The divide is not new -- craft.CostForItem already divides
-- by `made` to get a per-unit cost, for exactly this reason.
function craft.CraftsFor(wanted, made)
    wanted = math.floor(tonumber(wanted) or 1)
    made   = math.floor(tonumber(made) or 1)
    if made < 1 then made = 1 end
    if wanted < 1 then return 0 end
    return math.ceil(wanted / made)
end

-- What `wanted` finished items need, reagent by reagent.
--
-- Returns rows, shortCount. Each row is
--   { name, itemId, per, need, have, short }
-- where `per` is the recipe's own figure, `need` is that times the crafts, and
-- `short` is what you would still have to buy.
--
-- `haveOf` is a function itemId -> how many you own, injected rather than read
-- here -- the same discipline as db.InventoryRows taking live bags. This file
-- knows about recipes and prices; it has no business walking containers, and a
-- caller that can answer exactly is the one that should.
function craft.NeedFor(project, wanted, haveOf)
    local rows, shortCount = {}, 0
    if not project or not project.reagents then return rows, shortCount end
    local crafts = craft.CraftsFor(wanted or craft.Want(project), project.made)
    local i = 1
    while i <= table.getn(project.reagents) do
        local r = project.reagents[i]
        local id = ResolveId(r.itemId, r.name)
        local per = r.count or 1
        local need = per * crafts
        local have = 0
        if haveOf and id then have = haveOf(id) or 0 end
        local short = need - have
        if short < 0 then short = 0 end
        if short > 0 then shortCount = shortCount + 1 end
        table.insert(rows, {
            name = r.name, itemId = id, per = per,
            need = need, have = have, short = short,
        })
        i = i + 1
    end
    return rows, shortCount
end

-- ---------------------------------------------------------------------------
-- The shopping list
-- ---------------------------------------------------------------------------

-- Where to buy one reagent, and what a unit costs there.
--
-- A tie goes to the VENDOR. A vendor's price is fixed and always in stock; an
-- auction at the same money is a listing that may be gone when you get there.
function craft.CheaperSource(vendor, market)
    if vendor and market then
        if vendor <= market then return "vendor", vendor end
        return "ah", market
    end
    if vendor then return "vendor", vendor end
    if market then return "ah", market end
    return nil, nil
end

-- How deep sub-reagent expansion may go.
--
-- A GUARD, not a feature. Recipes can refer to each other in a loop -- a
-- server can define one, and a mis-captured recipe certainly can -- and an
-- unbounded walk would hang the client. Four is deeper than any real crafting
-- chain in this game.
craft.SHOP_MAX_DEPTH = 4

-- Every tracked recipe's reagents, aggregated into ONE list.
--
-- THE AGGREGATION IS THE POINT, and it is the whole difference between a
-- recipe tree and a shopping list. Track three recipes that each want Linen
-- Cloth and the tree shows it three times in three places, so you shop for it
-- three times and still get the total wrong. This says "Linen Cloth 40" once.
--
-- SUB-REAGENTS EXPAND. If you are short of something you can make yourself,
-- what you actually need to BUY is what that recipe needs -- so a shortfall of
-- Bolt of Linen becomes the Linen Cloth to make it, and the bolt is marked as
-- something you craft rather than something you shop for. Only for recipes we
-- hold: we capture those from the profession window, so coverage is whatever
-- you have opened.
--
-- EVERYTHING IS INJECTED -- wantOf, haveOf, recipeFor, vendorOf, marketOf --
-- so this is arithmetic over numbers and tables and a suite can run it without
-- a client. Same discipline as craft.NeedFor, and for the same reason: this
-- file knows about recipes, not about containers or auction houses.
--
-- Returns rows, shortCount. Each row:
--   { name, itemId, need, have, short, from = { recipe names },
--     craftable = true|nil, source = "vendor"|"ah"|nil, unit = copper|nil }
function craft.ShoppingList(projects, opts)
    opts = opts or {}
    local wantOf, haveOf = opts.wantOf, opts.haveOf
    local recipeFor = opts.expand and opts.recipeFor or nil
    local need, from, order = {}, {}, {}

    local function add(id, name, n, why)
        if not id or n <= 0 then return end
        if need[id] == nil then
            need[id] = 0
            from[id] = {}
            table.insert(order, { id = id, name = name })
        end
        need[id] = need[id] + n
        -- WHICH recipes want it, so a row can say why it is on the list. A
        -- linear scan because these lists are a handful of names.
        if why then
            local seen, k = false, 1
            while k <= table.getn(from[id]) do
                if from[id][k] == why then seen = true end
                k = k + 1
            end
            if not seen then table.insert(from[id], why) end
        end
    end

    local function addReagents(p, crafts, why)
        local rs = p.reagents or {}
        local ri = 1
        while ri <= table.getn(rs) do
            local r = rs[ri]
            add(ResolveId(r.itemId, r.name), r.name, (r.count or 1) * crafts, why)
            ri = ri + 1
        end
    end

    -- Pass one: what the tracked recipes themselves ask for.
    local pi = 1
    while pi <= table.getn(projects or {}) do
        local p = projects[pi]
        local want = (wantOf and wantOf(p)) or 1
        addReagents(p, craft.CraftsFor(want, p.made), p.name)
        pi = pi + 1
    end

    -- Passes two and on: replace a shortfall you can craft with what IT needs.
    --
    -- `order` is measured BEFORE each pass, so anything added by this pass is
    -- considered on the NEXT one. That is what makes the depth cap a real
    -- bound rather than a suggestion.
    local crafted = {}
    local depth = 1
    while recipeFor and depth <= craft.SHOP_MAX_DEPTH do
        local grew = false
        local n = table.getn(order)
        local k = 1
        while k <= n do
            local id = order[k].id
            if not crafted[id] then
                local short = need[id] - ((haveOf and haveOf(id)) or 0)
                if short > 0 then
                    local sub = recipeFor(id)
                    if sub then
                        crafted[id] = true
                        grew = true
                        addReagents(sub, craft.CraftsFor(short, sub.made),
                            order[k].name)
                    end
                end
            end
            k = k + 1
        end
        if not grew then break end
        depth = depth + 1
    end

    local rows, shortCount = {}, 0
    local i = 1
    while i <= table.getn(order) do
        local id, nm = order[i].id, order[i].name
        local have = (haveOf and haveOf(id)) or 0
        local short = need[id] - have
        if short < 0 then short = 0 end
        -- A thing you are going to CRAFT is not a thing you are short OF --
        -- its own reagents are already on this list, and counting both would
        -- tell you to buy the bolt and the cloth to make it.
        if short > 0 and not crafted[id] then shortCount = shortCount + 1 end
        local src, unit = craft.CheaperSource(
            opts.vendorOf and opts.vendorOf(id) or nil,
            opts.marketOf and opts.marketOf(id) or nil)
        table.insert(rows, {
            name = nm, itemId = id, need = need[id], have = have, short = short,
            from = from[id], craftable = crafted[id] and true or nil,
            source = src, unit = unit,
        })
        i = i + 1
    end

    -- What you still have to BUY first: that is what the list is for. Then
    -- alphabetical, so a line does not move under the cursor as counts change.
    table.sort(rows, function(a, b)
        local as = (a.short > 0 and not a.craftable) and 1 or 0
        local bs = (b.short > 0 and not b.craftable) and 1 or 0
        if as ~= bs then return as > bs end
        return (a.name or "") < (b.name or "")
    end)
    return rows, shortCount
end

-- ---------------------------------------------------------------------------
-- What you have actually made
-- ---------------------------------------------------------------------------

-- Crafted items since login, by item id.
--
-- IN MEMORY, and MANUAL RESET ONLY -- never on AUCTION_HOUSE_CLOSED. A crafting
-- run spans several trips to the auctioneer, so a counter that cleared on the
-- way out would clear in the middle of the thing it counts. Same reasoning as
-- the Buy tab's session tally.
craft.made = {}

function craft.RecordMade(itemId, n)
    if not itemId then return nil end
    n = math.floor(tonumber(n) or 1)
    if n < 1 then n = 1 end
    craft.made[itemId] = (craft.made[itemId] or 0) + n
    return craft.made[itemId]
end

function craft.MadeCount(itemId)
    return (itemId and craft.made[itemId]) or 0
end

function craft.ClearMade()
    craft.made = {}
end

-- The prefix the client puts in front of a created item, e.g. "You create: ".
--
-- Read from the client's own globals so it works in any locale, with the
-- English literal only as a fallback off Turtle. LOOT_ITEM_CREATED_SELF is
-- "You create: %s." -- everything before the %s is the prefix.
function craft.CreatePrefix(fmt)
    fmt = fmt or LOOT_ITEM_CREATED_SELF or "You create: %s."
    -- PLAIN find, so the needle is the two literal characters "%" and "s".
    -- Escaping it as "%%s" is right for a PATTERN and wrong here: with plain
    -- matching it looks for two percent signs, never matches, and every locale
    -- silently falls back to the English prefix.
    local at = string.find(fmt, "%s", 1, true)
    if not at or at < 2 then return "You create: " end
    return string.sub(fmt, 1, at - 1)
end

-- Did this chat line say we made something? Returns itemId, count.
--
-- THE CREATE MESSAGE IS THE ONLY SIGNAL. 1.12 has no spell-success event to
-- hang a craft counter on, but the client prints the line above to
-- CHAT_MSG_LOOT every time you make something. It is an O(1) string test on an
-- event that does not storm -- and it is the same discipline as the purchase
-- counter: never infer from bags what the game will tell you directly.
--
-- The multiple form is "You create: %sx%d." (no space), so a trailing "x12"
-- after the link is the count.
function craft.ParseCreate(msg)
    if type(msg) ~= "string" then return nil end
    local head = craft.CreatePrefix()
    if string.find(msg, head, 1, true) ~= 1 then return nil end
    local id = util.ItemIdFromLink(msg)
    if not id then return nil end
    -- The count sits after the link's colour terminator ("...|h|rx12."), so
    -- anchor on the END of the line rather than on any part of the link.
    local _, _, n = string.find(msg, "x(%d+)[%.%s]*$")
    return id, tonumber(n) or 1
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

-- You made something. The client prints "You create: [Item]" to CHAT_MSG_LOOT
-- on every craft, and that is the only signal 1.12 offers -- there is no
-- spell-success event on this client.
--
-- REGISTERED AT THE END OF THE FILE, not beside the other handlers. `craft` is
-- a file-scope local declared partway down; a closure written above that line
-- captures the nil GLOBAL of the same name and fails only when it runs. This
-- one did exactly that.
--
-- O(1): one prefix test, and an early return on the loot lines that are not
-- creates, which is nearly all of them.
A.RegisterEvent("CHAT_MSG_LOOT", function()
    local id, n = craft.ParseCreate(arg1)
    if id then
        craft.RecordMade(id, n)
        -- The UI hangs a FLAG-SETTER here, never a repaint. This handler is on
        -- a chat event that prints a line per item, so a big loot lands
        -- several of them in a few frames -- HARD RULE 16, and the same shape
        -- as sell.mailDirty.
        if craft.onMade then craft.onMade(id, n) end
    end
end)
