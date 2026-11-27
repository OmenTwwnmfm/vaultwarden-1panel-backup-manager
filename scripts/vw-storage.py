#!/usr/bin/env python3
import argparse
import base64
import hashlib
import http.client
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid
import xml.etree.ElementTree as ET


ARCHIVE_PATTERN = re.compile(r"(?:vw|pre-restore)-\d{8}-\d{6}(?:-\d+)?\.tar\.gz\.age\Z")
MEMBER_PATTERN = re.compile(
    r"((?:vw|pre-restore)-\d{8}-\d{6}(?:-\d+)?)(?:\.tar\.gz\.age|\.manifest\.json\.age)(?:\.sha256(?:\.sig)?|\.keep)?\Z"
)
DEFAULT_CONFIG = "/etc/vaultwarden-webdav.json"
SIGNING_DIRECTORY = "/etc/vaultwarden-backup-signing"
CHUNK_SIZE = 1024 * 1024
MANIFEST_LIMIT = 1024 * 1024


class WebDAVStatusError(ValueError):
    def __init__(self, method, status):
        self.status = status
        super().__init__(f"WebDAV {method} 返回 HTTP {status}")


class MissingSignature(ValueError):
    pass


def regular_file(path):
    return path.is_file() and not path.is_symlink() and path.stat().st_nlink == 1


def require_archive(name):
    if not ARCHIVE_PATTERN.fullmatch(name):
        raise ValueError("备份文件名无效")
    return name


def members_for(name):
    require_archive(name)
    manifest = name.removesuffix(".tar.gz.age") + ".manifest.json.age"
    return [name, name + ".sha256", manifest, manifest + ".sha256", name + ".sha256.sig", manifest + ".sha256.sig"]


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


def prune_local(directory, retention_days, now=None, *, replica=None, pending=None):
    if not isinstance(retention_days, int) or retention_days < 1:
        raise ValueError("本地备份保留天数必须为正整数")
    directory = Path(directory).resolve(strict=True)
    cutoff = (time.time() if now is None else now) - retention_days * 86400
    removed = []
    for row in local_sets(directory):
        name = row["name"]
        if name.startswith("pre-restore-") or queued(pending, name):
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
        try:
            verify_local(archive)
            if any(path.name.startswith(name.removesuffix(".tar.gz.age") + ".manifest") for path in group):
                verify_member(directory / members[2])
            if replica is None or not all(replica(path) for path in group):
                raise ValueError("副本缺失或内容不同")
        except (OSError, ValueError, http.client.HTTPException):
            print(f"保留本地备份 {name}：无法确认有完整副本。", file=sys.stderr)
            continue
        for path in group:
            path.unlink()
        removed.append(name)
    return removed


def queued(pending, name):
    return pending is not None and any((pending / target / name).exists() for target in ("github", "webdav"))


