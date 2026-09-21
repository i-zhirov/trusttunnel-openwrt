#!/bin/sh
# Routing script contract test.
#
# Real ip/nft/uci/firewall/logger calls are replaced by the stub scripts
# below: every invocation appends its argv to the log file $TT_CMD_LOG,
# the nft stub captures stdin only for the "-f -" transaction (the suite
# runner closes stdin, so an unconditional read would hang) and answers a
# "list table" call from $TT_NFT_LIST (empty by default), so the
# meter-counter parsing can be pinned against a canned listing. ip always
# reports success so the live device checks in attach pass. The uci stub
# keeps the zone device binding in $TT_UCI_STATE so the sync helpers can
# be observed (bind on attach, unbind on detach/down, no-op when the
# binding already matches). The fixture endpoints are literal addresses,
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
if [ "$1" = "-6" ]; then
    shift
fi
if [ "$1" = "rule" ] && [ "$2" = "show" ] && [ -f "$TT_IP_RULE" ]; then
    cat "$TT_IP_RULE"
fi
exit 0
EOF
cat > "$stub_dir/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "nft $*" >> "$TT_CMD_LOG"
if [ "${1-}" = "-f" ] && [ "${2-}" = "-" ]; then
    cat > "$TT_NFT_STDIN"
fi
if [ "${1-}" = "list" ] && [ "${2-}" = "table" ]; then
    cat "${TT_NFT_LIST:-/dev/null}"
fi
exit 0
EOF
cat > "$stub_dir/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "logger $*" >> "$TT_LOGGER_LOG"
exit 0
EOF
cat > "$stub_dir/uci" <<'EOF'
#!/bin/sh
if [ "$1" = "-q" ]; then
    shift
fi
case "$1" in
    get)
        case "$2" in
            'firewall.@zone[0].name')
                printf 'trusttunnel\n'
                exit 0
                ;;
            'firewall.@zone[0].device')
                if [ -s "$TT_UCI_STATE" ]; then
                    cat "$TT_UCI_STATE"
                    exit 0
                fi
                exit 1
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    add)
        printf '%s\n' "uci $*" >> "$TT_CMD_LOG"
        printf 'cfgtt\n'
        exit 0
        ;;
    set|add_list|delete|commit)
        printf '%s\n' "uci $*" >> "$TT_CMD_LOG"
        case "$2" in
            *.device=*) printf '%s\n' "${2#*=}" > "$TT_UCI_STATE" ;;
            *.device) rm -f "$TT_UCI_STATE" ;;
        esac
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
cat > "$stub_dir/firewall" <<'EOF'
#!/bin/sh
printf '%s\n' "firewall $*" >> "$TT_CMD_LOG"
exit 0
EOF
chmod +x "$stub_dir/ip" "$stub_dir/nft" "$stub_dir/logger" "$stub_dir/uci" "$stub_dir/firewall"

# The logger stub shadows the real logger through PATH; its capture file
# is separate from $TT_CMD_LOG so the "installs nothing" assertions keep
# counting ip/nft invocations only.
export PATH="$stub_dir:$PATH"
export TT_LOGGER_LOG="$TT_TEST_TMP/logger.log"

export TT_IP="$stub_dir/ip"
export TT_NFT="$stub_dir/nft"
export TT_UCI="$stub_dir/uci"
export TT_FW="$stub_dir/firewall"
export TT_CMD_LOG="$TT_TEST_TMP/cmd.log"
export TT_NFT_STDIN="$TT_TEST_TMP/nft.stdin"
export TT_UCI_STATE="$TT_TEST_TMP/uci.state"
export TT_IP_RULE="$TT_TEST_TMP/ip.rule"

reset_logs() {
    : > "$TT_CMD_LOG"
    : > "$TT_NFT_STDIN"
    : > "$TT_UCI_STATE"
    rm -f "$TT_IP_RULE"
}

