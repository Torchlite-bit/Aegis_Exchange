-- Aegis: Exchange
-- core/sell.lua
--
-- Posting engine: wraps the 1.12 create-auction API (each call verified against
-- the Turtle UI source) and layers Aegis price context + Turtle specifics on
-- top. The UI lives in ui/frame.lua's Sell tab, exactly as the scanner engine
-- (core/scan.lua) is driven from the Scan tab.
--
-- 1.12 API used here (all globals, valid while the AH SESSION is open —
-- independent of whether the Blizzard AuctionFrame is shown):
--   ClickAuctionSellItemButton()       -- move the cursor item into the sell slot
--   GetAuctionSellItemInfo()           -> name, texture, count, quality, canUse,
--                                         price, maxStack, link   (8 values)
--   CalculateAuctionDeposit(minutes)   -- client deposit math for the slot item
--   StartAuction(minBid, buyout, mins) -- COPPER for the WHOLE stack in the slot;
--                                         mins is 120 / 480 / 1440
--   GetNumAuctionItems("owner")        -> batch, total (total = your auctions)
--
-- Turtle specifics (CLAUDE.md): durations are x3, so 120/480/1440 minutes are
-- really 6h / 24h / 72h; 120-auction account cap; 5% consignment cut on sales;
-- and the shown deposit is inflated -- we scale it by ~0.6 and ALWAYS label it
-- "approx", never exact.

local A = AegisExchange
A.sell = {}
local sell = A.sell
local util = A.util

-- Duration options. `minutes` is what the client / StartAuction expects;
-- `label` is the Turtle-real time (x3) we actually SHOW.
sell.DURATIONS = {
    { minutes = 120,  label = "6h"  },
    { minutes = 480,  label = "24h" },
    { minutes = 1440, label = "72h" },
}
sell.DEFAULT_DURATION = 480   -- 24h, matching the stock UI's default radio

sell.CAP = 120     -- Turtle account-wide auction cap
sell.CUT = 0.05    -- 5% consignment cut taken on a sale

-- Turtle's shown deposit is inflated relative to what actually gets charged;
-- scale by this to approximate. The result is ALWAYS presented as "approx".
sell.TURTLE_DEPOSIT_FACTOR = 0.6

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- Normalized view of the item currently in the sell slot, or nil if empty.
function sell.GetItem()
    local name, texture, count, quality, canUse, price, maxStack, link =
        GetAuctionSellItemInfo()
    if not name then return nil end
    count = count or 1
    return {
        name     = name,
        texture  = texture,
        count    = count,
        quality  = quality,
        canUse   = canUse,
        price    = price or 0,          -- vendor deposit-base for the whole stack
        maxStack = maxStack or count,
        link     = link,
        itemId   = link and util.ItemIdFromLink(link) or nil,
    }
end

-- Your current number of active auctions (second return of GetNumAuctionItems).
function sell.OwnerCount()
    local _, total = GetNumAuctionItems("owner")
    return total or 0
end

function sell.AtCap()
    return sell.OwnerCount() >= sell.CAP
end

-- Approximate deposit (copper) for the slotted item at `minutes`. Prefers the
-- client's own CalculateAuctionDeposit (present once the AH UI has loaded),
-- scaled by the Turtle factor. Returns (copper, isApprox); isApprox is true on
-- Turtle so the UI can label it honestly.
function sell.EstimateDeposit(minutes)
    if not minutes or minutes <= 0 then return 0, true end
    local base
    if CalculateAuctionDeposit then
        base = CalculateAuctionDeposit(minutes)
    else
        -- Fallback: the vanilla formula, from the slot item directly.
        local it = sell.GetItem()
        if not it then return 0, true end
        base = math.floor(it.price * (minutes / 120)
            * (1 + (it.maxStack - it.count) * 0.05) * 0.025)
    end
    base = base or 0
    if A.isTurtle then
        return math.floor(base * sell.TURTLE_DEPOSIT_FACTOR), true
    end
    return base, false
end

-- Suggested per-unit prices for `itemId` from the price DB (any may be nil).
function sell.Suggest(itemId)
    if not itemId then return nil end
    return {
        market    = A.db.MarketValue(itemId),
        minBuyout = A.db.MinBuyout(itemId),
        vendor    = A.db.GetVendor(itemId),
    }
end

-- Per-unit price to undercut the cheapest seen buyout by ~5% (falls back to
-- market value). Returns copper, or nil if we have no data for the item.
function sell.UndercutUnit(itemId)
    local s = sell.Suggest(itemId)
    if not s then return nil end
    local base = s.minBuyout or s.market
    if not base then return nil end
    local under = math.floor(base * 0.95)
    if under < 1 then under = 1 end
    return under
end

-- ---------------------------------------------------------------------------
-- Posting
-- ---------------------------------------------------------------------------

-- Post the item currently in the slot. `unitBuyout` / `unitStart` are per-unit
-- copper (the whole stack is auctioned; totals are unit * count). `minutes` is
-- 120 / 480 / 1440. Returns (true) once the auction is fired, or (false,
-- reason) on a validation failure. Success is otherwise confirmed by the
-- follow-up NEW_AUCTION_UPDATE / AUCTION_OWNED_LIST_UPDATE events.
function sell.Post(unitBuyout, unitStart, minutes)
    local it = sell.GetItem()
    if not it then return false, "No item in the sell slot." end
    if sell.AtCap() then
        return false, "You are at the " .. sell.CAP .. "-auction cap."
    end
    if not minutes or minutes <= 0 then
        return false, "Pick a duration."
    end
    local count  = it.count
    local buyout = math.floor((unitBuyout or 0) * count)
    -- Start bid defaults to the buyout when left blank.
    local start  = math.floor((unitStart or unitBuyout or 0) * count)
    if start < 1 then
        return false, "Enter a start bid or buyout of at least 1 copper."
    end
    if buyout > 0 and start > buyout then
        return false, "Start bid can't exceed the buyout."
    end
    StartAuction(start, buyout, minutes)
    return true
end
