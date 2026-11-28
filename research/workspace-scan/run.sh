#!/bin/sh
# Development probe only; no Mix app, persistent storage or real protected folders.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/h-workspace-scan.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
include=$(erl +S 2:2 -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
case $(uname -s) in
    Darwin) set -- -dynamiclib -undefined dynamic_lookup ;;
    Linux) set -- -shared ;;
    *) echo 'This probe targets macOS and Linux' >&2; exit 1 ;;
esac
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -fPIC "$@" -I "$include" \
    "$here/workspace_scan_nif.c" -o "$work/workspace_scan_nif.so"
erlc -Werror -o "$work" "$here/workspace_scan_probe.erl"
mkdir "$work/fixture"
SCAN_FIXTURE="$work/fixture" SCAN_NIF="$work/workspace_scan_nif" \
    erl +S 2:2 +SDio 2 -pa "$work" -noshell -s workspace_scan_probe run -s init stop
