#!/bin/sh
# Scenario harness for the first-boot uci-defaults script.
#
# The script under test runs inside an OpenWrt rootfs container against
# scratch /etc/config/firewall and /etc/config/trusttunnel fixtures. The
# real uci toolchain and /lib/functions.sh from the image do the work;
# /etc/init.d/firewall, /etc/init.d/trusttunnel and logger are stubs that
# record their calls, so the assertions observe side effects instead of
# guessing at them. Six scenarios cover the contract: fresh, duplicated,
# legacy (tt0 binding), upgrade (profile seed), side-effects, idempotent.
#
# Selectors:
#   TT_UCD_SCRIPT  path of the script under test (default: the package's
#                  uci-defaults file; the file must live inside the
#                  uci-defaults directory mounted into the container)
#   TT_UCD_FILTER  case pattern limiting the scenarios, e.g. 'fresh' or
#                  'fresh|duplicated' (default: all six)
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

TT_UCD_SCRIPT=${TT_UCD_SCRIPT:-packages/luci-app-trusttunnel/root/etc/uci-defaults/40-luci-trusttunnel}
TT_UCD_FILTER=${TT_UCD_FILTER:-}

# Local machines without docker keep the suite runnable: report a visible
# skip; the CI runners always have docker.
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    tt_skip "docker unavailable — scenario tests not run"
fi

UCD_IMAGE=openwrt/rootfs:x86-64-25.12.0
UCD_SCRIPT_DIR=packages/luci-app-trusttunnel/root/etc/uci-defaults

# The fixture area must be visible inside the container. On the Linux CI
# runners TT_TEST_TMP (/tmp) binds in cleanly; the colima VM on macOS does
# not share /var/folders, so when the probe finds the scratch dir invisible
# the fixtures are staged under $HOME instead and removed on exit.
UCD_FIXTURE_ROOT=$TT_TEST_TMP
UCD_FIXTURE_TMP=""
UCD_PROBE=$UCD_FIXTURE_ROOT/.docker-visible-probe
: > "$UCD_PROBE"
if ! docker run --rm -v "$TT_TEST_TMP:/probe:ro" "$UCD_IMAGE" \
        sh -c 'test -f /probe/.docker-visible-probe' >/dev/null 2>&1; then
    # macOS mktemp ignores TMPDIR, so create the staging directory under
    # $HOME explicitly; $HOME is shared into the colima VM.
    UCD_FIXTURE_ROOT="$HOME/.cache/tt-ucd-$$"
    mkdir -p "$UCD_FIXTURE_ROOT" || exit 1
    UCD_FIXTURE_TMP=$UCD_FIXTURE_ROOT
    trap 'rm -rf "$UCD_FIXTURE_TMP"' EXIT HUP INT TERM
fi
rm -f "$UCD_PROBE"

# --- container command --------------------------------------------------------

# The container setup is common to every scenario: replace the stock configs
# and init scripts with the fixture copies (rm first: /bin/logger, /usr/bin/
# logger and the init scripts may be symlinks, and cp would write through
# them), then start the call logs empty.
ucd_setup='rm -f /etc/init.d/firewall /etc/init.d/trusttunnel /bin/logger /usr/bin/logger
cp /fixture/firewall /etc/config/firewall
cp /fixture/trusttunnel /etc/config/trusttunnel
cp /fixture/firewall-stub /etc/init.d/firewall
cp /fixture/trusttunnel-stub /etc/init.d/trusttunnel
cp /fixture/logger-stub /bin/logger
cp /fixture/logger-stub /usr/bin/logger
chmod +x /etc/init.d/firewall /etc/init.d/trusttunnel /bin/logger /usr/bin/logger
: > /tmp/tt_reloads
: > /tmp/tt_log
: > /tmp/tt_enable_log'

