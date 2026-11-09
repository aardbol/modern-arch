#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers sourced by the modern-arch-setup scripts.
# Not meant to be executed directly.

set -Eeuo pipefail

if [[ -t 1 ]]; then
	C_RESET=$'\033[0m' C_BOLD=$'\033[1m'
	C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_BLU=$'\033[34m'
else
	C_RESET='' C_BOLD='' C_RED='' C_GRN='' C_YEL='' C_BLU=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_root() {
	(( EUID == 0 )) || die "this script must run as root (try: sudo $0)"
}

require_cmds() {
	local c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
	done
}

# ask "prompt" -> prints the answer (reads from the terminal, not stdin)
ask() {
	local prompt=$1 reply=''
	read -r -p "$prompt" reply </dev/tty || die "aborted (no terminal)"
	printf '%s' "$reply"
}

# confirm_phrase "prompt" "PHRASE" -> exits unless PHRASE is typed exactly
confirm_phrase() {
	local prompt=$1 phrase=$2 reply=''
	read -r -p "$prompt" reply </dev/tty || die "aborted (no terminal)"
	[[ $reply == "$phrase" ]] || die "confirmation phrase did not match, aborting"
}

on_error() {
	local rc=$1 line=$2
	[[ $rc -eq 0 ]] && return
	warn "failed at line $line (exit $rc)"
	exit "$rc"
}
trap 'on_error $? $LINENO' ERR