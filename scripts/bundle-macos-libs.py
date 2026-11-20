#!/usr/bin/env python3
"""Package the Homebrew OTP libcrypto dependency, or reject unknown native links."""

import os
from pathlib import Path
import shutil
import subprocess
import sys

SYSTEM = ("/usr/lib/", "/System/Library/")


def run(*args):
    return subprocess.check_output(args, text=True)


def links(path):
    # Skip launcher scripts and OTP data without asking otool to parse them.
    with path.open("rb") as f:
        if f.read(4) not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            return []
    return [line.strip().split(" (", 1)[0] for line in run("/usr/bin/otool", "-L", str(path)).splitlines() if line.startswith("\t")]


def bundle(root):
    candidates = [p for p in root.rglob("*") if p.is_file() and (p.suffix in (".so", ".dylib") or p.parent.name == "bin")]
    rewrites = []
    crypto = set()
    for binary in candidates:
        for dependency in links(binary):
            if dependency.startswith(SYSTEM):
                continue
            if Path(dependency).is_absolute() and Path(dependency).name.startswith("libcrypto.") and Path(dependency).suffix == ".dylib":
                crypto.add(Path(dependency))
                rewrites.append((binary, dependency))
            else:
                raise SystemExit(f"Unsupported native dependency in {binary.name}: {dependency}")
    if not crypto:
        return  # OTP built with a statically linked crypto library.
    if len(crypto) != 1:
        raise SystemExit("Bundle requires exactly one dynamically linked libcrypto")
    source = crypto.pop()
    if any(not link.startswith(SYSTEM) and link != str(source) for link in links(source)):
        raise SystemExit("libcrypto has external native dependencies")
    prefix = source.resolve().parent.parent
    license_path = next((prefix / name for name in ["LICENSE.txt", "LICENSE"] if (prefix / name).is_file()), None)
    if license_path is None:
        raise SystemExit(f"Cannot find the libcrypto license under {prefix}")
    native = root / "native"
    native.mkdir()
    library = native / source.name
    shutil.copyfile(source, library)
    shutil.copyfile(license_path, native / "OpenSSL-LICENSE.txt")
    run("/usr/bin/install_name_tool", "-id", f"@loader_path/{library.name}", str(library))
    run("/usr/bin/codesign", "--force", "--sign", "-", str(library))
    for binary, old in rewrites:
        binary.chmod(binary.stat().st_mode | 0o200)
        relative = os.path.relpath(library, binary.parent)
        run("/usr/bin/install_name_tool", "-change", old, f"@loader_path/{relative}", str(binary))
        run("/usr/bin/codesign", "--force", "--sign", "-", str(binary))
    print(f"Bundled {library.name}; native links no longer point at the build machine's OpenSSL")


if __name__ == "__main__":
    bundle(Path(sys.argv[1]))
