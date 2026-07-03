#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import tarfile
import tempfile
import zipfile


def main() -> None:
    parser = argparse.ArgumentParser(description="Build a BSM .bsmupdate package")
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--kind", choices=["panel", "taskpack"], default="panel")
    parser.add_argument("--name", default="BSM Community")
    parser.add_argument("--version", required=True)
    args = parser.parse_args()

    source = args.source.resolve()
    if not source.is_dir():
        raise SystemExit("Source directory not found")

    with tempfile.TemporaryDirectory() as td:
        payload = pathlib.Path(td) / "payload.tar.gz"
        with tarfile.open(payload, "w:gz") as tf:
            tf.add(source, arcname=source.name, recursive=True)
        digest = hashlib.sha256(payload.read_bytes()).hexdigest()
        manifest = {
            "kind": args.kind,
            "name": args.name,
            "version": args.version,
            "payload_sha256": digest,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("manifest.json", json.dumps(manifest, indent=2) + "\n")
            zf.write(payload, "payload.tar.gz")
    print(args.output)


if __name__ == "__main__":
    main()
