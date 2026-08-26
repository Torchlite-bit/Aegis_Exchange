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
    local deUnpriced, deMissingId
    if Want("tipDisenchant") and A.de then
        disenchant, disenchantSource = A.de.ValueOf(itemId, A.de.MarketPrice)
        -- The rows are a fact about the ITEM, not about the market, so they do
        -- not depend on the value resolving. Shown when the setting asks for
        -- them, and always available on Shift whatever the setting says.
        local wantRows = (A.db.Setting and A.db.Setting("tipDisenchantRows") == true)
            or (IsShiftKeyDown and IsShiftKeyDown() and true or false)
        if wantRows then
            disenchantRows = A.de.YieldOf(itemId)
        end
        -- A missing value with rows present means the rule answered and the
        -- MARKET did not. Find out which material, so the line can say so
        -- instead of going quiet -- see de.MissingPrice.
        if not disenchant and A.de.MissingPriceOf then
            deUnpriced, _, deMissingId =
                A.de.MissingPriceOf(itemId, A.de.MarketPrice)
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

    if market then
        -- How many DAYS the median rests on. One day and thirty days give the
        -- same-looking number and are not the same claim, and the tooltip is
        -- the only place a player ever sees either.
        --
        -- On the VALUE side, not the label. A qualifier belongs next to the
        -- number it qualifies, and labels that change shape are hard to scan
        -- down a column -- the same reason the % sits beside Min Buyout below.
        local right = money(market)
        local days = A.db.DayCount and A.db.DayCount(itemId) or 0
        if days > 0 then
            right = right .. "  |cff9d8b5a" .. days .. "d|r"
        end
        gtt:AddDoubleLine("Aegis Market", right,
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)
    end
    if minBuy then
        -- Against the median, because the interesting question about today's
        -- cheapest listing is whether it is cheap. A bare figure makes the
        -- reader do that division in their head every time.
        local right = money(minBuy)
        if market and market > 0 then
            right = right .. "  |cff9d8b5a("
                .. math.floor(minBuy / market * 100 + 0.5) .. "% of mkt)|r"
        end
        gtt:AddDoubleLine("Aegis Min Buyout", right,
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)
    end
    if vendor then
        gtt:AddDoubleLine("Aegis Vendor Price", money(vendor),
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)
    end
    if disenchant then
        -- Deliberately NOT run through money(): a disenchant value is per
        -- ITEM, and multiplying it by a stack count would be wrong. You
        -- disenchant one thing at a time, and each break rolls the table
        -- again -- a stack of five is five separate draws, not five times
        -- this number.
        --
        -- WHERE THE LEVEL CAME FROM IS PART OF THE NUMBER. Source "required"
        -- means the item level was inferred from the level needed to equip the
        -- item (see de.REQ_OFFSET), which can land a band out -- and adjacent
        -- bands differ by more than double in yield. An unlabelled figure would
        -- read exactly like the measured one next to it, so the label is not
        -- decoration: it is the difference between an estimate and a claim.
        gtt:AddDoubleLine(
            "Aegis Disenchant"
                .. ((disenchantSource == "required") and " (approx)" or ""),
            util.FormatMoney(disenchant, true),
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)

        -- THE VERDICT. The number on its own still leaves the reader doing the
        -- comparison that made them hover in the first place -- is this worth
        -- more broken than sold? Both comparisons are against a PER-ITEM
        -- figure, so vendor and market are used per unit, never per stack.
        --
        -- Only ever states the case it can support: silent when there is
        -- nothing to compare against, and silent when the answer is "about the
        -- same", because a verdict on a 3% difference is noise.
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
        -- THE DIAGNOSIS. The rule answered; the market did not. Saying which
        -- material is missing turns "this item has never worked" into "scan
        -- for that shard", which is a thing a person can act on.
        local matName = deMissingId and GetItemInfo(deMissingId)
        local why
        if matName then
            why = "no price yet for " .. matName
        else
            why = deUnpriced .. " material(s) never seen on the AH"
        end
        gtt:AddDoubleLine("Aegis Disenchant", "|cff9d8b5a?|r",
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)
        gtt:AddLine("  " .. why, 0.6, 0.6, 0.6)
    end

    -- Outside both branches: the breakdown is a fact about the item and stands
    -- whether or not the market can price it.
    if disenchantRows then
        local lines = A.de.BreakdownText(disenchantRows, function(matId)
            return GetItemInfo(matId)
        end)
        local i = 1
        while lines and i <= table.getn(lines) do
            gtt:AddLine("  " .. lines[i], 0.6, 0.6, 0.6)
            i = i + 1
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
