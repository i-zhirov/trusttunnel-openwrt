#!/bin/sh
# Stub dry-run harness for install.sh — a docker-based developer tool.
#
# install.sh writes absolute paths under /etc, so every scenario runs
# inside a fresh openwrt/rootfs container whose real package managers and
# system tools (apk, opkg, uname, usign, wget) are renamed aside and
# replaced by recording stubs with env-driven canned responses. The call
# log and the captured /etc state are the comparison data.
#
# Usage:
#   sh tests/install-harness.sh                          # run the whole scenario set
#   TT_FILTER=chunk1 sh tests/install-harness.sh         # run only matching scenarios
#
# The harness is deliberately NOT picked up by tests/run.sh (the runner
# globs tests/test_*.sh) and reports SKIP (exit 77, the suite's skip
# status) when docker is unavailable.
#
# The assert_* functions are dispatched by name from run_scenario (indirect
# invocation shellcheck cannot see), and write_prep emits literal script
# text into the generated prep file — both are deliberate.
# shellcheck disable=SC2329,SC2016,SC2028

set -u

REPO_URL=http://repo.test
IMG_APK=openwrt/rootfs:x86-64-25.12.0
IMG_OPKG=openwrt/rootfs:x86-64-22.03.7
TT_FILTER="${TT_FILTER:-}"

TOTAL=0
FAILED=0
CID=""

command -v docker >/dev/null 2>&1 || {
    echo "  SKIP: docker not available"
    exit 77
}

# The scratch dir lives under $HOME: Docker Desktop on macOS only shares
# paths under /Users (a /tmp or /var/folders mount silently appears empty
# in the container).
SCRATCH=$(mktemp -d "$HOME/.tt-harness.XXXXXX") || exit 1

# --- assertion helpers ---------------------------------------------------------

pass() {
    TOTAL=$((TOTAL + 1))
    printf '  ok: %s\n' "$1"
}

fail() {
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    printf '  FAIL: %s\n' "$1"
}

# assert_grep <file> <needle> <description>
assert_grep() {
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        pass "$3"
    else
        fail "$3 (missing: $2)"
    fi
}

# assert_no_grep <file> <needle> <description>
assert_no_grep() {
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        fail "$3 (found: $2)"
    else
        pass "$3"
    fi
}

# assert_no_file <container path> <description>
assert_no_file() {
    if docker exec "$CID" sh -c 'test -e "$1"' sh "$1" 2>/dev/null; then
        fail "$2 (found: $1)"
    else
        pass "$2"
    fi
}

# assert_file_content <container path> <expected> <description>
assert_file_content() {
    _got=$(docker exec "$CID" sh -c 'cat "$1"' sh "$1" 2>/dev/null) || _got="<missing>"
    if [ "$_got" = "$2" ]; then
        pass "$3"
    else
        fail "$3 (expected: $2, got: $_got)"
    fi
}

# assert_log_order <early needle> <late needle> <description>
assert_log_order() {
    _early=$(grep -Fn -- "$1" "$SCRATCH/call.log" | head -1 | cut -d: -f1)
    _late=$(grep -Fn -- "$2" "$SCRATCH/call.log" | head -1 | cut -d: -f1)
    if [ -n "$_early" ] && [ -n "$_late" ] && [ "$_early" -lt "$_late" ]; then
        pass "$3"
    else
        fail "$3 (early line: ${_early:-missing}, late line: ${_late:-missing})"
    fi
}

# assert_crun <container command> <expected> <description>
assert_crun() {
    _got=$(docker exec "$CID" sh -c "$1" 2>/dev/null) || _got="<error>"
    if [ "$_got" = "$2" ]; then
        pass "$3"
    else
        fail "$3 (expected: $2, got: $_got)"
    fi
}

assert_log() { assert_grep "$SCRATCH/call.log" "$1" "$2"; }
assert_no_log() { assert_no_grep "$SCRATCH/call.log" "$1" "$2"; }

# --- container lifecycle --------------------------------------------------------

container_start() {
    CID=$(docker create -v "$TT_SRC_DIR:/src:ro" -v "$TT_STUBS:/stubs:ro" "$1" \
        sh -c 'trap "exit 0" TERM INT; while :; do sleep 3600; done') || return 1
    docker start "$CID" >/dev/null 2>&1 || return 1
    _i=0
    while ! docker exec "$CID" true >/dev/null 2>&1; do
        _i=$((_i + 1))
        [ "$_i" -ge 20 ] && return 1
        sleep 1
    done
    return 0
}