# ucd_run <name> <double: 0|1> <extra-setup>
# Runs the container, capturing stdout+stderr into <fixture>/out. The
# single-run variant dumps the UCI state and the recorded side effects once;
# the double-run variant runs the script twice, snapshots the state and the
# log after each run, and reports the diffs so the assertions can prove that
# the second run changed nothing.
ucd_run() {
    ucd_r_name=$1
    ucd_r_double=$2
    ucd_r_extra=$3
    ucd_r_fixture=$UCD_FIXTURE_ROOT/$ucd_r_name
    ucd_r_script=$(basename "$TT_UCD_SCRIPT")

    ucd_cmd=$ucd_setup
    if [ -n "$ucd_r_extra" ]; then
        ucd_cmd="$ucd_cmd
$ucd_r_extra"
    fi
    # The embedded $? and $(...) are for the container shell; the host must
    # pass them through untouched, hence the single-quoted segments.
    # shellcheck disable=SC2016
    if [ "$ucd_r_double" -eq 1 ]; then
        ucd_cmd="$ucd_cmd
sh /script/$ucd_r_script"'
echo "SCRIPT_EXIT=$?"
uci show firewall > /tmp/fw1
uci show trusttunnel > /tmp/tt1
echo "RELOADS1=$(wc -l < /tmp/tt_reloads)"
cp /tmp/tt_log /tmp/tt_log1
sh /script/'"$ucd_r_script"'
echo "SCRIPT_EXIT2=$?"
uci show firewall > /tmp/fw2
uci show trusttunnel > /tmp/tt2
echo "RELOADS2=$(wc -l < /tmp/tt_reloads)"
echo "ENABLE=$(wc -l < /tmp/tt_enable_log)"
if cmp -s /tmp/fw1 /tmp/fw2; then echo FW_IDENTICAL=yes; else echo FW_IDENTICAL=no; fi
if cmp -s /tmp/tt1 /tmp/tt2; then echo TT_IDENTICAL=yes; else echo TT_IDENTICAL=no; fi
if cmp -s /tmp/tt_log1 /tmp/tt_log; then echo LOG_STABLE=yes; else echo LOG_STABLE=no; fi
echo ---FW1---
cat /tmp/fw1
echo ---TT1---
cat /tmp/tt1
echo ---FW2---
cat /tmp/fw2
echo ---TT2---
cat /tmp/tt2
echo ---LOG---
cat /tmp/tt_log
readlink /etc/rc.d/S95trusttunnel 2>/dev/null
if [ -d /var/cache/trusttunnel ]; then echo CACHE_DIR=present; else echo CACHE_DIR=missing; fi
ls /var/cache/trusttunnel 2>/dev/null'
    else
        ucd_cmd="$ucd_cmd
sh /script/$ucd_r_script"'
echo "SCRIPT_EXIT=$?"
uci show firewall
uci show trusttunnel
echo "RELOADS=$(wc -l < /tmp/tt_reloads)"
echo "ENABLE=$(wc -l < /tmp/tt_enable_log)"
cat /tmp/tt_log
readlink /etc/rc.d/S95trusttunnel 2>/dev/null
if [ -d /var/cache/trusttunnel ]; then echo CACHE_DIR=present; else echo CACHE_DIR=missing; fi
ls /var/cache/trusttunnel 2>/dev/null
ls /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null'
    fi

    docker run --rm \
        -v "$PWD/$UCD_SCRIPT_DIR:/script:ro" \
        -v "$ucd_r_fixture:/fixture:ro" \
        "$UCD_IMAGE" sh -c "$ucd_cmd" < /dev/null \
        > "$ucd_r_fixture/out" 2>&1 || true
}

# --- fixtures -----------------------------------------------------------------

# ucd_stubs <dir> — the three recording stubs shared by every scenario.
ucd_stubs() {
    ucd_s_dir=$1
    cat > "$ucd_s_dir/firewall-stub" <<'EOF'
#!/bin/sh
echo reload >> /tmp/tt_reloads
exit 0
EOF
    cat > "$ucd_s_dir/trusttunnel-stub" <<'EOF'
#!/bin/sh
mkdir -p /etc/rc.d
ln -sf ../../etc/init.d/trusttunnel /etc/rc.d/S95trusttunnel
echo enable >> /tmp/tt_enable_log
exit 0
EOF
    cat > "$ucd_s_dir/logger-stub" <<'EOF'
#!/bin/sh
echo "$*" >> /tmp/tt_log
exit 0
EOF
}

