#!/bin/sh
# Package a tested standalone H bundle into a deterministic release tarball.
#
# Usage: scripts/package-release.sh <bundle-dir> <output-dir>
# Produces: <output-dir>/harness-v<VERSION>-<TARGET>.tar.gz
#           containing top-level directory `harness/`.
set -eu

if [ "$#" != 2 ]; then
  echo 'Usage: scripts/package-release.sh <bundle-dir> <output-dir>' >&2
  exit 2
fi

bundle_dir=$(CDPATH= cd -- "$1" && pwd -P)
mkdir -p "$2"
out_dir=$(CDPATH= cd -- "$2" && pwd -P)

manifest="$bundle_dir/BUILD_MANIFEST.json"
if [ ! -f "$manifest" ]; then
  echo "Missing BUILD_MANIFEST.json in bundle: $bundle_dir" >&2
  exit 1
fi

for req in bin/hi bin/h-daemon bin/hi-import bin/harness releases/start_erl.data README.md LICENSE; do
  if [ ! -e "$bundle_dir/$req" ]; then
    echo "Incomplete bundle ($bundle_dir): missing $req" >&2
    exit 1
  fi
done

python3 - "$bundle_dir" "$out_dir" <<'PY'
import gzip
import json
import os
from pathlib import Path
import tarfile
import sys

bundle_dir = Path(sys.argv[1]).resolve()
out_dir = Path(sys.argv[2]).resolve()
manifest = json.loads((bundle_dir / "BUILD_MANIFEST.json").read_text(encoding="utf-8"))

version = manifest["version"]
target = manifest["target"]
archive_name = f"harness-v{version}-{target}.tar.gz"
archive_path = out_dir / archive_name
tmp_path = out_dir / f".{archive_name}.tmp.{os.getpid()}"

# Use a fixed mtime (SOURCE_DATE_EPOCH or manifest built_at) and sorted entries
# with normalized uid/gid for reproducible tarballs across macOS and Linux.
mtime = int(os.environ.get("SOURCE_DATE_EPOCH", "1767225600"))

entries = []
for root, dirs, files in os.walk(bundle_dir):
    dirs.sort()
    files.sort()
    root_path = Path(root)
    rel_dir = root_path.relative_to(bundle_dir)
    entries.append((root_path, Path("harness") if rel_dir == Path(".") else Path("harness") / rel_dir))
    for name in files:
        if name == ".DS_Store":
            continue
        src = root_path / name
        rel = Path("harness") / (rel_dir / name if rel_dir != Path(".") else Path(name))
        entries.append((src, rel))

try:
    with tmp_path.open("wb") as raw_fh:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_fh, compresslevel=9, mtime=0) as gz_fh:
            with tarfile.open(fileobj=gz_fh, mode="w", format=tarfile.GNU_FORMAT) as tf:
                for src, arc in entries:
                    ti = tf.gettarinfo(str(src), arcname=arc.as_posix())
                    ti.uid = 0
                    ti.gid = 0
                    ti.uname = "root"
                    ti.gname = "root"
                    ti.mtime = mtime
                    # Preserve execute bits, normalize group/other write bits.
                    if ti.isdir():
                        ti.mode = 0o755
                    elif ti.issym():
                        ti.mode = 0o777
                    else:
                        ti.mode = 0o755 if (ti.mode & 0o111) else 0o644
                    if ti.isreg():
                        with src.open("rb") as fh:
                            tf.addfile(ti, fh)
                    else:
                        tf.addfile(ti)
    os.replace(tmp_path, archive_path)
finally:
    if tmp_path.exists():
        tmp_path.unlink()

print(f"Packaged {archive_path} ({archive_path.stat().st_size} bytes)")
PY