container_stop() {
    if [ -n "$CID" ]; then
        docker rm -f "$CID" >/dev/null 2>&1 || true
        CID=""
    fi
}

# write_prep <stubs> <release spec> <extra prep> — generates the in-container
# prep script: neutralizes the real tools, plants the named stubs, crafts or
# hides /etc/openwrt_release, plants the fake rpcd init script and runs the
# scenario-specific extra prep.
write_prep() {
    _prep_file=$SCRATCH/prep.sh
    {
        echo '#!/bin/sh'
        echo 'set -u'
        echo 'mkdir -p /var/lock /etc/apk/keys /etc/apk/repositories.d /etc/opkg/keys /usr/local/bin'
        echo 'rm -f /etc/opkg/keys/* /etc/apk/keys/* 2>/dev/null || true'
        echo 'uname -m > /tmp/tt_uname_default 2>/dev/null || true'
        echo 'for t in apk opkg uname usign wget; do'
        echo '    p=$(command -v "$t" 2>/dev/null) || continue'
        echo '    mv "$p" "$p.real"'
        echo 'done'
        if [ -n "$1" ]; then
            echo 'for s in '"$1"'; do'
            echo '    cp "/stubs/bin/$s" /usr/local/bin/'
            echo 'done'
        fi
        echo 'chmod +x /usr/local/bin/* 2>/dev/null || true'
        case "$2" in
            -) ;;
            hidden)
                echo 'mv /etc/openwrt_release /etc/openwrt_release.hidden'
                ;;
            *)
                echo "printf \"DISTRIB_RELEASE='%s'\\n\" \"$2\" > /etc/openwrt_release"
                ;;
        esac
        echo 'cp /stubs/etc/init.d/rpcd /etc/init.d/rpcd'
        echo 'chmod +x /etc/init.d/rpcd'
        if [ -n "$3" ]; then
            printf '%s\n' "$3"
        fi
        echo 'true'
    } > "$_prep_file"
}

# run_scenario <name> <image> <expected rc> <stubs> <release> <env> <prep> <assert fn>
run_scenario() {
    _name=$1
    case $_name in
        *"$TT_FILTER"*) ;;
        *) return ;;
    esac
    echo "== $_name"
    write_prep "$4" "$5" "$7" || { fail "prep generation failed for: $_name"; return; }
    if ! container_start "$2"; then
        fail "could not start a container for: $_name"
        return
    fi
    if ! docker cp "$SCRATCH/prep.sh" "$CID:/tmp/prep.sh" >/dev/null 2>&1; then
        fail "could not copy the prep script for: $_name"
        container_stop
        return
    fi
    if ! docker exec "$CID" sh /tmp/prep.sh >/dev/null 2>&1; then
        fail "container prep failed for: $_name"
        container_stop
        return
    fi
    _flags="-e TT_REPO_URL=$REPO_URL -e PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    for _w in $6; do
        _flags="$_flags -e $_w"
    done
    # shellcheck disable=SC2086
    docker exec $_flags "$CID" sh /src/install.sh > "$SCRATCH/run.out" 2>&1
    _actual=$?
    docker exec "$CID" sh -c 'cat /tmp/tt_call.log 2>/dev/null || true' > "$SCRATCH/call.log"
    if [ "$_actual" -eq "$3" ]; then
        pass "exit code $3"
    else
        fail "exit code $3 (got $_actual)"
    fi
    "$8"
    container_stop
}

# --- chunk 1: environment checks + PM detection with version floors -------------

sc_openwrt_hidden() {
    run_scenario "chunk1: /etc/openwrt_release missing -> die" "$IMG_OPKG" 1 "" hidden "" "" as_openwrt_hidden
}
as_openwrt_hidden() {
    assert_grep "$SCRATCH/run.out" "this script is for OpenWrt only" "die message names OpenWrt only"
}

sc_no_pm() {
    run_scenario "chunk1: no package manager -> die" "$IMG_OPKG" 1 "" - "" "" as_no_pm
}
as_no_pm() {
    assert_grep "$SCRATCH/run.out" "neither apk nor opkg" "die message names both package managers"
}