# Fixtures: a vpn-mode profile with an IP/CIDR bypass list, a bypass-mode
# profile with a purely address-based VPN list, a bypass-mode profile with
# a domain entry (forces mark-all), a profile-less record set (direct by
# default), a variant with the blackhole disabled, an endpoint list with
# one IPv4 and one IPv6 literal, and the router-traffic variant.
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan br-guest\nnetwork.include_router_traffic\t0\nendpoint.routing_profile\tDefault\nrouting_profile.name\tDefault\nrouting_profile.mode\tvpn\nrouting_profile.bypass_rules\t1.2.3.0/24\nrouting_profile.bypass_rules\tbank.example\n' > "$TT_TEST_TMP/up.tsv"
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan\nnetwork.include_router_traffic\t1\nrouting_profile.mode\tvpn\n' > "$TT_TEST_TMP/router.tsv"
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan\nnetwork.include_router_traffic\t0\nnetwork.blackhole_on_down\t0\nrouting_profile.mode\tvpn\n' > "$TT_TEST_TMP/nobh.tsv"
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan\nnetwork.include_router_traffic\t0\nrouting_profile.mode\tbypass\nrouting_profile.vpn_rules\t1.2.3.4\nrouting_profile.vpn_rules\t2001:db8::/32\n' > "$TT_TEST_TMP/selective.tsv"
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan\nnetwork.include_router_traffic\t0\nrouting_profile.mode\tbypass\nrouting_profile.vpn_rules\ttelegram.org\n' > "$TT_TEST_TMP/bypassdom.tsv"
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan\nnetwork.include_router_traffic\t0\n' > "$TT_TEST_TMP/none.tsv"
printf 'network.fwmark\t0x9527\nnetwork.lan_devices\tbr-lan br-guest\nnetwork.include_router_traffic\t0\nendpoint.address\t1.2.3.4:443\nendpoint.address\t[2001:db8::1]:443\n' > "$TT_TEST_TMP/eps.tsv"

# --- dump --------------------------------------------------------------------

dump_up="$(sh "$R" dump "$TT_TEST_TMP/up.tsv")"
dump_router="$(sh "$R" dump "$TT_TEST_TMP/router.tsv")"
dump_sel="$(sh "$R" dump "$TT_TEST_TMP/selective.tsv")"
dump_dom="$(sh "$R" dump "$TT_TEST_TMP/bypassdom.tsv")"
dump_none="$(sh "$R" dump "$TT_TEST_TMP/none.tsv")"

# line_count <needle> <text> — how many lines of <text> match <needle>.
line_count() {
    printf '%s\n' "$2" | grep -c "$1"
}

assert_contains "$dump_up" 'table inet trusttunnel { }' "dump opens with an empty table"
assert_contains "$dump_up" 'delete table inet trusttunnel' "dump deletes the table first, so it is idempotent"
assert_contains "$dump_up" 'set tt_endpoint4 { type ipv4_addr; flags interval; }' "dump declares the IPv4 endpoint set"
assert_contains "$dump_up" 'set tt_endpoint6 { type ipv6_addr; flags interval; }' "dump declares the IPv6 endpoint set"
assert_contains "$dump_up" 'set tt_route4 { type ipv4_addr; flags interval; }' "dump declares the IPv4 route set"
assert_contains "$dump_up" 'set tt_route6 { type ipv6_addr; flags interval; }' "dump declares the IPv6 route set"
assert_contains "$dump_up" 'set tt_bypass4 { type ipv4_addr; flags interval; }' "dump declares the IPv4 bypass set"
assert_contains "$dump_up" 'set tt_bypass6 { type ipv6_addr; flags interval; }' "dump declares the IPv6 bypass set"
assert_contains "$dump_up" 'type filter hook prerouting priority mangle' "prerouting is a filter/mangle hook"
assert_contains "$dump_up" 'iifname != { "br-lan", "br-guest" } return' "prerouting returns for the LAN devices"
assert_contains "$dump_up" 'ip daddr @tt_endpoint4 return' "prerouting returns marked IPv4 endpoints"
assert_contains "$dump_up" 'ip6 daddr @tt_endpoint6 return' "prerouting returns marked IPv6 endpoints"
assert_contains "$dump_up" '192.168.0.0/16' "the private IPv4 ranges are returned (spot check)"
assert_contains "$dump_up" 'fc00::/7' "the private IPv6 ranges are returned (spot check)"
assert_contains "$dump_up" 'ip daddr { 1.2.3.0/24 } return' "a vpn-mode profile bypasses its IP/CIDR entries at the kernel"
assert_eq "0" "$(line_count 'bank.example' "$dump_up")" "a domain bypass entry stays out of the kernel ruleset"
assert_contains "$dump_up" 'meta mark set 0x9527' "a vpn-mode profile marks the rest"
assert_eq "0" "$(line_count 'hook output' "$dump_up")" "no output chain while router traffic is off"
assert_eq "0" "$(line_count 'dstnat' "$dump_up")" "no dstnat chain is emitted"

