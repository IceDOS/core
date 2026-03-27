# 🧊 IceDOS

**IceDOS** is a highly opinionated **NixOS** framework designed to deliver a high-performance gaming and general-purpose computing experience. It balances sane defaults with a flexible configuration system to meet diverse user needs.

## ✨ Features

- **🎮 Gaming Optimized:** Pre-configured kernels, drivers, and tools for a low-latency gaming experience.

- **🔧 Modular Configuration:** Easily extend the system via `config.toml` or custom Nix modules.

- **⚡ IceDOS CLI:** A suite of tools designed to manage your system without the complexity of raw Nix commands.

- **📂 State Management:** Isolated build environment within the `.state` directory to keep your source tree clean.

- **❄️ Inputs Management:** Easily control the resulting Flake inputs from your `config.toml` or your **IceDOS** modules.

## 🚀 Installation

To get started with the default [template](https://github.com/IceDOS/template), run the following commands:

```bash
git clone https://github.com/icedos/template icedos
cd icedos
nix --extra-experimental-features "flakes nix-command pipe-operators" run . -- --boot
```

## ⚙️ Configuration

**IceDOS** provides two primary ways to customize your system:

1. **Simple:** Edit `config.toml`. This file exposes high-level options provided by **IceDOS** modules. You can find all available options of each module in their respective example `config.toml`.

2. **Advanced:** Add nix and/or icedos, modules to the `extra-modules` directory for full control.

> **ℹ️ NOTE**
> The `.state` directory stores the generated `flake.nix` and your `flake.lock`. You generally should not need to edit these manually.

## 🛠️ Usage

> **⚠️ WARNING**
> Do not use `nixos-rebuild` directly. **IceDOS** uses a custom wrapper to manage its modular architecture and state.

**Use the IceDOS CLI to manage your installation:**

```bash
icedos rebuild [FLAGS] [--build-args <extra rebuild args...>]
```

Default behavior (no action flag) is equivalent to `switch`.

| Command | Description |
| --- | --- |
| `icedos` | View all available tools in the **IceDOS** suite. |
| `icedos rebuild` | Apply configuration changes to the system. |
| `icedos update` | Update all flake inputs (system update). Alias for `icedos rebuild --update`. |

> **ℹ️ NOTE**
> `icedos update` is an alias for `icedos rebuild --update`. All flags documented below work with both commands (e.g. `icedos update --boot`, `icedos update --logs`).

### Action flags

These choose the rebuild action mode:

| Flag | Effect | Typical use |
| --- | --- | --- |
| `--boot` | Uses `boot` action. New generation is prepared for next reboot. | Safer rollout when you don't want to activate immediately. |
| `--build` | Uses `build` action. Builds but does not activate. | CI checks or validation before switching. |
| `none` | Uses `switch` action. Builds and activates now. | Day-to-day system changes. |

### Update flags

These control what gets updated before the build:

| Flag | Effect | Typical use |
| --- | --- | --- |
| `--update` | Enables all update paths: core, repositories, nix. | Full update workflow. |
| `--update-core` | Runs `nix flake update` in the config root, then re-runs the command once. | Updates **IceDOS** core libraries/modules. |
| `--update-nix` | Runs `nix flake update` in the state directory. | Updates nix related modules. |
| `--update-repos` | Enables refresh behavior for **IceDOS** repositories input generation (`--refresh` + `ICEDOS_UPDATE=1`). | Updates **IceDOS** repositories and their modules. |

### Behavior flags

| Flag | Effect | Typical use |
| --- | --- | --- |
| `--export-full-config` | Generates `.cache/full-config.json` and `.cache/config.json` in the state directory, then exits (no build). | Inspecting merged/evaluated configuration. |
| `--ask` | Adds `-a` to the `nh os` flow (interactive confirmation). | Manual confirmation before applying in the `nh` path. |
| `--builder <host>` | Uses `sudo nixos-rebuild ... --build-host <host>` instead of `nh`. | Remote/distributed build host workflow. |
| `--logs` | Enables `ICEDOS_LOGGING=1` and passes `--show-trace` to evaluation/build commands. | Debugging eval/build failures with full traces. |
| `--build-args ...` | Forwards all remaining arguments to the final rebuild command. Must be last. | Passing extra `nixos-rebuild`/`nh` args (e.g. `-j`, `--keep-going`). |

### Important warnings

- **`--build-args` consumes the rest of the command line** — anything after it is forwarded as raw rebuild args and is not parsed as flags. Always put it last.

- **`--builder` switches the execution path** — with `--builder`, the script uses `sudo nixos-rebuild` directly; without it, it uses `nh`.

- **`--update-core` re-execs the command once** — the script updates the config flake and re-runs itself via `nix run . -- <original args>` to avoid stale state after core input updates.

- **`--export-full-config` is a non-build mode** — it exits right after writing the exported config in JSON format.

- **Unknown flags fail** — any unsupported flag prints `Unknown arg: ...` and exits with code `1`.

- **State/build directories are regenerated** — the temporary build directory is recreated each run. Generated flake/state files are written into the state directory and copied into a temp build dir.

### Examples

```bash
# Standard apply
icedos rebuild

# Build only (no activation)
icedos rebuild --build

# Prepare next boot generation and show traces
icedos rebuild --boot --logs

# Full update + apply
icedos update

# Remote builder
icedos rebuild --builder example@192.168.1.2

# Pass-through rebuild arguments
icedos rebuild --logs --build-args -j 8
```

## 🤝 Contributing

We welcome contributions! To ensure your PR is directed to the right place, please follow these guidelines:

- **Core Functionality:** PRs improving the framework core, CLI, or base modules should be made directly to this repository.

- **Specific Apps/Configs:** PRs regarding specific software suites or specialized configurations should be submitted to their respective repositories within the **IceDOS** organization.

- **🙏 We need a logo, please! 🙏**
