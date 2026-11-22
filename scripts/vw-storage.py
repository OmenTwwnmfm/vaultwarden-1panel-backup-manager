#!/usr/bin/env python3
import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import stat
import sys
import tempfile
import time
import urllib.parse
import uuid
import xml.etree.ElementTree as ET


ARCHIVE_PATTERN = re.compile(r"(?:vw|pre-restore)-\d{8}-\d{6}(?:-\d+)?\.tar\.gz\.age\Z")
MEMBER_PATTERN = re.compile(
    r"((?:vw|pre-restore)-\d{8}-\d{6}(?:-\d+)?)(?:\.tar\.gz\.age|\.manifest\.json\.age)(?:\.sha256|\.keep)?\Z"
)
DEFAULT_CONFIG = "/etc/vaultwarden-webdav.json"
CHUNK_SIZE = 1024 * 1024


class WebDAVStatusError(ValueError):
    def __init__(self, method, status):
        self.status = status
        super().__init__(f"WebDAV {method} 返回 HTTP {status}")


def regular_file(path):
    return path.is_file() and not path.is_symlink() and path.stat().st_nlink == 1


def require_archive(name):
    if not ARCHIVE_PATTERN.fullmatch(name):
        raise ValueError("备份文件名无效")
    return name


def members_for(name):
    require_archive(name)
    manifest = name.removesuffix(".tar.gz.age") + ".manifest.json.age"
    return [name, name + ".sha256", manifest, manifest + ".sha256"]


def local_sets(directory):
    directory = Path(directory)
    grouped = {}
    for path in directory.iterdir():
        match = MEMBER_PATTERN.fullmatch(path.name)
        if match and not match[0].endswith(".keep"):
            name = match[1] + ".tar.gz.age"
            grouped.setdefault(name, []).append(path)
    rows = []
    for name, paths in sorted(grouped.items(), key=lambda item: re.search(r"\d{8}-\d{6}", item[0])[0], reverse=True):
        members = members_for(name)
        protected = any(os.path.lexists(directory / (member + ".keep")) for member in members)
        safe_files = all(regular_file(path) for path in paths)
        rows.append({
            "name": name,
            "bytes": sum(path.lstat().st_size for path in paths),
            "files": len(paths),
            "protected": protected,
            "ready": safe_files and all(regular_file(directory / member) for member in members[:2]),
            "kind": "恢复前快照" if name.startswith("pre-restore-") else "常规备份",
        })
    return rows


def delete_local(directory, name, data_dir, repo_dir):
    directory = Path(directory).resolve(strict=True)
    if str(directory) in (directory.anchor, "/var", "/var/lib", "/opt", "/root", "/home", "/etc", "/usr"):
        raise ValueError("本地备份目录必须是专用子目录")
    for other in (data_dir, repo_dir):
        if not other:
            continue
        other = Path(other).resolve()
        if directory == other or directory in other.parents or other in directory.parents:
            raise ValueError("备份目录与数据目录或 Git 工作目录重叠")
    members = members_for(name)
    if any(os.path.lexists(directory / (member + ".keep")) for member in members):
        raise ValueError("该备份有 .keep 保护标记，请先确认并取消保护")
    paths = [directory / member for member in members if os.path.lexists(directory / member)]
    if not paths:
        raise ValueError("本地备份组不存在")
    if any(not regular_file(path) for path in paths):
        raise ValueError("备份组包含链接或非普通文件，删除已停止")
    for path in paths:
        path.unlink()
    return len(paths)


def prune_local(directory, retention_days, now=None):
    if not isinstance(retention_days, int) or retention_days < 1:
        raise ValueError("本地备份保留天数必须为正整数")
    directory = Path(directory).resolve(strict=True)
    cutoff = (time.time() if now is None else now) - retention_days * 86400
    removed = []
    for row in local_sets(directory):
        name = row["name"]
        if name.startswith("pre-restore-"):
            continue
        archive = directory / name
        if not regular_file(archive) or archive.stat().st_mtime >= cutoff:
            continue
        members = members_for(name)
        group = [directory / member for member in members if os.path.lexists(directory / member)]
        if any(os.path.lexists(directory / (member + ".keep")) for member in members):
            continue
        if any(not regular_file(path) for path in group):
            continue
        for path in group:
            path.unlink()
        removed.append(name)
    return removed


