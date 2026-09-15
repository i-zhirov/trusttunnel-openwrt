#!/bin/sh
# License-clean gate: fail when a blob reachable from the current HEAD tree
# (default) — or from any ref, with --history — is byte-identical to a file
# of the upstream NooBiToo/TrustTunnelOpenWrt repository. The upstream
# content hashes are pinned in upstream-blobs.sha1 next to this script.
#
# The manifest holds git object SHA-1s only, never upstream content:
# committing it does not redistribute any of the upstream GPL-2.0 material.
#
# Regenerate the manifest from a fresh upstream clone when re-auditing
# against a new upstream ref (run from that clone):
#
#     git ls-files -z | xargs -0 -n1 git hash-object | sort -u \
#         > /path/to/tests/license-clean/upstream-blobs.sha1
#
# The tree gate is the CI contract; the history gate is the publish-time
# verification (run `git reflog expire --expire=now --all` first so
# reflogs do not pin old objects).
#
# Usage: sh tests/license-clean/check.sh [--history]
set -u

BASE="$(dirname "$0")"
MANIFEST="$BASE/upstream-blobs.sha1"

[ -f "$MANIFEST" ] || {
	echo "license-clean: manifest missing: $MANIFEST" >&2
	exit 1
}

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

if [ "${1:-}" = "--history" ]; then
	# Every object reachable from any ref. The first field is the object
	# name; git object names are content-addressed, so a SHA that matches
	# the manifest is byte-identical regardless of whether the object is
	# local (partial clones report absent blobs as "<sha> <path> missing",
	# which is why the object TYPE is never inspected here).
	git rev-list --all --objects \
		| awk '{ print $1 }' \
		| sort -u > "$tmp/blobs"
else
	git ls-tree -r HEAD \
		| awk '$2 == "blob" { print $3 }' \
		| sort -u > "$tmp/blobs"
fi

comm -12 "$tmp/blobs" "$MANIFEST" > "$tmp/hits"

if [ -s "$tmp/hits" ]; then
	echo "license-clean: FAIL — byte-identical to an upstream file:" >&2
	while read -r h; do
		git ls-tree -r HEAD | awk -v h="$h" '$2 == "blob" && $3 == h { print "  " $4 }'
	done < "$tmp/hits"
	exit 1
fi

count=$(grep -c . "$tmp/blobs")
echo "license-clean: OK ($count blobs checked, none matches upstream)"
