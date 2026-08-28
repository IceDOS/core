from __future__ import annotations

import fcntl
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from .context import BuildEnv
from .options import Options
from .util import sync_dir


def build(env: BuildEnv, opts: Options) -> None:
    build_dir = Path(tempfile.mkdtemp(prefix="icedos-build-", suffix="-0"))
    os.environ["ICEDOS_BUILD_DIR"] = str(build_dir)

    # Held open for the whole build (and the VM exec), so flock isn't released early.
    lock_file = open(build_dir / ".lock", "w")  # noqa: SIM115
    os.set_inheritable(lock_file.fileno(), True)
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        msg = f"could not lock {build_dir}/.lock; a gc sweep may delete this build dir"
        print(f"warning: {msg}", file=sys.stderr)

    sync_dir(env.state_dir, build_dir)
    print(f"building from path {build_dir}...")

    cmd = [
        "nh",
        "os",
        opts.action,
        "--no-update-lock-file",
        "path:.",
        *opts.nh_build_args,
        "--hostname",
        "icedos",
        "--",
        *opts.trace,
        *opts.global_build_args,
    ]
    proc = subprocess.run(
        cmd,
        cwd=build_dir,
        pass_fds=(lock_file.fileno(),),
        check=False,
    )
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)

    if opts.action == "build-vm":
        print(f"VM configuration stored in {build_dir}/result")

    if opts.run_vm:
        scripts = sorted((build_dir / "result" / "bin").glob("run-*-vm"))
        if not scripts:
            print(
                f"error: no VM script found in {build_dir}/result/bin", file=sys.stderr
            )
            raise SystemExit(1)
        if len(scripts) != 1:
            names = " ".join(str(path) for path in scripts)
            print(
                f"error: expected exactly one VM script, got: {names}", file=sys.stderr
            )
            raise SystemExit(1)
        # The VM script defaults NIX_DISK_IMAGE to ./<vmName>.qcow2, so it must run
        # from the temp build dir — otherwise the image lands in the config root.
        os.chdir(build_dir)
        os.execv(str(scripts[0]), [str(scripts[0])])
