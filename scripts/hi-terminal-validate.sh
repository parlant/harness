#!/usr/bin/env bash
set -euo pipefail

# Disposable terminal validation runner for `hi` (fullscreen & regular modes).
# Never modifies user terminal config/state, never contacts remote hosts, and
# uses only disposable FakeDaemon + isolated `tmux -S` fixtures under /tmp.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_RELEASE_HI="/Users/partenkirchen/Projects/diy-harness/clients/tui/target/release/hi"

if [[ -z "${HI_BIN:-}" ]]; then
  for candidate in \
    "${REPO_ROOT}/clients/tui/target/release/hi" \
    "${REPO_ROOT}/clients/tui/target/debug/hi" \
    "${DEFAULT_RELEASE_HI}"
  do
    if [[ -x "${candidate}" ]]; then
      export HI_BIN="${candidate}"
      break
    fi
  done
fi

if [[ -z "${HI_BIN:-}" || ! -x "${HI_BIN}" ]]; then
  echo "error: executable hi binary not found; set HI_BIN=/path/to/hi" >&2
  exit 1
fi

export HI_PTY_REQUIRE_BIN=1
export PYTHONDONTWRITEBYTECODE=1

echo "==> Validating hi binary: ${HI_BIN}"
echo "==> Running full Unix PTY suite (disposable FakeDaemon + isolated tmux/SSH/Unicode)..."
python3 -B -m unittest discover -s "${REPO_ROOT}/clients/tui/tests" -p 'test_*.py' -v

echo
echo "PASS: automated PTY terminal checks passed in fullscreen and regular modes."
echo "Next (requires a person): run the manual IME, font-width, clipboard, and real-SSH"
echo "checks documented in docs/hi/terminal.md."
