-- Aegis: Exchange
-- ui/tooltip.lua
--
-- GameTooltip price lines, matching the design/01-scan-strip.png mockup:
--
--   Aegis Market:      1g 40s
--   Aegis Min Buyout:  1g 20s (x20 = 24g)
--
-- Labels use a cool blue accent so the lines read as addon info, distinct
-- from Blizzard's own.
--
-- HOOKING RULE (see CLAUDE.md): NO hooksecurefunc and NO secure hooks. Every
-- hook here SAVES the original function, REPLACES it, and calls the saved
-- original from the replacement.

local A = AegisExchange
A.tooltip = {}
local tooltip = A.tooltip
local util = A.util

-- Cool accent for the left column (design's #5ac8fa).
local ACCENT_R, ACCENT_G, ACCENT_B = 0.35, 0.78, 0.98

-- The amber a 1.12 tooltip uses for a HINT -- the register "Alt+Click to trade
-- with ..." is written in. The sighting count belongs there rather than in
-- grey: it is context for everything under it, not a dimmed afterthought, and
-- grey reads as "ignore me" beside lines that matter.
local HINT_R, HINT_G, HINT_B = 1.0, 0.72, 0.26

-- Verdict colours, as inline escapes because AddDoubleLine takes ONE colour
-- for the whole left string and only the parenthesised clause is being
-- coloured. |r restores the line's own colour, so the label around it stays
-- the accent.
--
-- Green says "destroy it", red says "sell it" -- the two are opposite advice
-- about an irreversible action, so they must not read alike at a glance.
local VERDICT_GOOD = "|cff4cd94c"
local VERDICT_BAD  = "|cffe6663d"

-- Saved originals, keyed by method name.
tooltip.orig = {}

-- Item the tooltip currently describes ({ id, count, source }); consumed by
-- the SetTooltipMoney hook below to learn vendor prices.
tooltip.current = nil

-- Guard so hooks install only once.
tooltip.hooked = false

-- ---------------------------------------------------------------------------
-- The added lines
-- ---------------------------------------------------------------------------

-- Append the Aegis price lines for `itemId` to `gtt` and re-flow it.
-- AddLine/AddDoubleLine do NOT re-layout on their own — Show() is mandatory.
-- A per-line toggle from the Aegis tab. Unset counts as ON, so a save written
-- before these existed keeps showing everything.
local function Want(key)
    if not A.db.Setting then return true end
    return A.db.Setting(key) ~= false
end

function tooltip.Extend(gtt, itemId, count)
    -- Honour the Aegis-tab toggle for tooltip price lines.
    if A.db.Setting and A.db.Setting("tooltip") == false then return end
    local market = Want("tipMarket")    and A.db.MarketValue(itemId) or nil
    local minBuy = Want("tipMinBuyout") and A.db.MinBuyout(itemId)   or nil
    local vendor = Want("tipVendor")    and A.db.GetVendor(itemId)   or nil

    -- Resolved LAST, and only when the line is wanted. It is the one entry
    -- here that costs a GetItemInfo, and a tooltip that ends up showing no
    -- Aegis lines at all should not have paid for one.
    --
    -- de.ValueOf answers nil for everything not disenchantable, everything the
    -- client has not cached, and everything whose item level no source knows
    -- -- which today is most of a bag. That silence is deliberate: an "Aegis
    -- Disenchant: unknown" line on every grey and every trade good would be
    -- noise on hundreds of items to be informative about a handful.
    -- What a captured recipe says one of these costs to make. Nil unless the
    -- player has actually opened the tradeskill and Aegis captured it.
    local craftCost = A.craft and A.craft.CostForItem
        and A.craft.CostForItem(itemId) or nil

    local disenchant, disenchantRows, disenchantSource
    local deUnpriced, deMissingId, deInfo
    if Want("tipDisenchant") and A.de then
        -- The item's CLASS, for the line that frames the split: armour and
        -- weapons break into different things. One lookup, taken only when
        -- this section is wanted at all.
        deInfo = util.ItemInfo(itemId)
        -- One resolve, not two: de.ValueOf hands back WHY it failed alongside
        -- the failure, so the diagnosis below costs nothing extra.
        disenchant, disenchantSource, deUnpriced, deMissingId =
            A.de.ValueOf(itemId, A.de.MarketPrice, deInfo)
        -- The rows are a fact about the ITEM, not about the market, so they do
        -- not depend on the value resolving. Shown when the setting asks for
        -- them, and always available on Shift whatever the setting says.
        local wantRows = (A.db.Setting and A.db.Setting("tipDisenchantRows") == true)
            or (IsShiftKeyDown and IsShiftKeyDown() and true or false)
        if wantRows then
            disenchantRows = A.de.YieldOf(itemId, deInfo)
        end
    end

    if not market and not minBuy and not vendor and not disenchant
        and not disenchantRows and not deUnpriced and not craftCost then
        return
    end

    -- Stack totals: always, or only while Shift is held. Holding Shift is the
    -- familiar gesture for "show me the whole stack" and keeps the tooltip
    -- short when every bag slot is a stack of 20.
    local withStack = count and count > 1
    if withStack and A.db.Setting
        and A.db.Setting("tipStackShift") == true then
        withStack = IsShiftKeyDown and IsShiftKeyDown() and true or false
    end
    local function money(unit)
        local right = util.FormatMoney(unit, true)
        if withStack then
            right = right .. " (x" .. count .. " = "
                .. util.FormatMoney(unit * count, true) .. ")"
        end
        return right
    end

    -- ---------------------------------------------------------------------
    -- LAYOUT. Values right, everything else hard left.
    --
    -- A line with no value on the right is written with AddLine, not
    -- AddDoubleLine and an empty string: a double line reserves the right
    -- column whether or not anything sits in it, and the label then reads as
    -- the left half of a pair with a missing value rather than as a heading.
    -- That is why Class and "Disenchants Into" are single lines.
    --
    -- Blank separators are a single space -- an empty string collapses to
    -- nothing on 1.12 and the groups run together.
    -- ---------------------------------------------------------------------
    local function blank() gtt:AddLine(" ") end
    local function pair(label, right)
        gtt:AddDoubleLine(label, right, ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)
    end
    local function heading(text)
        gtt:AddLine(text, ACCENT_R, ACCENT_G, ACCENT_B)
    end

    -- How many auctions everything below rests on. Ahead of the figures,
    -- because it qualifies all of them rather than any one.
    local seen = A.db.SeenCount and A.db.SeenCount(itemId) or 0
    if seen > 0 then
        gtt:AddLine("Seen " .. seen .. " times at auction total",
            HINT_R, HINT_G, HINT_B)
    end

    -- WHAT IT IS WORTH: the three prices, one group. Buyout first -- today's
    -- cheapest is what a buyer acts on; the median is context for it.
    if minBuy or market or vendor then
        if seen > 0 then blank() end
        if minBuy then pair("Aegis Buyout:", money(minBuy)) end
        if market then pair("Aegis Market:", money(market)) end
        if vendor then pair("Sell to Vendor:", money(vendor)) end
    end

    -- WHAT IT COSTS TO MAKE, when a captured recipe makes it.
    if craftCost then
        blank()
        pair("Crafting Cost:", util.FormatMoney(craftCost, true))
    end

    -- WHAT IT BREAKS INTO. Rows before the value, so the reader sees what the
    -- number is made of before the number.
    local itemClass = deInfo and deInfo.type
    if disenchant or deUnpriced or disenchantRows then
        blank()
        if itemClass then gtt:AddLine("Class: " .. itemClass, 1, 1, 1) end

        -- PROVENANCE. "required" means the item level was inferred from the
        -- level needed to equip the item, which can land a band out -- and
        -- adjacent bands differ by more than double in yield. It rides on
        -- whichever line is actually present, so it can never be dropped.
        local approx = (disenchantSource == "required")
            and " (approx, from required level)" or ""

        if disenchantRows then
            heading("Disenchants Into" .. approx .. ":")
            -- Names in their QUALITY COLOUR, the way every other item name in
            -- the game is written. Wrapped here rather than in
            -- de.BreakdownText so core/ stays free of UI escape codes.
            local lines = A.de.BreakdownText(disenchantRows, function(matId)
                local mi = util.ItemInfo(matId)
                if not mi or not mi.name then return nil end
                local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[mi.quality]
                if c and c.hex then return c.hex .. mi.name .. "|r" end
                return mi.name
            end)
            local i = 1
            while lines and i <= table.getn(lines) do
                gtt:AddLine("    " .. lines[i], 0.6, 0.6, 0.6)
                i = i + 1
            end
        end

        if disenchant then
            -- THE VERDICT LIVES IN THE LABEL. On its own line it read as a
            -- footnote to a number the reader had already moved past; beside
            -- the figure it is the answer to why they hovered.
            local verdict, good
            local ah = minBuy or market
            if vendor and vendor > 0 and disenchant > vendor * 1.1 then
                verdict, good = "worth more than vendor", true
            end
            if ah and ah > 0 and disenchant > ah * 1.1 then
                verdict, good = "worth more than the AH", true
            elseif ah and ah > 0 and disenchant * 1.1 < ah then
                verdict, good = "sells for more than it breaks for", false
            end
            local clause = ""
            if verdict then
                clause = " " .. (good and VERDICT_GOOD or VERDICT_BAD)
                    .. "(" .. verdict .. ")|r"
            end
            if disenchantRows then blank() end
            -- NOT run through money(): a disenchant value is per ITEM. Each
            -- break rolls the table again, so a stack of five is five separate
            -- draws, not five times this number.
            pair("Disenchant" .. clause
                    .. ((not disenchantRows) and approx or "") .. ":",
                util.FormatMoney(disenchant, true))
        elseif deUnpriced and deUnpriced > 0 then
            -- The rule answered; the market did not. Naming the material turns
            -- "this item has never worked" into "scan for that shard".
            if disenchantRows then blank() end
            pair("Disenchant" .. ((not disenchantRows) and approx or "") .. ":",
                "|cff9d8b5a?|r")
            local matName = deMissingId and util.ItemName(deMissingId)
            if matName then
                gtt:AddLine("    no price yet for " .. matName, 0.6, 0.6, 0.6)
            else
                gtt:AddLine("    " .. deUnpriced
                    .. " material(s) never seen on the AH", 0.6, 0.6, 0.6)
            end
        end
    end

    gtt:Show()
end

-- ---------------------------------------------------------------------------
-- Resolvers: (hook args) -> itemId, count
-- ---------------------------------------------------------------------------
-- Each returns nil,nil when there is nothing to price. All 1.12-safe.

local resolvers = {}

function resolvers.SetBagItem(bag, slot)
    local id = util.ItemIdFromLink(GetContainerItemLink(bag, slot))
    if not id then return nil end
    local _, itemCount = GetContainerItemInfo(bag, slot)
    return id, itemCount or 1
end

function resolvers.SetInventoryItem(unit, slot)
    local id = util.ItemIdFromLink(GetInventoryItemLink(unit, slot))
    if not id then return nil end
    return id, 1
end

function resolvers.SetAuctionItem(listType, index)
    local id = util.ItemIdFromLink(GetAuctionItemLink(listType, index))
    if not id then return nil end
    local _, _, count = GetAuctionItemInfo(listType, index)
    return id, count or 1
end

function resolvers.SetHyperlink(link)
    -- Accepts both full links and bare item strings.
    local id = util.ItemIdFromLink(link)
    if not id then return nil end
    return id, 1
end

function resolvers.SetAuctionSellItem()
    -- The item currently in the auction sell slot (8th return is the link).
    local name, _, count, _, _, _, _, link = GetAuctionSellItemInfo()
    local id = link and util.ItemIdFromLink(link)
    if not id then return nil end
    return id, count or 1
end

function resolvers.SetMerchantItem(index)
    local id = util.ItemIdFromLink(GetMerchantItemLink(index))
    if not id then return nil end
    local _, _, _, quantity = GetMerchantItemInfo(index)
    return id, quantity or 1
end

function resolvers.SetInboxItem(index)
    -- 1.12 has no GetInboxItemLink; resolve through the scan-fed name map.
    local name, _, count = GetInboxItem(index)
    local id = A.db.IdFromName(name)
    if not id then return nil end
    return id, count or 1
end

-- The surfaces below are the "is this worth picking up / is this worth making"
-- ones. Every getter is probed before use: HookMethod already skips a tooltip
-- method the client doesn't have, but a method can exist while its link getter
-- doesn't, so each resolver guards its own.

function resolvers.SetLootItem(slot)
    if not GetLootSlotLink then return nil end
    local id = util.ItemIdFromLink(GetLootSlotLink(slot))
    if not id then return nil end
    local count = 1
    if GetLootSlotInfo then
        local _, _, quantity = GetLootSlotInfo(slot)
        count = quantity or 1
    end
    return id, count
end

function resolvers.SetQuestItem(qtype, slot)
    if not GetQuestItemLink then return nil end
    local id = util.ItemIdFromLink(GetQuestItemLink(qtype, slot))
    if not id then return nil end
    local count = 1
    if GetQuestItemInfo then
        local _, _, numItems = GetQuestItemInfo(qtype, slot)
        count = numItems or 1
    end
    return id, count
end

function resolvers.SetQuestLogItem(qtype, slot)
    if not GetQuestLogItemLink then return nil end
    local id = util.ItemIdFromLink(GetQuestLogItemLink(qtype, slot))
    if not id then return nil end
    return id, 1
end

-- Tradeskill and Craft share a shape: with a slot it's a reagent, without one
-- it's the thing being made. Pairs with the Crafting tab's profit line -- hover
-- a reagent and see what it's worth without leaving the profession window.
function resolvers.SetTradeSkillItem(skill, slot)
    local link, count = nil, 1
    if slot then
        if not GetTradeSkillReagentItemLink then return nil end
        link = GetTradeSkillReagentItemLink(skill, slot)
        if GetTradeSkillReagentInfo then
            local _, _, n = GetTradeSkillReagentInfo(skill, slot)
            count = n or 1
        end
    else
        if not GetTradeSkillItemLink then return nil end
        link = GetTradeSkillItemLink(skill)
    end
    local id = util.ItemIdFromLink(link)
    if not id then return nil end
    return id, count
end

function resolvers.SetCraftItem(skill, slot)
    local link, count = nil, 1
    if slot then
        if not GetCraftReagentItemLink then return nil end
        link = GetCraftReagentItemLink(skill, slot)
        if GetCraftReagentInfo then
            local _, _, n = GetCraftReagentInfo(skill, slot)
            count = n or 1
        end
    else
        if not GetCraftItemLink then return nil end
        link = GetCraftItemLink(skill)
    end
    local id = util.ItemIdFromLink(link)
    if not id then return nil end
    return id, count
end

function resolvers.SetCraftSpell(slot)
    if not GetCraftItemLink then return nil end
    local id = util.ItemIdFromLink(GetCraftItemLink(slot))
    if not id then return nil end
    return id, 1
end

-- ---------------------------------------------------------------------------
-- Hook installation
-- ---------------------------------------------------------------------------

-- Save-and-replace one GameTooltip method. The replacement resolves the item
-- FIRST (so tooltip.current is set while the original runs — that is when the
-- client calls SetTooltipMoney), then calls the original, then appends our
-- lines.
local function HookMethod(name, source)
    -- Only hook a method that actually exists on this client; otherwise we'd
    -- install a replacement whose "original" is nil and error the moment it is
    -- called (e.g. GameTooltip:SetHyperlink on some 1.12 builds).
    local orig = GameTooltip[name]
    if type(orig) ~= "function" then return end
    tooltip.orig[name] = orig
    GameTooltip[name] = function(self, a1, a2)
        local id, count = resolvers[name](a1, a2)
        if id then
            tooltip.current = { id = id, count = count, source = source }
        else
            tooltip.current = nil
        end
        -- SetBagItem returns hasCooldown, repairCost on 1.12; pass both up.
        -- The client fills the sell-price money line via SetTooltipMoney
        -- DURING this original call, so tooltip.current must stay set across
        -- it. We deliberately do NOT clear current afterward — the next Set*
        -- call overwrites it — so a slightly-late money callback still finds
        -- the right item.
        local r1, r2 = tooltip.orig[name](self, a1, a2)
        if id then
            tooltip.Extend(self, id, count)
        end
        return r1, r2
    end
end

function tooltip.Install()
    if tooltip.hooked then return end
    if not GameTooltip then return end

    HookMethod("SetBagItem",         "bag")
    HookMethod("SetInventoryItem",   "inventory")
    HookMethod("SetAuctionItem",     "auction")
    HookMethod("SetAuctionSellItem", "sell")
    HookMethod("SetHyperlink",       "link")
    HookMethod("SetMerchantItem",    "merchant")
    HookMethod("SetInboxItem",       "inbox")
    HookMethod("SetLootItem",        "loot")
    HookMethod("SetQuestItem",       "quest")
    HookMethod("SetQuestLogItem",    "questlog")
    HookMethod("SetTradeSkillItem",  "tradeskill")
    HookMethod("SetCraftItem",       "craft")
    HookMethod("SetCraftSpell",      "craft")

    -- Vendor-price collection. 1.12's GetItemInfo has no sell price; the only
    -- source is the money line the client adds to bag-item tooltips while a
    -- merchant window is open. SetTooltipMoney is the FrameXML function that
    -- draws it — save/replace it and snoop the amount. The shown amount is
    -- for the whole stack, so divide by count. Merchant BUY prices also flow
    -- through here (via SetMerchantItem), which is why only source == "bag"
    -- is recorded.
    if type(SetTooltipMoney) == "function" then
        tooltip.orig_SetTooltipMoney = SetTooltipMoney
        SetTooltipMoney = function(frame, money)
            tooltip.orig_SetTooltipMoney(frame, money)
            local cur = tooltip.current
            if cur and (cur.source == "bag" or cur.source == "inventory")
                and money and money > 0
                and frame == GameTooltip
                and MerchantFrame and MerchantFrame:IsVisible() then
                A.db.SetVendor(cur.id,
                    math.floor(money / (cur.count or 1)))
            end
        end
    end

    tooltip.hooked = true
end

A.OnLoad(tooltip.Install)
