# `.bsmupdate` format

A BSM update is a ZIP archive containing:

```text
manifest.json
payload.tar.gz
```

Example manifest:

```json
{
  "kind": "panel",
  "name": "BSM Community",
  "version": "0.2.0",
  "payload_sha256": "HEX_SHA256"
}
```

The agent rejects absolute paths, `..`, symbolic links, hard links, missing required release files, invalid versions, and checksum mismatches. A checksum does not authenticate a publisher; production releases should additionally be signed.