sc_apk_detected() {
    run_scenario "chunk1: apk-only detection passes" "$IMG_APK" 0 "uname apk wget" "25.12.0" "" "" as_apk_detected
}
as_apk_detected() {
    assert_log "apk update" "the apk branch ran"
    assert_no_log "opkg update" "the opkg branch did not run"
}

sc_opkg_detected() {
    run_scenario "chunk1: opkg-only detection passes" "$IMG_OPKG" 0 "uname opkg wget usign" "22.03.7" "" "" as_opkg_detected
}
as_opkg_detected() {
    assert_log "opkg update" "the opkg branch ran"
    assert_no_log "apk update" "the apk branch did not run"
}

sc_apk_floor() {
    run_scenario "chunk1: apk on OpenWrt 21.x -> die" "$IMG_APK" 1 "uname apk wget" "21.02.7" "" "" as_apk_floor
}
as_apk_floor() {
    assert_grep "$SCRATCH/run.out" "25.12" "die message names the 25.12 floor"
}

sc_opkg_floor() {
    run_scenario "chunk1: opkg on OpenWrt 21.x -> die" "$IMG_OPKG" 1 "uname opkg wget usign" "21.02.7" "" "" as_opkg_floor
}
as_opkg_floor() {
    assert_grep "$SCRATCH/run.out" "22.03" "die message names the 22.03 floor"
}

sc_non_numeric_release() {
    run_scenario "chunk1: unparseable release -> warning, continue" "$IMG_OPKG" 0 "uname opkg wget usign" "rolling" "" "" as_non_numeric_release
}
as_non_numeric_release() {
    assert_grep "$SCRATCH/run.out" "warning" "a warning is printed"
    assert_log "opkg update" "the install continues"
}

# --- chunk 2: CPU check (uname -m allowlist, die before any writes) -------------

sc_cpu_accept() {
    echo "== chunk2: all 10 accepted architectures pass the CPU check"
    for _a in x86_64 x86-64 x64 amd64 aarch64 arm64 armv7l armv8l mips mipsel; do
        sc_cpu_arch=$_a
        run_scenario "chunk2: accepted arch $_a" "$IMG_APK" 0 "uname apk wget" "25.12.0" "STUB_UNAME_M=$_a" "" as_cpu_accept
    done
}
as_cpu_accept() {
    assert_log "apk update" "the install proceeds past the CPU check"
}

sc_cpu_reject() {
    echo "== chunk2: unsupported architectures die before any writes"
    for _a in armv5tel armv6l mips64el riscv64 powerpc i386 ""; do
        sc_cpu_arch=$_a
        run_scenario "chunk2: rejected arch ($_a)" "$IMG_OPKG" 1 "uname opkg wget usign" - \
            "STUB_UNAME_M=$_a" 'printf "%s\n" "src/gz other http://other/feed" > /etc/opkg/customfeeds.conf' as_cpu_reject
    done
}
as_cpu_reject() {
    assert_grep "$SCRATCH/run.out" "unsupported CPU" "die message names the unsupported CPU"
    case $sc_cpu_arch in
        riscv64)
            assert_no_file /etc/opkg/keys/trusttunnel.pub "riscv64: no opkg key file was written"
            assert_no_file /etc/apk/keys/trusttunnel.pub "riscv64: no apk key file was written"
            assert_no_file /etc/apk/repositories.d/trusttunnel.list "riscv64: no apk repo entry was written"
            assert_file_content /etc/opkg/customfeeds.conf "src/gz other http://other/feed" "riscv64: the feed file is untouched"
            ;;
    esac
}

# --- chunk 3: repository setup per PM -------------------------------------------

sc_apk_repo_happy() {
    run_scenario "chunk3: apk repo happy path" "$IMG_APK" 0 "uname apk wget" "25.12.0" "" "" as_apk_repo_happy
}
as_apk_repo_happy() {
    assert_log "-O /etc/apk/keys/trusttunnel.pub" "wget targets the apk key path"
    assert_log "http://repo.test/apk/key-build.pub" "wget fetches the apk key URL"
    assert_log_order "http://repo.test/apk/key-build.pub" "apk --print-arch" "the key is fetched before the arch is probed"
    assert_file_content /etc/apk/keys/trusttunnel.pub "stub pubkey" "the apk key file holds the fetched body"
    assert_file_content /etc/apk/repositories.d/trusttunnel.list "http://repo.test/apk/x86_64/packages.adb" "the apk repo entry is the single arch-specific line"
}

