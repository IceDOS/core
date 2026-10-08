from __future__ import annotations

import contextlib
import io
import unittest

from build import term


class _Tty(io.StringIO):
    def isatty(self) -> bool:
        return True


class TermTest(unittest.TestCase):
    def test_plain_when_stdout_is_not_a_tty(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(term.paint(term.RED, "error"), "error")
            self.assertEqual(term.clr_line(), "")

    def test_coloured_on_a_tty(self):
        with contextlib.redirect_stdout(_Tty()):
            self.assertEqual(term.paint(term.RED, "error"), "\033[1;31merror\033[0m")
            self.assertEqual(term.clr_line(), "\033[2K\r")

    def test_log_step_and_log_ok_write_stdout(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            term.log_step("generating")
            term.log_ok("done")
        self.assertEqual(out.getvalue(), "> generating\n✓ done\n")

    def test_log_warn_writes_stderr(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            term.log_warn("careful")
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(err.getvalue(), "⚠ careful\n")


if __name__ == "__main__":
    unittest.main()
