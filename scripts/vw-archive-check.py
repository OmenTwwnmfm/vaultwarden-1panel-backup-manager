#!/usr/bin/env python3
"""Validate a streamed Vaultwarden tar archive and report extracted bytes."""
from __future__ import annotations

import gzip
import sys
import tarfile
import zlib


def reject(message: str) -> None:
    print(f"archive rejected: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    seen: dict[str, str] = {}
    has_children: set[str] = set()
    total_bytes = 0
    member_count = 0
    writable_entries = 0

    try:
        with gzip.GzipFile(fileobj=sys.stdin.buffer) as compressed, tarfile.open(fileobj=compressed, mode="r|", errorlevel=2) as archive:
            for member in archive:
                member_count += 1
                if member_count > 1_000_000:
                    reject("too many archive entries")

                name = member.name
                if not name or name.startswith("/") or any(ord(char) < 32 or ord(char) == 127 for char in name):
                    reject("absolute, empty, or invalid member path")
                parts = [part for part in name.split("/") if part not in ("", ".")]
                if any(part == ".." for part in parts):
                    reject(f"path traversal in member {name!r}")
                normalized = "/".join(parts) or "."

                if member.isdir():
                    kind = "directory"
                elif member.type in (tarfile.REGTYPE, tarfile.AREGTYPE) and not member.issparse() and parts and member.size >= 0:
                    kind = "file"
                    total_bytes += member.size
                else:
                    reject(f"link or special file in member {name!r}")
                if member.mode & 0o6000:
                    reject(f"setuid/setgid mode in member {name!r}")
                if member.mode & 0o002:
                    writable_entries += 1

                previous_kind = seen.get(normalized)
                if previous_kind is not None:
                    if previous_kind == kind == "directory":
                        continue
                    reject(f"duplicate member path {name!r}")
                if normalized in has_children and kind != "directory":
                    reject(f"file replaces a directory containing entries: {name!r}")

                parent_path = ""
                for part in parts[:-1]:
                    parent_path = f"{parent_path}/{part}".strip("/")
                    if seen.get(parent_path) == "file":
                        reject(f"member is nested under a regular file: {name!r}")
                    has_children.add(parent_path)
                seen[normalized] = kind
            while compressed.read(1024 * 1024):
                pass
    except (OSError, EOFError, tarfile.TarError, zlib.error) as exc:
        print(f"archive rejected: invalid or truncated tar stream ({type(exc).__name__})", file=sys.stderr)
        return 1

    if writable_entries:
        print(f"archive warning: {writable_entries} world-writable entries", file=sys.stderr)
    print(total_bytes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
