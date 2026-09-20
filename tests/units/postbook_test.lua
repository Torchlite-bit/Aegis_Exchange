-- Aegis: Exchange -- tests/units/postbook_test.lua
--
-- The posting book: what this character put up, so a sale mail can say how
-- many were in the stack.
--
-- WHY IT HAS TO EXIST AT ALL. A sale's quantity is not obtainable from the
-- mailbox. Not in the subject ("Auction successful: <item>"), not in the
-- invoice (GetInboxInvoiceInfo returns a name and prices, no stack size), and
-- a sold auction's mail has no attachment to count -- the buyer got the items.
-- The only moment the number exists is when we posted it.
--
-- WHAT HAS A WRONG ANSWER THAT STILL LOOKS RIGHT:
--
--   * GUESSING. Three stacks of an item up at two different sizes cannot say
--     which one sold, and there is no auction id on 1.12 to ask with. Picking
--     one is a number the player will reconcile against their own mail and
--     find wrong. nil is the answer, and db.RecordTxn already treats absent as
--     unknown rather than as one.
--   * CONSUMING ON A GUESS. Taking a posting out of the book on an ambiguous
--     match throws away the evidence that we guessed.
--   * NOT CONSUMING AN EXPIRY. An auction that came back unsold is not waiting
--     on a sale mail, and leaving it in turns a book of one size into a mixed
--     one -- which costs the NEXT sale its quantity.
--   * LEAKING. One row per posted stack is unbounded for a player who posts
--     all day and never opens their mail.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db = A.db

local DAY = 86400
local NOW = 1700000000

local function reset() db.char.posted = {} end

-- ---------------------------------------------------------------------------
H.section("one stack up, one sale")
-- ---------------------------------------------------------------------------

do
    reset()
    H.check("a posting is remembered",
            db.RecordPosting("Linen Cloth", 2589, 20, NOW))
    H.eq("the sale knows how many", db.MatchPosting("Linen Cloth", NOW), 20)
    -- CONSUMED. A second sale of an item with nothing left up is not the same
    -- stack a second time.
    H.isNil("...and only once", db.MatchPosting("Linen Cloth", NOW))
end

-- An item that was never posted from this character says nothing.
do
    reset()
    H.isNil("an unposted item is unknown", db.MatchPosting("Silk Cloth", NOW))
end

-- ---------------------------------------------------------------------------
H.section("several stacks of one item")
-- ---------------------------------------------------------------------------

-- ALL THE SAME SIZE IS NOT AMBIGUOUS. Which of three identical stacks sold is
-- unanswerable and also the wrong question: the size is the same either way.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    H.eq("the first sale answers", db.MatchPosting("Linen Cloth", NOW), 20)
    H.eq("...and the second", db.MatchPosting("Linen Cloth", NOW), 20)
    H.eq("...and the third", db.MatchPosting("Linen Cloth", NOW), 20)
    H.isNil("...and then there are none", db.MatchPosting("Linen Cloth", NOW))
end

-- DIFFERENT SIZES ARE. There is no auction id to ask which one sold, so the
-- honest answer is that we do not know.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Linen Cloth", 2589, 5, NOW)
    H.isNil("a mixed book cannot say", db.MatchPosting("Linen Cloth", NOW))
    -- ...AND NOTHING WAS CONSUMED. Taking one out on a guess throws away the
    -- evidence that we guessed -- and would make the NEXT sale, of the one
    -- remaining size, answer confidently about the wrong stack.
    H.eq("nothing was consumed", table.getn(db.Postings()), 2)
end

-- One item's stacks do not make ANOTHER item ambiguous.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Silk Cloth", 4306, 5, NOW)
    H.eq("the linen answers", db.MatchPosting("Linen Cloth", NOW), 20)
    H.eq("the silk answers", db.MatchPosting("Silk Cloth", NOW), 5)
end

-- ---------------------------------------------------------------------------
H.section("an auction that came back")
-- ---------------------------------------------------------------------------

-- THE POINT OF READING EXPIRY MAIL AT ALL. Post 20, it expires; post 5, it
-- sells. Without consuming the expiry the book holds both sizes and the sale
-- of the 5 cannot say how many it was.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.ExpirePosting("Linen Cloth", NOW)
    db.RecordPosting("Linen Cloth", 2589, 5, NOW)
    H.eq("the sale after an expiry is unambiguous",
         db.MatchPosting("Linen Cloth", NOW), 5)
end

-- ...and without it, it is not. Asserted so the expiry path cannot be removed
-- as redundant.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Linen Cloth", 2589, 5, NOW)
    H.isNil("...which it would not be otherwise",
            db.MatchPosting("Linen Cloth", NOW))
end

-- ---------------------------------------------------------------------------
H.section("the book does not grow forever")
-- ---------------------------------------------------------------------------

