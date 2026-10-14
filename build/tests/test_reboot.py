from __future__ import annotations

import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from build.options import Options
from build.reboot import offer_reboot, reboot_reasons


class _SystemsCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.booted = self.root / "booted-system"
        self.current = self.root / "current-system"
        self.booted.mkdir()
        self.current.mkdir()

    def link(self, system: Path, component: str, content: str) -> None:
        target = self.root / f"{system.name}-{component}"
        _ = target.write_text(content)
        (system / component).symlink_to(target)


class RebootReasonsTest(_SystemsCase):
    def test_same_content_needs_no_reboot(self):
        self.link(self.booted, "kernel", "k1")
        self.link(self.current, "kernel", "k1")
        self.assertEqual(reboot_reasons(self.booted, self.current), [])

    def test_changed_components_are_reported_in_order(self):
        for component in ("initrd", "kernel"):
            self.link(self.booted, component, "old")
            self.link(self.current, component, "new")
        self.assertEqual(
            reboot_reasons(self.booted, self.current), ["kernel", "initrd"]
        )

    def test_component_missing_on_either_side_is_skipped(self):
        self.link(self.booted, "kernel", "k1")
        self.link(self.current, "initrd", "i1")
        self.assertEqual(reboot_reasons(self.booted, self.current), [])


class OfferRebootTest(_SystemsCase):
    def setUp(self):
        super().setUp()
        self.link(self.booted, "kernel", "old")
        self.link(self.current, "kernel", "new")

    def offer(
        self,
        *,
        action: str = "switch",
        answer: str | type[BaseException] = "y",
        interactive: bool = True,
        systemctl_rc: int = 0,
    ) -> tuple[str, list[list[str]], mock.MagicMock]:
        commands: list[list[str]] = []

        def fake_run(
            cmd: list[str], check: bool = False
        ) -> subprocess.CompletedProcess[str]:
            commands.append(cmd)
            return subprocess.CompletedProcess(
                cmd, systemctl_rc if cmd[0] == "systemctl" else 0
            )

        out = io.StringIO()
        with (
            mock.patch("build.reboot._interactive", return_value=interactive),
            mock.patch(
                "builtins.input",
                side_effect=[answer] if isinstance(answer, str) else answer,
            ) as ask,
            mock.patch("build.reboot.subprocess.run", side_effect=fake_run),
            contextlib.redirect_stdout(out),
        ):
            offer_reboot(
                Options(action=action), booted=self.booted, current=self.current
            )
        return out.getvalue(), commands, ask

    def test_yes_reboots(self):
        out, commands, _ = self.offer(answer="y")
        self.assertIn("warning: reboot recommended for kernel changes to apply", out)
        self.assertEqual(commands, [["systemctl", "reboot", "-i"]])

    def test_falls_back_to_sudo(self):
        _, commands, _ = self.offer(answer="yes", systemctl_rc=1)
        self.assertEqual(
            commands,
            [["systemctl", "reboot", "-i"], ["sudo", "systemctl", "reboot", "-i"]],
        )

    def test_anything_else_declines(self):
        for answer in ("", "n", "nope", EOFError, KeyboardInterrupt):
            with self.subTest(answer=answer):
                _, commands, _ = self.offer(answer=answer)
                self.assertEqual(commands, [])

    def test_without_a_tty_it_only_warns(self):
        out, commands, ask = self.offer(interactive=False)
        self.assertIn("reboot recommended", out)
        ask.assert_not_called()
        self.assertEqual(commands, [])

    def test_only_switch_is_checked(self):
        for action in ("boot", "build", "build-vm"):
            with self.subTest(action=action):
                out, commands, ask = self.offer(action=action)
                self.assertEqual((out, commands), ("", []))
                ask.assert_not_called()


if __name__ == "__main__":
    unittest.main()