# The default trusttunnel fixture shape is the shipped-config shape: a
# routing_profile section already present, so the seed block is a no-op.
# The upgrade shape (no profile, populated domains.direct) is written by the
# scenarios that need the seed block to fire.
ucd_trusttunnel_default() {
    ucd_t_dir=$1
    cat > "$ucd_t_dir/trusttunnel" <<'EOF'
config routing_profile
	option name 'Default'
	option mode 'vpn'
EOF
}

# --- assertions ---------------------------------------------------------------

# ucd_grep_count <pattern> <text> — number of matching lines, 0 when none.
ucd_grep_count() {
    ucd_gc_pattern=$1
    ucd_gc_text=$2
    printf '%s\n' "$ucd_gc_text" | grep -c "$ucd_gc_pattern" || true
}

# ucd_block <name> <text> — extract a "---NAME---"-marked block from the
# double-run output.
ucd_block() {
    ucd_b_name=$1
    ucd_b_text=$2
    printf '%s\n' "$ucd_b_text" | awk -v name="$ucd_b_name" '
        $0 == "---" name "---" { grab = 1; next }
        grab && /^---/ { exit }
        grab { print }
    '
}

# --- scenarios ----------------------------------------------------------------

scenario_fresh() {
    ucd_f_dir=$UCD_FIXTURE_ROOT/fresh
    mkdir -p "$ucd_f_dir"
    cat > "$ucd_f_dir/firewall" <<'EOF'
config defaults
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'REJECT'
EOF
    ucd_trusttunnel_default "$ucd_f_dir"
    ucd_stubs "$ucd_f_dir"
    ucd_run fresh 0 ""

    ucd_out=$(cat "$ucd_f_dir/out")

    assert_contains "$ucd_out" "SCRIPT_EXIT=0" \
        "fresh: the script exits 0"
    assert_eq "1" "$(ucd_grep_count "name='trusttunnel'" "$ucd_out")" \
        "fresh: exactly one trusttunnel zone"
    assert_contains "$ucd_out" "firewall.@zone[0].name='trusttunnel'" \
        "fresh: zone created with the contractual name"
    assert_contains "$ucd_out" "firewall.@zone[0].input='REJECT'" \
        "fresh: zone input REJECT"
    assert_contains "$ucd_out" "firewall.@zone[0].output='ACCEPT'" \
        "fresh: zone output ACCEPT"
    assert_contains "$ucd_out" "firewall.@zone[0].forward='REJECT'" \
        "fresh: zone forward REJECT"
    assert_contains "$ucd_out" "firewall.@zone[0].masq='1'" \
        "fresh: zone masq enabled"
    assert_contains "$ucd_out" "firewall.@zone[0].mtu_fix='1'" \
        "fresh: zone mtu_fix enabled"
    assert_contains "$ucd_out" "firewall.@zone[0].device='tun+'" \
        "fresh: zone binds the tun+ wildcard"
    assert_contains "$ucd_out" "firewall.@forwarding[0].src='lan'" \
        "fresh: forwarding from lan"
    assert_contains "$ucd_out" "firewall.@forwarding[0].dest='trusttunnel'" \
        "fresh: forwarding to trusttunnel"
    assert_eq "1" "$(ucd_grep_count "dest='trusttunnel'" "$ucd_out")" \
        "fresh: exactly one forwarding to trusttunnel"
    assert_contains "$ucd_out" "RELOADS=1" \
        "fresh: firewall reloaded exactly once"
    assert_eq "0" "$(ucd_grep_count '^-t trusttunnel' "$ucd_out")" \
        "fresh: no log lines (the seed block is a no-op)"
}