sc_apk_repo_wget_fail() {
    run_scenario "chunk3: apk key fetch failure -> die" "$IMG_APK" 1 "uname apk wget" "25.12.0" "STUB_WGET_RC=1" "" as_apk_repo_wget_fail
}
as_apk_repo_wget_fail() {
    assert_no_file /etc/apk/repositories.d/trusttunnel.list "no apk repo entry is written"
    assert_no_file /etc/apk/keys/trusttunnel.pub "no apk key file is written"
}

sc_apk_repo_arch_fail() {
    run_scenario "chunk3: apk --print-arch failure -> die" "$IMG_APK" 1 "uname apk wget" "25.12.0" "STUB_APK_PRINT_ARCH_RC=1" "" as_apk_repo_arch_fail
}
as_apk_repo_arch_fail() {
    assert_no_file /etc/apk/repositories.d/trusttunnel.list "no apk repo entry is written"
}

sc_opkg_repo_fresh() {
    run_scenario "chunk3: opkg repo fresh setup (feed file absent)" "$IMG_OPKG" 0 "uname opkg wget usign" "22.03.7" "STUB_USIGN_FP=aabbccdd" 'rm -f /etc/opkg/customfeeds.conf' as_opkg_repo_fresh
}
as_opkg_repo_fresh() {
    assert_file_content /etc/opkg/customfeeds.conf "src/gz trusttunnel http://repo.test/opkg" "the feed file is created with exactly one feed line"
    assert_log "-O /etc/opkg/keys/trusttunnel.pub" "wget targets the opkg key path"
    assert_log "http://repo.test/opkg/opkg-key.pub" "wget fetches the opkg key URL"
    assert_log_order "http://repo.test/opkg/opkg-key.pub" "usign -F -p /etc/opkg/keys/trusttunnel.pub" "the key is fetched before the fingerprint is computed"
    assert_file_content /etc/opkg/keys/trusttunnel.pub "stub pubkey" "the stable-name key copy holds the fetched body"
    assert_file_content /etc/opkg/keys/aabbccdd "stub pubkey" "the fingerprint-named key copy is identical"
}

sc_opkg_repo_stock_file() {
    run_scenario "chunk3: opkg feed line appended to the stock file" "$IMG_OPKG" 0 "uname opkg wget usign" "22.03.7" "" "" as_opkg_repo_stock_file
}
as_opkg_repo_stock_file() {
    assert_crun 'grep -c "^src/gz trusttunnel " /etc/opkg/customfeeds.conf || true' "1" "exactly one trusttunnel feed line"
    assert_crun 'grep -c "^# add your custom package feeds here" /etc/opkg/customfeeds.conf || true' "1" "the stock comment header is preserved"
}

sc_opkg_repo_idempotent() {
    _name="chunk3: opkg feed line idempotence"
    echo "== $_name"
    case $_name in
        *"$TT_FILTER"*) ;;
        *) return ;;
    esac
    write_prep "uname opkg wget usign" - 'printf "%s\n" "src/gz other http://other/feed" "src/gz trusttunnel http://old.test/opkg" > /etc/opkg/customfeeds.conf' \
        || { fail "prep generation failed for: chunk3 idempotence"; return; }
    if ! container_start "$IMG_OPKG"; then
        fail "could not start a container for: chunk3 idempotence"
        return
    fi
    if ! docker cp "$SCRATCH/prep.sh" "$CID:/tmp/prep.sh" >/dev/null 2>&1; then
        fail "could not copy the prep script for: chunk3 idempotence"
        container_stop
        return
    fi
    if ! docker exec "$CID" sh /tmp/prep.sh >/dev/null 2>&1; then
        fail "container prep failed for: chunk3 idempotence"
        container_stop
        return
    fi
    _flags="-e TT_REPO_URL=$REPO_URL -e PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    # shellcheck disable=SC2086
    docker exec $_flags "$CID" sh /src/install.sh > "$SCRATCH/run.out" 2>&1
    _r1=$?
    # shellcheck disable=SC2086
    docker exec $_flags "$CID" sh /src/install.sh > "$SCRATCH/run.out" 2>&1
    _r2=$?
    docker exec "$CID" sh -c 'cat /tmp/tt_call.log 2>/dev/null || true' > "$SCRATCH/call.log"
    if [ "$_r1" -eq 0 ]; then pass "first run exits 0"; else fail "first run exits 0 (got $_r1)"; fi
    if [ "$_r2" -eq 0 ]; then pass "second run exits 0"; else fail "second run exits 0 (got $_r2)"; fi
    _lines=$(docker exec "$CID" sh -c 'grep -c "^src/gz trusttunnel " /etc/opkg/customfeeds.conf || true')
    if [ "$_lines" = "1" ]; then
        pass "exactly one trusttunnel feed line after two runs"
    else
        fail "exactly one trusttunnel feed line after two runs (got $_lines)"
    fi
    assert_crun 'cat /etc/opkg/customfeeds.conf' "src/gz other http://other/feed
