#!/usr/bin/env python3
import base64
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
import xml.etree.ElementTree as ET
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("vw_storage", ROOT / "scripts/vw-storage.py")
storage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(storage)
NAME = "vw-20261122-131632.tar.gz.age"
ROLLBACK = "pre-restore-20261122-131927-1244301.tar.gz.age"
PAYLOAD = b"age-encryption.org/v1\n" + b"encrypted test bytes\x00" * 100


def make_pair(directory, name=NAME, content=PAYLOAD):
    archive = directory / name
    archive.write_bytes(content)
    (directory / (name + ".sha256")).write_text(
        hashlib.sha256(content).hexdigest() + "  " + name + "\n", encoding="ascii"
    )
    return archive


class DAVHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def authorized(self):
        if self.headers.get("Authorization") != self.server.authorization:
            self.send_error(401)
            return False
        return True

    def send_content(self, status, content=b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        if content:
            self.wfile.write(content)

    def do_PROPFIND(self):
        self.server.requests.append(("PROPFIND", self.path))
        if not self.authorized():
            return
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if urllib.parse.unquote(self.path) != self.server.base:
            self.send_error(400)
            return
        root = ET.Element("{DAV:}multistatus")
        if self.headers.get("Depth") == "0":
            response = ET.SubElement(root, "{DAV:}response")
            ET.SubElement(response, "{DAV:}href").text = urllib.parse.quote(self.server.base)
            propstat = ET.SubElement(response, "{DAV:}propstat")
            ET.SubElement(propstat, "{DAV:}status").text = "HTTP/1.1 200 OK"
            prop = ET.SubElement(propstat, "{DAV:}prop")
            resource = ET.SubElement(prop, "{DAV:}resourcetype")
            ET.SubElement(resource, "{DAV:}collection")
            self.send_content(207, ET.tostring(root))
            return
        if self.headers.get("Depth") != "1":
            self.send_error(400)
            return
        for name in self.server.files:
            response = ET.SubElement(root, "{DAV:}response")
            ET.SubElement(response, "{DAV:}href").text = urllib.parse.quote(self.server.base + name)
            propstat = ET.SubElement(response, "{DAV:}propstat")
            ET.SubElement(propstat, "{DAV:}status").text = "HTTP/1.1 200 OK"
            prop = ET.SubElement(propstat, "{DAV:}prop")
            ET.SubElement(prop, "{DAV:}resourcetype")
        for href in ("https://evil.invalid/" + NAME, self.server.base + "../" + NAME, self.server.base + "nested/" + NAME):
            response = ET.SubElement(root, "{DAV:}response")
            ET.SubElement(response, "{DAV:}href").text = href
        self.send_content(207, ET.tostring(root))

    def do_GET(self):
        self.server.requests.append(("GET", self.path))
        if not self.authorized():
            return
        name = urllib.parse.unquote(self.path).removeprefix(self.server.base)
        if self.server.redirect:
            self.send_response(302)
            self.send_header("Location", "https://evil.invalid/secret")
            self.end_headers()
            return
        if name not in self.server.files:
            self.send_error(404)
            return
        self.send_content(200, self.server.files[name])

    def do_PUT(self):
        self.server.requests.append(("PUT", self.path))
        if not self.authorized():
            return
        content = self.rfile.read(int(self.headers["Content-Length"]))
        if self.server.readonly:
            self.send_error(403)
            return
        name = urllib.parse.unquote(self.path).removeprefix(self.server.base)
        if self.headers.get("If-None-Match") != "*" or name in self.server.files:
            self.send_error(412)
            return
        self.server.files[name] = b"corrupted" if self.server.corrupt else content
        self.send_content(201)

    def do_MOVE(self):
        self.server.requests.append(("MOVE", self.path))
        if not self.authorized():
            return
        source = urllib.parse.unquote(self.path).removeprefix(self.server.base)
        destination = urllib.parse.unquote(urllib.parse.urlsplit(self.headers["Destination"]).path).removeprefix(self.server.base)
        if self.headers.get("Overwrite") != "F" or destination in self.server.files:
            self.send_error(412)
            return
        self.server.files[destination] = self.server.files.pop(source)
        self.send_content(201)

    def do_DELETE(self):
        if not self.authorized():
            return
        name = urllib.parse.unquote(self.path).removeprefix(self.server.base)
        self.server.files.pop(name, None)
        self.send_content(204)


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.archive = make_pair(self.directory)

    def tearDown(self):
        self.temporary.cleanup()

    def test_inventory_groups_manifest_and_rollback(self):
        manifest = NAME.removesuffix(".tar.gz.age") + ".manifest.json.age"
        (self.directory / manifest).write_bytes(b"manifest")
        (self.directory / (manifest + ".sha256")).write_text("checksum", encoding="ascii")
        make_pair(self.directory, ROLLBACK)
        (self.directory / "unrelated.txt").write_text("keep", encoding="ascii")
        rows = {row["name"]: row for row in storage.local_sets(self.directory)}
        self.assertEqual(rows[NAME]["files"], 4)
        self.assertEqual(rows[ROLLBACK]["kind"], "恢复前快照")
        self.assertEqual(storage.delete_local(self.directory, NAME, self.directory / "../data", self.directory / "../repo"), 4)
        self.assertTrue((self.directory / ROLLBACK).exists())
        self.assertTrue((self.directory / "unrelated.txt").exists())

    def test_delete_honors_keep_and_rejects_overlaps_and_names(self):
        marker = self.directory / (NAME + ".keep")
        marker.touch()
        with self.assertRaisesRegex(ValueError, "保护"):
            storage.delete_local(self.directory, NAME, "", "")
        marker.unlink()
        for data_dir in (self.directory, self.directory / "nested", self.directory.parent):
            with self.assertRaisesRegex(ValueError, "重叠"):
                storage.delete_local(self.directory, NAME, data_dir, "")
        with self.assertRaises(ValueError):
            storage.delete_local(self.directory, "../" + NAME, "", "")
        self.assertTrue(self.archive.exists())

    def test_missing_archive_still_exposes_orphan_files(self):
        self.archive.unlink()
        rows = storage.local_sets(self.directory)
        self.assertEqual(len(rows), 1)
        self.assertFalse(rows[0]["ready"])
        self.assertEqual(storage.delete_local(self.directory, NAME, "", ""), 1)

    def test_local_retention_prunes_only_expired_unprotected_regular_backups(self):
        old_name = "vw-20261120-010000.tar.gz.age"
        old_archive = make_pair(self.directory, old_name)
        os.utime(old_archive, (100, 100))
        os.utime(Path(str(old_archive) + ".sha256"), (100, 100))
        kept_name = "vw-20261120-020000.tar.gz.age"
        kept_archive = make_pair(self.directory, kept_name)
        os.utime(kept_archive, (100, 100))
        os.utime(Path(str(kept_archive) + ".sha256"), (100, 100))
        (self.directory / (kept_name + ".keep")).touch()
        rollback_name = "pre-restore-20261120-030000.tar.gz.age"
        rollback_archive = make_pair(self.directory, rollback_name)
        os.utime(rollback_archive, (100, 100))
        os.utime(Path(str(rollback_archive) + ".sha256"), (100, 100))
        self.assertEqual(storage.prune_local(self.directory, 30, now=100 + 31 * 86400), [])
        self.assertTrue(old_archive.exists())
        pending = self.directory / "pending"
        (pending / "webdav").mkdir(parents=True)
        marker = pending / "webdav" / old_name
        marker.touch()
        self.assertEqual(storage.prune_local(self.directory, 30, now=100 + 31 * 86400, replica=lambda path: path.is_file(), pending=pending), [])
        marker.unlink()
        removed = storage.prune_local(self.directory, 30, now=100 + 31 * 86400, replica=lambda path: path.is_file())
        self.assertEqual(removed, [old_name])
        self.assertFalse(old_archive.exists())
        self.assertTrue(kept_archive.exists())
        self.assertTrue(rollback_archive.exists())

    def test_local_retention_is_skipped_when_remote_upload_fails(self):
        self.assertTrue(self.archive.exists())
        self.assertEqual(storage.prune_local(self.directory, 30, now=100), [])

    def test_signature_rejects_forged_content_and_unknown_signer(self):
        trust = self.directory / "first-signer"
        untrusted = self.directory / "second-signer"
        for directory in (trust, untrusted):
            directory.mkdir(mode=0o700)
            key = directory / "backup"
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                check=True,
            )
            public_key = key.with_suffix(".pub").read_text(encoding="ascii")
            (directory / "allowed_signers").write_text(
                f"vbm-backup {public_key}", encoding="ascii", newline="\n"
            )
        with patch.object(storage, "trusted_file", side_effect=lambda path, **kwargs: path.is_file()):
            with self.assertRaises(storage.MissingSignature):
                storage.verify_signature(self.archive, trust)
            storage.sign_backup(self.archive, trust)
            storage.verify_signature(self.archive, trust)
            with self.assertRaisesRegex(ValueError, "验证失败"):
                storage.verify_signature(self.archive, untrusted)
            signature = Path(str(self.archive) + ".sha256.sig")
            original_signature = signature.read_bytes()
            signature.write_bytes(b"invalid signature")
            with self.assertRaisesRegex(ValueError, "验证失败"):
                storage.verify_signature(self.archive, trust)
            signature.write_bytes(original_signature)
            make_pair(self.directory, NAME, PAYLOAD + b"changed")
            storage.verify_local(self.archive)
            with self.assertRaisesRegex(ValueError, "验证失败"):
                storage.verify_signature(self.archive, trust)

    def test_checksum_must_bind_selected_archive(self):
        storage.verify_local(self.archive)
        checksum = self.directory / (NAME + ".sha256")
        checksum.write_text(hashlib.sha256(PAYLOAD).hexdigest() + "  ../other\n", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "原始文件名"):
            storage.verify_local(self.archive)
        make_pair(self.directory)
        self.archive.write_bytes(PAYLOAD + b"tampered")
        with self.assertRaisesRegex(ValueError, "不匹配"):
            storage.verify_local(self.archive)

    def test_delete_refuses_hardlinks(self):
        external = self.directory.parent / (self.directory.name + "-linked")
        try:
            os.link(self.archive, external)
            with self.assertRaisesRegex(ValueError, "普通文件"):
                storage.delete_local(self.directory, NAME, "", "")
            self.assertTrue(external.exists())
        finally:
            external.unlink(missing_ok=True)

    def test_delete_refuses_symlinks(self):
        checksum = self.directory / (NAME + ".sha256")
        original = self.directory / "original-checksum"
        checksum.rename(original)
        try:
            checksum.symlink_to(original)
        except OSError:
            self.skipTest("OS does not permit creating symlinks")
        with self.assertRaises(ValueError):
            storage.delete_local(self.directory, NAME, "", "")
        self.assertTrue(original.exists())


class WebDAVTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.archive = make_pair(self.directory)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DAVHandler)
        self.server.files = {}
        self.server.requests = []
        self.server.base = "/备份 files/vbm/"
        self.server.authorization = "Basic " + base64.b64encode("user:secret-value".encode()).decode()
        self.server.corrupt = False
        self.server.readonly = False
        self.server.redirect = False
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.config = {"url": f"http://127.0.0.1:{self.server.server_port}/%E5%A4%87%E4%BB%BD%20files/", "username": "user", "secret": "secret-value"}
        self.client = storage.WebDAV(self.config)
        self.client.path = urllib.parse.quote(self.server.base, safe="/")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def test_upload_list_download_and_idempotent_retry(self):
        self.assertTrue(self.client.path.endswith("/vbm/"))
        self.client.ensure_directory()
        manifest = NAME.removesuffix(".tar.gz.age") + ".manifest.json.age"
        make_pair(self.directory, manifest)
        self.client.upload(self.archive)
        self.assertEqual(self.client.list_archives(), [NAME])
        self.assertEqual(len(self.server.files), 4)
        requests_before = len([method for method, path in self.server.requests if method == "PUT"])
        self.client.upload(self.archive)
        self.assertEqual(len([method for method, path in self.server.requests if method == "PUT"]), requests_before)
        destination = self.directory / "download"
        result = self.client.download(NAME, destination)
        self.assertEqual(result.read_bytes(), PAYLOAD)
        storage.verify_local(result)
        publication = [urllib.parse.unquote(path) for method, path in self.server.requests if method == "MOVE"]
        self.assertTrue(publication[-1].startswith(self.server.base + NAME + ".sha256.upload-"))

    def test_upload_from_cli_and_private_configuration(self):
        config_path = self.directory / "webdav.json"
        config_path.write_text(json.dumps(self.config), encoding="utf-8")
        config_path.chmod(0o600)
        self.directory.chmod(0o700)
        if os.name == "posix" and os.geteuid() != 0:
            self.skipTest("Production CLI requires root-owned config")
        location = subprocess.check_output([sys.executable, "-B", str(ROOT / "scripts/vw-storage.py"), "--config", str(config_path), "location"], text=True, encoding="utf-8")
        self.assertEqual(location.strip(), self.config["url"] + "vbm/")
        self.assertEqual(self.server.requests, [])
        output = subprocess.check_output([sys.executable, "-B", str(ROOT / "scripts/vw-storage.py"), "--config", str(config_path), "upload", str(self.archive)], text=True, encoding="utf-8")
        self.assertIn("SHA256", output)
        self.assertNotIn("secret-value", output)

    def test_wrong_auth_and_readonly_fail(self):
        bad = storage.WebDAV(dict(self.config, secret="wrong"))
        with self.assertRaisesRegex(ValueError, "401"):
            bad.list_archives()
        self.server.readonly = True
        with self.assertRaisesRegex(ValueError, "403"):
            self.client.upload(self.archive)
        self.assertTrue(self.archive.exists())
        self.assertEqual(self.server.files, {})

    def test_corrupt_upload_is_unpublished_and_retry_succeeds(self):
        self.server.corrupt = True
        with self.assertRaisesRegex(ValueError, "不匹配"):
            self.client.upload(self.archive)
        self.assertEqual(self.client.list_archives(), [])
        self.assertEqual(self.server.files, {})
        self.server.corrupt = False
        self.client.upload(self.archive)
        self.assertEqual(self.client.list_archives(), [NAME])

    def test_manifest_can_be_listed_and_downloaded_without_archive(self):
        manifest, checksum = storage.members_for(NAME)[2:4]
        payload = b"encrypted manifest" * 400
        make_pair(self.directory, manifest, payload)
        for name in (manifest, checksum):
            self.server.files[name] = (self.directory / name).read_bytes()
        self.assertEqual(self.client.list_archives(manifests=True), [manifest])
        self.assertEqual(self.client.list_archives(), [])
        destination = self.directory / "download"
        result = self.client.download_manifest(NAME, destination)
        self.assertEqual(result.read_bytes(), payload)
        storage.verify_member(result)
        with self.assertRaises(FileExistsError):
            self.client.download_manifest(NAME, destination)
        self.assertEqual(result.read_bytes(), payload)
        self.server.files[manifest] = b"broken"
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.client.download_manifest(NAME, self.directory / "corrupt")

    def test_history_delete_removes_only_selected_group(self):
        for name in (*storage.members_for(NAME), *storage.members_for(ROLLBACK)):
            self.server.files[name] = b"payload"
        self.client.delete_remote(NAME)
        self.assertEqual(set(self.server.files), set(storage.members_for(ROLLBACK)))

    def test_signed_sidecars_roundtrip(self):
        signature_name = NAME + ".sha256.sig"
        (self.directory / signature_name).write_bytes(b"signature-fixture")
        self.client.upload(self.archive)
        restored = self.directory / "restore"
        self.client.download(NAME, restored)
        self.assertEqual((restored / signature_name).read_bytes(), b"signature-fixture")
        self.server.files[NAME + ".keep"] = b"keep"
        with self.assertRaisesRegex(ValueError, "保护"):
            self.client.delete_remote(NAME)

    def test_conflicting_remote_file_is_preserved(self):
        self.server.files[NAME] = b"existing different data"
        with self.assertRaisesRegex(ValueError, "同名"):
            self.client.upload(self.archive)
        self.assertEqual(self.server.files[NAME], b"existing different data")
        self.assertNotIn(NAME + ".sha256", self.server.files)

    def test_download_checksum_mismatch_removes_partial(self):
        self.client.upload(self.archive)
        self.server.files[NAME] += b"corruption"
        destination = self.directory / "download"
        with self.assertRaisesRegex(ValueError, "不匹配"):
            self.client.download(NAME, destination)
        self.assertEqual(list(destination.iterdir()), [])

    def test_download_rejects_malicious_checksum_and_existing_directory(self):
        self.client.upload(self.archive)
        with self.assertRaisesRegex(ValueError, "为空"):
            self.client.download(NAME, self.directory)
        self.server.files[NAME + ".sha256"] = hashlib.sha256(PAYLOAD).hexdigest().encode() + b"  ../evil\n"
        with self.assertRaisesRegex(ValueError, "原始文件名"):
            self.client.download(NAME, self.directory / "download")

    def test_redirects_and_insecure_remote_urls_are_rejected(self):
        self.server.redirect = True
        with self.assertRaisesRegex(ValueError, "302"):
            self.client.remote_digest(NAME)
        for url in ("http://example.com/backups/", "https://user@example.com/", "https://example.com/../root", "https://example.com/?token=hidden"):
            with self.assertRaises(ValueError):
                storage.WebDAV(dict(self.config, url=url))

    def test_existing_vbm_url_is_not_nested_again(self):
        client = storage.WebDAV(dict(self.config, url=self.config["url"] + "vbm/"))
        self.assertEqual(client.backup_url(), self.config["url"] + "vbm/")

    def test_rollback_archive_roundtrip(self):
        archive = make_pair(self.directory, ROLLBACK)
        self.client.upload(archive)
        self.assertEqual(self.client.list_archives(), [ROLLBACK])
        self.client.download(ROLLBACK, self.directory / "download")


if __name__ == "__main__":
    unittest.main()
