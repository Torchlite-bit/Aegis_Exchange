-- Aegis: Exchange
-- ui/tooltip.lua
--
-- GameTooltip hook -- STUB. Eventually adds our auction-price line to item
-- tooltips.
--
-- HOOKING RULE (see CLAUDE.md): NO hooksecurefunc and NO secure hooks. On this
-- client we hook by SAVING the original function and REPLACING it, then
-- calling the saved original from our replacement.

local A = AegisExchange
A.tooltip = {}
local tooltip = A.tooltip

-- Guard so the hook is installed only once.
tooltip.hooked = false

-- Append our line(s) to a GameTooltip already showing an item. STUB -- reads
-- nothing from the DB yet.
function tooltip.AddLine(gtt, itemName, itemId)
    -- TODO: record = A.db.GetPrice(itemId); add an AH price line, e.g.
    --   gtt:AddLine("Aegis: " .. A.util.FormatMoney(record.market, true))
    --   gtt:Show()   -- re-flow the tooltip after adding lines
end

-- Install the hook by saving the original method and replacing it.
function tooltip.Install()
    if tooltip.hooked then return end
    if not GameTooltip then return end

    -- Save the original, then replace with our wrapper. `self` is the
    -- GameTooltip. We call the original FIRST so the default tooltip is fully
    -- built, then we get our chance to add lines.
    tooltip.orig_SetBagItem = GameTooltip.SetBagItem
    GameTooltip.SetBagItem = function(self, bag, slot)
        local ret = tooltip.orig_SetBagItem(self, bag, slot)
        -- TODO: resolve the item from (bag, slot) and call tooltip.AddLine.
        return ret
    end

    tooltip.hooked = true
end

A.OnLoad(tooltip.Install)
