#!/bin/sh
# Scenario harness for the net hotplug route-reattach script.
#
# The script hardcodes its fixed paths, so scenarios run a sed-generated
# test copy with those prefixes redirected into a scratch tree; stubs take
# the place of /etc/init.d/trusttunnel, the routing helper and logger.
# Invariant scenarios assert the REAL file still carries the contract paths.
# Usage: sh tests/test_hotplug.sh [filters|guards|attach|invariants]
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

HOTPLUG="packages/luci-app-trusttunnel/root/etc/hotplug.d/net/40-trusttunnel"

scratch="$TT_TEST_TMP/root"
export SCRATCH="$scratch"
mkdir -p "$scratch/var/etc/trusttunnel" "$scratch/etc/init.d" \
         "$scratch/usr/libexec/trusttunnel" "$scratch/bin" \
         "$scratch/sys/class/net/tun0" "$scratch/sys/class/net/tun1"
cp tests/fixtures/records/minimal.tsv "$scratch/var/etc/trusttunnel/settings.tsv"
printf '0x1001\n' > "$scratch/sys/class/net/tun0/tun_flags"
printf '0x1001\n' > "$scratch/sys/class/net/tun1/tun_flags"

# Stub of the procd "running" probe: exit code from a state file (default 0).
cat > "$scratch/etc/init.d/trusttunnel" <<'STUB'
#!/bin/sh
exit "$(cat "$SCRATCH/init_rc" 2>/dev/null || printf 0)"
STUB
chmod +x "$scratch/etc/init.d/trusttunnel"

# Recorder stub of the routing helper: appends its arguments, honors a state
# file for the exit code (default 0).
cat > "$scratch/usr/libexec/trusttunnel/routing" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SCRATCH/routing_calls"
exit "$(cat "$SCRATCH/routing_rc" 2>/dev/null || printf 0)"
STUB
chmod +x "$scratch/usr/libexec/trusttunnel/routing"

# logger stub: records the tag + message.
cat > "$scratch/bin/logger" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SCRATCH/log_lines"
STUB
chmod +x "$scratch/bin/logger"

# Test copy: substitute the four fixed absolute prefixes with scratch paths.
# '|' as the sed delimiter avoids escaping the path slashes.
sed -e "s|/var/etc/trusttunnel|$scratch/var/etc/trusttunnel|g" \
    -e "s|/etc/init.d/trusttunnel|$scratch/etc/init.d/trusttunnel|g" \
    -e "s|/usr/libexec/trusttunnel/routing|$scratch/usr/libexec/trusttunnel/routing|g" \
    -e "s|/sys/class/net|$scratch/sys/class/net|g" \
    "$HOTPLUG" > "$scratch/40-trusttunnel.test"
chmod +x "$scratch/40-trusttunnel.test"

# Reset per-scenario state: restore the FULL default scratch state, so every
# scenario starts identical no matter what earlier scenarios mutated (F5
# rewrites tun0/tun_flags, G1 deletes settings.tsv, G4 deletes the tun1
# sysfs dir — none of that may leak into a later scenario). Recorders and
# stub rc overrides are cleared, the device record is removed, settings.tsv
# is re-copied from the fixture, and the tun0/tun1 sysfs dirs are recreated
# with non-persistent flags. Scenario deltas are applied AFTER this call.
reset_state() {
	rm -f "$scratch/routing_calls" "$scratch/log_lines" \
	      "$scratch/var/etc/trusttunnel/device" "$scratch/init_rc" \
	      "$scratch/routing_rc"
	cp tests/fixtures/records/minimal.tsv \
	   "$scratch/var/etc/trusttunnel/settings.tsv"
	mkdir -p "$scratch/sys/class/net/tun0" "$scratch/sys/class/net/tun1"
	printf '0x1001\n' > "$scratch/sys/class/net/tun0/tun_flags"
	printf '0x1001\n' > "$scratch/sys/class/net/tun1/tun_flags"
}

run_hotplug() {
	PATH="$scratch/bin:$PATH" ACTION="$ACT" INTERFACE="$IFACE" \
	DEVICENAME="$DEVNAME" sh "$scratch/40-trusttunnel.test"
}

calls() { cat "$scratch/routing_calls" 2>/dev/null || printf '<none>'; }
logs()  { cat "$scratch/log_lines" 2>/dev/null || printf '<none>'; }

attach_line="attach $scratch/var/etc/trusttunnel/settings.tsv $scratch/var/etc/trusttunnel tun0"

# --- filters: event and device pre-checks -------------------------------------

scn_f1() {
	# F1: a non-add event is ignored before anything else.
	ACT=remove IFACE=tun0 DEVNAME=''; reset_state
	run_hotplug
	assert_eq "0" "$?" "non-add event exits 0"
	assert_eq "<none>" "$(calls)" "non-add event never reaches routing"
}

scn_f2() {
	# F2: an add event with no device name is ignored.
	ACT=add IFACE='' DEVNAME=''; reset_state
	run_hotplug
	assert_eq "0" "$?" "no device name exits 0"
	assert_eq "<none>" "$(calls)" "no device name never reaches routing"
}

scn_f3() {
	# F3: INTERFACE wins over DEVICENAME.
	ACT=add IFACE=tun0 DEVNAME=tun1; reset_state
	run_hotplug
	assert_eq "$attach_line" "$(calls)" "INTERFACE supplies the device name"
}

scn_f4() {
	# F4: a device without a sysfs tun_flags file is not a tun device.
	ACT=add IFACE=tun99 DEVNAME=''; reset_state
	run_hotplug
	assert_eq "0" "$?" "non-tun device exits 0"
	assert_eq "<none>" "$(calls)" "non-tun device never reaches routing"
}

