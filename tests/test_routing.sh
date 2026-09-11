#!/bin/sh
# Routing script contract test.
#
# Real ip/nft calls are replaced by the stub scripts below: every invocation
# appends its argv to the log file $TT_CMD_LOG, the nft stub captures stdin
# only for the "-f -" transaction (the suite runner closes stdin, so an
# unconditional read would hang), and ip always reports success so the live
# device checks in attach pass. The fixture endpoints are literal addresses,
# which keeps real nslookup out of the test.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

R=packages/luci-app-trusttunnel/root/usr/libexec/trusttunnel/routing
export TT_LIBDIR="${TT_LIBDIR:-packages/luci-app-trusttunnel/root/usr/libexec/trusttunnel}"

stub_dir=$TT_TEST_TMP/bin
mkdir -p "$stub_dir"
cat > "$stub_dir/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "ip $*" >> "$TT_CMD_LOG"
exit 0
EOF
cat > "$stub_dir/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "nft $*" >> "$TT_CMD_LOG"
if [ "${1-}" = "-f" ] && [ "${2-}" = "-" ]; then
    cat > "$TT_NFT_STDIN"
fi
exit 0
EOF
chmod +x "$stub_dir/ip" "$stub_dir/nft"

export TT_IP="$stub_dir/ip"
export TT_NFT="$stub_dir/nft"
export TT_CMD_LOG="$TT_TEST_TMP/cmd.log"
export TT_NFT_STDIN="$TT_TEST_TMP/nft.stdin"
: > "$TT_CMD_LOG"
: > "$TT_NFT_STDIN"

# Fixtures: two dump shapes (router traffic off / on), a variant with the
# blackhole disabled, and an endpoint list with one IPv4 and one IPv6
# literal.
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan br-guest\nnetwork.include_router_traffic\t0\n' > "$TT_TEST_TMP/up.tsv"
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan\nnetwork.include_router_traffic\t1\n' > "$TT_TEST_TMP/router.tsv"
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan\nnetwork.include_router_traffic\t0\nnetwork.blackhole_on_down\t0\n' > "$TT_TEST_TMP/nobh.tsv"
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan br-guest\nnetwork.include_router_traffic\t0\nendpoint.address\t1.2.3.4:443\nendpoint.address\t[2001:db8::1]:443\n' > "$TT_TEST_TMP/eps.tsv"

# --- dump --------------------------------------------------------------------

dump_up="$(sh "$R" dump "$TT_TEST_TMP/up.tsv")"
dump_router="$(sh "$R" dump "$TT_TEST_TMP/router.tsv")"

# line_count <needle> <text> — how many lines of <text> match <needle>.
line_count() {
    printf '%s\n' "$2" | grep -c "$1"
}

assert_contains "$dump_up" 'table inet trusttunnel { }' "dump opens with an empty table"
assert_contains "$dump_up" 'delete table inet trusttunnel' "dump deletes the table first, so it is idempotent"
assert_contains "$dump_up" 'set tt_endpoint4 { type ipv4_addr; flags interval; }' "dump declares the IPv4 endpoint set"
assert_contains "$dump_up" 'set tt_endpoint6 { type ipv6_addr; flags interval; }' "dump declares the IPv6 endpoint set"
assert_contains "$dump_up" 'type filter hook prerouting priority mangle' "prerouting is a filter/mangle hook"
assert_contains "$dump_up" 'iifname != { "br-lan", "br-guest" } return' "prerouting returns for the LAN devices"
assert_contains "$dump_up" 'ip daddr @tt_endpoint4 return' "prerouting returns marked IPv4 endpoints"
assert_contains "$dump_up" 'ip6 daddr @tt_endpoint6 return' "prerouting returns marked IPv6 endpoints"
assert_contains "$dump_up" '192.168.0.0/16' "the private IPv4 ranges are returned (spot check)"
assert_contains "$dump_up" 'fc00::/7' "the private IPv6 ranges are returned (spot check)"
assert_contains "$dump_up" 'meta mark set 0x9527' "matching traffic gets the fwmark"
assert_eq "0" "$(line_count 'tt_bypass' "$dump_up")" "no bypass sets are emitted"
assert_eq "0" "$(line_count 'hook output' "$dump_up")" "no output chain while router traffic is off"
assert_eq "0" "$(line_count 'dstnat' "$dump_up")" "no dstnat chain is emitted"

assert_contains "$dump_router" 'iifname != { "br-lan" } return' "single LAN device in the router-traffic dump"
assert_contains "$dump_router" 'type route hook output priority mangle' "router traffic adds the output chain"
assert_contains "$dump_router" 'oifname "tun*" return' "the output chain spares the tunnel device"
assert_eq "0" "$(line_count 'dstnat' "$dump_router")" "no dstnat chain with router traffic either"

# Line-break hygiene that substring checks cannot see: a verdict must end
# its line (nothing glued after "return") and a closing brace must sit on
# its own line (never after the mark statement).
assert_eq "0" "$(printf '%s\n' "$dump_up" | grep -cE 'return[[:space:]]+[a-z]')" "every return verdict ends its line"
assert_eq "0" "$(printf '%s\n' "$dump_up" | grep -c 'mark set.*}')" "the closing brace has its own line"
assert_eq "0" "$(printf '%s\n' "$dump_router" | grep -cE 'return[[:space:]]+[a-z]')" "router dump: every return verdict ends its line"
assert_eq "0" "$(printf '%s\n' "$dump_router" | grep -c 'mark set.*}')" "router dump: the closing brace has its own line"

