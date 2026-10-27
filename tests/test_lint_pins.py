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


if __name__ == "__main__":
    unittest.main()
