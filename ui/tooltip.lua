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
        and not disenchantRows and not deUnpriced then
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
    -- LAYOUT. Label left, value right, in three groups separated by blank
    -- lines: what the auction house says, what a vendor says, and what
    -- destroying it says. Blank lines are a single space -- an empty string
    -- collapses to nothing on 1.12 and the groups run together.
    -- ---------------------------------------------------------------------
    local function blank() gtt:AddLine(" ") end
    local function pair(label, right)
        gtt:AddDoubleLine(label, right, ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)
    end

    -- How many auctions this rests on, ahead of any number it produced.
    -- Confidence belongs BEFORE the figures, not appended to one of them.
    local seen = A.db.SeenCount and A.db.SeenCount(itemId) or 0
    if seen > 0 then
        gtt:AddLine("Seen " .. seen .. " times at auction total",
            0.6, 0.6, 0.6)
    end

    if minBuy or market then
        if seen > 0 then blank() end
        -- Buyout first: today's cheapest is what a buyer acts on, and the
        -- median is the context for it rather than the other way round.
        if minBuy then pair("Aegis Buyout:", money(minBuy)) end
        if market then pair("Aegis Market:", money(market)) end
    end

    if vendor then
        blank()
        pair("Sell to Vendor:", money(vendor))
    end

    -- The disenchant group, and the item class that frames it -- armour and
    -- weapons break into different things, so the class is part of reading the
    -- split rather than trivia.
    local itemClass = deInfo and deInfo.type
    if disenchant or deUnpriced or disenchantRows or itemClass then
        blank()
        if itemClass then pair("Class:", itemClass) end

        if disenchant then
            -- NOT run through money(): a disenchant value is per ITEM. Each
            -- break rolls the table again, so a stack of five is five separate
            -- draws, not five times this number.
            --
            -- "(approx)" marks a level inferred from the level needed to equip
            -- the item, which can land a band out -- and adjacent bands differ
            -- by more than double in yield.
            pair("Disenchant Value:"
                    .. ((disenchantSource == "required") and " (approx)" or ""),
                util.FormatMoney(disenchant, true))

            local beats, verdict = nil, nil
            local ah = minBuy or market
            if vendor and vendor > 0 and disenchant > vendor * 1.1 then
                beats, verdict = true, "worth more than vendor"
            end
            if ah and ah > 0 and disenchant > ah * 1.1 then
                beats, verdict = true, "worth more than the AH"
            elseif ah and ah > 0 and disenchant * 1.1 < ah then
                beats, verdict = false, "sells for more than it breaks for"
            end
            if verdict then
                local r, g, b = 0.30, 0.85, 0.30
                if not beats then r, g, b = 0.75, 0.55, 0.35 end
                gtt:AddLine("  " .. verdict, r, g, b)
            end
        elseif deUnpriced and deUnpriced > 0 then
            -- The rule answered; the market did not. Naming the material turns
            -- "this item has never worked" into "scan for that shard".
            local matName = deMissingId and util.ItemName(deMissingId)
            pair("Disenchant Value:", "|cff9d8b5a?|r")
            if matName then
                gtt:AddLine("  no price yet for " .. matName, 0.6, 0.6, 0.6)
            else
                gtt:AddLine("  " .. deUnpriced
                    .. " material(s) never seen on the AH", 0.6, 0.6, 0.6)
            end
        end

        if disenchantRows then
            gtt:AddLine("Disenchants Into:", ACCENT_R, ACCENT_G, ACCENT_B)
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