scenario_duplicated() {
    ucd_d_dir=$UCD_FIXTURE_ROOT/duplicated
    mkdir -p "$ucd_d_dir"
    cat > "$ucd_d_dir/firewall" <<'EOF'
config defaults
	option input 'ACCEPT'

config zone
	option name 'trusttunnel'
	option marker 'first'

config zone
	option name 'trusttunnel'
	option marker 'second'

config zone
	option name 'trusttunnel'
	option marker 'third'

config forwarding
	option dest 'trusttunnel'
	option marker 'a'

config forwarding
	option dest 'trusttunnel'
	option marker 'b'

config forwarding
	option dest 'trusttunnel'
	option marker 'c'

config zone
	option name 'lanzone'
EOF
    ucd_trusttunnel_default "$ucd_d_dir"
    ucd_stubs "$ucd_d_dir"
    ucd_run duplicated 0 ""

    ucd_out=$(cat "$ucd_d_dir/out")

    assert_contains "$ucd_out" "SCRIPT_EXIT=0" \
        "duplicated: the script exits 0"
    assert_eq "1" "$(ucd_grep_count "name='trusttunnel'" "$ucd_out")" \
        "duplicated: duplicates collapsed to one trusttunnel zone"
    assert_contains "$ucd_out" "marker='first'" \
        "duplicated: the first zone is kept"
    assert_eq "0" "$(ucd_grep_count "marker='third'" "$ucd_out")" \
        "duplicated: the third zone is removed"
    assert_eq "2" "$(ucd_grep_count '@zone\[[0-9]*\]=zone' "$ucd_out")" \
        "duplicated: two zones total, the unrelated one survives"
    assert_contains "$ucd_out" "name='lanzone'" \
        "duplicated: the unrelated zone is untouched"
    assert_eq "1" "$(ucd_grep_count "dest='trusttunnel'" "$ucd_out")" \
        "duplicated: one forwarding to trusttunnel kept"
    assert_contains "$ucd_out" "marker='a'" \
        "duplicated: the first forwarding is kept"
    assert_eq "0" "$(ucd_grep_count "marker='c'" "$ucd_out")" \
        "duplicated: the third forwarding is removed"
    assert_contains "$ucd_out" "RELOADS=2" \
        "duplicated: one reload for the dedup and one for the device repair"
    assert_eq "1" "$(ucd_grep_count 'removed duplicate firewall zones left by an earlier version' "$ucd_out")" \
        "duplicated: the dedup log line appears exactly once"
    assert_eq "1" "$(ucd_grep_count 'firewall zone migrated from tt0 to the tun+ wildcard' "$ucd_out")" \
        "duplicated: the migration log line appears exactly once"
    assert_eq "2" "$(ucd_grep_count "device='tun+'" "$ucd_out")" \
        "duplicated: the surviving zones all bind the tun+ wildcard"
}

scenario_legacy() {
    ucd_l_dir=$UCD_FIXTURE_ROOT/legacy
    mkdir -p "$ucd_l_dir"
    cat > "$ucd_l_dir/firewall" <<'EOF'
config zone
	option name 'trusttunnel'
	list device 'tt0'
EOF
    ucd_trusttunnel_default "$ucd_l_dir"
    ucd_stubs "$ucd_l_dir"
    ucd_run legacy 0 ""

    ucd_out=$(cat "$ucd_l_dir/out")

    assert_contains "$ucd_out" "SCRIPT_EXIT=0" \
        "legacy: the script exits 0"
    assert_eq "1" "$(ucd_grep_count "name='trusttunnel'" "$ucd_out")" \
        "legacy: the existing zone stays"
    assert_contains "$ucd_out" "device='tun+'" \
        "legacy: the zone binds the tun+ wildcard after migration"
    assert_eq "0" "$(ucd_grep_count "device='tt0'" "$ucd_out")" \
        "legacy: the old tt0 binding is gone"
    assert_contains "$ucd_out" "RELOADS=1" \
        "legacy: firewall reloaded exactly once"
    assert_eq "1" "$(ucd_grep_count 'firewall zone migrated from tt0 to the tun+ wildcard' "$ucd_out")" \
        "legacy: the migration log line appears exactly once"
    assert_eq "0" "$(ucd_grep_count "dest='trusttunnel'" "$ucd_out")" \
        "legacy: no forwarding created (creation only fires without a zone)"
}