assert_contains "$dump_router" 'iifname != { "br-lan" } return' "single LAN device in the router-traffic dump"
assert_contains "$dump_router" 'type route hook output priority mangle' "router traffic adds the output chain"
assert_contains "$dump_router" 'oifname "tun*" return' "the output chain spares the tunnel device"
assert_eq "0" "$(line_count 'dstnat' "$dump_router")" "no dstnat chain with router traffic either"

assert_contains "$dump_sel" 'ip daddr { 1.2.3.4 } meta mark set 0x9527' "a pure-IP bypass profile marks only its IPv4 VPN rules"
assert_contains "$dump_sel" 'ip6 daddr { 2001:db8::/32 } meta mark set 0x9527' "a pure-IP bypass profile marks only its IPv6 VPN rules"
assert_eq "0" "$(line_count '^\t\tmeta mark set ' "$dump_sel")" "a pure-IP bypass profile emits no blanket mark"

assert_contains "$dump_dom" 'meta mark set 0x9527' "a bypass profile with a domain entry marks everything (the client splits by SNI)"
assert_eq "0" "$(line_count '@tt_route\|@tt_bypass' "$dump_none")" "no profile references no selection sets"
assert_eq "0" "$(line_count 'meta mark set' "$dump_none")" "no profile emits no mark statement (direct by default)"

# Line-break hygiene that substring checks cannot see: a verdict must end
# its line (nothing glued after "return") and a closing brace must sit on
# its own line (never after the mark statement).
assert_eq "0" "$(printf '%s\n' "$dump_up" | grep -cE 'return[[:space:]]+[a-z]')" "every return verdict ends its line"
assert_eq "0" "$(printf '%s\n' "$dump_up" | grep -c 'mark set.*}')" "the closing brace has its own line"
assert_eq "0" "$(printf '%s\n' "$dump_router" | grep -cE 'return[[:space:]]+[a-z]')" "router dump: every return verdict ends its line"
assert_eq "0" "$(printf '%s\n' "$dump_router" | grep -c 'mark set.*}')" "router dump: the closing brace has its own line"

assert_exit 1 "an unknown subcommand fails" sh "$R" bogus "$TT_TEST_TMP/up.tsv"

# --- up ----------------------------------------------------------------------

reset_logs
sh "$R" up "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP"
up_log=$(cat "$TT_CMD_LOG")

assert_eq "0" "$(line_count 'route replace blackhole' "$up_log")" "up installs no blackhole (attach arms it on the tun device)"
assert_contains "$up_log" 'ip route del blackhole default table 880 metric 1000' "up removes a stale IPv4 blackhole"
assert_contains "$up_log" 'ip -6 route del blackhole default table 880 metric 1000' "up removes a stale IPv6 blackhole"
assert_contains "$up_log" 'ip rule add fwmark 0x9527 table 880 priority 30820' "up adds the IPv4 fwmark rule"
assert_contains "$up_log" 'ip -6 rule add fwmark 0x9527 table 880 priority 30820' "up adds the IPv6 fwmark rule"
assert_eq "0" "$(line_count 'tuntap add' "$up_log")" "up does not create any device"
assert_eq "0" "$(line_count 'link set dev' "$up_log")" "up does not touch a device link"
assert_eq "0" "$(line_count 'route replace default' "$up_log")" "up attaches no default route yet"
assert_eq "1" "$(line_count '^nft -f -$' "$up_log")" "up loads the ruleset in a single nft transaction"
nft_stdin=$(cat "$TT_NFT_STDIN")
assert_contains "$nft_stdin" 'table inet trusttunnel {' "the transaction stdin opens the table"
assert_contains "$nft_stdin" 'meta mark set 0x9527' "the transaction stdin marks the traffic"
assert_contains "$up_log" 'nft add element inet trusttunnel tt_bypass4 { 1.2.3.0/24 }' "the bypass IP lands in tt_bypass4"