src/gz trusttunnel http://old.test/opkg" "the pre-existing lines are untouched"
    container_stop
}

sc_opkg_repo_key_fail() {
    run_scenario "chunk3: opkg key fetch failure -> die" "$IMG_OPKG" 1 "uname opkg wget usign" "22.03.7" "STUB_WGET_RC=1" "" as_opkg_repo_key_fail
}
as_opkg_repo_key_fail() {
    assert_no_file /etc/opkg/keys/trusttunnel.pub "no opkg key file is written"
}

sc_opkg_repo_usign_missing() {
    run_scenario "chunk3: usign missing -> die" "$IMG_OPKG" 1 "uname opkg wget" "22.03.7" "" "" as_opkg_repo_usign_missing
}
as_opkg_repo_usign_missing() {
    assert_crun 'ls /etc/opkg/keys' "trusttunnel.pub" "no fingerprint-named key copy exists"
}

sc_opkg_repo_usign_fail() {
    run_scenario "chunk3: usign failure -> die" "$IMG_OPKG" 1 "uname opkg wget usign" "22.03.7" "STUB_USIGN_RC=1" "" as_opkg_repo_usign_fail
}
as_opkg_repo_usign_fail() {
    assert_crun 'ls /etc/opkg/keys' "trusttunnel.pub" "no fingerprint-named key copy exists"
}

# --- chunk 4: update/install sequence (deps, app, tripwire) ---------------------

sc_apk_install_happy() {
    run_scenario "chunk4: apk install happy path" "$IMG_APK" 0 "uname apk wget" "25.12.0" "" "" as_apk_install_happy
}
as_apk_install_happy() {
    assert_log_order "apk update" "apk add kmod-tun ip-full nftables curl ca-bundle" "update precedes the dependency install"
    assert_log_order "apk add kmod-tun ip-full nftables curl ca-bundle" "apk add luci-app-trusttunnel" "dependencies precede the main package"
    assert_log_order "apk add luci-app-trusttunnel" "apk info -e trusttunnel-client" "the tripwire runs after the installs"
}

sc_opkg_install_happy() {
    run_scenario "chunk4: opkg install happy path" "$IMG_OPKG" 0 "uname opkg wget usign" "22.03.7" "STUB_USIGN_FP=aabbccdd" "" as_opkg_install_happy
}
as_opkg_install_happy() {
    assert_log_order "opkg update" "opkg install kmod-tun ip-full nftables curl ca-bundle" "update precedes the dependency install"
    assert_log_order "opkg install kmod-tun ip-full nftables curl ca-bundle" "opkg install luci-app-trusttunnel" "dependencies precede the main package"
    assert_log_order "opkg install luci-app-trusttunnel" "opkg list-installed" "the tripwire runs after the installs"
}

sc_apk_tripwire_fail() {
    run_scenario "chunk4: apk tripwire failure is fatal" "$IMG_APK" 1 "uname apk wget" "25.12.0" "STUB_APK_INFO_RC=1" "" as_apk_tripwire_fail
}
as_apk_tripwire_fail() {
    assert_grep "$SCRATCH/run.out" "trusttunnel-client" "the die message names the client package"
}

sc_opkg_tripwire_fail() {
    run_scenario "chunk4: opkg tripwire failure is fatal" "$IMG_OPKG" 1 "uname opkg wget usign" "22.03.7" "STUB_OPKG_LIST=some-other-pkg 1.0" "" as_opkg_tripwire_fail
}
as_opkg_tripwire_fail() {
    assert_grep "$SCRATCH/run.out" "trusttunnel-client" "the die message names the client package"
}

