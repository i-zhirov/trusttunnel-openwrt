#!/bin/sh
# Pins the client-only release path in .github/workflows/release.yml: a
# client-v* tag must publish a new client without rebuilding the LuCI app
# or re-running the full integration suite, and the publish step must not
# be blocked by those skipped jobs. The failure modes are silent and
# expensive (a broken gate fails late in a 37-arch matrix, or publishes a
# release whose packages do not match its tag), so the workflow structure
# is a contract, like the dependency declarations in test_deps.sh.
. "$(dirname "$0")/lib.sh"

WF=.github/workflows/release.yml
[ -f "$WF" ] || { echo "  FAIL: cannot read $WF"; exit 1; }
wf="$(cat "$WF")"

# Extract one top-level job block (two-space indent) from the workflow.
job_body() {
	awk -v job="$1" '
		$0 ~ "^  " job ":" { inbody = 1; next }
		inbody && $0 ~ "^  [a-z][a-z0-9-]*:" { exit }
		inbody { print }
	' "$WF"
}

# The trigger: client-v* tags enter the same pipeline as v* tags.
assert_contains "$wf" '- "client-v*"' "release.yml triggers on client-v* tags"

# The gate job refuses runs that are not tag pushes: it must accept
# client-v* tags too, or a client-only release would be refused before
# any build starts.
assert_contains "$(job_body gate)" 'refs/tags/v*|refs/tags/client-v*' "the gate accepts client-v* tag pushes"

# The app build must be skipped on client-v* tags: its artifact-name
# assertion derives the version from the tag, and on a client-v* tag it
# would demand a client version in the app's file name and fail.
assert_contains "$(job_body build)" "!startsWith(github.ref, 'refs/tags/client-v')" "the app build skips client-v* tags"

# The full end-to-end suite is deliberately skipped for client-only
# releases; the publish step verifies the new client against the current
# app instead.
assert_contains "$(job_body verify-integration)" "!startsWith(github.ref, 'refs/tags/client-v')" "verify-integration skips client-v* tags"

# The client matrix must assert the built package against the tag — the
# mirror of the app's own tag-matching assertion, scoped to client tags.
assert_contains "$(job_body build-client)" "Assert the client version matches the tag" "build-client asserts the client version against a client-v* tag"
assert_contains "$(job_body build-client)" 'GITHUB_REF_NAME#client-v' "build-client derives the expected version from the tag"

# The publish job must run when the app build and the integration run
# were skipped (its needs then include skipped jobs), but must not run
# when anything failed: !failure() && !cancelled() is the gate.
assert_contains "$(job_body publish-repo)" '!failure() && !cancelled()' "publish-repo runs past skipped jobs but not past failures"

# On a client-only release the app artifacts do not exist: the download
# steps are gated, and the app is merged from the prior releases instead.
assert_contains "$(job_body publish-repo)" "Download the LuCI packages (apk)" "publish-repo still downloads the app artifacts on v* tags"
assert_contains "$(job_body publish-repo)" "!startsWith(github.ref, 'refs/tags/client-v')" "the app download steps are gated on client-v* tags"

# The rootfs verification asserts the installed client version: on a
# client-v* release this is what proves the repositories serve the new
# client together with the current app.
assert_contains "$(job_body publish-repo)" 'grep -q "$CLIENT_VERSION"' "the rootfs verification asserts the installed client version"

# The release upload splits: a v* tag carries app+client, a client-v*
# tag the client files alone (the app is unchanged and lives on its own
# release).
assert_contains "$(job_body publish-repo)" "Upload the client files to the client GitHub release" "publish-repo uploads a client-only release"
assert_contains "$(job_body publish-repo)" "startsWith(github.ref, 'refs/tags/v')" "the app+client upload step is scoped to v* tags"

tt_test_summary
