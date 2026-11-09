"""Tests for the pin checks in tools/lint-skills.py (check_pins)."""
import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "lint-skills.py"
H = "a" * 64


def load_lint():
    spec = importlib.util.spec_from_file_location("lint_skills", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CheckPins(unittest.TestCase):
    def check(self, name, text):
        lint = load_lint()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "pins").mkdir()
        (root / "pins" / name).write_bytes(text.encode())
        lint.ROOT = root
        lint.errors.clear()
        lint.check_pins()
        return lint.errors

    def memsync(self, **over):
        keys = {"URL": "https://example.test/o/r/releases/download", "TAG": "v0.1.0"}
        keys.update({f"SHA256_{t}": H for t in ("linux_amd64", "linux_arm64", "darwin_amd64", "darwin_arm64")})
        keys.update(over)
        return "".join(f"MEMSYNC_{k}={v}\n" for k, v in keys.items() if v is not None)

    def test_complete_pin_passes(self):
        self.assertEqual(self.check("memsync.env", self.memsync()), [])

    def test_a_pre_release_tag_passes(self):
        self.assertEqual(self.check("memsync.env", self.memsync(TAG="v0.3.0-ev.1")), [])

    def test_a_malformed_pre_release_tag_fails(self):
        for bad in ("v0.3.0-", "v0.3.0-a/b", "v0.3.0+meta", "v0.3.0-a b", "v\u0661.2.3", "v0.3.0-\u00e9"):
            self.assertTrue(self.check("memsync.env", self.memsync(TAG=bad)), bad)

    def test_unpinned_passes(self):
        self.assertEqual(self.check("memsync.env", "MEMSYNC_URL=\nMEMSYNC_TAG=TODO\n"), [])

    def test_duplicate_key_fails(self):
        errs = self.check("memsync.env", self.memsync() + f"MEMSYNC_SHA256_linux_amd64={'b' * 64}\n")
        self.assertTrue(any("duplicate" in e for e in errs), errs)

    def test_crlf_fails(self):
        errs = self.check("memsync.env", self.memsync().replace("\n", "\r\n"))
        self.assertTrue(any("CR" in e for e in errs), errs)

    def test_memsync_missing_a_darwin_hash_fails(self):
        errs = self.check("memsync.env", self.memsync(SHA256_darwin_arm64=None))
        self.assertTrue(any("darwin_arm64" in e for e in errs), errs)

    def test_bitc_needs_all_four_targets_now(self):
        # bitc 0.1.0 ships darwin builds too, so a Linux-only pin is incomplete.
        text = ("BITC_URL=https://example.test/o/bitc/releases/download\nBITC_TAG=v0.2.0\n"
                f"BITC_SHA256_linux_amd64={H}\nBITC_SHA256_linux_arm64={H}\n")
        errs = self.check("bitc.env", text)
        self.assertTrue(any("darwin" in e for e in errs), errs)

    def test_bitc_missing_linux_arm64_fails(self):
        text = ("BITC_URL=https://example.test/o/bitc/releases/download\nBITC_TAG=v0.2.0\n"
                f"BITC_SHA256_linux_amd64={H}\n")
        errs = self.check("bitc.env", text)
        self.assertTrue(any("linux_arm64" in e for e in errs), errs)

    def test_url_without_host_fails(self):
        errs = self.check("memsync.env", self.memsync(URL="https:///x"))
        self.assertTrue(any("https URL" in e for e in errs), errs)

    def herdr(self, **over):
        keys = {"URL": "https://example.test/o/herdr/releases/download", "TAG": "v0.9.5-ev.2"}
        keys.update({f"SHA256_{t}": H for t in ("linux_amd64", "linux_arm64", "darwin_amd64", "darwin_arm64")})
        keys.update(over)
        return "".join(f"HERDR_{k}={v}\n" for k, v in keys.items() if v is not None)

    def test_a_well_formed_version_key_passes(self):
        for good in ("0.9.5", "1.2.3-ev.2", "10.20.30-rc1"):
            self.assertEqual(self.check("herdr.env", self.herdr(VERSION=good)), [], good)

    def test_a_malformed_version_key_fails(self):
        for bad in ("", "0.9", "v0.9.5", "0.9.5-", "0.9.5+meta", "0.9.5 x", "0.9.\u0661", "0.9.5-\u00e9"):
            errs = self.check("herdr.env", self.herdr(VERSION=bad))
            self.assertTrue(any("VERSION" in e and "unexpected line" not in e for e in errs), (bad, errs))

    def test_a_duplicate_version_key_fails(self):
        errs = self.check("herdr.env", self.herdr(VERSION="0.9.5") + "HERDR_VERSION=0.9.6\n")
        self.assertTrue(any("duplicate" in e for e in errs), errs)

    def test_a_version_key_in_an_unpinned_file_fails(self):
        errs = self.check("herdr.env", "HERDR_URL=\nHERDR_TAG=TODO\nHERDR_VERSION=0.9.5\n")
        self.assertTrue(any("VERSION" in e and "unexpected line" not in e for e in errs), errs)

    def test_a_blank_version_key_in_an_unpinned_file_passes(self):
        self.assertEqual(self.check("herdr.env", "HERDR_URL=\nHERDR_TAG=TODO\nHERDR_VERSION=\n"), [])

    def test_the_real_pins_tree_passes(self):
        lint = load_lint()
        lint.errors.clear()
        lint.check_pins()
        self.assertEqual(lint.errors, [])

    def test_a_key_that_is_not_one_of_the_known_suffixes_fails(self):
        # HERDR_FOO_VERSION would pass the prefix check yet never be read by install.sh.
        errs = self.check("herdr.env", self.herdr() + "HERDR_FOO_VERSION=1.2.3\n")
        self.assertTrue(any("HERDR_FOO_VERSION" in e for e in errs), errs)
        errs = self.check("herdr.env", self.herdr(VERSION="0.9.5") + "HERDR_X_VERSION=0.9.5\n")
        self.assertTrue(any("HERDR_X_VERSION" in e for e in errs), errs)

    def test_holder_pins_are_linux_only(self):
        # ntfy and tailscale are pinned for the holder image, which is a Linux image.
        for tool, prefix, url in (("ntfy", "NTFY", "https://example.test/o/ntfy/releases/download"),
                                  ("tailscale", "TAILSCALE", "https://example.test/stable")):
            text = (f"{prefix}_URL={url}\n{prefix}_TAG=v1.2.3\n"
                    f"{prefix}_SHA256_linux_amd64={H}\n{prefix}_SHA256_linux_arm64={H}\n")
            self.assertEqual(self.check(f"{tool}.env", text), [], tool)
            errs = self.check(f"{tool}.env", text.replace(f"{prefix}_SHA256_linux_arm64={H}\n", ""))
            self.assertTrue(any("linux_arm64" in e for e in errs), (tool, errs))