# The element guards are the last statements of up, and an empty list
# short-circuits them to exit 1: that must never become the function's own
# status, so up reports success for every selection shape.
assert_exit 0 "up exits 0 with a vpn profile" sh "$R" up "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP"
assert_exit 0 "up exits 0 with a pure-IP bypass profile" sh "$R" up "$TT_TEST_TMP/selective.tsv" "$TT_TEST_TMP"
assert_exit 0 "up exits 0 with a domain-carrying bypass profile" sh "$R" up "$TT_TEST_TMP/bypassdom.tsv" "$TT_TEST_TMP"
assert_exit 0 "up exits 0 without a profile" sh "$R" up "$TT_TEST_TMP/none.tsv" "$TT_TEST_TMP"

# The rule guard must recognize THIS package's rule, not any rule that
# happens to reference the table.
reset_logs
printf '30820: from all fwmark 0x9527 lookup 880\n' > "$TT_IP_RULE"
sh "$R" up "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP"
assert_eq "0" "$(line_count '^ip rule add ' "$(cat "$TT_CMD_LOG")")" "an existing fwmark rule is not added twice"

# --- endpoint and selection elements -----------------------------------------

reset_logs
sh "$R" up "$TT_TEST_TMP/eps.tsv" "$TT_TEST_TMP"
eps_log=$(cat "$TT_CMD_LOG")
assert_contains "$eps_log" 'nft add element inet trusttunnel tt_endpoint4 { 1.2.3.4 }' "an IPv4 endpoint lands in tt_endpoint4"
assert_contains "$eps_log" 'nft add element inet trusttunnel tt_endpoint6 { 2001:db8::1 }' "an IPv6 endpoint lands in tt_endpoint6"
assert_eq "0" "$(line_count 'meta mark set' "$(cat "$TT_NFT_STDIN")")" "a profile-less record set marks nothing"

reset_logs
sh "$R" up "$TT_TEST_TMP/selective.tsv" "$TT_TEST_TMP"
sel_log=$(cat "$TT_CMD_LOG")
assert_contains "$sel_log" 'nft add element inet trusttunnel tt_route4 { 1.2.3.4 }' "a pure-IP bypass profile routes its IPv4 VPN rules"
assert_contains "$sel_log" 'nft add element inet trusttunnel tt_route6 { 2001:db8::/32 }' "a pure-IP bypass profile routes its IPv6 VPN rules"

# --- attach / detach ---------------------------------------------------------

reset_logs
sh "$R" attach "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP" tun7
attach_log=$(cat "$TT_CMD_LOG")
assert_contains "$attach_log" 'ip route replace blackhole default table 880 metric 1000' "attach arms the IPv4 blackhole"
assert_contains "$attach_log" 'ip -6 route replace blackhole default table 880 metric 1000' "attach arms the IPv6 blackhole"
assert_contains "$attach_log" 'ip route replace default dev tun7 table 880 metric 1' "attach replaces the IPv4 default route"
assert_contains "$attach_log" 'ip -6 route replace default dev tun7 table 880 metric 1' "attach replaces the IPv6 default route"
assert_contains "$attach_log" 'table 880 metric 1' "attach's metric 1 wins over the blackhole's 1000"
assert_contains "$attach_log" 'uci add_list firewall.@zone[0].device=tun7' "attach binds the firewall zone to the concrete device"
assert_contains "$attach_log" 'uci commit firewall' "attach commits the firewall change"
assert_contains "$attach_log" 'firewall reload' "attach reloads the firewall"
assert_eq "tun7" "$(cat "$TT_TEST_TMP/device")" "attach records the device name"

