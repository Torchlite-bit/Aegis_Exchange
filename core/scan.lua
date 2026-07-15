-- Aegis: Exchange
-- core/scan.lua
--
-- Auction scanner module -- STUB. No scanning logic yet; this only stakes out
-- the module surface. The rules the real implementation MUST follow (all from
-- the 1.12 client; see CLAUDE.md for the authoritative list):
--
--   * QueryAuctionItems(name, minLevel, maxLevel, invTypeIndex, classIndex,
--         subclassIndex, page, isUsable, qualityIndex)   -- 9 args
--     `page` is 0-indexed. There is NO working getAll on 1.12.
--
--   * Poll CanSendAuctionQuery() before EVERY query; leave ~4 seconds between
--     pages. Wait for AUCTION_ITEM_LIST_UPDATE before reading a page.
--
--   * Page size is 50.
--
--   * GetAuctionItemInfo("list", i) returns ONLY, in this order:
--         name, texture, count, quality, canUse, level,
--         minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner
--     Nothing else. `owner` may be nil until the name resolves.

local A = AegisExchange
A.scan = {}
local scan = A.scan

-- Auctions returned per page by the 1.12 server.
scan.PAGE_SIZE = 50

-- Seconds to wait between page queries (throttle around CanSendAuctionQuery).
scan.PAGE_DELAY = 4

-- Scanner state. Filled in when scanning is implemented.
scan.state = {
    running = false,
    page    = 0,   -- 0-indexed, matches QueryAuctionItems
    total   = 0,   -- total auctions across all pages (GetNumAuctionItems)
}

-- Begin a full scan. STUB.
function scan.Start()
    -- TODO: drive QueryAuctionItems page by page, gated on
    -- CanSendAuctionQuery() and AUCTION_ITEM_LIST_UPDATE, PAGE_SIZE per page.
end

-- Stop / reset the scanner. STUB.
function scan.Stop()
    scan.state.running = false
    scan.state.page    = 0
end
