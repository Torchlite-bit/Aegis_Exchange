-- Aegis: Exchange -- tests/units/tooltip_hook_test.lua
--
-- The HOOK layer, as opposed to the lines it adds (tooltip_test.lua).
--
-- WHY THIS EXISTS. The simulated client had no GameTooltip at all, so
-- tooltip.Install() returned early on its own `if not GameTooltip then return
-- end` guard and every hook in the file was untested. What shipped through
-- that gap was a wrapper that turned SOMEBODY ELSE'S error into an error
-- carrying our file name:
--
--   Interface\AddOns\Aegis_Exchange\ui\tooltip.lua:489: Unknown link type
--
-- 1.12's SetHyperlink throws that for any link it cannot render -- a spell, an
-- enchant, a profession link, a malformed one. Any addon in the session can
-- hand it one. Without our hook the error is attributed to whoever called it;
-- with our hook there is a Lua frame of ours in between, so the player blames
-- Aegis for a link Aegis never touched.
--
-- The mock models the REFUSAL (W.tooltipThrows), because a tooltip that
-- accepts everything cannot show that a wrapper mishandles a rejection.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.LoadUI("tooltip")
W.FireAddonLoaded(A)
local tooltip = A.tooltip

W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
local SILK = W.items[4306].link

tooltip.Install()

-- ---------------------------------------------------------------------------
H.section("the hooks are actually installed")
-- ---------------------------------------------------------------------------

-- The guard that hid all of this: with no GameTooltip, Install returns having
-- done nothing and every assertion below would pass vacuously.
H.eq("Install ran", tooltip.hooked, true)
H.check("SetHyperlink was replaced", tooltip.orig.SetHyperlink ~= nil)
H.check("SetBagItem was replaced", tooltip.orig.SetBagItem ~= nil)

-- ---------------------------------------------------------------------------
H.section("a good link passes through and gains our lines")
-- ---------------------------------------------------------------------------

W.ResetTooltip()
A.db.RecordAuction(4306, 500, "Silk Cloth")
GameTooltip:SetHyperlink(SILK)

H.eq("the original was called", table.getn(W.tooltipCalls), 1)
H.eq("...with the link it was given", W.tooltipCalls[1].a1, SILK)
H.check("...and our lines were added", GameTooltip:NumLines() > 0)
H.eq("nothing was recorded as a failure", tooltip.failures, 0)

-- ---------------------------------------------------------------------------
H.section("a link the CLIENT refuses does not become our error")
-- ---------------------------------------------------------------------------

W.ResetTooltip()
tooltip.failures = 0
tooltip.lastFailure = nil
W.tooltipThrows.SetHyperlink = "Unknown link type"

-- THE REPORTED BUG. Before the guard this propagated, and the red line in the
-- player's chat named ui/tooltip.lua for a link Aegis never touched.
H.survives("a refused link does not throw out of the hook", function()
    GameTooltip:SetHyperlink("|Henchant:7218|h[Enchant Bracer]|h")
end)

H.eq("the original was still attempted", table.getn(W.tooltipCalls), 1)
H.eq("...and the refusal was counted", tooltip.failures, 1)
H.check("...and remembered", tooltip.lastFailure ~= nil)
H.eq("...naming the method", tooltip.lastFailure.method, "SetHyperlink")
H.check("...and carrying the client's own words",
        string.find(tooltip.lastFailure.err or "", "Unknown link type", 1, true)
            ~= nil, tostring(tooltip.lastFailure.err))

-- NOT swallowed silently: a second refusal counts again, so a storm of them
-- shows up in /aex diag as a storm rather than as one.
GameTooltip:SetHyperlink("|Hquest:1234:60|h[A Quest]|h")
H.eq("a second refusal counts too", tooltip.failures, 2)

-- ---------------------------------------------------------------------------
H.section("...and our lines are not added on top of a failure")
-- ---------------------------------------------------------------------------

-- A refused Set* leaves the tooltip in a state we did not build. Appending
-- price lines to whatever happened to be on screen is how a stale tooltip
-- grows a second item's numbers.
W.ResetTooltip()
W.tooltipThrows.SetHyperlink = "Unknown link type"
GameTooltip:SetHyperlink(SILK)          -- an item we DO have prices for
H.eq("no lines were added to a tooltip that failed to build",
     GameTooltip:NumLines(), 0)

-- ---------------------------------------------------------------------------
H.section("a working method still returns what the client returns")
-- ---------------------------------------------------------------------------

-- SetBagItem hands back hasCooldown, repairCost on 1.12 and callers read them.
-- A wrapper that ate the return values would break the stock UI quietly.
W.ResetTooltip()
W.SetBags({ [0] = { { link = SILK, count = 5 } } })
local hasCooldown, repairCost = GameTooltip:SetBagItem(0, 1)
H.eq("the original was called", W.tooltipCalls[1].method, "SetBagItem")
H.eq("...and its second return came back", repairCost, 0)
H.eq("...and its first", hasCooldown, nil)

-- ---------------------------------------------------------------------------
H.section("every method it claims to hook, it hooks")
-- ---------------------------------------------------------------------------

-- A method named in Install but missing from the client is skipped by design
-- (HookMethod checks the type first). The risk is the reverse: a method listed
-- in resolvers that Install forgot, so the surface silently shrinks.
local expected = {
    "SetBagItem", "SetInventoryItem", "SetAuctionItem", "SetAuctionSellItem",
    "SetHyperlink", "SetMerchantItem", "SetInboxItem", "SetLootItem",
    "SetQuestItem", "SetQuestLogItem", "SetTradeSkillItem", "SetCraftItem",
    "SetCraftSpell",
}
local i = 1
while i <= table.getn(expected) do
    H.check(expected[i] .. " is hooked", tooltip.orig[expected[i]] ~= nil)
    i = i + 1
end

os.exit(H.report("tooltip.hook"))
