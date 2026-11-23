#!/usr/bin/env python3
"""Install one trusted, locally built H bundle, never a checkout or remote download."""

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


def run(argv, env, timeout=20):
    return subprocess.run(argv, env=env, text=True, capture_output=True, timeout=timeout)


def checked(argv, env, timeout=20):
    result = run(argv, env, timeout)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{Path(argv[0]).name} exited {result.returncode}")
    if result.stdout.strip():
        print(result.stdout.strip())
    return result


def valid_bundle(bundle):
    if not (bundle / "releases/start_erl.data").is_file() or not all(
        (bundle / name).is_file() and os.access(bundle / name, os.X_OK)
        for name in ("bin/hi", "bin/h-daemon", "bin/harness")
    ):
        raise RuntimeError(f"Not a complete H bundle: {bundle}")
    # No link may retain a dependency on the source checkout or another release.
    for path in bundle.rglob("*"):
        if path.is_symlink():
            if path.readlink().is_absolute():
                raise RuntimeError(f"Bundle contains a non-relocatable symlink: {path.relative_to(bundle)}")
            path.resolve(strict=True).relative_to(bundle)


def current_release(current, releases):
    if not os.path.lexists(current):
        return None
    if not current.is_symlink():
        raise RuntimeError(f"Refusing to replace non-symlink {current}")
    old = current.resolve(strict=True)
    if old.parent != releases:
        raise RuntimeError(f"Refusing to replace {current}: target is outside {releases}")
    valid_bundle(old)
    return old


def switch(current, release):
    scratch = current.with_name(f".current-{uuid.uuid4().hex}")
    scratch.symlink_to(Path("releases") / release.name)
    try:
        os.replace(scratch, current)
    finally:
        scratch.unlink(missing_ok=True)


@contextmanager
def installation_lock(prefix):
    lock = prefix / ".install-lock"
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        raise RuntimeError(f"Installation already in progress. If it was interrupted, inspect {lock} before removing it.") from None
    try:
        yield
    finally:
        lock.rmdir()


def service_file(home, data, launcher):
    if sys.platform != "darwin":
        return None
    # Match the same stable directory hash used by hi's service manager.
    value = 0xCBF29CE484222325
    for byte in os.fsencode(data):
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    path = home / "Library/LaunchAgents" / f"local.harness.daemon.{value}.plist"
    if not os.path.lexists(path):
        return None
    with path.open("rb") as fh:
        arguments = plistlib.load(fh).get("ProgramArguments")
    if arguments != [str(launcher), "--data-dir", str(data)]:
        raise RuntimeError(f"Existing LaunchAgent is pinned to another launcher. Safely uninstall it first: {path}")
    return path


def wait_until_stopped(service, env):
    target = f"gui/{os.getuid()}/{service.stem}"
    deadline = time.monotonic() + 60
    last = "no launchd status received"
    while (remaining := deadline - time.monotonic()) > 0:
        try:
            status = run(["/bin/launchctl", "print", target], env, timeout=min(5, remaining))
        except subprocess.TimeoutExpired:
            last = "launchctl print timed out"
        else:
            if status.returncode:
                raise RuntimeError(f"Cannot establish LaunchAgent shutdown for {target}; current bundle was not changed: {status.stderr.strip()}")
            # `print` is not a stable API. Demand an explicit inactive state,
            # zero active instances, and no PID; don't infer exit from a failed
            # query or from the missing daemon listener. Never log its full
            # output (it also includes the service environment).
            fields = dict(re.findall(r"^[ \t]*(state|active count|pid|last exit code) = ([\w ()-]+)$", status.stdout, re.MULTILINE))
            last = ", ".join(f"{key}={fields.get(key, 'unreported')}" for key in ("state", "active count", "pid", "last exit code"))
            pid_reported = re.search(r"^[ \t]*pid[ \t]*=", status.stdout, re.MULTILINE)
            if fields.get("state") in ("not running", "exited") and fields.get("active count") == "0" and not pid_reported:
                return
        time.sleep(0.2)
    raise RuntimeError(f"LaunchAgent shutdown did not finish for {target} ({last}); current bundle was not changed")


def wait_until_serving(hi, env):
    deadline = time.monotonic() + 30
    last_error = "No readiness response"
    while time.monotonic() < deadline:
        last = run([hi, "daemon", "status"], env, timeout=5)
        if last.returncode == 0:
            print(last.stdout.strip())
            return
        last_error = last.stderr.strip()
        time.sleep(0.2)
    raise RuntimeError(f"LaunchAgent has not become ready. Check h-daemon.log and `hi daemon status`: {last_error}")


PREFERRED_BIN_DIRS = ("/usr/local/bin", "/opt/local/bin", "/opt/homebrew/bin")


def _norm_dir(raw: str) -> Path:
    return Path(os.path.normpath(os.path.expanduser(raw)))