class CheckDockerfiles(unittest.TestCase):
    def check(self, text):
        lint = load_lint()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "holder").mkdir()
        (root / "holder" / "Dockerfile").write_bytes(text.encode())
        lint.ROOT = root
        lint.errors.clear()
        lint.check_dockerfiles()
        return lint.errors

    def test_a_base_pinned_by_digest_passes(self):
        self.assertEqual(self.check(f"FROM debian:bookworm-slim@sha256:{H} AS base\nRUN true\nFROM base\n"), [])

    def test_a_base_by_tag_only_fails(self):
        errs = self.check("FROM debian:bookworm-slim\n")
        self.assertTrue(any("digest" in e for e in errs), errs)

    def test_a_short_or_malformed_digest_fails(self):
        for bad in ("debian@sha256:abc", f"debian@sha256:{'G' * 64}", f"debian@md5:{H}"):
            self.assertTrue(self.check(f"FROM {bad}\n"), bad)

    def test_a_later_stage_by_tag_fails(self):
        errs = self.check(f"FROM debian@sha256:{H} AS a\nFROM alpine:3\n")
        self.assertTrue(errs)

    def test_from_scratch_and_a_stage_name_pass(self):
        self.assertEqual(self.check(f"FROM debian@sha256:{H} AS a\nFROM scratch\nFROM a\n"), [])


if __name__ == "__main__":
    unittest.main()