def checksum_value(content, name):
    try:
        text = content.decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError("SHA256 文件编码无效") from error
    match = re.fullmatch(r"([a-fA-F0-9]{64}) [ *]([^\r\n]+)(?:\r?\n)?", text)
    if not match or match[2] != name:
        raise ValueError("SHA256 必须且只能校验所选文件的原始文件名")
    return match[1].lower()


def file_digest(path):
    with path.open("rb") as source:
        digest = hashlib.sha256()
        while chunk := source.read(CHUNK_SIZE):
            digest.update(chunk)
        return digest.hexdigest()


def verify_local(archive):
    archive = Path(archive)
    require_archive(archive.name)
    checksum = Path(str(archive) + ".sha256")
    if not regular_file(archive) or not regular_file(checksum):
        raise ValueError("备份及配套 SHA256 必须为独立的普通文件")
    if checksum.stat().st_size > 4096:
        raise ValueError("SHA256 文件过大")
    expected = checksum_value(checksum.read_bytes(), archive.name)
    with archive.open("rb") as source:
        if source.readline(100) != b"age-encryption.org/v1\n":
            raise ValueError("备份的 age 文件头无效")
    if file_digest(archive) != expected:
        raise ValueError("备份 SHA256 不匹配")
    return expected


class WebDAV:
    def __init__(self, config):
        if not isinstance(config, dict) or any(not isinstance(config.get(field, ""), str) for field in ("url", "username", "secret")):
            raise ValueError("WebDAV 配置字段格式无效")
        parsed = urllib.parse.urlsplit(config["url"])
        if parsed.scheme not in ("https", "http") or not parsed.hostname or "@" in parsed.netloc or parsed.query or parsed.fragment:
            raise ValueError("WebDAV 地址须为专用目录 URL，凭据请填写到用户名和密码字段")
        if parsed.scheme == "http" and parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
            raise ValueError("远程 WebDAV 必须使用 HTTPS")
        decoded = urllib.parse.unquote(parsed.path)
        if any(part in (".", "..") for part in decoded.split("/")) or any(ord(char) < 32 for char in decoded) or "\\" in decoded:
            raise ValueError("WebDAV 目录路径无效")
        if re.search(r"%[a-fA-F0-9]{2}", decoded):
            raise ValueError("WebDAV 目录路径不接受多重编码")
        components = [part for part in decoded.split("/") if part]
        if not components or components[-1] != "vbm":
            decoded = decoded.rstrip("/") + "/vbm"
        self.parsed = parsed
        self.path = urllib.parse.quote(decoded.rstrip("/") + "/", safe="/")
        if self.path in ("/", ""):
            raise ValueError("WebDAV URL 必须指向专用备份子目录")
        username = config.get("username", "")
        secret = config.get("secret", "")
        if ":" in username or any(char in username + secret for char in "\r\n\x00"):
            raise ValueError("WebDAV 凭据格式无效")
        token = base64.b64encode((username + ":" + secret).encode("utf-8")).decode("ascii")
        self.authorization = "Basic " + token

    def request(self, method, name="", body=None, headers=None):
        stored_name = name.split(".upload-", 1)[0]
        if name and (not MEMBER_PATTERN.fullmatch(stored_name) or stored_name.endswith(".keep") or (name != stored_name and not re.fullmatch(re.escape(stored_name) + r"\.upload-[a-f0-9]{32}", name))):
            raise ValueError("WebDAV 文件名无效")
        connection_type = http.client.HTTPSConnection if self.parsed.scheme == "https" else http.client.HTTPConnection
        options = {"timeout": 60}
        if self.parsed.scheme == "https":
            options["context"] = ssl.create_default_context()
        connection = connection_type(self.parsed.hostname, self.parsed.port, **options)
        request_headers = {"Authorization": self.authorization, "Accept-Encoding": "identity"}
        request_headers.update(headers or {})
        try:
            connection.request(method, self.path + urllib.parse.quote(name, safe=""), body=body, headers=request_headers)
            response = connection.getresponse()
            if response.status not in (200, 201, 204, 207):
                raise WebDAVStatusError(method, response.status)
            return connection, response
        except BaseException:
            connection.close()
            raise

    def small_request(self, method, name="", body=None, headers=None, limit=4096):
        connection, response = self.request(method, name, body, headers)
        try:
            content = response.read(limit + 1)
            if len(content) > limit:
                raise ValueError("WebDAV 响应超过大小限制")
            return content
        finally:
            connection.close()

    def ensure_directory(self):
        body = b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>'
        headers = {"Depth": "0", "Content-Type": "application/xml"}
        try:
            content = self.small_request("PROPFIND", body=body, headers=headers)
        except WebDAVStatusError as error:
            if error.status != 404:
                raise
            try:
                self.small_request("MKCOL")
            except WebDAVStatusError as create_error:
                if create_error.status not in (405, 409):
                    raise
            content = self.small_request("PROPFIND", body=body, headers=headers)
        if b"<!DOCTYPE" in content.upper() or b"<!ENTITY" in content.upper():
            raise ValueError("WebDAV XML 包含不受支持的声明")
        root = ET.fromstring(content)
        collection = any(
            resource is not None and resource.find("{DAV:}collection") is not None
            for resource in root.findall(".//{DAV:}resourcetype")
        )
        if root.tag != "{DAV:}multistatus" or not collection:
            raise ValueError("WebDAV vbm 目录不存在或不是集合")

    def list_archives(self):
        self.ensure_directory()
        body = b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>'
        content = self.small_request("PROPFIND", body=body, headers={"Depth": "1", "Content-Type": "application/xml"}, limit=8 * 1024 * 1024)
        if b"<!DOCTYPE" in content.upper() or b"<!ENTITY" in content.upper():
            raise ValueError("WebDAV XML 包含不受支持的声明")
        root = ET.fromstring(content)
        if root.tag != "{DAV:}multistatus":
            raise ValueError("WebDAV 未返回 multistatus 列表")
        names = set()
        base_path = urllib.parse.unquote(self.path)
        for entry in root.findall("{DAV:}response"):
            href = urllib.parse.urlsplit(entry.findtext("{DAV:}href", ""))
            if href.netloc and (href.netloc != self.parsed.netloc or href.scheme != self.parsed.scheme):
                continue
            if href.query or href.fragment:
                continue
            path = urllib.parse.unquote(href.path)
            if not path.startswith("/"):
                path = base_path + path
            if not path.startswith(base_path):
                continue
            name = path[len(base_path):]
            if not MEMBER_PATTERN.fullmatch(name) or name.endswith(".keep"):
                continue
            for propstat in entry.findall("{DAV:}propstat"):
                status_text = propstat.findtext("{DAV:}status", "")
                resource = propstat.find("{DAV:}prop/{DAV:}resourcetype")
                if " 200 " in status_text and resource is not None and len(resource) == 0:
                    names.add(name)
        archives = (name for name in names if ARCHIVE_PATTERN.fullmatch(name) and name + ".sha256" in names)
        return sorted(archives, key=lambda name: re.search(r"\d{8}-\d{6}", name)[0], reverse=True)

    def remote_digest(self, name):
        connection, response = self.request("GET", name)
        try:
            digest = hashlib.sha256()
            while chunk := response.read(CHUNK_SIZE):
                digest.update(chunk)
            return digest.hexdigest()
        finally:
            connection.close()

    def upload_file(self, path, expected):
        temporary = path.name + ".upload-" + uuid.uuid4().hex
        try:
            with path.open("rb") as source:
                connection, response = self.request("PUT", temporary, source, {
                    "Content-Length": str(path.stat().st_size),
                    "Content-Type": "application/octet-stream",
                    "If-None-Match": "*",
                })
                try:
                    response.read(4096)
                finally:
                    connection.close()
            if self.remote_digest(temporary) != expected:
                raise ValueError("WebDAV 上传后回读 SHA256 不匹配，本地密文已保留")
            destination = urllib.parse.urlunsplit((self.parsed.scheme, self.parsed.netloc, self.path + urllib.parse.quote(path.name), "", ""))
            try:
                self.small_request("MOVE", temporary, headers={"Destination": destination, "Overwrite": "F"})
            except WebDAVStatusError as error:
                if error.status != 412 or self.remote_digest(path.name) != expected:
                    raise
            if self.remote_digest(path.name) != expected:
                raise ValueError("WebDAV 发布后的文件核验失败")
        finally:
            try:
                self.small_request("DELETE", temporary)
            except (OSError, ValueError, http.client.HTTPException):
                pass

    def upload(self, archive):
        archive = Path(archive)
        verify_local(archive)
        members = members_for(archive.name)
        pairs = [(members[0], members[1])]
        manifest = archive.parent / members[2]
        manifest_checksum = archive.parent / members[3]
        if os.path.lexists(manifest) or os.path.lexists(manifest_checksum):
            if not regular_file(manifest) or not regular_file(manifest_checksum) or manifest_checksum.stat().st_size > 4096:
                raise ValueError("部署清单及校验文件不完整")
            expected = checksum_value(manifest_checksum.read_bytes(), manifest.name)
            if file_digest(manifest) != expected:
                raise ValueError("部署清单 SHA256 不匹配")
            pairs.insert(0, (members[2], members[3]))
        pending = []
        for encrypted, checksum in pairs:
            for name in (encrypted, checksum):
                path = archive.parent / name
                expected = file_digest(path)
                try:
                    existing = self.remote_digest(name)
                except WebDAVStatusError as error:
                    if error.status != 404:
                        raise
                else:
                    if existing != expected:
                        raise ValueError("远端存在同名不同内容文件，上传已停止")
                    continue
                pending.append((path, expected))
        for path, expected in pending:
            self.upload_file(path, expected)

    def download(self, name, directory, min_free_mb=0):
        require_archive(name)
        directory = Path(directory)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if any(directory.iterdir()):
            raise ValueError("WebDAV 下载目录必须为空")
        checksum = self.small_request("GET", name + ".sha256")
        expected = checksum_value(checksum, name)
        target = directory / name
        connection, response = self.request("GET", name)
        try:
            reserve_bytes = int(min_free_mb) * 1024 * 1024
            if reserve_bytes < 0:
                raise ValueError("恢复空间阈值无效")
            length = response.getheader("Content-Length")
            if length is not None and (not length.isdigit() or int(length) + reserve_bytes > shutil.disk_usage(directory).free):
                raise ValueError("WebDAV 下载目录空间不足或文件大小无效")
            expected_length = int(length) if length is not None else None
            with target.open("xb") as output:
                os.chmod(target, 0o600)
                digest = hashlib.sha256()
                downloaded = 0
                while chunk := response.read(CHUNK_SIZE):
                    downloaded += len(chunk)
                    remaining_bytes = expected_length - downloaded if expected_length is not None else 0
                    if remaining_bytes + reserve_bytes > shutil.disk_usage(directory).free:
                        raise ValueError("WebDAV 下载期间剩余空间不足")
                    output.write(chunk)
                    digest.update(chunk)
                output.flush()
                os.fsync(output.fileno())
            if digest.hexdigest() != expected:
                raise ValueError("WebDAV 下载 SHA256 不匹配")
            checksum_path = directory / (name + ".sha256")
            with checksum_path.open("xb") as output:
                os.chmod(checksum_path, 0o600)
                output.write(checksum)
            verify_local(target)
        except BaseException:
            target.unlink(missing_ok=True)
            (directory / (name + ".sha256")).unlink(missing_ok=True)
            raise
        finally:
            connection.close()
        return target