def _is_writable_dir(path: Path) -> bool:
    return path.is_dir() and os.access(path, os.W_OK | os.X_OK)


def _local_bin_usable(local_bin: Path, home: Path) -> bool:
    if _is_writable_dir(local_bin):
        return True
    if os.path.lexists(local_bin):
        return False
    local_dir = home / ".local"
    if _is_writable_dir(local_dir):
        return True
    return not os.path.lexists(local_dir) and _is_writable_dir(home)


def _is_excluded_path_dir(raw: str, norm: Path, home_bin: Path) -> bool:
    if not raw or not os.path.isabs(raw):
        return True
    s = str(norm)
    if s in ("/", "/bin", "/usr/bin", "/sbin", "/usr/sbin"):
        return True
    if s.startswith(("/System/", "/Library/", "/var/run/")):
        return True
    if norm == home_bin:
        return True
    parts = norm.parts
    if s.endswith("/.cargo/bin") or s.endswith("/node_modules/.bin"):
        return True
    if "Cellar" in parts or "shims" in parts:
        return True
    if any(part.startswith("erts-") for part in parts):
        return True
    return False


def select_bin_dir(
    explicit: str | None = None,
    *,
    home: Path | None = None,
    path_env: str | None = None,
    preferred: tuple[str, ...] | None = None,
) -> Path:
    if explicit:
        return Path(explicit).expanduser().absolute()
    env_bin_dir = os.environ.get("H_BIN_DIR")
    if env_bin_dir:
        return Path(env_bin_dir).expanduser().absolute()

    home_dir = (home if home is not None else Path.home()).resolve()
    raw_path = os.environ.get("PATH", "") if path_env is None else path_env
    path_entries = [entry for entry in raw_path.split(os.pathsep) if entry]
    norm_path_entries = [_norm_dir(entry) for entry in path_entries]
    path_set = set(norm_path_entries)

    pref_dirs = (
        preferred
        if preferred is not None
        else tuple(
            os.environ["H_PREFERRED_BIN_DIRS"].split(os.pathsep)
            if os.environ.get("H_PREFERRED_BIN_DIRS")
            else PREFERRED_BIN_DIRS
        )
    )
    pref_paths = [_norm_dir(p) for p in pref_dirs if p]

    # 1. Preferred standard locations on PATH and writable.
    for pref in pref_paths:
        if pref in path_set and _is_writable_dir(pref):
            return pref

    local_bin = _norm_dir(str(home_dir / ".local/bin"))
    if local_bin in path_set and _local_bin_usable(local_bin, home_dir):
        return local_bin

    # 2. Any other user-writable directory on PATH (excluding OS, shims, and ~/.bin).
    home_bin = _norm_dir(str(home_dir / ".bin"))
    for raw, norm in zip(path_entries, norm_path_entries):
        if _is_excluded_path_dir(raw, norm, home_bin):
            continue
        if _is_writable_dir(norm):
            return norm

    # 3. ~/.bin if it is on PATH and writable.
    if home_bin in path_set and _is_writable_dir(home_bin):
        return home_bin

    # 4. Off-PATH fallback: preferred writable standard dirs, then existing writable ~/.local/bin, then ~/.bin last.
    for pref in pref_paths:
        if _is_writable_dir(pref):
            return pref
    if _is_writable_dir(local_bin):
        return local_bin
    return home_bin