# A repeated attach with the same device skips the zone rewrite.
reset_logs
printf 'tun7\n' > "$TT_UCI_STATE"
sh "$R" attach "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP" tun7
repeat_log=$(cat "$TT_CMD_LOG")
assert_eq "0" "$(line_count 'add_list' "$repeat_log")" "a repeated attach leaves the zone binding alone"

# attach with the killswitch disabled: no blackhole, stale one removed.
reset_logs
sh "$R" attach "$TT_TEST_TMP/nobh.tsv" "$TT_TEST_TMP" tun7
nobh_attach_log=$(cat "$TT_CMD_LOG")
assert_eq "0" "$(line_count 'route replace blackhole' "$nobh_attach_log")" "no blackhole is armed when the killswitch is disabled"
assert_contains "$nobh_attach_log" 'ip route del blackhole default table 880 metric 1000' "a stale IPv4 blackhole is removed when the killswitch is disabled"
assert_contains "$nobh_attach_log" 'ip -6 route del blackhole default table 880 metric 1000' "a stale IPv6 blackhole is removed when the killswitch is disabled"

reset_logs
printf 'tun7\n' > "$TT_UCI_STATE"
sh "$R" detach "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP"
detach_log=$(cat "$TT_CMD_LOG")
assert_contains "$detach_log" 'ip route del default table 880 metric 1' "detach deletes the IPv4 default route"
assert_contains "$detach_log" 'ip -6 route del default table 880 metric 1' "detach deletes the IPv6 default route"
assert_contains "$detach_log" 'ip route del blackhole default table 880 metric 1000' "detach removes the IPv4 blackhole"
assert_contains "$detach_log" 'ip -6 route del blackhole default table 880 metric 1000' "detach removes the IPv6 blackhole"
assert_contains "$detach_log" 'uci delete firewall.@zone[0].device' "detach unbinds the firewall zone"
assert_contains "$detach_log" 'firewall reload' "detach reloads the firewall"
if [ -e "$TT_TEST_TMP/device" ]; then
    _tt_fail "detach forgets the recorded device name"
else
    _tt_pass "detach forgets the recorded device name"
fi

# --- down --------------------------------------------------------------------

