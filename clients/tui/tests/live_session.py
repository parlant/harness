"""Drive hi while the Phoenix native_client test owns the real (fake-provider) daemon."""
import os
import sys
from pty_harness import PtySession

binary, data_dir, sid, cwd = sys.argv[1:]
env = {**os.environ, "TERM": "xterm-256color"}
env.pop("H_DAEMON_URL", None)
mode = env.get("HI_TEST_MODE", "fullscreen")
with PtySession([binary, "--data-dir", data_dir, "-s", sid, "--tui-mode", mode], env=env, cwd=cwd) as terminal:
    terminal.wait_for_raw_mode()
    terminal.wait_for_output("Ready")
    terminal.send_text("Hello from Rust TUI")
    terminal.send_enter()
    terminal.wait_for_output("Synced", timeout=10)
    terminal.send_ctrl("d")
    assert terminal.wait(timeout=5) == 0 and terminal.is_cooked_mode()
