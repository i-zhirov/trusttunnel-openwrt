#!/bin/sh
# Runtime test for the LuCI views: executes status.js, settings.js and
# diagnostics.js against mocks that replicate the CURRENT LuCI runtime
# contracts (uci.load resolving with the package-name list, form without
# a plain Section class, E()/DOM.create reading only arguments[2]) and
# asserts the rendered output.
#
# This is the gate the syntax-only view checks cannot provide: the three
# released view bugs (v1.0.16-1.0.20 era) were all runtime contract
# mismatches — data.trusttunnel from uci.load(), form.Section, and
# variadic E() children — that parse fine and only fail when executed.
# The mocks deliberately implement the current contracts, so a regression
# to any of the old patterns fails here.
#
# Needs node (the CI job already runs node for the view syntax gate);
# without it the test skips (exit 77).

. "$(dirname "$0")/lib.sh"

if ! command -v node >/dev/null 2>&1; then
    tt_skip "node is not available (the views runtime test needs node)"
fi

out=$(node "$(dirname "$0")/views_runtime.js" 2>&1)
rc=$?

assert_eq "0" "$rc" "the view runtime harness exits 0"
assert_contains "$out" "ALL VIEW TESTS PASSED" "the view runtime harness reports success"

# The output is the evidence: keep the assertion lines visible.
printf '%s\n' "$out" | sed 's/^/    /'

tt_test_summary