reset_logs
printf 'tun7\n' > "$TT_TEST_TMP/device"
printf 'tun7\n' > "$TT_UCI_STATE"
sh "$R" down "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP"
down_log=$(cat "$TT_CMD_LOG")
assert_contains "$down_log" 'nft delete table inet trusttunnel' "down removes the nft table"
assert_contains "$down_log" 'ip rule del fwmark 0x9527 table 880 priority 30820' "down removes the IPv4 fwmark rule"
assert_contains "$down_log" 'ip -6 rule del fwmark 0x9527 table 880 priority 30820' "down removes the IPv6 fwmark rule"
assert_contains "$down_log" 'ip route del default table 880 metric 1' "down deletes the IPv4 default route"
assert_contains "$down_log" 'ip route del blackhole default table 880 metric 1000' "down deletes the IPv4 blackhole"
assert_contains "$down_log" 'ip -6 route del blackhole default table 880 metric 1000' "down deletes the IPv6 blackhole"
assert_eq "0" "$(line_count 'route flush' "$down_log")" "down never flushes the table (foreign routes must survive)"
assert_contains "$down_log" 'uci delete firewall.@zone[0].device' "down unbinds the firewall zone"
assert_eq "0" "$(line_count 'link del' "$down_log")" "down keeps the client device"
order_ok=$(awk '/^nft delete table inet trusttunnel$/ { n = NR }
               /^uci delete firewall.@zone\[0\].device$/ { f = NR }
               END { if (n && f && n < f) print "1"; else print "0" }' "$TT_CMD_LOG")
assert_eq "1" "$order_ok" "down tears the nft table down before the zone"

# --- no blackhole -------------------------------------------------------------

reset_logs
sh "$R" up "$TT_TEST_TMP/nobh.tsv" "$TT_TEST_TMP"
nobh_log=$(cat "$TT_CMD_LOG")
assert_eq "0" "$(line_count 'route replace blackhole' "$nobh_log")" "up never installs the blackhole even with the killswitch enabled"
assert_contains "$nobh_log" 'ip route del blackhole default table 880 metric 1000' "up still removes a stale IPv4 blackhole"
assert_contains "$nobh_log" 'ip -6 route del blackhole default table 880 metric 1000' "up still removes a stale IPv6 blackhole"

# --- proxy mode guard ----------------------------------------------------------

# Proxy mode owns no kernel routing: up must refuse instead of installing a
# pipeline whose marked traffic would blackhole with no tun device behind it.
printf 'main.mode\tproxy\nproxy.address\t0.0.0.0:1080\n' > "$TT_TEST_TMP/proxy.tsv"
reset_logs
if sh "$R" up "$TT_TEST_TMP/proxy.tsv" "$TT_TEST_TMP" 2>/dev/null; then
	_tt_fail "up in proxy mode exits non-zero"
else
	_tt_pass "up in proxy mode exits non-zero"
fi
assert_eq "0" "$(wc -c < "$TT_CMD_LOG" | tr -d ' ')" \
	"up in proxy mode installs nothing"
assert_eq "0" "$(wc -c < "$TT_NFT_STDIN" | tr -d ' ')" \
	"up in proxy mode loads no ruleset"

# --- meter ---------------------------------------------------------------------

# The proxy-mode usage meter counts bytes on the SOCKS listener port:
# requests into the listener (dport, prerouting) are the upload path,
# responses from it (sport, output) the download path. The rules land in
# the same table up owns, so down removes them like any other ruleset.
: > "$TT_CMD_LOG"
: > "$TT_NFT_STDIN"
sh "$R" meter "$TT_TEST_TMP/proxy.tsv" "$TT_TEST_TMP"
meter_log=$(cat "$TT_CMD_LOG")
meter_stdin=$(cat "$TT_NFT_STDIN")

assert_eq "1" "$(line_count '^nft -f -$' "$meter_log")" "meter loads its ruleset in a single nft transaction"
assert_eq "0" "$(line_count 'blackhole' "$meter_log")" "meter installs no blackhole"
assert_eq "0" "$(line_count 'rule add' "$meter_log")" "meter installs no fwmark rule"
assert_eq "0" "$(line_count 'route ' "$meter_log")" "meter touches no routes"
assert_contains "$meter_stdin" 'table inet trusttunnel { }' "the meter transaction opens the table"
assert_contains "$meter_stdin" 'delete table inet trusttunnel' "the meter transaction is idempotent"
assert_contains "$meter_stdin" 'type filter hook prerouting priority mangle' "the meter counts requests in prerouting"
assert_contains "$meter_stdin" 'tcp dport 1080 counter' "the meter counts bytes into the listener"
assert_contains "$meter_stdin" 'type filter hook output priority mangle' "the meter counts responses in output"
assert_contains "$meter_stdin" 'tcp sport 1080 counter' "the meter counts bytes from the listener"
assert_eq "0" "$(line_count 'meta mark' "$meter_stdin")" "the meter never marks traffic"
assert_eq "0" "$(line_count 'tt_endpoint' "$meter_stdin")" "the meter carries no endpoint sets"

# Tun mode owns the kernel routing: meter must refuse just like up
# refuses proxy mode — the two rulesets never coexist.
: > "$TT_CMD_LOG"
: > "$TT_NFT_STDIN"
if sh "$R" meter "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP" 2>/dev/null; then
	_tt_fail "meter in tun mode exits non-zero"
else
	_tt_pass "meter in tun mode exits non-zero"
fi
assert_eq "0" "$(wc -c < "$TT_CMD_LOG" | tr -d ' ')" \
	"meter in tun mode installs nothing"
assert_eq "0" "$(wc -c < "$TT_NFT_STDIN" | tr -d ' ')" \
	"meter in tun mode loads no ruleset"

# A listener address without a numeric port cannot be counted: refuse
# instead of installing a ruleset that never matches.
printf 'main.mode\tproxy\nproxy.address\t127.0.0.1\n' > "$TT_TEST_TMP/noport.tsv"
: > "$TT_CMD_LOG"
: > "$TT_NFT_STDIN"
if sh "$R" meter "$TT_TEST_TMP/noport.tsv" "$TT_TEST_TMP" 2>/dev/null; then
	_tt_fail "meter without a numeric port exits non-zero"
else
	_tt_pass "meter without a numeric port exits non-zero"
fi
assert_eq "0" "$(wc -c < "$TT_CMD_LOG" | tr -d ' ')" \
	"meter without a numeric port installs nothing"
assert_eq "0" "$(wc -c < "$TT_NFT_STDIN" | tr -d ' ')" \
	"meter without a numeric port loads no ruleset"

# A failing nft must not swallow the reason: the meter logs nft's
# stderr (the mirror of up's capture), so a persistently failing
# install is diagnosable from the log rather than hidden behind the
# non-fatal warning.
cat > "$TT_TEST_TMP/failnft" <<'EOF'
#!/bin/sh
printf '%s\n' "nft $*" >> "$TT_CMD_LOG"
echo "nft: no handler for this command" >&2
exit 1
EOF
chmod +x "$TT_TEST_TMP/failnft"
: > "$TT_CMD_LOG"
: > "$TT_LOGGER_LOG"
if TT_NFT="$TT_TEST_TMP/failnft" sh "$R" meter "$TT_TEST_TMP/proxy.tsv" "$TT_TEST_TMP" 2>/dev/null; then
	_tt_fail "meter with a failing nft exits non-zero"
else
	_tt_pass "meter with a failing nft exits non-zero"
fi
failnft_log=$(cat "$TT_LOGGER_LOG")
assert_contains "$failnft_log" 'failed to install the usage meter' "the meter logs the failure"
assert_contains "$failnft_log" 'no handler for this command' "the meter logs nft's stderr"

# --- status with the meter ------------------------------------------------------

# The status subcommand reports the meter counters exactly as the nft
# listing carries them: rx from the sport rule (downloads), tx from the
# dport rule (uploads).
cat > "$TT_TEST_TMP/meter.list" <<'EOF'
table inet trusttunnel {
	chain tt_meter_in {
		type filter hook prerouting priority -150; policy accept;
		tcp dport 1080 counter packets 7 bytes 2048
	}
	chain tt_meter_out {
		type filter hook output priority -150; policy accept;
		tcp sport 1080 counter packets 13 bytes 4096
	}
}
EOF
export TT_NFT_LIST="$TT_TEST_TMP/meter.list"
meter_status=$(sh "$R" status "$TT_TEST_TMP/proxy.tsv" "$TT_TEST_TMP")
assert_contains "$meter_status" 'nft present' "status sees the meter table"
assert_contains "$meter_status" 'meter up' "status reports the meter rules"
assert_contains "$meter_status" 'meter rx 4096' "status reports the download bytes"
assert_contains "$meter_status" 'meter tx 2048' "status reports the upload bytes"

# The meter lines appear only while BOTH counter rules exist: a tun-mode
# ruleset (or a stale table after a port change) must report no meter.
cat > "$TT_TEST_TMP/tun.list" <<'EOF'
table inet trusttunnel {
	set tt_endpoint4 { type ipv4_addr; flags interval; elements = { 1.2.3.4 } }
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;
		iifname != { "br-lan" } return
		ip daddr @tt_endpoint4 return
		meta mark set 0x9527
	}
}
EOF
export TT_NFT_LIST="$TT_TEST_TMP/tun.list"
tun_status=$(sh "$R" status "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP")
assert_contains "$tun_status" 'nft present' "status sees the tun ruleset"
assert_eq "0" "$(line_count 'meter' "$tun_status")" "no meter lines for a tun-mode ruleset"

# An empty listing is an absent table: no nft, no meter.
export TT_NFT_LIST=/dev/null
absent_status=$(sh "$R" status "$TT_TEST_TMP/up.tsv" "$TT_TEST_TMP")
assert_contains "$absent_status" 'nft absent' "an empty listing reports no table"
unset TT_NFT_LIST

tt_test_summary
