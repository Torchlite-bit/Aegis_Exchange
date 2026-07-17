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
function tooltip.Extend(gtt, itemId, count)
    local market = A.db.MarketValue(itemId)
    local minBuy = A.db.MinBuyout(itemId)
    local vendor = A.db.GetVendor(itemId)
    if not market and not minBuy and not vendor then return end

    if market then
        gtt:AddDoubleLine("Aegis Market",
            util.FormatMoney(market, true),
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)
    end
    if minBuy then
        local right = util.FormatMoney(minBuy, true)
        if count and count > 1 then
            -- Per-unit price, then the whole-stack total, per the mockup.
            right = right .. " (x" .. count .. " = "
                .. util.FormatMoney(minBuy * count, true) .. ")"
        end
        gtt:AddDoubleLine("Aegis Min Buyout", right,
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)
    end
    if vendor then
        local right = util.FormatMoney(vendor, true)
        if count and count > 1 then
            right = right .. " (x" .. count .. " = "
                .. util.FormatMoney(vendor * count, true) .. ")"
        end
        gtt:AddDoubleLine("Aegis Vendor Price", right,
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)
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

-- ---------------------------------------------------------------------------
-- Hook installation
-- ---------------------------------------------------------------------------

-- Save-and-replace one GameTooltip method. The replacement resolves the item
-- FIRST (so tooltip.current is set while the original runs — that is when the
-- client calls SetTooltipMoney), then calls the original, then appends our
-- lines.
local function HookMethod(name, source)
    tooltip.orig[name] = GameTooltip[name]
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

    HookMethod("SetBagItem",       "bag")
    HookMethod("SetInventoryItem", "inventory")
    HookMethod("SetAuctionItem",   "auction")
    HookMethod("SetHyperlink",     "link")
    HookMethod("SetMerchantItem",  "merchant")
    HookMethod("SetInboxItem",     "inbox")

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