def install(args):
    home = Path.home().resolve()
    prefix = (home / ".local/opt/harness").resolve()
    releases = prefix / "releases"
    current = prefix / "current"
    bin_dir = select_bin_dir(args.bin_dir, home=home)
    hi_link = bin_dir / "hi"
    import_link = bin_dir / "hi-import"
    import_bin = current / "bin/hi-import"
    hi = current / "bin/hi"
    launcher = current / "bin/h-daemon"
    data = Path(args.data_dir).expanduser().resolve()
    # Binding the install to the selected store explicitly avoids accidentally
    # using any daemon URL or build path inherited from the terminal.
    env = {k: v for k, v in os.environ.items() if k not in ("H_DAEMON_URL", "H_DAEMON_BIN", "H_BUILD_PATH")}
    env["H_DATA_DIR"] = str(data)
    if args.service and sys.platform != "darwin":
        raise RuntimeError("--service requires a macOS desktop login")

    if not args.activate:
        path = Path(args.path) if args.path is not None else Path("dist/harness")
        try:
            bundle = path.resolve(strict=True)
        except FileNotFoundError as err:
            if args.path is not None:
                raise
            raise RuntimeError("No bundle at dist/harness; run mix h.bundle first or pass a bundle directory.") from err
        valid_bundle(bundle)

    prefix.mkdir(parents=True, exist_ok=True, mode=0o700)
    with installation_lock(prefix):
        releases.mkdir(exist_ok=True)
        old = current_release(current, releases)
        if os.path.lexists(hi_link) and (not hi_link.is_symlink() or hi_link.readlink() != hi):
            raise RuntimeError(f"Refusing to replace the existing {hi_link}")
        existing_service = service_file(home, data, launcher)
        if args.service and not data.exists():
            data.mkdir(parents=True, mode=0o700)
        if args.activate:
            if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}", args.path):
                raise RuntimeError("Expected one installed release ID")
            release = releases / args.path
            if release.is_symlink() or not release.is_dir():
                raise RuntimeError(f"No installed release: {release}")
            valid_bundle(release)
        else:
            name = f"{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
            release = releases / name
            with tempfile.TemporaryDirectory(prefix=".stage-", dir=releases) as temp:
                staged = Path(temp) / "bundle"
                shutil.copytree(bundle, staged, symlinks=True)
                staged.rename(release)
            print(f"Staged {release.name}: {release}")

        has_import = (release / "bin/hi-import").is_file() and os.access(release / "bin/hi-import", os.X_OK)
        owned_import_link = import_link.is_symlink() and import_link.readlink() == import_bin
        if has_import and os.path.lexists(import_link) and not owned_import_link:
            raise RuntimeError(f"Refusing to replace the existing {import_link}")

        checked([release / "bin/h-daemon", "--data-dir", data, "--check-config"], env)
        status = run([release / "bin/hi", "daemon", "status"], env)
        if status.returncode != 0 and "Daemon is not running" not in status.stderr:
            raise RuntimeError(f"Cannot establish daemon status; activation refused: {status.stderr.strip()}")
        if status.returncode == 0 and existing_service is None:
            raise RuntimeError("A manually started or embedded daemon is running. Finish its work, stop it, then retry activation.")
        if existing_service is not None:
            if old is None:
                raise RuntimeError("The LaunchAgent has no previous current bundle; repair it before activation")
            # A successful idle shutdown exits 0, so KeepAlive does not restart
            # the old release while the link is being switched.
            checked([release / "bin/hi", "daemon", "check-service"], env)
            # Use the new release's hi so cooperative drain mode is sent even when
            # upgrading from an older release whose hi only supported idle shutdown.
            checked([release / "bin/hi", "daemon", "stop"], env, timeout=660)
            # The API and store lock can disappear before the VM exits. A kickstart
            # while launchd still tracks that process may not start a replacement.
            print("Waiting for launchd to finish stopping the old release...")
            try:
                wait_until_stopped(existing_service, env)
            except RuntimeError as err:
                raise RuntimeError(
                    f"{err}\nCheck launchctl and {data / 'h-daemon.log'}. "
                    f"Once the service is stopped, retry with mix h.install --activate {release.name}."
                ) from err

        switch(current, release)
        if not os.path.lexists(hi_link):
            bin_dir.mkdir(parents=True, exist_ok=True)
            hi_link.symlink_to(hi)
        if has_import and not owned_import_link:
            import_link.symlink_to(import_bin)
        elif not has_import and owned_import_link:
            import_link.unlink()
        print(f"Activated {release.name}; {hi_link} points through {current}")
        if old is not None and old != release:
            print(f"Previous bundle retained: {old.name} (mix h.install --activate {old.name})")
        if existing_service is not None or args.service:
            try:
                action = ["start-service"] if existing_service is not None else ["install-service", "--launcher", launcher]
                checked([hi, "daemon", *action], env)
                wait_until_serving(hi, env)
            except (RuntimeError, subprocess.TimeoutExpired) as err:
                # Once launch has been attempted we cannot prove it never served
                # a command. Never switch back or kill it on a readiness error.
                raise RuntimeError(f"{err}\nCurrent still points to {release.name}; no automatic rollback was attempted.") from err
        path_dirs = [Path(entry).resolve() for entry in os.get_exec_path() if entry]
        if bin_dir.resolve() not in path_dirs:
            print(f"Add {bin_dir} to PATH in your shell startup file.")


def main():
    parser = argparse.ArgumentParser(prog="mix h.install", description=__doc__)
    parser.add_argument("path", nargs="?", help="prebuilt bundle directory (default: dist/harness), or installed release ID with --activate")
    parser.add_argument("--activate", action="store_true", help="activate an existing release instead of copying")
    parser.add_argument("--service", action="store_true", help="register and start a macOS per-user LaunchAgent on first install")
    parser.add_argument(
        "--bin-dir",
        default=None,
        help="directory for the hi symlink (default: cascade writable PATH dirs, falling back to ~/.bin last)",
    )
    parser.add_argument("--data-dir", default=os.environ.get("H_DATA_DIR") or "~/.local/share/h")
    args = parser.parse_args()
    if args.activate and args.path is None:
        parser.error("--activate requires an installed release ID")
    try:
        install(args)
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as err:
        print(f"Installation refused or incomplete: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
