from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import shutil
import sys
from typing import IO, Any

from .context import BuildEnv
from .util import JSON, read_json, warn

DEFAULT_PROFILE = "/nix/var/nix/profiles/system"


def read_profile(profile_path: str = DEFAULT_PROFILE) -> str:
    try:
        return os.readlink(profile_path)
    except OSError:
        return ""


def keep_after_failure(action: str, before: str, after: str, remote_target: bool) -> bool:
    if remote_target:
        return False
    return action in ("switch", "boot") and before != after


class Transaction:
    def __init__(
        self,
        store: Path,
        lock_path: Path,
        files: list[Path],
        profile_path: str = DEFAULT_PROFILE,
    ) -> None:
        self.store = store
        self.lock_path = lock_path
        self.files = files
        self.profile_path = profile_path
        self.profile_before = read_profile(profile_path)
        self._lock_file: IO[str] | None = None

    @classmethod
    def for_env(cls, env: BuildEnv, profile_path: str = DEFAULT_PROFILE) -> Transaction:
        files: list[Path] = []
        if env.config_root:
            files.append(env.config_root / "flake.lock")
        files.append(env.state_dir / "flake.nix")
        files.append(env.state_dir / "flake.lock")
        return cls(
            store=env.state_dir / ".txn",
            lock_path=env.state_dir / ".txn.lock",
            files=files,
            profile_path=profile_path,
        )

    def begin(self) -> None:
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock_file = open(self.lock_path, "a+")
        try:
            fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("error: another icedos rebuild is running for this config", file=sys.stderr)
            raise SystemExit(1)

        if self.store.exists():
            manifest_file = self.store / "manifest.json"
            if manifest_file.exists():
                warn(
                    "warning: previous rebuild did not finish; "
                    "restored flake.lock and .state/flake.{nix,lock} from before it"
                )
                self.rollback()
            else:
                shutil.rmtree(self.store, ignore_errors=True)

        self.store.mkdir(parents=True, exist_ok=True)
        manifest_entries: list[dict[str, Any]] = []
        for i, path in enumerate(self.files):
            present = path.exists()
            copy_name = str(i)
            if present:
                shutil.copy2(path, self.store / copy_name)
            manifest_entries.append(
                {"path": str(path.resolve()), "present": present, "copy": copy_name}
            )

        manifest_data = {
            "files": manifest_entries,
            "profile_before": self.profile_before,
        }
        tmp_manifest = self.store / "manifest.json.tmp"
        with tmp_manifest.open("w") as f:
            json.dump(manifest_data, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_manifest, self.store / "manifest.json")

    def rollback(self) -> None:
        manifest_file = self.store / "manifest.json"
        if not manifest_file.exists():
            shutil.rmtree(self.store, ignore_errors=True)
            return

        try:
            data = read_json(manifest_file)
            entries = data.get("files", []) if isinstance(data, dict) else []
        except Exception:
            entries = []

        restored_names: list[str] = []
        for entry in entries:
            target = Path(entry["path"])
            present = entry.get("present", False)
            copy_name = entry.get("copy", "")
            backup_copy = self.store / copy_name

            if present and backup_copy.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                tmp_target = target.parent / f"{target.name}.icedos-tmp"
                shutil.copy2(backup_copy, tmp_target)
                os.replace(tmp_target, target)
                restored_names.append(target.name)
            else:
                try:
                    target.unlink(missing_ok=True)
                except OSError:
                    pass

        shutil.rmtree(self.store, ignore_errors=True)
        if restored_names:
            print(f"restored {', '.join(restored_names)} from transaction store", file=sys.stderr)

    def commit(self) -> None:
        shutil.rmtree(self.store, ignore_errors=True)

    def finish(self, ok: bool, action: str, remote_target: bool) -> None:
        try:
            if ok:
                self.commit()
            elif keep_after_failure(
                action, self.profile_before, read_profile(self.profile_path), remote_target
            ):
                warn(
                    "warning: rebuild failed after the system profile changed; "
                    "keeping the updated locks so the config matches the installed generation"
                )
                self.commit()
            else:
                if remote_target:
                    warn(
                        "warning: deploy to remote target failed; locks restored, "
                        "check the remote generation with 'nixos-rebuild list-generations' on the host"
                    )
                self.rollback()
        finally:
            if self._lock_file is not None:
                try:
                    fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_UN)
                    self._lock_file.close()
                except OSError:
                    pass
                self._lock_file = None

    def original_lock(self, which: str) -> dict[str, JSON]:
        manifest_file = self.store / "manifest.json"
        if not manifest_file.exists():
            return {}
        try:
            data = read_json(manifest_file)
            entries = data.get("files", []) if isinstance(data, dict) else []
        except Exception:
            return {}

        state_dir_path = self.store.parent.resolve()
        target_name = "flake.lock"
        for entry in entries:
            p = Path(entry["path"]).resolve()
            if p.name == target_name:
                is_state = p.parent == state_dir_path
                if which == "state" and is_state:
                    copy_file = self.store / entry["copy"]
                    if copy_file.exists():
                        val = read_json(copy_file)
                        return val if isinstance(val, dict) else {}
                elif which == "config" and not is_state:
                    copy_file = self.store / entry["copy"]
                    if copy_file.exists():
                        val = read_json(copy_file)
                        return val if isinstance(val, dict) else {}
        return {}
