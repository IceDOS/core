from __future__ import annotations

import contextlib
import io
import unittest

from build.options import parse_args


def _parse(argv: list[str]):
    # _die writes to stderr; keep the test output readable.
    with contextlib.redirect_stderr(io.StringIO()):
        return parse_args(argv)


class ParseArgsTest(unittest.TestCase):
    def test_defaults_to_switch(self):
        opts, _ = _parse([])
        self.assertEqual(opts.action, "switch")
        self.assertFalse(opts.run_vm)

    def test_update_sets_every_update_flag(self):
        opts, _ = _parse(["--update"])
        self.assertTrue(opts.update_all)
        self.assertTrue(opts.update_core)
        self.assertTrue(opts.update_repos)
        self.assertTrue(opts.update_repos_inputs)

    def test_run_vm_implies_build_vm(self):
        opts, _ = _parse(["--run-vm"])
        self.assertEqual(opts.action, "build-vm")
        self.assertTrue(opts.run_vm)

    def test_nh_args_stop_at_build_args(self):
        opts, _ = _parse(["--nh-args", "-v", "--dry", "--build-args", "--impure"])
        self.assertEqual(opts.nh_build_args, ["-v", "--dry"])
        self.assertEqual(opts.global_build_args, ["--impure"])

    def test_nh_args_run_to_the_end_without_build_args(self):
        opts, _ = _parse(["--nh-args", "-v", "-x"])
        self.assertEqual(opts.nh_build_args, ["-v", "-x"])
        self.assertEqual(opts.global_build_args, [])

    def test_build_args_as_final_token_yields_empty(self):
        opts, _ = _parse(["--build-args"])
        self.assertEqual(opts.global_build_args, [])

    def test_previous_arguments_is_the_raw_argv(self):
        argv = ["--update", "--logs"]
        _, previous = _parse(argv)
        self.assertEqual(previous, argv)

    def test_trace_follows_logs(self):
        self.assertEqual(_parse([])[0].trace, [])
        self.assertEqual(_parse(["--logs"])[0].trace, ["--show-trace"])

    def test_repos_select_splits_on_whitespace(self):
        opts, _ = _parse(
            ["--update-repos-select", "github:icedos/apps github:icedos/gaming"]
        )
        self.assertEqual(
            opts.repos_select, ["github:icedos/apps", "github:icedos/gaming"]
        )

    def test_repos_select_rejects_a_following_flag(self):
        with self.assertRaises(SystemExit):
            _parse(["--update-repos-select", "--logs"])

    def test_repos_select_rejects_an_empty_list(self):
        with self.assertRaises(SystemExit):
            _parse(["--update-repos-select", "   "])

    def test_state_inputs_rejects_a_following_flag(self):
        with self.assertRaises(SystemExit):
            _parse(["--update-state-inputs", "--logs"])

    def test_builder_and_target_map_to_nh_flags(self):
        opts, _ = _parse(["--builder", "b.example", "--target", "t.example"])
        self.assertEqual(
            opts.nh_build_args,
            ["--build-host", "b.example", "--target-host", "t.example"],
        )

    def test_github_token_requires_a_value(self):
        with self.assertRaises(SystemExit):
            _parse(["--github-token"])

    def test_github_token_path_requires_a_value(self):
        with self.assertRaises(SystemExit):
            _parse(["--github-token-path"])

    def test_github_token_flags_are_captured(self):
        opts, _ = _parse(["--github-token", "tok", "--github-token-path", "/p"])
        self.assertEqual(opts.github_token, "tok")
        self.assertEqual(opts.github_token_path, "/p")

    def test_github_ssh_flag_is_captured(self):
        opts, _ = _parse(["--github-ssh"])
        self.assertTrue(opts.github_ssh)
        self.assertFalse(_parse([])[0].github_ssh)

    def test_unknown_arg_exits(self):
        with self.assertRaises(SystemExit):
            _parse(["--nope"])


if __name__ == "__main__":
    unittest.main()