def load_webdav_config(path):
    path = Path(path)
    if not regular_file(path):
        raise ValueError("WebDAV 配置不存在或包含链接，请先配置 WebDAV")
    if os.name == "posix":
        if path.stat().st_uid != 0 or stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise ValueError("WebDAV 配置必须由 root 所有且权限为 600")
        if path.parent.stat().st_uid != 0 or path.parent.stat().st_mode & 0o022:
            raise ValueError("WebDAV 配置目录权限无效")
    return json.loads(path.read_text(encoding="utf-8"))


def configure_webdav(path):
    values = sys.stdin.buffer.read(65537)
    if len(values) > 65536:
        raise ValueError("配置输入过长")
    fields = values.decode("utf-8").split("\x00")
    if len(fields) != 4 or fields[-1] != "":
        raise ValueError("配置输入格式无效")
    config = dict(zip(("url", "username", "secret"), fields[:3]))
    client = WebDAV(config)
    client.ensure_directory()
    client.list_archives()
    path = Path(path)
    if path.is_symlink():
        raise ValueError("WebDAV 配置不能是符号链接")
    if os.name == "posix" and (os.geteuid() != 0 or path.parent.stat().st_uid != 0 or path.parent.stat().st_mode & 0o022):
        raise ValueError("WebDAV 配置须由 root 写入安全目录")
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.chmod(temporary, 0o600)
            json.dump(config, output, ensure_ascii=False)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        if os.name == "posix":
            descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main():
    sys.stdout.reconfigure(newline="\n")
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("local-list")
    listing.add_argument("directory")
    listing.add_argument("--archives", action="store_true")
    deletion = commands.add_parser("local-delete")
    deletion.add_argument("directory")
    deletion.add_argument("name")
    deletion.add_argument("--data-dir", required=True)
    deletion.add_argument("--repo-dir", required=True)
    prune = commands.add_parser("prune-local")
    prune.add_argument("directory")
    prune.add_argument("retention_days", type=int)
    verify = commands.add_parser("verify")
    verify.add_argument("archive")
    commands.add_parser("configure")
    commands.add_parser("list")
    upload = commands.add_parser("upload")
    upload.add_argument("archive")
    download = commands.add_parser("download")
    download.add_argument("name")
    download.add_argument("directory")
    download.add_argument("--min-free-mb", type=int, default=0)
    args = parser.parse_args()
    if args.command == "local-list":
        for row in local_sets(args.directory):
            if args.archives:
                if row["ready"]:
                    print(row["name"])
            else:
                protection = "已保护" if row["protected"] else "可删除"
                if not all(regular_file(path) for path in Path(args.directory).iterdir() if (match := MEMBER_PATTERN.fullmatch(path.name)) and match[1] == row["name"].removesuffix(".tar.gz.age")):
                    protection = "文件类型异常"
                state = "可校验" if row["ready"] else "配套缺失"
                print(f'{row["name"]}\t{row["bytes"]}\t{row["files"]}\t{row["kind"]}\t{protection}\t{state}')
    elif args.command == "local-delete":
        print(f"已删除 {delete_local(args.directory, args.name, args.data_dir, args.repo_dir)} 个本地文件")
    elif args.command == "prune-local":
        removed = prune_local(args.directory, args.retention_days)
        print(f"已按保留期限清理 {len(removed)} 组本地常规备份")
    elif args.command == "verify":
        verify_local(Path(args.archive))
    elif args.command == "configure":
        configure_webdav(args.config)
        print("WebDAV 目录读取测试通过，配置已保存")
    else:
        client = WebDAV(load_webdav_config(args.config))
        if args.command == "list":
            for name in client.list_archives():
                print(name)
        elif args.command == "upload":
            client.upload(Path(args.archive))
            print("WebDAV 上传与远端回读 SHA256 核验通过")
        elif args.command == "download":
            print(client.download(args.name, args.directory, args.min_free_mb))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, http.client.HTTPException) as error:
        if isinstance(error, ValueError):
            detail = str(error)
        else:
            detail = type(error).__name__
        print(f"[错误] {detail}", file=sys.stderr)
        sys.exit(1)
