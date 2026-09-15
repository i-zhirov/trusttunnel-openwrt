#!/bin/sh
# Regenerate tests/fixtures/schema-keys.txt from the schema declarations in
# uci-export. Run from the repo root:
#
#     sh tests/tools/dump-schema-keys.sh > tests/fixtures/schema-keys.txt
#
# The fixture pins the canonical records schema for the classifier
# completeness check in test_init_apply.sh: a key added to uci-export
# without a class_for_key entry fails that test. Regenerate the fixture
# whenever uci-export gains or loses an option, and commit both together.
set -e

UCI_EXPORT="packages/luci-app-trusttunnel/root/usr/libexec/trusttunnel/uci-export"

# uci-export declares its schema in three shapes:
#   # schema-keys: <key>...                         — the profile options
#   for o in <opts>; do scalar <sec> "$o"; done     — section scalars
#   listopt <sec> <opt>                             — section lists
# A scalar loop may split its option list over a trailing-backslash line
# and puts its body (scalar, done) on the lines below, so every `for o in`
# declaration is joined into a single line first; loops without a scalar
# call (the profile section is emitted directly) are not declarations and
# fall through.
awk '
	{
		line = $0
		while (line ~ /\\$/ || (line ~ /^for o in / && line !~ /done/)) {
			if (getline nxt <= 0)
				break
			line = line " " nxt
		}
		if (line ~ /^# schema-keys: /) {
			sub(/^# schema-keys: /, "", line)
			n = split(line, a, /[ \t]+/)
			for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
		}
		else if (line ~ /^for o in / && line ~ /scalar /) {
			# Strip the backslash continuations, then read the section
			# from `scalar <sec> "$o"` and the options from the words
			# between `in` and the first `;`.
			gsub(/\\/, "", line)
			sec = ""
			n = split(line, a, /[ \t]+/)
			for (i = 1; i <= n; i++) if (a[i] == "scalar") sec = a[i + 1]
			sub(/^for o in[ \t]+/, "", line)
			sub(/;.*/, "", line)
			m = split(line, b, /[ \t]+/)
			for (i = 1; i <= m; i++) if (b[i] != "") print sec "." b[i]
		}
		else if (line ~ /^listopt /) {
			n = split(line, a, /[ \t]+/)
			print a[2] "." a[3]
		}
	}
' "$UCI_EXPORT" | sort -u
