#!/usr/bin/env python3
"""Validate a streamed Vaultwarden tar archive and report extracted bytes."""
from __future__ import annotations

import sys
import tarfile


def reject(message: str) -> None:
    print(f"archive rejected: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    seen: dict[str, str] = {}
    total_bytes = 0
    member_count = 0

    try:
        with tarfile.open(fileobj=sys.stdin.buffer, mode="r|gz", errorlevel=2) as archive:
            for member in archive:
                member_count += 1
                if member_count > 1_000_000:
                    reject("too many archive entries")

                name = member.name
                if not name or name.startswith("/") or "\0" in name:
                    reject("absolute, empty, or invalid member path")
                parts = [part for part in name.split("/") if part not in ("", ".")]
                if any(part == ".." for part in parts):
                    reject(f"path traversal in member {name!r}")
                normalized = "/".join(parts) or "."

                if member.isdir():
                    kind = "directory"
                elif member.isfile():
                    kind = "file"
                    total_bytes += member.size
                else:
                    reject(f"link or special file in member {name!r}")
                if member.mode & 0o6000:
                    reject(f"setuid/setgid mode in member {name!r}")

                previous_kind = seen.get(normalized)
                if previous_kind is not None:
                    if previous_kind == kind == "directory":
                        continue
                    reject(f"duplicate member path {name!r}")
                if any(path.startswith(normalized + "/") for path in seen) and kind != "directory":
                    reject(f"file replaces a directory containing entries: {name!r}")

                parent_path = ""
                for part in parts[:-1]:
                    parent_path = f"{parent_path}/{part}".strip("/")
                    if seen.get(parent_path) == "file":
                        reject(f"member is nested under a regular file: {name!r}")
                seen[normalized] = kind
    except (OSError, EOFError, tarfile.TarError) as exc:
        print(f"archive rejected: invalid or truncated tar stream ({type(exc).__name__})", file=sys.stderr)
        return 1

    print(total_bytes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