-- 72h is the longest auction Turtle allows and mail then sits for up to 30
-- days, so a posting older than the two together is a leak and not a record.
do
    reset()
    db.RecordPosting("Old Thing", 1, 20, NOW - 40 * DAY)
    db.RecordPosting("New Thing", 2, 5, NOW - 1 * DAY)
    db.PrunePostings(NOW)
    H.eq("the stale one is gone", table.getn(db.Postings()), 1)
    H.eq("...and the live one is not", db.Postings()[1].name, "New Thing")
end

-- Just inside the window survives, so the cutoff is not a round-down to zero.
do
    reset()
    db.RecordPosting("Just Alive", 1, 20, NOW - 32 * DAY)
    db.PrunePostings(NOW)
    H.eq("a posting inside the window stays", table.getn(db.Postings()), 1)
end

-- A posting with no timestamp cannot be aged, and a record that can never
-- expire is the leak this prune exists to prevent.
do
    reset()
    table.insert(db.Postings(), { name = "Undated", qty = 5 })
    db.PrunePostings(NOW)
    H.eq("an undated posting is dropped", table.getn(db.Postings()), 0)
end

-- THE CAP, for a player who posts all day and never opens their mail. Oldest
-- go first: the newest are the ones a sale is most likely to be about.
do
    reset()
    local i = 1
    while i <= db.POSTED_MAX + 25 do
        db.RecordPosting("Thing " .. i, i, 1, NOW)
        i = i + 1
    end
    H.eq("the book is capped", table.getn(db.Postings()), db.POSTED_MAX)
    H.eq("...and it kept the newest", db.Postings()[db.POSTED_MAX].name,
         "Thing " .. (db.POSTED_MAX + 25))
end

-- ---------------------------------------------------------------------------
H.section("what is not a posting")
-- ---------------------------------------------------------------------------

H.check("no name is not recorded", not db.RecordPosting(nil, 1, 20, NOW))
H.check("an empty name is not", not db.RecordPosting("", 1, 20, NOW))
H.check("no quantity is not", not db.RecordPosting("X", 1, nil, NOW))
H.check("a zero quantity is not", not db.RecordPosting("X", 1, 0, NOW))
H.check("a negative one is not", not db.RecordPosting("X", 1, -3, NOW))

do
    reset()
    db.RecordPosting("X", 1, 2.7, NOW)
    H.eq("a fraction is floored", db.Postings()[1].qty, 2)
end

H.isNil("matching nothing is nothing", db.MatchPosting(nil, NOW))

-- ---------------------------------------------------------------------------
H.section("...and the real paths actually use it")
-- ---------------------------------------------------------------------------

-- A BOOK NOTHING WRITES TO IS A TESTED FUNCTION AND AN UNCHANGED SCREEN. Both
-- ways of posting have to record, and the mail scan has to match -- the
-- arithmetic above is correct either way.
do
    local function body(path)
        local f = assert(io.open(path, "r"), "run this from the repo root")
        local src = f:read("*a")
        f:close()
        return src
    end
    local sellSrc = body("core/sell.lua")
    local uiSrc = body("ui/frame.lua")
    local function says(src, needle)
        return string.find(src, needle, 1, true) ~= nil
    end

    H.check("posting one stack remembers it",
            says(sellSrc, "A.db.RecordPosting(it.name, it.itemId, count)"))
    -- ONE PER StartAuction, or a run of ten stacks leaves nine sales unable to
    -- say how many they were.
    H.check("...and so does every stack of a multi-post",
            says(sellSrc,
                 "A.db.RecordPosting(it.name, job.itemId, job.stackSize)"))

    H.check("a sale mail matches against it",
            says(uiSrc, "local qty = A.db.MatchPosting(item)"))
    H.check("...and passes the count to the ledger",
            says(uiSrc,
                 'A.db.RecordTxn("sale", item, money, A.db.IdFromName(item), qty)'))
    H.check("an expiry gives the posting back",
            says(uiSrc, "A.db.ExpirePosting(back)"))

    -- GetInboxInvoiceInfo MARKS THE MAIL AS READ, which shortens its timeout.
    -- In an inbox walk that would do it to every mail in the box, including
    -- mail Aegis has nothing to do with. Data loss, not lag.
    --
    -- SCOPED TO THE WALK, and looking for a CALL. The rule is not "never" --
    -- opening one mail is exactly where it belongs -- and the name appears in
    -- a comment right there explaining why it is not called, which a whole-file
    -- search for the bare name matches.
    local at = string.find(uiSrc, "function ui.ScanMailSales(", 1, true)
    local stop = string.find(uiSrc, "\nend\n", at, true)
    local walk = string.sub(uiSrc, at, stop)
    H.check("the inbox walk never CALLS the invoice API",
            string.find(walk, "GetInboxInvoiceInfo(", 1, true) == nil,
            "it reads the mail, which shortens every mail's life")
end

os.exit(H.report("postbook"))
