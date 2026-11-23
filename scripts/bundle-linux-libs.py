#!/usr/bin/env python3
"""Bundle non-core Linux shared libraries for H releases and verify ELF links.

Mirrors scripts/bundle-macos-libs.py on Linux without setting LD_LIBRARY_PATH
(which would leak into child user_shell commands). Instead, copies allowed
portable runtime libraries (libcrypto.so.3, libtinfo.so.6, libncursesw.so.6)
into <bundle>/native/ and rewrites ELF RUNPATH with patchelf using relative
$ORIGIN paths. Rejects any unexpected native dependency and verifies that the
Rust CLIs (bin/hi, bin/hi-import) only link against core glibc libraries.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ELF_MAGIC = b"\x7fELF"

# Always provided by any glibc-based Linux system (Ubuntu 22.04+, Debian 12+,
# Fedora, RHEL/Rocky 9+, Arch, etc.). Never bundle glibc or libgcc_s/libstdc++.
CORE_GLIBC = {
    "libc.so.6",
    "libm.so.6",
    "libdl.so.2",
    "libpthread.so.0",
    "librt.so.1",
    "libresolv.so.2",
    "libutil.so.1",
    "libgcc_s.so.1",
}

# Permitted on ERTS / C++ runtime binaries (beam.smp links libstdc++.so.6).
CORE_CPP = {"libstdc++.so.6"}

# Libraries we intentionally vendor into <bundle>/native/ with relative $ORIGIN
# RUNPATH so the bundle runs on minimal distros (e.g. Debian/Ubuntu slim,
# Fedora, Arch, Alpine+gcompat) without requiring system OpenSSL 3 or libtinfo6.
BUNDLEABLE = {
    "libcrypto.so.3": {
        "license_name": "OpenSSL-LICENSE.txt",
        "license_candidates": [
            "/usr/share/doc/libssl3/copyright",
            "/usr/share/doc/libssl3t64/copyright",
            "/usr/share/licenses/openssl/LICENSE.txt",
            "/usr/share/licenses/openssl/LICENSE",
            "/usr/share/doc/openssl/copyright",
        ],
    },
    "libtinfo.so.6": {
        "license_name": "ncurses-LICENSE.txt",
        "license_candidates": [
            "/usr/share/doc/libtinfo6/copyright",
            "/usr/share/licenses/ncurses/COPYING",
            "/usr/share/doc/ncurses-base/copyright",
        ],
    },
    "libncursesw.so.6": {
        "license_name": "ncurses-LICENSE.txt",
        "license_candidates": [
            "/usr/share/doc/libncursesw6/copyright",
            "/usr/share/doc/libtinfo6/copyright",
            "/usr/share/licenses/ncurses/COPYING",
        ],
    },
    "libz.so.1": {
        "license_name": "zlib-LICENSE.txt",
        "license_candidates": [
            "/usr/share/doc/zlib1g/copyright",
            "/usr/share/licenses/zlib/LICENSE",
        ],
    },
}

RUST_CLIS = {"hi", "hi-import"}

LDD_LINE = re.compile(r"^\s*(\S+)\s+=>\s+(\S+)\s+\(0x[0-9a-fA-F]+\)$")
LDD_MISSING = re.compile(r"^\s*(\S+)\s+=>\s+not found$")


def is_elf(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    try:
        with path.open("rb") as fh:
            return fh.read(4) == ELF_MAGIC
    except OSError:
        return False


def is_dynamic_linker(soname: str) -> bool:
    return soname.startswith("ld-linux") or soname.startswith("/lib") or soname.startswith("/usr/lib") or soname == "linux-vdso.so.1"


def ldd_deps(path: Path):
    """Return list of (soname, resolved_path) for an ELF file."""
    proc = subprocess.run(["ldd", str(path)], text=True, capture_output=True)
    combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
    if "not a dynamic executable" in combined or "statically linked" in combined:
        return []
    if proc.returncode != 0:
        raise SystemExit(f"ldd failed on {path}: {combined.strip()}")
    deps = []
    for line in proc.stdout.splitlines():
        missing = LDD_MISSING.match(line)
        if missing:
            raise SystemExit(f"Unresolved shared library in {path}: {missing.group(1)}")
        match = LDD_LINE.match(line)
        if match:
            soname, target = match.group(1), match.group(2)
            deps.append((soname, Path(target)))
    return deps


def find_license(soname: str) -> Path:
    meta = BUNDLEABLE[soname]
    for candidate in meta["license_candidates"]:
        p = Path(candidate)
        if p.is_file():
            return p
    raise SystemExit(f"Cannot locate license file for bundled library {soname}; checked {meta['license_candidates']}")


def set_rpath(binary: Path, relative_dir: str):
    rpath = "$ORIGIN" if relative_dir in ("", ".") else f"$ORIGIN/{relative_dir}"
    binary.chmod(binary.stat().st_mode | 0o200)
    subprocess.run(
        ["patchelf", "--force-rpath", "--set-rpath", rpath, str(binary)],
        check=True,
    )


def bundle(root: Path):
    root = root.resolve()
    if shutil.which("patchelf") is None:
        raise SystemExit("patchelf is required on Linux to rewrite ELF RUNPATH for bundled libraries")

    elf_files = sorted(p for p in root.rglob("*") if is_elf(p))
    if not elf_files:
        raise SystemExit(f"No ELF binaries found in bundle: {root}")

    to_bundle = {}  # soname -> resolved host Path
    binaries_to_patch = set()

    for binary in elf_files:
        rel = binary.relative_to(root)
        is_rust_cli = rel.parent == Path("bin") and binary.name in RUST_CLIS
        for soname, resolved in ldd_deps(binary):
            if is_dynamic_linker(soname):
                continue
            if soname in CORE_GLIBC:
                continue
            if is_rust_cli:
                raise SystemExit(
                    f"Rust CLI {rel} must only link core glibc libraries, found {soname} ({resolved})"
                )
            if soname in CORE_CPP:
                continue
            if soname in BUNDLEABLE:
                real_target = resolved.resolve(strict=True)
                existing = to_bundle.get(soname)
                if existing is not None and existing != real_target:
                    raise SystemExit(f"Conflicting paths for {soname}: {existing} vs {real_target}")
                to_bundle[soname] = real_target
                binaries_to_patch.add(binary)
            else:
                raise SystemExit(f"Unsupported native dependency in {rel}: {soname} ({resolved})")

    if not to_bundle:
        print("Verified Linux ELF binaries: only core glibc/libstdc++ links detected")
        return

    native = root / "native"
    native.mkdir(exist_ok=True)
    copied_licenses = set()

    for soname, source in sorted(to_bundle.items()):
        # Ensure the vendored library itself only depends on core glibc or other bundled libs.
        for sub_soname, sub_resolved in ldd_deps(source):
            if is_dynamic_linker(sub_soname) or sub_soname in CORE_GLIBC:
                continue
            if sub_soname in to_bundle:
                continue
            raise SystemExit(
                f"Bundled library {soname} ({source}) has unsupported transitive dependency {sub_soname} ({sub_resolved})"
            )

        dest = native / soname
        shutil.copyfile(source, dest)
        dest.chmod(0o755)
        set_rpath(dest, ".")

        lic_name = BUNDLEABLE[soname]["license_name"]
        if lic_name not in copied_licenses:
            lic_src = find_license(soname)
            shutil.copyfile(lic_src, native / lic_name)
            copied_licenses.add(lic_name)

    for binary in sorted(binaries_to_patch):
        rel_native = os.path.relpath(native, binary.parent)
        set_rpath(binary, rel_native)

    # Re-verify every patched binary resolves its bundled libs from <bundle>/native/.
    for binary in sorted(binaries_to_patch):
        for soname, resolved in ldd_deps(binary):
            if soname in to_bundle:
                if resolved.resolve(strict=True) != (native / soname).resolve(strict=True):
                    raise SystemExit(
                        f"Patched binary {binary.relative_to(root)} still resolves {soname} to {resolved}, expected {native / soname}"
                    )

    bundled_names = ", ".join(sorted(to_bundle))
    print(f"Bundled {bundled_names} into native/ with relative $ORIGIN RUNPATH (zero LD_LIBRARY_PATH needed)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: scripts/bundle-linux-libs.py /path/to/bundle")
    bundle(Path(sys.argv[1]))
