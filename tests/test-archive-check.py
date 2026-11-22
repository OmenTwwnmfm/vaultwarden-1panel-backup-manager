#!/usr/bin/env python3
from __future__ import annotations

import io
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

    print("PASS: archive validator accepts normal data and totals extracted bytes")
    print("PASS: archive validator rejects traversal, links, duplicate paths, and setuid modes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