scenario_upgrade() {
    ucd_u_dir=$UCD_FIXTURE_ROOT/upgrade
    mkdir -p "$ucd_u_dir"
    cat > "$ucd_u_dir/firewall" <<'EOF'
config zone
	option name 'trusttunnel'
	list device 'tun+'

config forwarding
	option src 'lan'
	option dest 'trusttunnel'
EOF
    cat > "$ucd_u_dir/trusttunnel" <<'EOF'
config endpoint 'endpoint'
	option host 'vpn.example.com'

config domains 'domains'
	list direct 'example.com'
	list direct 'api.example.net'
EOF
    ucd_stubs "$ucd_u_dir"
    ucd_run upgrade 1 ""

    ucd_out=$(cat "$ucd_u_dir/out")
    ucd_tt1=$(ucd_block TT1 "$ucd_out")
    ucd_tt2=$(ucd_block TT2 "$ucd_out")

    assert_contains "$ucd_out" "SCRIPT_EXIT=0" \
        "upgrade: run 1 exits 0"
    assert_contains "$ucd_out" "SCRIPT_EXIT2=0" \
        "upgrade: run 2 exits 0"
    assert_eq "1" "$(ucd_grep_count '@routing_profile\[[0-9]*\]=routing_profile' "$ucd_tt1")" \
        "upgrade: one routing profile seeded"
    assert_contains "$ucd_tt1" "name='Default'" \
        "upgrade: the seeded profile is named Default"
    assert_contains "$ucd_tt1" "mode='vpn'" \
        "upgrade: the seeded profile mode is vpn"
    assert_contains "$ucd_tt1" "bypass_rules='example.com api.example.net'" \
        "upgrade: every domains.direct value moved into bypass_rules"
    assert_contains "$ucd_tt1" "endpoint.routing_profile='Default'" \
        "upgrade: the endpoint references the seeded profile"
    assert_contains "$ucd_out" "RELOADS1=0" \
        "upgrade: the firewall block is untouched on run 1"
    assert_contains "$ucd_out" "RELOADS2=0" \
        "upgrade: the firewall block is untouched on run 2"
    assert_contains "$ucd_out" "FW_IDENTICAL=yes" \
        "upgrade: the firewall state is identical after run 2"
    assert_contains "$ucd_out" "TT_IDENTICAL=yes" \
        "upgrade: the trusttunnel state is identical after run 2"
    assert_contains "$ucd_out" "LOG_STABLE=yes" \
        "upgrade: no new log lines on run 2"
    assert_eq "1" "$(ucd_grep_count 'created the default routing profile; the old direct list moved into its bypass rules' "$ucd_out")" \
        "upgrade: the seed log line appears exactly once"
    assert_eq "1" "$(ucd_grep_count '@routing_profile\[[0-9]*\]=routing_profile' "$ucd_tt2")" \
        "upgrade: no second profile after run 2"
}