def git_replica(repo, commit, path):
    marker = commit + ":" + path.name + ".keep"
    if subprocess.run(["git", "-C", str(repo), "cat-file", "-e", marker], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        return False
    with subprocess.Popen(["git", "-C", str(repo), "cat-file", "blob", commit + ":" + path.name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        digest = hashlib.sha256()
        while chunk := process.stdout.read(CHUNK_SIZE):
            digest.update(chunk)
        return process.wait() == 0 and digest.hexdigest() == file_digest(path)


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


def verify_member(path):
    path = Path(path)
    if not MEMBER_PATTERN.fullmatch(path.name) or not path.name.endswith(".manifest.json.age"):
        raise ValueError("部署清单文件名无效")
    if not regular_file(path) or path.stat().st_size > MANIFEST_LIMIT:
        raise ValueError("部署清单不是普通文件或超过大小限制")
    checksum = Path(str(path) + ".sha256")
    if not regular_file(checksum) or checksum.stat().st_size > 4096:
        raise ValueError("配套 SHA256 文件缺失或无效")
    expected = checksum_value(checksum.read_bytes(), path.name)
    if file_digest(path) != expected:
        raise ValueError("文件 SHA256 不匹配")
    return expected


def trusted_file(path, *, private=False):
    if not regular_file(path):
        return False
    if os.name != "posix":
        return True
    metadata = path.stat()
    parent = path.parent
    for directory in (parent, *parent.parents):
        if directory.is_symlink() or directory.stat().st_uid != 0 or directory.stat().st_mode & 0o022:
            return False
    return metadata.st_uid == 0 and not metadata.st_mode & 0o022 and (not private or stat.S_IMODE(metadata.st_mode) == 0o600)


def initialize_signing(directory):
    directory = Path(directory)
    directory.mkdir(mode=0o700, exist_ok=True)
    key = directory / "backup"
    signers = directory / "allowed_signers"
    public_key = key.with_suffix(".pub")
    if any(os.path.lexists(path) for path in (key, public_key, signers)):
        raise ValueError("签名目录已有密钥或信任配置，请保留原配置")
    if directory.is_symlink() or (os.name == "posix" and (directory.stat().st_uid != 0 or directory.stat().st_mode & 0o022)):
        raise ValueError("签名目录权限不安全")
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "vbm-backup", "-f", str(key)], check=True)
    with signers.open("x", encoding="ascii") as stream:
        stream.write("vbm-backup " + public_key.read_text(encoding="ascii"))


def check_signing_key(directory, deploy_key=None):
    directory = Path(directory)
    key = directory / "backup"
    if not trusted_file(key, private=True) or not trusted_file(directory / "allowed_signers"):
        raise ValueError("签名密钥或可信签名者文件缺失或权限不安全，请在菜单 [03] 初始化")
    if deploy_key and Path(deploy_key).is_file():
        public_keys = [
            subprocess.check_output(["ssh-keygen", "-y", "-P", "", "-f", str(path)], stderr=subprocess.DEVNULL, timeout=10).split()[:2]
            for path in (key, deploy_key)
        ]
        if public_keys[0] == public_keys[1]:
            raise ValueError("备份签名密钥必须独立于 GitHub Deploy Key")
    return key


def sign_backup(path, directory):
    key = check_signing_key(directory)
    checksum = Path(str(path) + ".sha256")
    if os.path.lexists(str(checksum) + ".sig"):
        raise ValueError("签名文件已存在")
    subprocess.run(["ssh-keygen", "-Y", "sign", "-f", str(key), "-n", "vbm-backup", str(checksum)], check=True, stderr=subprocess.DEVNULL, timeout=10)
    verify_signature(path, directory)


def verify_signature(path, directory):
    checksum = Path(str(path) + ".sha256")
    signature = Path(str(checksum) + ".sig")
    if not os.path.lexists(signature):
        raise MissingSignature("备份没有签名")
    signers = Path(directory) / "allowed_signers"
    if not trusted_file(signers) or not regular_file(signature) or signature.stat().st_size > 4096:
        raise ValueError("签名或可信签名者文件缺失或无效")
    if not regular_file(checksum) or checksum.stat().st_size > 4096:
        raise ValueError("签名对应的 SHA256 文件无效")
    checksum_bytes = checksum.read_bytes()
    expected = checksum_value(checksum_bytes, path.name)
    result = subprocess.run(
        ["ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", "vbm-backup", "-n", "vbm-backup", "-s", str(signature)],
        input=checksum_bytes, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
    )
    if result.returncode != 0 or not regular_file(path) or file_digest(path) != expected:
        raise ValueError("备份签名或内容验证失败")


def parse_webdav_xml(content):
    xml_text = content.decode("utf-8-sig")
    if "<!DOCTYPE" in xml_text.upper() or "<!ENTITY" in xml_text.upper():
        raise ValueError("WebDAV XML 包含不受支持的声明")
    return ET.fromstring(xml_text)


class WebDAV:
    def __init__(self, config):
        if not isinstance(config, dict) or any(not isinstance(config.get(field, ""), str) for field in ("url", "username", "secret")):
            raise ValueError("WebDAV 配置字段格式无效")
        parsed = urllib.parse.urlsplit(config["url"])
        if parsed.scheme not in ("https", "http") or not parsed.hostname or "@" in parsed.netloc or parsed.query or parsed.fragment or not parsed.netloc.isprintable():
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

    def backup_url(self):
        return urllib.parse.urlunsplit((self.parsed.scheme, self.parsed.netloc, self.path, "", ""))

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
                if create_error.status == 409:
                    raise ValueError("WebDAV 上级目录不存在：请先在 WebDAV 服务端创建所填写的目录，工具只会在其下自动创建 vbm 子目录") from create_error
                if create_error.status not in (405, 409):
                    raise
            content = self.small_request("PROPFIND", body=body, headers=headers)
        root = parse_webdav_xml(content)
        collection = any(
            resource is not None and resource.find("{DAV:}collection") is not None
            for resource in root.findall(".//{DAV:}resourcetype")
        )
        if root.tag != "{DAV:}multistatus" or not collection:
            raise ValueError("WebDAV vbm 目录不存在或不是集合")

    def list_members(self):
        return set(self.directory_members())

    def directory_members(self, *, temporary=False):
        body = b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getlastmodified/></d:prop></d:propfind>'
        content = self.small_request("PROPFIND", body=body, headers={"Depth": "1", "Content-Type": "application/xml"}, limit=8 * 1024 * 1024)
        root = parse_webdav_xml(content)
        if root.tag != "{DAV:}multistatus":
            raise ValueError("WebDAV 未返回 multistatus 列表")
        names = {}
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
            if temporary:
                basename, separator, suffix = name.rpartition(".upload-")
                if not separator or not MEMBER_PATTERN.fullmatch(basename) or not re.fullmatch(r"[a-f0-9]{32}", suffix):
                    continue
            elif not MEMBER_PATTERN.fullmatch(name):
                continue
            for propstat in entry.findall("{DAV:}propstat"):
                status_text = propstat.findtext("{DAV:}status", "")
                resource = propstat.find("{DAV:}prop/{DAV:}resourcetype")
                if " 200 " in status_text and resource is not None and len(resource) == 0:
                    names[name] = propstat.findtext("{DAV:}prop/{DAV:}getlastmodified")
        return names

    def cleanup_uploads(self):
        try:
            for name, modified in self.directory_members(temporary=True).items():
                if not modified:
                    continue
                try:
                    last_modified = parsedate_to_datetime(modified)
                except (ValueError, TypeError, OverflowError):
                    continue
                if last_modified.tzinfo is not None and time.time() - last_modified.timestamp() > 7 * 86400:
                    self.small_request("DELETE", name)
        except (OSError, ValueError, ET.ParseError, http.client.HTTPException):
            print("WebDAV 临时对象清理未完成，下次上传会重试。", file=sys.stderr)

    def list_archives(self, *, manifests=False):
        names = self.list_members()
        suffix = ".manifest.json.age" if manifests else ".tar.gz.age"
        matches = (name for name in names if name.endswith(suffix) and name + ".sha256" in names)
        return sorted(matches, key=lambda name: re.search(r"\d{8}-\d{6}", name)[0], reverse=True)

    def prune(self, local_directory, days, minimum, pending=None):
        if days == 0:
            return
        if days < 0 or minimum < 1:
            raise ValueError("WebDAV 保留配置无效")
        names = self.list_members()
        archives = sorted(
            (name for name in names if name.startswith("vw-") and ARCHIVE_PATTERN.fullmatch(name) and name + ".sha256" in names),
            reverse=True,
        )
        cutoff = time.time() - days * 86400
        for name in archives[minimum:]:
            members = members_for(name)
            if queued(pending, name) or any(member + ".keep" in names for member in members):
                continue
            stamp = re.search(r"\d{8}-\d{6}", name)[0]
            if datetime.strptime(stamp, "%Y%m%d-%H%M%S").replace(tzinfo=timezone.utc).timestamp() >= cutoff - 86400:
                continue
            remote_members = [member for member in members if member in names]
            try:
                if not all(regular_file(local_directory / member) and file_digest(local_directory / member) == self.remote_digest(member) for member in remote_members):
                    continue
                self.delete_remote(name)
                print(f"WebDAV 已清理：{name}")
            except (OSError, ValueError, http.client.HTTPException):
                print(f"WebDAV 清理失败，保留本地副本：{name}", file=sys.stderr)

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
        self.ensure_directory()
        self.cleanup_uploads()
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
            signature_name = checksum + ".sig"
            files = (encrypted, checksum, signature_name) if os.path.lexists(archive.parent / signature_name) else (encrypted, checksum)
            for name in files:
                path = archive.parent / name
                if not regular_file(path):
                    raise ValueError("备份组包含非普通文件")
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

    def delete_remote(self, name):
        require_archive(name)
        names = self.list_members()
        if any(member + ".keep" in names for member in members_for(name)):
            raise ValueError("该 WebDAV 备份组受 .keep 保护")
        for member in members_for(name):
            try:
                connection, response = self.request("DELETE", member)
                connection.close()
                if response.status not in (200, 204):
                    raise WebDAVStatusError("DELETE", response.status)
            except WebDAVStatusError as error:
                if error.status != 404:
                    raise

    def get_signature(self, name):
        try:
            return self.small_request("GET", name + ".sha256.sig")
        except WebDAVStatusError as error:
            if error.status != 404:
                raise
            return None

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
            if expected_length is not None and downloaded != expected_length:
                raise ValueError("WebDAV 下载长度与 Content-Length 不符")
            if digest.hexdigest() != expected:
                raise ValueError("WebDAV 下载 SHA256 不匹配")
            checksum_path = directory / (name + ".sha256")
            with checksum_path.open("xb") as output:
                os.chmod(checksum_path, 0o600)
                output.write(checksum)
            signature = self.get_signature(name)
            if signature is not None:
                (directory / (name + ".sha256.sig")).write_bytes(signature)
            verify_local(target)
        except BaseException:
            target.unlink(missing_ok=True)
            (directory / (name + ".sha256")).unlink(missing_ok=True)
            (directory / (name + ".sha256.sig")).unlink(missing_ok=True)
            raise
        finally:
            connection.close()
        return target

    def download_manifest(self, archive_name, directory):
        require_archive(archive_name)
        directory = Path(directory)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        manifest = archive_name.removesuffix(".tar.gz.age") + ".manifest.json.age"
        checksum = manifest + ".sha256"
        content = self.small_request("GET", checksum)
        expected = checksum_value(content, manifest)
        target = directory / manifest
        checksum_path = directory / checksum
        payload = self.small_request("GET", manifest, limit=MANIFEST_LIMIT)
        if hashlib.sha256(payload).hexdigest() != expected:
            raise ValueError("部署清单 SHA256 不匹配")
        created = []
        signature = self.get_signature(manifest)
        files = [(target, payload), (checksum_path, content)]
        if signature is not None:
            files.append((directory / (manifest + ".sha256.sig"), signature))
        try:
            for path, data in files:
                with path.open("xb") as output:
                    created.append(path)
                    os.chmod(path, 0o600)
                    output.write(data)
        except BaseException:
            for path in created:
                path.unlink(missing_ok=True)
            raise
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
    parser.add_argument("--signing-dir", default=SIGNING_DIRECTORY, type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("local-list")
    listing.add_argument("directory")
    listing.add_argument("--archives", action="store_true")
    listing.add_argument("--manifests", action="store_true")
    deletion = commands.add_parser("local-delete")
    deletion.add_argument("directory")
    deletion.add_argument("name")
    deletion.add_argument("--data-dir", required=True)
    deletion.add_argument("--repo-dir", required=True)
    prune = commands.add_parser("prune-local")
    prune.add_argument("directory")
    prune.add_argument("retention_days", type=int)
    replica = prune.add_mutually_exclusive_group()
    replica.add_argument("--replica", type=Path)
    replica.add_argument("--replica-git", nargs=2, metavar=("REPOSITORY", "VERIFIED_COMMIT"))
    replica.add_argument("--webdav", action="store_true")
    prune.add_argument("--pending", type=Path)
    remote_prune = commands.add_parser("prune-webdav")
    remote_prune.add_argument("directory", type=Path)
    remote_prune.add_argument("days", type=int)
    remote_prune.add_argument("minimum", type=int)
    remote_prune.add_argument("--pending", type=Path)
    commands.add_parser("init-signing")
    commands.add_parser("check-signing").add_argument("--deploy-key")
    commands.add_parser("sign").add_argument("path", type=Path)
    commands.add_parser("verify-signature").add_argument("path", type=Path)
    verify = commands.add_parser("verify")
    verify.add_argument("archive")
    member_verify = commands.add_parser("verify-member")
    member_verify.add_argument("member")
    commands.add_parser("configure")
    commands.add_parser("location")
    commands.add_parser("list").add_argument("--manifests", action="store_true")
    upload = commands.add_parser("upload")
    upload.add_argument("archive")
    remote_delete = commands.add_parser("remote-delete")
    remote_delete.add_argument("name")
    download = commands.add_parser("download")
    download.add_argument("name")
    download.add_argument("directory")
    download.add_argument("--min-free-mb", type=int, default=0)
    manifest_download = commands.add_parser("download-manifest")
    manifest_download.add_argument("archive")
    manifest_download.add_argument("directory")
    args = parser.parse_args()
    if args.command == "local-list":
        for row in local_sets(args.directory):
            if args.manifests:
                manifest = Path(args.directory) / members_for(row["name"])[2]
                if regular_file(manifest) and regular_file(Path(str(manifest) + ".sha256")):
                    print(manifest.name)
                continue
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
        replica_check = None
        if args.replica:
            replica_check = lambda path: regular_file(args.replica / path.name) and file_digest(path) == file_digest(args.replica / path.name)
        elif args.replica_git:
            repo, commit = args.replica_git
            if not re.fullmatch(r"[a-f0-9]{40,64}", commit):
                raise ValueError("Git 副本必须指定已核验的提交")
            replica_check = lambda path: git_replica(repo, commit, path)
        elif args.webdav:
            remote = WebDAV(load_webdav_config(args.config))
            remote_names = remote.list_members()
            replica_check = lambda path: path.name in remote_names and path.name + ".keep" not in remote_names and remote.remote_digest(path.name) == file_digest(path)
        removed = prune_local(args.directory, args.retention_days, replica=replica_check, pending=args.pending)
        print(f"已按保留期限清理 {len(removed)} 组本地常规备份")
    elif args.command == "init-signing":
        initialize_signing(args.signing_dir)
    elif args.command == "check-signing":
        check_signing_key(args.signing_dir, args.deploy_key)
    elif args.command == "sign":
        sign_backup(args.path, args.signing_dir)
    elif args.command == "verify-signature":
        verify_signature(args.path, args.signing_dir)
    elif args.command == "verify":
        verify_local(Path(args.archive))
    elif args.command == "verify-member":
        verify_member(Path(args.member))
    elif args.command == "configure":
        configure_webdav(args.config)
        print("WebDAV 目录读取测试通过，配置已保存")
    else:
        client = WebDAV(load_webdav_config(args.config))
        if args.command == "location":
            print(client.backup_url())
        elif args.command == "list":
            for name in client.list_archives(manifests=args.manifests):
                print(name)
        elif args.command == "upload":
            client.upload(Path(args.archive))
            print("WebDAV 上传与远端回读 SHA256 核验通过")
        elif args.command == "remote-delete":
            client.delete_remote(args.name)
            print("WebDAV 备份组已删除")
        elif args.command == "prune-webdav":
            client.prune(args.directory, args.days, args.minimum, args.pending)
        elif args.command == "download":
            print(client.download(args.name, args.directory, args.min_free_mb))
        elif args.command == "download-manifest":
            print(client.download_manifest(args.archive, args.directory))


if __name__ == "__main__":
    try:
        main()
    except MissingSignature as error:
        print(f"[警告] {error}", file=sys.stderr)
        sys.exit(3)
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, http.client.HTTPException, subprocess.SubprocessError) as error:
        if isinstance(error, ValueError):
            detail = str(error)
        else:
            detail = type(error).__name__
        print(f"[错误] {detail}", file=sys.stderr)
        sys.exit(1)