sc_apk_update_fail() {
    run_scenario "chunk4: apk update failure -> die" "$IMG_APK" 1 "uname apk wget" "25.12.0" "STUB_APK_UPDATE_RC=1" "" as_apk_update_fail
}
as_apk_update_fail() {
    assert_no_log "apk add" "no install call follows the failed update"
}

# --- chunk 5: was_running restore, rpcd restart, immediate uci-defaults run ------

sc_first_install() {
    run_scenario "chunk5: first install leaves the service disabled" "$IMG_APK" 0 "uname apk wget" "25.12.0" "" "" as_first_install
}
as_first_install() {
    assert_no_log "init.d/trusttunnel stop" "no stop is called on a fresh install"
    assert_no_log "init.d/trusttunnel start" "no start is called on a fresh install"
}

sc_was_running_stopped() {
    run_scenario "chunk5: stopped service is stopped but not restarted" "$IMG_APK" 0 "uname apk wget" "25.12.0" "STUB_TT_RUNNING_RC=1" 'cp /stubs/etc/init.d/trusttunnel /etc/init.d/trusttunnel; chmod +x /etc/init.d/trusttunnel' as_was_running_stopped
}
as_was_running_stopped() {
    assert_log "init.d/trusttunnel stop" "the existing service is stopped"
    assert_no_log "init.d/trusttunnel start" "a stopped service is not restarted"
}

sc_was_running_restore() {
    run_scenario "chunk5: running service is stopped and restarted" "$IMG_APK" 0 "uname apk wget" "25.12.0" "STUB_TT_RUNNING_RC=0" 'cp /stubs/etc/init.d/trusttunnel /etc/init.d/trusttunnel; chmod +x /etc/init.d/trusttunnel' as_was_running_restore
}
as_was_running_restore() {
    assert_log_order "apk add kmod-tun ip-full nftables curl ca-bundle" "init.d/trusttunnel stop" "the stop follows the dependency install"
    assert_log_order "init.d/trusttunnel stop" "apk add luci-app-trusttunnel" "the stop precedes the main package install"
    assert_log_order "init.d/rpcd restart" "init.d/trusttunnel start" "the restart comes after the rpcd refresh"
}

sc_was_running_restore_opkg() {
    run_scenario "chunk5: running service is stopped and restarted (opkg)" "$IMG_OPKG" 0 "uname opkg wget usign" "22.03.7" "STUB_TT_RUNNING_RC=0 STUB_USIGN_FP=aabbccdd" 'cp /stubs/etc/init.d/trusttunnel /etc/init.d/trusttunnel; chmod +x /etc/init.d/trusttunnel' as_was_running_restore_opkg
}
as_was_running_restore_opkg() {
    assert_log_order "opkg install kmod-tun ip-full nftables curl ca-bundle" "init.d/trusttunnel stop" "the stop follows the dependency install"
    assert_log_order "init.d/trusttunnel stop" "opkg install luci-app-trusttunnel" "the stop precedes the main package install"
    assert_log_order "init.d/rpcd restart" "init.d/trusttunnel start" "the restart comes after the rpcd refresh"
}

sc_rpcd_failure_nonfatal() {
    run_scenario "chunk5: rpcd restart failure is not fatal" "$IMG_APK" 0 "uname apk wget" "25.12.0" "STUB_RPCD_RC=1" "" as_rpcd_failure_nonfatal
}
as_rpcd_failure_nonfatal() {
    assert_log "init.d/rpcd restart" "rpcd restart is invoked"
}