assert_exit 1 "an unknown subcommand fails" sh "$R" bogus "$TT_TEST_TMP/up.tsv"

# --- up ----------------------------------------------------------------------

: > "$TT_CMD_LOG"
: > "$TT_NFT_STDIN"
sh "$R" up "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP"
up_log=$(cat "$TT_CMD_LOG")

assert_contains "$up_log" 'ip route replace blackhole default table 880 metric 1000' "up installs the IPv4 blackhole first"
assert_contains "$up_log" 'ip -6 route replace blackhole default table 880 metric 1000' "up installs the IPv6 blackhole first"
assert_contains "$up_log" 'ip rule add fwmark 0x9527 table 880 priority 30820' "up adds the IPv4 fwmark rule"
assert_contains "$up_log" 'ip -6 rule add fwmark 0x9527 table 880 priority 30820' "up adds the IPv6 fwmark rule"
assert_eq "0" "$(line_count 'tuntap add' "$up_log")" "up does not create any device"
assert_eq "0" "$(line_count 'link set dev' "$up_log")" "up does not touch a device link"
assert_eq "0" "$(line_count 'route replace default' "$up_log")" "up attaches no default route yet"
assert_eq "1" "$(line_count '^nft -f -$' "$up_log")" "up loads the ruleset in a single nft transaction"
nft_stdin=$(cat "$TT_NFT_STDIN")
assert_contains "$nft_stdin" 'table inet trusttunnel {' "the transaction stdin opens the table"
assert_contains "$nft_stdin" 'meta mark set 0x9527' "the transaction stdin marks the traffic"

# --- endpoint elements -------------------------------------------------------

: > "$TT_CMD_LOG"
sh "$R" up "$TT_TEST_TMP/eps.tsv" "$TT_TEST_TMP"
eps_log=$(cat "$TT_CMD_LOG")
assert_contains "$eps_log" 'nft add element inet trusttunnel tt_endpoint4 { 1.2.3.4 }' "an IPv4 endpoint lands in tt_endpoint4"
assert_contains "$eps_log" 'nft add element inet trusttunnel tt_endpoint6 { 2001:db8::1 }' "an IPv6 endpoint lands in tt_endpoint6"

# --- attach / detach ---------------------------------------------------------

: > "$TT_CMD_LOG"
sh "$R" attach "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP" tun7
attach_log=$(cat "$TT_CMD_LOG")
assert_contains "$attach_log" 'ip route replace default dev tun7 table 880 metric 1' "attach replaces the IPv4 default route"
assert_contains "$attach_log" 'ip -6 route replace default dev tun7 table 880 metric 1' "attach replaces the IPv6 default route"
assert_contains "$attach_log" 'table 880 metric 1' "attach's metric 1 wins over the blackhole's 1000"
assert_eq "tun7" "$(cat "$TT_TEST_TMP/device")" "attach records the device name"

: > "$TT_CMD_LOG"
sh "$R" detach "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP"
detach_log=$(cat "$TT_CMD_LOG")
assert_contains "$detach_log" 'ip route del default table 880 metric 1' "detach deletes the IPv4 default route"
assert_contains "$detach_log" 'ip -6 route del default table 880 metric 1' "detach deletes the IPv6 default route"
assert_eq "0" "$(line_count 'blackhole' "$detach_log")" "detach leaves the blackhole untouched"
if [ -e "$TT_TEST_TMP/device" ]; then
    _tt_fail "detach forgets the recorded device name"
else
    _tt_pass "detach forgets the recorded device name"
fi

# --- down --------------------------------------------------------------------

printf 'tun7\n' > "$TT_TEST_TMP/device"
: > "$TT_CMD_LOG"
sh "$R" down "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP"
down_log=$(cat "$TT_CMD_LOG")
assert_contains "$down_log" 'nft delete table inet trusttunnel' "down removes the nft table"
assert_contains "$down_log" 'ip rule del fwmark 0x9527 table 880 priority 30820' "down removes the IPv4 fwmark rule"
assert_contains "$down_log" 'ip -6 rule del fwmark 0x9527 table 880 priority 30820' "down removes the IPv6 fwmark rule"
assert_contains "$down_log" 'ip route flush table 880' "down flushes the IPv4 routing table"
assert_contains "$down_log" 'ip -6 route flush table 880' "down flushes the IPv6 routing table"
assert_eq "0" "$(line_count 'link del' "$down_log")" "down keeps the client device"
order_ok=$(awk '/^nft delete table inet trusttunnel$/ { n = NR }
               /^ip route flush table 880$/ { f = NR }
               END { if (n && f && n < f) print "1"; else print "0" }' "$TT_CMD_LOG")
assert_eq "1" "$order_ok" "down tears the nft table down before the routes"

# --- no blackhole -------------------------------------------------------------

: > "$TT_CMD_LOG"
sh "$R" up "$TT_TEST_TMP/nobh.tsv" "$TT_TEST_TMP"
nobh_log=$(cat "$TT_CMD_LOG")
assert_eq "0" "$(line_count 'blackhole' "$nobh_log")" "no blackhole route when the killswitch is disabled"

tt_test_summary
