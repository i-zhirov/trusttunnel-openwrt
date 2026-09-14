#!/bin/sh
# Architecture and version derivation from the trusttunnel-client ipk
# file names, shared between the release pipeline's opkg repository
# assembly (release.yml) and the integration harness's regression stage
# (st_archparse in run.sh) — the pipeline and its test cannot drift
# apart.
#
# File name shape: trusttunnel-client_<ver>-<rel>_<arch>.ipk
#   <ver>  - dotted digits (the vendor version; no underscores)
#   <rel>  - digits
#   <arch> - the OpenWrt package architecture, which KEEPS its
#            underscores (x86_64, mipsel_24kc, aarch64_cortex-a53,
#            arm_cortex-a7_neon-vfpv4, mipsel_24kc_24kf, ...)
#
# The version-revision head is split at the FIRST underscore after the
# package prefix; the arch is everything after that head. Splitting at
# the LAST underscore (the classic bug) clips arch names: mipsel_24kc
# became "24kc" and x86_64 became "64", producing feed directories no
# device would ever fetch. The arch names must never be clipped, and
# the version filter must never see an arch fragment.
#
# Usage:
#   TT_IPK_ARCH_SOURCED=1; . ipk-arch.sh   (source; defines tt_ipk_arch
#                                           and tt_ipk_verrev — the
#                                           marker is REQUIRED, see below)
#   sh ipk-arch.sh arch   <file>           (execute; print the arch)
#   sh ipk-arch.sh verrev <file>           (execute; print the <ver>-<rel> head)
#
# The CLI runs only when the script is executed, never when it is
# sourced. The callers that source it (release.yml's opkg assembly and
# the integration harness) set TT_IPK_ARCH_SOURCED=1 first: bash and
# dash keep $0 as the caller's name when sourcing, but zsh sets it to
# the sourced file's own name, which would otherwise trigger the CLI
# (and its exit) inside the caller.

# tt_ipk_arch <ipk-file> — prints the architecture from the file name.
tt_ipk_arch() {
	_rest="${1:-}"
	_rest="${_rest##*/}"
	_rest="${_rest#trusttunnel-client_}"
	_rest="${_rest#*_}"       # drop the <ver>-<rel> head
	printf '%s\n' "${_rest%.ipk}"
}

# tt_ipk_verrev <ipk-file> — prints the <ver>-<rel> head of the file
# name (the version filter key of the repository assembly).
tt_ipk_verrev() {
	_rest="${1:-}"
	_rest="${_rest##*/}"
	_rest="${_rest#trusttunnel-client_}"
	printf '%s\n' "${_rest%%_*}"
}

# The CLI runs only when the script is executed, never when it is
# sourced (the callers set TT_IPK_ARCH_SOURCED=1 before sourcing — see
# the header).
if [ -z "${TT_IPK_ARCH_SOURCED:-}" ] && [ "$(basename "$0" 2>/dev/null)" = "ipk-arch.sh" ]; then
	case "${1:-}" in
		arch) tt_ipk_arch "$2" ;;
		verrev) tt_ipk_verrev "$2" ;;
		*)
			echo "usage: ipk-arch.sh arch|verrev <ipk-file>" >&2
			exit 1
			;;
	esac
fi