scn_f5() {
	# F5: the IFF_PERSIST bit (0x800) filters out manual/legacy tun devices.
	ACT=add IFACE=tun0 DEVNAME=''; reset_state
	printf '0x1801\n' > "$scratch/sys/class/net/tun0/tun_flags"
	run_hotplug
	assert_eq "0" "$?" "persistent tun exits 0"
	assert_eq "<none>" "$(calls)" "persistent tun never reaches routing"
}

group_filters() {
	scn_f1
	scn_f2
	scn_f3
	scn_f4
	scn_f5
}

# --- guards: records, service probe, foreign device ---------------------------

scn_g1() {
	# G1: no records file means the service is not configured.
	ACT=add IFACE=tun0 DEVNAME=''; reset_state
	rm "$scratch/var/etc/trusttunnel/settings.tsv"
	run_hotplug
	assert_eq "0" "$?" "missing records file exits 0"
	assert_eq "<none>" "$(calls)" "missing records file never reaches routing"
}

scn_g2() {
	# G2: a stopped service must not reattach anything.
	ACT=add IFACE=tun0 DEVNAME=''; reset_state
	printf '1\n' > "$scratch/init_rc"
	run_hotplug
	assert_eq "0" "$?" "stopped service exits 0"
	assert_eq "<none>" "$(calls)" "stopped service never reaches routing"
}

scn_g3() {
	# G3: a live recorded foreign device must keep its tunnel untouched.
	ACT=add IFACE=tun0 DEVNAME=''; reset_state
	printf 'tun1\n' > "$scratch/var/etc/trusttunnel/device"
	run_hotplug
	assert_eq "0" "$?" "foreign live device exits 0"
	assert_eq "<none>" "$(calls)" "foreign live device never reaches routing"
}

scn_g4() {
	# G4: a recorded device that no longer exists cannot block the event.
	ACT=add IFACE=tun0 DEVNAME=''; reset_state
	printf 'tun1\n' > "$scratch/var/etc/trusttunnel/device"
	rm -rf "$scratch/sys/class/net/tun1"
	run_hotplug
	assert_eq "$attach_line" "$(calls)" "dead recorded device does not block"
}

scn_g5() {
	# G5: the recorded device being the event device itself is not foreign.
	ACT=add IFACE=tun0 DEVNAME=''; reset_state
	printf 'tun0\n' > "$scratch/var/etc/trusttunnel/device"
	run_hotplug
	assert_eq "$attach_line" "$(calls)" "recorded event device attaches"
}

scn_g6() {
	# G6: with no recorded device the event attaches freely.
	ACT=add IFACE=tun0 DEVNAME=''; reset_state
	run_hotplug
	assert_eq "$attach_line" "$(calls)" "no recorded device attaches"
}

group_guards() {
	scn_g1
	scn_g2
	scn_g3
	scn_g4
	scn_g5
	scn_g6
}

# --- attach: the routing call and the log -------------------------------------

scn_a1() {
	# A1: happy path — attach is called with the contract arguments and the
	# log line is emitted only afterwards.
	ACT=add IFACE=tun0 DEVNAME=''; reset_state
	run_hotplug
	assert_eq "0" "$?" "happy path exits 0"
	assert_eq "$attach_line" "$(calls)" "attach receives the contract arguments"
	assert_contains "$(logs)" "-t trusttunnel hotplug: reattached routing to tun0" \
		"attach success logs the reattach line"
}

scn_a2() {
	# A2: an attach failure must exit non-zero and emit no log line.
	ACT=add IFACE=tun0 DEVNAME=''; reset_state
	printf '1\n' > "$scratch/routing_rc"
	if run_hotplug; then
		_tt_fail "attach failure exits non-zero"
	else
		_tt_pass "attach failure exits non-zero"
	fi
	assert_eq "<none>" "$(logs)" "attach failure logs nothing"
}

group_attach() {
	scn_a1
	scn_a2
}

# --- invariants: the real file carries the contract ---------------------------

scn_i1() {
	# I1: the shipped file is a POSIX sh script.
	assert_eq "#!/bin/sh" "$(sed -n '1p' "$HOTPLUG")" "real file shebang is #!/bin/sh"
}

scn_i2() {
	# I2: the shipped file keeps the contract paths (the test copy only
	# works because these prefixes are the fixed, un-overridable ones).
	assert_contains "$(cat "$HOTPLUG")" \
		"RECORDS=/var/etc/trusttunnel/settings.tsv" \
		"real file binds the records path"
	assert_contains "$(cat "$HOTPLUG")" \
		"OUTDIR=/var/etc/trusttunnel" \
		"real file binds the output dir"
	assert_contains "$(cat "$HOTPLUG")" \
		"/etc/init.d/trusttunnel running" \
		"real file probes the running service"
	assert_contains "$(cat "$HOTPLUG")" \
		"/usr/libexec/trusttunnel/routing attach" \
		"real file calls the routing attach helper"
}

scn_i3() {
	# I3: the shipped file is executable.
	assert_exit 0 "real file is executable" test -x "$HOTPLUG"
}

group_invariants() {
	scn_i1
	scn_i2
	scn_i3
}

# --- dispatcher ---------------------------------------------------------------

if [ "$#" -eq 0 ]; then
	set -- filters guards attach invariants
fi
for tt_group in "$@"; do
	case $tt_group in
		filters) group_filters ;;
		guards) group_guards ;;
		attach) group_attach ;;
		invariants) group_invariants ;;
		*)
			echo "unknown scenario group: $tt_group" >&2
			exit 2
			;;
	esac
done

tt_test_summary