sc_uci_defaults_success() {
    run_scenario "chunk5: immediate uci-defaults run succeeds" "$IMG_APK" 0 "uname apk wget" "25.12.0" "STUB_TT_RUNNING_RC=0" \
        'cp /stubs/etc/init.d/trusttunnel /etc/init.d/trusttunnel; mkdir -p /etc/uci-defaults; cp /stubs/etc/uci-defaults/40-luci-trusttunnel /etc/uci-defaults/40-luci-trusttunnel; chmod +x /etc/init.d/trusttunnel /etc/uci-defaults/40-luci-trusttunnel' as_uci_defaults_success
}
as_uci_defaults_success() {
    assert_log "uci-defaults/40-luci-trusttunnel" "the uci-defaults script is invoked"
    assert_crun 'grep -c "uci-defaults/40-luci-trusttunnel" /tmp/tt_call.log || true' "1" "the uci-defaults script is invoked exactly once"
    assert_log_order "init.d/rpcd restart" "uci-defaults/40-luci-trusttunnel" "rpcd restart precedes the uci-defaults run"
    assert_log_order "uci-defaults/40-luci-trusttunnel" "init.d/trusttunnel start" "the service restarts after the uci-defaults run"
    assert_no_grep "$SCRATCH/run.out" "leak" "the uci-defaults output is silenced"
    assert_grep "$SCRATCH/run.out" "== Seeding the default routing profile" "the seeding banner is printed"
}

sc_uci_defaults_failure() {
    run_scenario "chunk5: uci-defaults failure warns and continues" "$IMG_APK" 0 "uname apk wget" "25.12.0" "STUB_TT_RUNNING_RC=0 STUB_UCI_DEFAULTS_RC=1" \
        'cp /stubs/etc/init.d/trusttunnel /etc/init.d/trusttunnel; mkdir -p /etc/uci-defaults; cp /stubs/etc/uci-defaults/40-luci-trusttunnel /etc/uci-defaults/40-luci-trusttunnel; chmod +x /etc/init.d/trusttunnel /etc/uci-defaults/40-luci-trusttunnel' as_uci_defaults_failure
}
as_uci_defaults_failure() {
    assert_grep "$SCRATCH/run.out" "warning: the default routing profile was not created; run /etc/uci-defaults/40-luci-trusttunnel manually" "the exact warning fallback is printed"
    assert_log "init.d/trusttunnel start" "the service still restarts"
}

sc_uci_defaults_absent() {
    run_scenario "chunk5: absent uci-defaults script is skipped" "$IMG_APK" 0 "uname apk wget" "25.12.0" "STUB_TT_RUNNING_RC=0" 'cp /stubs/etc/init.d/trusttunnel /etc/init.d/trusttunnel; chmod +x /etc/init.d/trusttunnel' as_uci_defaults_absent
}
as_uci_defaults_absent() {
    assert_no_log "uci-defaults/40-luci-trusttunnel" "the absent uci-defaults script is not invoked"
    assert_no_grep "$SCRATCH/run.out" "== Seeding the default routing profile" "no seeding banner is printed"
    assert_no_grep "$SCRATCH/run.out" "warning: the default routing profile" "no warning is printed"
    assert_log "init.d/trusttunnel start" "the service restore is independent of the uci-defaults step"
}

sc_closing_apk() {
    run_scenario "chunk5: closing banner names the apk upgrade path" "$IMG_APK" 0 "uname apk wget" "25.12.0" "" "" as_closing_apk
}
as_closing_apk() {
    assert_grep "$SCRATCH/run.out" "apk update && apk upgrade" "the repository persistence is stated for apk"
}

sc_closing_opkg() {
    run_scenario "chunk5: closing banner names the opkg upgrade path" "$IMG_OPKG" 0 "uname opkg wget usign" "22.03.7" "STUB_USIGN_FP=aabbccdd" "" as_closing_opkg
}
as_closing_opkg() {
    assert_grep "$SCRATCH/run.out" "opkg update && opkg upgrade" "the repository persistence is stated for opkg"
}

# --- main ------------------------------------------------------------------------

TT_STUBS=$SCRATCH/stubs
mkdir -p "$TT_STUBS/bin" "$TT_STUBS/etc/init.d" "$TT_STUBS/etc/uci-defaults"

cat > "$TT_STUBS/bin/uname" <<'STUB'
#!/bin/sh
printf 'uname %s\n' "$*" >> /tmp/tt_call.log
[ "$1" = "-m" ] || exit 0
case ${STUB_UNAME_M+x} in
    x) printf '%s\n' "$STUB_UNAME_M" ;;
    *) cat /tmp/tt_uname_default 2>/dev/null ;;
esac
exit 0
STUB

