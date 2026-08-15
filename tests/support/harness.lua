-- Aegis: Exchange -- tests/support/harness.lua
--
-- Assertions and reporting. Desktop Lua 5.1 only; never loaded by the client.
--
-- One rule this file exists to enforce: an assertion you have not seen FAIL is
-- decoration. Every check here reports the value it actually got, so a failure
-- tells you what happened rather than only that something did -- and
-- tests/sabotage.lua can flip the code under a suite and confirm the suite
-- notices.

local H = {}

H.passes   = 0
H.failures = {}
H.current  = "(no section)"

local function record(ok, label, detail)
    if ok then
        H.passes = H.passes + 1
        if H.verbose then print("  ok   " .. label) end
    else
        table.insert(H.failures, {
            section = H.current, label = label, detail = detail,
        })
        print("  FAIL [" .. H.current .. "] " .. label)
        if detail and detail ~= "" then print("         " .. detail) end
    end
    return ok
end

function H.section(name)
    H.current = name
    if H.verbose then print(name) end
end

-- Bare truthiness. `detail` should say what the value WAS.
function H.check(label, cond, detail)
    return record(cond and true or false, label, detail)
end

local function show(v)
    if v == nil then return "nil" end
    if type(v) == "string" then return '"' .. v .. '"' end
    return tostring(v)
end

function H.eq(label, got, want)
    return record(got == want, label,
                  "got " .. show(got) .. ", want " .. show(want))
end

function H.neq(label, got, unwanted)
    return record(got ~= unwanted, label,
                  "got " .. show(got) .. ", which is what it must NOT be")
end

function H.near(label, got, want, tol)
    tol = tol or 0.0001
    local ok = type(got) == "number"
                 and got >= want - tol and got <= want + tol
    return record(ok, label,
                  "got " .. show(got) .. ", want " .. show(want)
                  .. " +/- " .. tol)
end

function H.isNil(label, got)
    return record(got == nil, label, "got " .. show(got) .. ", want nil")
end

-- Arrays compared element-wise, so a failure names the differing index rather
-- than printing two blobs.
function H.listEq(label, got, want)
    if type(got) ~= "table" then
        return record(false, label, "got " .. show(got) .. ", want a table")
    end
    local gn, wn = table.getn(got), table.getn(want)
    if gn ~= wn then
        return record(false, label,
                      "length " .. gn .. ", want " .. wn
                      .. "  [" .. table.concat(got, ", ") .. "]")
    end
    for i = 1, wn do
        if got[i] ~= want[i] then
            return record(false, label,
                          "index " .. i .. ": got " .. show(got[i])
                          .. ", want " .. show(want[i]))
        end
    end
    return record(true, label)
end

-- `fn` must raise. Guards the paths that are supposed to refuse bad input.
function H.raises(label, fn)
    local ok = pcall(fn)
    return record(not ok, label, "call succeeded; it was expected to error")
end

-- `fn` must NOT raise. This is the shape most 1.12 API-contract tests take:
-- the client hands back nil far more often than callers expect, and a nil
-- reaching arithmetic is the single most common way this addon has broken.
function H.survives(label, fn)
    local ok, err = pcall(fn)
    return record(ok, label, "raised: " .. tostring(err))
end

function H.report(suiteName)
    local n = table.getn(H.failures)
    print("")
    if n == 0 then
        print(suiteName .. ": ALL PASS (" .. H.passes .. " checks)")
        return 0
    end
    print(suiteName .. ": " .. n .. " FAILED of "
          .. (H.passes + n) .. " checks")
    for i = 1, n do
        local f = H.failures[i]
        print("  - [" .. f.section .. "] " .. f.label)
    end
    return 1
end

return H
