#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import tarfile
import tempfile

EXCLUDES = {'.git', '__pycache__', '.pytest_cache', 'node_modules', 'dist', 'build'}


def include_filter(info: tarfile.TarInfo) -> tarfile.TarInfo | None:
    parts = pathlib.PurePosixPath(info.name).parts
    if any(part in EXCLUDES for part in parts):
        return None
    if info.name.endswith(('.pyc', '.pyo', '.log', '.db')):
        return None
    return info


def main() -> None:
    parser = argparse.ArgumentParser(description='Build a self-extracting BSM bootstrap')
    parser.add_argument('source', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    args = parser.parse_args()

    source = args.source.resolve()
    if not (source / 'bootstrap.sh').is_file():
        raise SystemExit('bootstrap.sh not found in source directory')

    with tempfile.TemporaryDirectory() as td:
        archive = pathlib.Path(td) / 'payload.tar.gz'
        with tarfile.open(archive, 'w:gz') as tf:
            tf.add(source, arcname=source.name, filter=include_filter)
        payload = archive.read_bytes()
        digest = hashlib.sha256(payload).hexdigest()

        header = f'''#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_SHA256="{digest}"
SELF="$(readlink -f "$0")"
TMP="$(mktemp -d -t bsm-community.XXXXXX)"
ARCHIVE="$TMP/payload.tar.gz"
trap 'rm -rf "$TMP"' EXIT

LINE="$(awk '/^__BSM_ARCHIVE_BELOW__$/ {{print NR + 1; exit}}' "$SELF")"
[[ -n "$LINE" ]] || {{ echo "Embedded archive marker not found." >&2; exit 1; }}
tail -n +"$LINE" "$SELF" > "$ARCHIVE"
ACTUAL_SHA256="$(sha256sum "$ARCHIVE" | awk '{{print $1}}')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {{ echo "Embedded archive checksum mismatch." >&2; exit 1; }}
tar -xzf "$ARCHIVE" -C "$TMP"
ROOT="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -x "$ROOT/bootstrap.sh" ]] || chmod +x "$ROOT/bootstrap.sh"
exec "$ROOT/bootstrap.sh" "$@"
__BSM_ARCHIVE_BELOW__
'''.encode('utf-8')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open('wb') as f:
            f.write(header)
            f.write(payload)
        os.chmod(args.output, 0o755)
        print(args.output)


if __name__ == '__main__':
    main()
