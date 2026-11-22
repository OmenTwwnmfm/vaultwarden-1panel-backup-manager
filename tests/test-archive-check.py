#!/usr/bin/env python3
from __future__ import annotations

import gzip
import io
import os
import subprocess
import sys
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts" / "vw-archive-check.py"


def make_archive(entries: list[tarfile.TarInfo]) -> bytes:
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for member in entries:
            data = b"x" * member.size if member.isfile() else None
            archive.addfile(member, io.BytesIO(data) if data is not None else None)
    return stream.getvalue()


def file_entry(name: str, data: bytes = b"data") -> tarfile.TarInfo:
    member = tarfile.TarInfo(name)
    member.size = len(data)
    member.mode = 0o600
    return member


def check(payload: bytes) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECKER)],
        input=payload,
        capture_output=True,
        text=False,
        check=False,
        timeout=30,
    )


def main() -> int:
    valid = make_archive([file_entry("./db.sqlite3", b"database"), file_entry("attachments/a", b"file")])
    result = check(valid)
    assert result.returncode == 0, result.stderr.decode()
    assert result.stdout.splitlines() == [b"12"], result.stdout

    traversal = file_entry("../outside")
    result = check(make_archive([traversal]))
    assert result.returncode != 0 and b"traversal" in result.stderr

    symlink = tarfile.TarInfo("link")
    symlink.type = tarfile.SYMTYPE
    symlink.linkname = "/etc/passwd"
    result = check(make_archive([symlink]))
    assert result.returncode != 0 and b"link or special" in result.stderr

    hardlink = tarfile.TarInfo("link")
    hardlink.type = tarfile.LNKTYPE
    hardlink.linkname = "db.sqlite3"
    result = check(make_archive([hardlink]))
    assert result.returncode != 0 and b"link or special" in result.stderr

    duplicate = file_entry("db.sqlite3")
    result = check(make_archive([duplicate, file_entry("db.sqlite3")]))
    assert result.returncode != 0 and b"duplicate" in result.stderr

    setuid = file_entry("dangerous", b"x")
    setuid.mode = 0o4755
    result = check(make_archive([setuid]))
    assert result.returncode != 0 and b"setuid/setgid" in result.stderr

    result = check(make_archive([file_entry("dir/file"), file_entry("dir")]))
    assert result.returncode != 0 and b"replaces a directory" in result.stderr
    result = check(make_archive([file_entry("dir"), file_entry("dir/file")]))
    assert result.returncode != 0 and b"nested under" in result.stderr
    assert check(make_archive([file_entry("line\nbreak")])).returncode != 0
    damaged = bytearray(valid)
    damaged[-8] ^= 1
    assert check(damaged).returncode != 0
    with_trailing_data = gzip.compress(gzip.decompress(valid) + os.urandom(1024 * 1024))
    assert check(with_trailing_data).returncode == 0
    damaged_tail = bytearray(with_trailing_data)
    damaged_tail[-8] ^= 1
    assert check(damaged_tail).returncode != 0
    large = make_archive([file_entry(f"attachments/file-{index}", b"x") for index in range(15000)])
    result = check(large)
    assert result.returncode == 0 and result.stdout.strip() == b"15000", result.stderr

    print("PASS: archive validator accepts normal data and totals extracted bytes")
    print("PASS: archive validator rejects traversal, links, duplicate paths, and setuid modes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
