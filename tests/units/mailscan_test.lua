-- Aegis: Exchange -- tests/units/mailscan_test.lua
--
-- The mailbox sale scan, and the storm it has to survive (CLAUDE.md, HARD
-- RULE 16).
--
-- The first time a session opens a mailbox with unseen attachments, the
-- client fires MAIL_INBOX_UPDATE dozens of times in a few frames while each
-- item resolves. ui.ScanMailSales used to run on every one of those fires,
-- and -- whenever History was the last tab you had open -- repainted the whole
-- History tab each time, chart and all, with the window CLOSED. Fixed in #107
-- (contributed); this suite pins what that fix does:
--
--   * a storm of fires is ONE scan on the next frame, not one per fire;
--   * the driver idles once it has run, and a fire DURING the scan is not
--     lost -- it is hidden first, so a re-fire re-arms it;
--   * History is repainted only when the scan logged something NEW and the
--     window is actually on screen, on the History tab.
--
-- No suite loads ui/frame.lua; the wiring and the scan are taken out of its
-- source and run here against the real core.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db = A.db

local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
local src = f:read("*a")
f:close()

-- A whole function, `end` included.
local function chunk(head)
    local at = assert(string.find(src, head, 1, true), "did not find: " .. head)
    local stop = assert(string.find(src, "\nend\n", at, true))
    return string.sub(src, at, stop + 4)
end

-- The event wiring: the driver frame and the MAIL_INBOX_UPDATE handler, as
-- one block of file-scope code.
local function wiring()
    local head = 'ui.mailScanDriver = CreateFrame("Frame", "AegisExchangeMailScan")'
    local at = assert(string.find(src, head, 1, true), "did not find the driver")
    local tail = 'A.RegisterEvent("MAIL_INBOX_UPDATE", function()'
    local h = assert(string.find(src, tail, at, true), "did not find the handler")
    local stop = assert(string.find(src, "\nend)\n", h, true))
    return string.sub(src, at, stop + 5)
end

-- A tick the way the CLIENT runs one: OnUpdate fires only on a SHOWN frame.
-- W.Tick runs the script whatever the frame's state, which is right for the
-- drivers that never hide -- and would make a driver that never idles look
-- exactly like one that does.
local function frameTick(fr)
    if fr:IsShown() then W.Tick(fr) end
end

ui = {}
_G.A = A
util = A.util

-- ---------------------------------------------------------------------------
H.section("A storm of fires is one scan, on the next frame")
-- ---------------------------------------------------------------------------

local scans = 0
ui.ScanMailSales = function() scans = scans + 1 end
assert(loadstring(wiring()))()

H.check("the driver starts idle", not ui.mailScanDriver:IsShown())
local k = 1
while k <= 40 do
    W.FireEvent(A.frame, "MAIL_INBOX_UPDATE")
    k = k + 1
end
H.eq("forty fires scan nothing inline", scans, 0)
frameTick(ui.mailScanDriver)
H.eq("...and once on the next frame", scans, 1)
frameTick(ui.mailScanDriver)
frameTick(ui.mailScanDriver)
H.eq("...and not again until the mailbox fires again", scans, 1)
H.check("the driver idles once it has run", not ui.mailScanDriver:IsShown())

-- A fire that lands WHILE the scan runs. Hidden first, so the fire re-arms
-- it; hidden after, and the fire is swallowed with the frame it arrived in.
ui.ScanMailSales = function()
    scans = scans + 1
    if scans == 2 then W.FireEvent(A.frame, "MAIL_INBOX_UPDATE") end
end
W.FireEvent(A.frame, "MAIL_INBOX_UPDATE")
frameTick(ui.mailScanDriver)
frameTick(ui.mailScanDriver)
H.eq("a fire during the scan is not lost: it scans again next frame", scans, 3)

-- ---------------------------------------------------------------------------
H.section("The repaint: only what is new, and only on screen")
-- ---------------------------------------------------------------------------

assert(loadstring(chunk("local function MailPrefix(")
    .. chunk("local function SubjectItem(")
    .. chunk("local function AuctionSoldItem(")
    .. chunk("local function AuctionExpiredItem(")
    .. chunk("function ui.ScanMailSales(")))()

local repaints = 0
ui.RefreshHistory = function() repaints = repaints + 1 end
ui.frame = CreateFrame("Frame", "AegisExchangeFrame")
ui.frame:Hide()
ui.selectedSubTab = "History"
db.ClearLedger()
db.char.posted = {}
local function logged() return table.getn(db.account.ledger) end
local function sale(item, money, days)
    return { subject = "Auction successful: " .. item, money = money,
             daysLeft = days }
end

-- At a mailbox the auction house is closed, and so is the window.
W.SetInbox({ sale("Linen Cloth", 1900, 29.5) })
ui.ScanMailSales()
H.eq("a sale is logged with the window closed", logged(), 1)
H.eq("...without repainting a tab nobody can see", repaints, 0)

ui.frame:Show()
ui.ScanMailSales()
H.eq("the same mail again logs nothing", logged(), 1)
H.eq("...and repaints nothing", repaints, 0)

W.SetInbox({ sale("Linen Cloth", 1900, 29.5), sale("Silk Cloth", 900, 29.4) })
ui.ScanMailSales()
H.eq("a new sale with History on screen is logged", logged(), 2)
H.eq("...and repaints it, once", repaints, 1)

ui.selectedSubTab = "Sell"
W.SetInbox({ sale("Wool Cloth", 600, 29.3) })
ui.ScanMailSales()
H.eq("a new sale on another tab is logged", logged(), 3)
H.eq("...without repainting History", repaints, 1)

-- An auction given back to the book is something new too.
ui.selectedSubTab = "History"
db.RecordPosting("Mageweave Cloth", 4338, 20)
W.SetInbox({ { subject = "Auction expired: Mageweave Cloth", money = 0,
               daysLeft = 29.2 } })
ui.ScanMailSales()
H.eq("an expiry gives its posting back", table.getn(db.Postings()), 0)
H.eq("...and counts as something new", repaints, 2)

W.SetInbox({})
os.exit(H.report("mailscan"))
