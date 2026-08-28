from __future__ import annotations

import contextlib
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from build import main as build_main
from build.options import Options


def _opts(**kwargs) -> Options:
    return Options(**kwargs)


@contextlib.contextmanager
def _env(**values: str | None):
    # None removes the variable; everything else is set for the block.
    patched = {k: v for k, v in values.items() if v is not None}
    removed = [k for k, v in values.items() if v is None]
    with mock.patch.dict(os.environ, patched):
        for key in removed:
            _ = os.environ.pop(key, None)
        yield


class TokenFilePathTest(unittest.TestCase):
    def test_flag_beats_env_beats_default(self):
        with _env(ICEDOS_GITHUB_TOKEN_PATH="/from/env"):
            self.assertEqual(
                build_main._token_file_path(_opts(github_token_path="/from/flag")),
                Path("/from/flag"),
            )
            self.assertEqual(
                build_main._token_file_path(_opts()), Path("/from/env")
            )
        with _env(ICEDOS_GITHUB_TOKEN_PATH=None):
            self.assertEqual(
                build_main._token_file_path(_opts()),
                Path(build_main.DEFAULT_TOKEN_PATH),
            )


class ResolveTokenTest(unittest.TestCase):
    def test_literal_flag_wins_over_env_and_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "token"
            _ = path.write_text("from-file\n")
            with _env(
                ICEDOS_GITHUB_TOKEN="from-env", ICEDOS_GITHUB_TOKEN_PATH=str(path)
            ):
                self.assertEqual(
                    build_main._resolve_token(_opts(github_token="from-flag")),
                    "from-flag",
                )

    def test_env_literal_wins_over_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "token"
            _ = path.write_text("from-file\n")
            with _env(
                ICEDOS_GITHUB_TOKEN="from-env", ICEDOS_GITHUB_TOKEN_PATH=str(path)
            ):
                self.assertEqual(build_main._resolve_token(_opts()), "from-env")

    def test_falls_through_to_the_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "token"
            _ = path.write_text("from-file\n")
            with _env(ICEDOS_GITHUB_TOKEN=None, ICEDOS_GITHUB_TOKEN_PATH=str(path)):
                self.assertEqual(build_main._resolve_token(_opts()), "from-file")

    def test_blank_literals_do_not_shadow_the_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "token"
            _ = path.write_text("from-file\n")
            with _env(ICEDOS_GITHUB_TOKEN="   ", ICEDOS_GITHUB_TOKEN_PATH=str(path)):
                self.assertEqual(
                    build_main._resolve_token(_opts(github_token="  ")), "from-file"
                )


class ReadTokenFileTest(unittest.TestCase):
    def test_missing_file_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(build_main._read_token_file(Path(d) / "nope"), "")

    def test_trailing_newline_is_stripped(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "token"
            _ = path.write_text("tok\n")
            self.assertEqual(build_main._read_token_file(path), "tok")

    def test_crlf_is_stripped(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "token"
            _ = path.write_text("tok\r\n")
            self.assertEqual(build_main._read_token_file(path), "tok")

    # The sudo fallback used to return `cat` output verbatim, so a token file with
    # CRLF authenticated on the direct path and failed on the sudo one.
    def test_sudo_path_strips_like_the_direct_path(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "token"
            _ = path.write_text("unused")
            with (
                mock.patch.object(Path, "read_text", side_effect=PermissionError),
                mock.patch.object(build_main, "_sudo_read", return_value="tok\r\n"),
            ):
                self.assertEqual(build_main._read_token_file(path), "tok")

    def test_unreadable_file_warns_and_continues(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "token"
            _ = path.write_text("unused")
            stderr = io.StringIO()
            with (
                mock.patch.object(Path, "read_text", side_effect=PermissionError),
                mock.patch.object(build_main, "_sudo_read", return_value=None),
                contextlib.redirect_stderr(stderr),
            ):
                self.assertEqual(build_main._read_token_file(path), "")
            self.assertIn("cannot read", stderr.getvalue())

    # A non-UTF-8 file raises UnicodeDecodeError (a ValueError, not an OSError);
    # it must fall through to the sudo path rather than crash with a traceback.
    def test_non_utf8_file_does_not_crash(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "token"
            _ = path.write_bytes(b"\xff\xfe\x00binary")
            stderr = io.StringIO()
            with (
                mock.patch.object(build_main, "_sudo_read", return_value=None),
                contextlib.redirect_stderr(stderr),
            ):
                self.assertEqual(build_main._read_token_file(path), "")


class NixConfigTest(unittest.TestCase):
    def test_base_config_only_without_a_token(self):
        with _env(ICEDOS_GITHUB_TOKEN=None, ICEDOS_GITHUB_TOKEN_PATH="/nonexistent"):
            self.assertEqual(build_main._nix_config(_opts()), build_main.BASE_NIX_CONFIG)

    # NIX_CONFIG is nix.conf content, so the token has to land on its own line.
    def test_token_is_appended_on_its_own_line(self):
        config = build_main._nix_config(_opts(github_token="tok"))
        self.assertEqual(
            config.splitlines(),
            [build_main.BASE_NIX_CONFIG, "access-tokens = github.com=tok"],
        )


if __name__ == "__main__":
    unittest.main()