cat > "$TT_STUBS/bin/apk" <<'STUB'
#!/bin/sh
printf 'apk %s\n' "$*" >> /tmp/tt_call.log
case "$1" in
    --print-arch)
        printf '%s\n' 'x86_64'
        exit "${STUB_APK_PRINT_ARCH_RC:-0}"
        ;;
    update)
        exit "${STUB_APK_UPDATE_RC:-0}"
        ;;
    add)
        exit 0
        ;;
    info)
        exit "${STUB_APK_INFO_RC:-0}"
        ;;
    *)
        exit 0
        ;;
esac
STUB

cat > "$TT_STUBS/bin/opkg" <<'STUB'
#!/bin/sh
printf 'opkg %s\n' "$*" >> /tmp/tt_call.log
case "$1" in
    update)
        exit 0
        ;;
    install)
        exit 0
        ;;
    list-installed)
        printf '%s\n' "${STUB_OPKG_LIST:-trusttunnel-client 1.0-r1}"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
STUB

cat > "$TT_STUBS/bin/wget" <<'STUB'
#!/bin/sh
printf 'wget %s\n' "$*" >> /tmp/tt_call.log
_out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-O" ] && [ "$#" -ge 2 ]; then
        _out=$2
        shift 2
        continue
    fi
    shift
done
if [ "${STUB_WGET_RC:-0}" -eq 0 ]; then
    [ -n "$_out" ] && printf '%s\n' 'stub pubkey' > "$_out"
fi
exit "${STUB_WGET_RC:-0}"
STUB

cat > "$TT_STUBS/bin/usign" <<'STUB'
#!/bin/sh
printf 'usign %s\n' "$*" >> /tmp/tt_call.log
if [ "${STUB_USIGN_RC:-0}" -eq 0 ]; then
    printf '%s\n' "${STUB_USIGN_FP:-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef}"
fi
exit "${STUB_USIGN_RC:-0}"
STUB

cat > "$TT_STUBS/etc/init.d/rpcd" <<'STUB'
#!/bin/sh
printf 'init.d/rpcd %s\n' "$*" >> /tmp/tt_call.log
exit "${STUB_RPCD_RC:-0}"
STUB

cat > "$TT_STUBS/etc/init.d/trusttunnel" <<'STUB'
#!/bin/sh
printf 'init.d/trusttunnel %s\n' "$*" >> /tmp/tt_call.log
case "$1" in
    running)
        exit "${STUB_TT_RUNNING_RC:-1}"
        ;;
    *)
        exit 0
        ;;
esac
STUB

cat > "$TT_STUBS/etc/uci-defaults/40-luci-trusttunnel" <<'STUB'
#!/bin/sh
printf 'uci-defaults/40-luci-trusttunnel %s\n' "$*" >> /tmp/tt_call.log
printf '%s\n' "leak on stdout"
printf '%s\n' "leak on stderr" >&2
exit "${STUB_UCI_DEFAULTS_RC:-0}"
STUB

TT_SRC_DIR=$PWD
echo "== testing $PWD/install.sh"

trap 'container_stop; rm -rf "$SCRATCH"' EXIT INT TERM

run_all() {
    sc_openwrt_hidden
    sc_no_pm
    sc_apk_detected
    sc_opkg_detected
    sc_apk_floor
    sc_opkg_floor
    sc_non_numeric_release
    sc_cpu_accept
    sc_cpu_reject
    sc_apk_repo_happy
    sc_apk_repo_wget_fail
    sc_apk_repo_arch_fail
    sc_opkg_repo_fresh
    sc_opkg_repo_stock_file
    sc_opkg_repo_idempotent
    sc_opkg_repo_key_fail
    sc_opkg_repo_usign_missing
    sc_opkg_repo_usign_fail
    sc_apk_install_happy
    sc_opkg_install_happy
    sc_apk_tripwire_fail
    sc_opkg_tripwire_fail
    sc_apk_update_fail
    sc_first_install
    sc_was_running_stopped
    sc_was_running_restore
    sc_was_running_restore_opkg
    sc_rpcd_failure_nonfatal
    sc_uci_defaults_success
    sc_uci_defaults_failure
    sc_uci_defaults_absent
    sc_closing_apk
    sc_closing_opkg
}
run_all

echo "== $TOTAL assertions, $FAILED failed"
if [ "$FAILED" -eq 0 ]; then
    echo "== harness green"
    exit 0
fi
echo "== HARNESS FAILURES"
exit 1
