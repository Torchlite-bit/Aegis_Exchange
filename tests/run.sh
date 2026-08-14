#!/usr/bin/env bash
#
# Aegis: Exchange -- the whole check suite.
#
#   ./tests/run.sh              lint + compile + units
#   ./tests/run.sh --sabotage   ...and prove the suites catch real bugs
#
# Run from the REPO ROOT. Needs lua5.1 / luac5.1 and python3; on Debian or
# Ubuntu that is `apt install lua5.1 liblua5.1-0-dev` (luac5.1 ships with it).
#
# NOTHING HERE RUNS IN THE GAME. These are desktop Lua 5.1 scripts, and none of
# tests/ is in Aegis_Exchange.toc. See tests/README.md for what this can and
# cannot tell you -- the short version is that it covers logic and API shape,
# and says nothing at all about how the window looks.

set -u

cd "$(dirname "$0")/.." || exit 1

fail=0
step() {
    printf '\n\033[1m== %s ==\033[0m\n' "$1"
}

# ---------------------------------------------------------------------------
step "Lua 5.0 language rules"
# Every construct this catches is legal Lua 5.1, so nothing else in this file
# would notice. It has its own self-test because a lint that never fires is
# worse than none.
python3 tests/lint/selftest.py  >/dev/null || { echo "lint selftest FAILED"; \
    python3 tests/lint/selftest.py; fail=1; }
python3 tests/lint/lua50.py     || fail=1

# ---------------------------------------------------------------------------
step "Syntax"
for f in core/*.lua ui/*.lua; do
    if ! luac5.1 -p "$f" 2>/tmp/aegis-luac-err; then
        echo "FAIL $f"
        cat /tmp/aegis-luac-err
        fail=1
    fi
done
[ "$fail" -eq 0 ] && echo "syntax: ok"

# ---------------------------------------------------------------------------
step "Upvalue ceiling (32 -- the client REFUSES to load past this)"
python3 tests/lint/upvalues.py || fail=1

# ---------------------------------------------------------------------------
step "Top-level definitions still present"
# Skipped when the tree is dirty against no useful ref, or outside a git repo.
if git rev-parse --git-dir >/dev/null 2>&1; then
    python3 tests/lint/definitions.py HEAD >/dev/null || {
        python3 tests/lint/definitions.py HEAD; fail=1; }
    echo "definitions: ok (vs HEAD)"
else
    echo "definitions: skipped (not a git repo)"
fi

# ---------------------------------------------------------------------------
step "Unit suites"
for t in tests/units/*.lua; do
    if out=$(lua5.1 "$t" 2>&1); then
        echo "$out" | tail -1
    else
        echo "$out"
        fail=1
    fi
done

# ---------------------------------------------------------------------------
if [ "${1:-}" = "--sabotage" ]; then
    step "Sabotage (each planted bug MUST be caught)"
    python3 tests/sabotage.py || fail=1
fi

# ---------------------------------------------------------------------------
echo ""
if [ "$fail" -eq 0 ]; then
    printf '\033[32mall checks passed\033[0m\n'
else
    printf '\033[31mSOMETHING FAILED -- see above\033[0m\n'
fi
exit "$fail"