scenario_side_effects() {
    ucd_e_dir=$UCD_FIXTURE_ROOT/side-effects
    mkdir -p "$ucd_e_dir"
    cat > "$ucd_e_dir/firewall" <<'EOF'
config defaults
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'REJECT'
EOF
    ucd_trusttunnel_default "$ucd_e_dir"
    ucd_stubs "$ucd_e_dir"

    ucd_extra='mkdir -p /tmp/luci-modulecache
echo stale > /tmp/luci-modulecache/cache-entry
: > /tmp/luci-indexcache'

    ucd_run side-effects 0 "$ucd_extra"

    ucd_out=$(cat "$ucd_e_dir/out")

    assert_contains "$ucd_out" "SCRIPT_EXIT=0" \
        "side-effects: the script exits 0"
    assert_contains "$ucd_out" "../../etc/init.d/trusttunnel" \
        "side-effects: the rc.d link points at the init script"
    assert_contains "$ucd_out" "ENABLE=1" \
        "side-effects: the service enable call happened exactly once"
    assert_contains "$ucd_out" "CACHE_DIR=missing" \
        "side-effects: the update-check cache directory is not created"
    assert_eq "0" "$(ucd_grep_count 'luci-indexcache' "$ucd_out")" \
        "side-effects: the LuCI index cache is removed"
    assert_eq "0" "$(ucd_grep_count 'cache-entry' "$ucd_out")" \
        "side-effects: the LuCI module cache is emptied"
    assert_eq "0" "$(ucd_grep_count '^-t trusttunnel' "$ucd_out")" \
        "side-effects: no log lines (the seed block is a no-op)"
}

scenario_idempotent() {
    ucd_i_dir=$UCD_FIXTURE_ROOT/idempotent
    mkdir -p "$ucd_i_dir"
    cat > "$ucd_i_dir/firewall" <<'EOF'
config defaults
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'REJECT'
EOF
    cat > "$ucd_i_dir/trusttunnel" <<'EOF'
config endpoint 'endpoint'
	option host 'vpn.example.com'

config domains 'domains'
	list direct 'example.com'
	list direct 'api.example.net'
EOF
    ucd_stubs "$ucd_i_dir"
    ucd_run idempotent 1 ""

    ucd_out=$(cat "$ucd_i_dir/out")
    ucd_fw1=$(ucd_block FW1 "$ucd_out")
    ucd_tt2=$(ucd_block TT2 "$ucd_out")

    assert_contains "$ucd_out" "SCRIPT_EXIT=0" \
        "idempotent: run 1 exits 0"
    assert_contains "$ucd_out" "SCRIPT_EXIT2=0" \
        "idempotent: run 2 exits 0"
    assert_contains "$ucd_fw1" "name='trusttunnel'" \
        "idempotent: the zone is created on run 1"
    assert_contains "$ucd_out" "FW_IDENTICAL=yes" \
        "idempotent: the firewall state is identical after run 2"
    assert_contains "$ucd_out" "TT_IDENTICAL=yes" \
        "idempotent: the trusttunnel state is identical after run 2"
    assert_contains "$ucd_out" "LOG_STABLE=yes" \
        "idempotent: no new log lines on run 2"
    assert_contains "$ucd_out" "RELOADS1=1" \
        "idempotent: one reload on run 1"
    assert_contains "$ucd_out" "RELOADS2=1" \
        "idempotent: no reload on run 2"
    assert_eq "1" "$(ucd_grep_count '@routing_profile\[[0-9]*\]=routing_profile' "$ucd_tt2")" \
        "idempotent: the seeded profile is not duplicated"
    assert_eq "1" "$(ucd_grep_count 'created the default routing profile; the old direct list moved into its bypass rules' "$ucd_out")" \
        "idempotent: the seed log line appears exactly once"
}

# --- runner -------------------------------------------------------------------

ucd_matches() {
    ucd_m_name=$1
    # TT_UCD_FILTER is deliberately a case pattern (e.g. 'fresh|duplicated'),
    # not a literal string, so it must stay unquoted.
    # shellcheck disable=SC2254
    case $ucd_m_name in
        $TT_UCD_FILTER) return 0 ;;
        *) return 1 ;;
    esac
}

for ucd_scenario in fresh duplicated legacy upgrade side-effects idempotent; do
    if [ -z "$TT_UCD_FILTER" ] || ucd_matches "$ucd_scenario"; then
        echo "== scenario: $ucd_scenario"
        case $ucd_scenario in
            side-effects) scenario_side_effects ;;
            *) scenario_$ucd_scenario ;;
        esac
    fi
done

tt_test_summary
