# 🧊 IceDOS

**IceDOS** is a highly opinionated **NixOS** framework designed to deliver a high-performance gaming and general-purpose computing experience. A whole machine is described almost entirely by a single **`config.toml`**, and the **`icedos` CLI** turns that into a NixOS system — you toggle and configure modules instead of hand-writing Nix.

The framework is spread across many small repositories (this one, `core`, is the engine; features live in-module repos). It balances sane defaults with a flexible, layered configuration system to meet diverse user needs.

> **ℹ️ For contributors/agents:** [AGENTS.md](./AGENTS.md) is the canonical, in-depth reference for the whole framework (build pipeline, library API, module structure, rules). This README is the user-facing overview.

## ✨ Features

- **🎮 Gaming-focused:** Curated kernels, graphics drivers, low-latency tweaks, and gaming tooling — delivered through the [tweaks](https://github.com/IceDOS/tweaks) and [hardware](https://github.com/IceDOS/hardware) module repos.

- **🧩 Modular multi-repo system:** Enable features by listing modules from IceDOS repositories ([apps](https://github.com/IceDOS/apps), [hardware](https://github.com/IceDOS/hardware), [desktop](https://github.com/IceDOS/desktop), DE repos, …) in `config.toml`. Each module declares its own options and dependencies, which are resolved and pulled in automatically.

- **🔧 Layered configuration:** Configure high-level module options from `config.toml`, drop down to **raw NixOS options** for anything no module exposes, or add full custom Nix in `extra-modules/`.

- **🌐 Raw NixOS passthrough:** Any top-level TOML table that isn't `icedos` is applied verbatim as NixOS configuration — typed and validated by nixpkgs itself, no module required (see more below).

- **🚀 Self-hosted binary cache:** A public IceDOS Nix cache is configured **by default**, so you pull prebuilt artifacts instead of compiling everything locally.

- **🩹 Layered patching:** Patch a whole module repo, a module's own input, or a module's input **from your config** — all without forking anything.

- **🪝 Lifecycle hooks:** Run arbitrary commands around rebuilds and garbage collection (`preRebuild`/`postRebuild`/`preUpdate`/`postUpdate`, `preGc`/`postGc`).

- **🕘 Config snapshots:** Every rebuild snapshots your `config.toml` and generated flake files into a timestamped `.cache/` folder whenever they change, giving you a built-in history.

- **✅ Rich validation:** Options are validated with path-aware error messages that fire on both your overrides and the modules' own defaults, catching typos early without a full rebuild.

- **⚡ IceDOS CLI:** A suite of tools to manage your system without the complexity of raw Nix commands (`rebuild`, `pkgs`, `session`, `gc`, `shell`, …).

- **📂 State isolation:** The generated `flake.nix`/`flake.lock` live in an isolated `.state` directory, keeping your source tree clean.

- **🏠 home-manager integrated:** User environments are configured alongside the system from the same `config.toml`.

## 🧩 Repository map

IceDOS is consumed as flake inputs. You don't need every repo checked out — list the ones you want in `config.toml`.

| Repo | Kind | Purpose |
| --- | --- | --- |
| **[core](https://github.com/IceDOS/core)** | framework | **This repo.** The `icedos` CLI, the `lib/` library, base modules, `build.sh`, and the flake-generation engine. |
| [apps](https://github.com/IceDOS/apps) | module repo | ~70 application modules (`btop`, `steam`, `sunshine`, …) with various exposed extra options and our chosen defaults. |
| [hardware](https://github.com/IceDOS/hardware) | module repo | Kernel, graphics (`radeon`/`nvidia`), `pipewire`, `bluetooth`, bootloaders, `zram`, cachyos kernel and a lot more... |
| [desktop](https://github.com/IceDOS/desktop) | module repo | Cross-DE glue: `gdm`, `stylix`, `displays`, portals, desktop entries, session. |
| [gnome](https://github.com/IceDOS/gnome) / [hyprland](https://github.com/IceDOS/hyprland) / [kde](https://github.com/IceDOS/kde) / [cosmic](https://github.com/IceDOS/cosmic) | DE repos | Desktop environments / window managers and their integrations. |
| [tweaks](https://github.com/IceDOS/tweaks) | module repo | Performance/behavior tweaks: `cachyos`, `gaming`, `kernel`, … |
| [providers](https://github.com/IceDOS/providers) | module repo | Extra package sources: `nur`, `jovian`. |
| [template](https://github.com/IceDOS/template) | starter | Minimal config to **fork** when creating your own config root. |
| [cache-server](https://github.com/IceDOS/cache-server) | cache infrastructure | The self-hosted Nix binary cache (not a module repo). |
| *(your config)* | **user config** | **Your own repo** — any name/location, created by forking [template](https://github.com/IceDOS/template). Holds `config.toml`, `flake.nix`, and `extra-modules/`, and drives everything. |

## 🚀 Installation

To get started with the default [template](https://github.com/IceDOS/template), run the following commands:

```bash
git clone https://github.com/icedos/template icedos
cd icedos
nix --extra-experimental-features "flakes nix-command pipe-operators" run path:. -- --boot
```

This forks the template into your own config repo and prepares the first generation for next boot.

## ⚙️ Configuration

**IceDOS** provides three ways to customize your system, in increasing order of control:

1. **Simple:** Edit `config.toml`. This file exposes high-level options provided by **IceDOS** modules. You can find all available options of each module in their respective example `config.toml`.

2. **Raw NixOS options:** Any top-level table in `config.toml` (or `.private.toml`) that is **not** `icedos` is applied directly as NixOS configuration — no module needed. The options are typed and validated by nixpkgs itself. Use it for plain options no **IceDOS** module exposes:

   ```toml
   [services.joycond]
   enable = true

   # home-manager is reachable the usual way
   [home-manager.users.alice.programs.git]
   enable = true
   ```

   This only covers what TOML can express; for Nix values (packages, `null`, `mkForce`, `lib.*`) use the Advanced method below.

3. **Advanced:** Add custom modules to the `extra-modules/` directory for full control — for anything TOML can't express (packages, `null`, `mkForce`, `lib.*`, custom options). Two kinds are supported and discovered automatically:

   - **Plain NixOS module** — `extra-modules/<name>/default.nix` (or a loose `extra-modules/<name>.nix`). A standard module that receives `{ config, lib, pkgs, ... }`.
   - **IceDOS module** — `extra-modules/<name>/icedos.nix`. A full IceDOS module that receives `{ icedosLib, ... }` and may declare `options`, `inputs`, `outputs.nixosModules`, and `meta` — exactly like a module from a repo (see the module-structure guide in [AGENTS.md](./AGENTS.md)). It **must** live in its own subdirectory; a top-level `extra-modules/icedos.nix` is not valid.

   ```text
   extra-modules/
   ├── my-tweak/
   │   └── default.nix     # plain NixOS module
   └── my-feature/
       └── icedos.nix      # full IceDOS module (options + outputs)
   ```

### Enabling modules

Modules come from IceDOS repositories. Declare each repo as a `[[icedos.repositories]]` entry and list the modules you want; their dependencies are pulled in automatically.

```toml
[[icedos.repositories]]
url = "github:icedos/apps"
modules = [ "btop", "steam" ]          # which modules to enable

# overrideUrl = "path:/abs/path/to/apps"  # use a local checkout (dev/testing)
# fetchDependencies = true                # pull each module's dependencies (default: true)
# fetchOptionalDependencies = false       # also pull optionalDependencies (default: false)
# patches = [ "patches/apps.patch" ]      # patch the whole repo source
```

### `config.toml` schema map

Everything under `icedos` is the framework's typed schema. The top-level groups:

| Key | What it controls |
| --- | --- |
| `icedos.repositories` | Module repositories to load and which modules to enable (see above). |
| `icedos.system` | System-wide settings: `arch`, `version`, `nixpkgsChannel`, `allowUnfree`, `generations`, `packages`, `permittedInsecurePackages`, `loadHardwareConfiguration`, the binary `cache`, extra `channels`/`overlays`, and `buildVm` options. |
| `icedos.users` | User accounts (home-manager integrated): groups, password, packages, sudo, … |
| `icedos.applications.*` | Per-module options. Core ships `toolset` (CLI/hooks) and `gc` (garbage collection); module repos add their own (e.g. `icedos.applications.btop`). |

Per-module option defaults are documented in each module's sibling `config.toml`.

### Channels & overlays

Register extra nixpkgs instances with `[[icedos.system.channels]]`. Each channel is exposed inside the active package set under its name, so its packages become reachable as `<channel>.<package>`:

```toml
[[icedos.system.channels]]
name = "stable"
url = "github:nixos/nixpkgs/nixos-26.05" # Current stable when written
```

To instead **replace** a package's default source everywhere (so a plain `obs-studio` resolves to the other source), use an overlay. `[[icedos.system.overlays.fromChannel]]` lifts named packages from a declared `channel` or straight from a flake `url`:

```toml
# from a declared channel (see channels above)
[[icedos.system.overlays.fromChannel]]
channel = "stable"
packages = [ "obs-studio" ]

# or directly from a flake URL (registered automatically)
[[icedos.system.overlays.fromChannel]]
url = "github:nixos/nixpkgs/nixos-unstable"
packages = [ "mesa" ]
```

> **ℹ️ NOTE**
> Neither a channel nor an overlay installs anything on its own — a channel only makes a source reachable (as `<channel>.<package>`), and an overlay only swaps a package's default source. Both become meaningful only once the package is actually referenced: as a global package (`icedos.system.packages`), a home-manager user package (`icedos.users.<name>.packages`), or by a module. Reference a channel package by its `<channel>.<package>` name (e.g. `stable.obs-studio`); an overlaid package keeps its plain name (e.g. `obs-studio`) and is swapped wherever it's already used, including transitive pulls like `mesa` from the graphics stack.

### Hardware configuration

Your machine's `/etc/nixos/hardware-configuration.nix` is automatically loaded into the generated system, so the host essentials (filesystems, kernel modules, microcode, …) always apply and the machine stays bootable. This is governed by `icedos.system.loadHardwareConfiguration`, which is **`true` by default**:

```toml
[icedos.system]
loadHardwareConfiguration = true   # default; set false to opt out
```

Only set it to `false` if you provide the equivalent hardware settings another way (e.g. from a module or `extra-modules/`).

### Build VM

`icedos rebuild --build-vm` / `--run-vm` build a throwaway QEMU VM of your configuration (see [Usage](#-usage)). `[icedos.system.buildVm]` tunes that VM image — it never affects the host:

| Option | Default | Effect |
| --- | --- | --- |
| `memory` | `1024` | VM RAM, in MiB. |
| `cores` | `1` | VM CPU cores. |
| `diskSize` | `"auto"` | VM disk size in MiB, or `"auto"`. |
| `resolution` | `"1920x1080"` | VM display resolution, `<width>x<height>`. |
| `ssh.enable` | `false` | forward a host port to the VM's SSH. |
| `ssh.hostPort` | `2222` | host-side port for the SSH forward. |
| `ssh.vmPort` | `22` | guest SSH port. |
| `[[icedos.system.buildVm.sharedDirectories]]` | `[]` | `{ source, target }` host→guest shared folders. |

```toml
[icedos.system.buildVm]
memory = 8192
cores = 4
diskSize = 32768
resolution = "2560x1440"

[icedos.system.buildVm.ssh]
enable = true
hostPort = 2222

[[icedos.system.buildVm.sharedDirectories]]
source = "/home/me/shared"
target = "shared"
```

### `.private.toml`

`.private.toml` has the same shape as `config.toml` and is **strict-merged** with it (lists are concatenated; defining the same key in both files is an error). Use it to keep secrets or host-specific values out of your main config.

### Hooks

Run arbitrary commands around the rebuild and garbage-collection lifecycle:

```toml
[icedos.system.toolset.rebuild.hooks]
preRebuild  = [ "echo 'before build'" ]
postRebuild = [ "echo 'after activation'" ]
preUpdate   = [ "echo 'runs with --update, before build'" ]
postUpdate  = [ "flatpak update" ]          # runs with --update, after build

[icedos.system.gc.hooks]
preGc  = [ "echo 'before gc'" ]
postGc = [ "echo 'after gc'" ]
```

`preUpdate`/`postUpdate` only fire when `--update` is passed. They can also be run on their own — without a system rebuild — via `icedos rebuild --update-hooks` (handy for refreshing non-Nix resources like `flatpak update`).

### Patches

IceDOS can apply patches at three layers, all from your config, without forking:

- **Whole-repo** — `[[icedos.repositories]].patches`: patch an entire module repo's source.
- **Module-author input** — a module's `inputs.<name>.patches`: shipped by the module itself.
- **Consumer input** — `[[icedos.repositories.inputPatches]]`: patch a specific module's specific flake input from your config.

See [AGENTS.md](./AGENTS.md) for the full patching model.

## 🛠️ Usage

> **⚠️ WARNING**
> Do not use `nixos-rebuild` directly. **IceDOS** uses a custom wrapper to manage its modular architecture and state.

**Use the IceDOS CLI to manage your installation.** Run `icedos` to list commands, or `icedos --tree` to list everything recursively.

### Command reference

| Command | Description |
| --- | --- |
| `icedos` | List top-level commands in the **IceDOS** suite. |
| `icedos --tree` | Recursively list every command and subcommand. |
| `icedos rebuild` | Apply configuration changes to the system (see flags below). |
| `icedos configuration show options [query]` | Fuzzy-search **IceDOS** options (fzf) with a paste-ready TOML snippet (`--no-fzf` for a plain list). |
| `icedos configuration show modules [--enabled]` | Browse modules — enabled / available / dependencies (fzf; `--no-fzf` prints a grouped overview). |
| `icedos session reboot [uefi]` | Reboot, ignoring inhibitors and other users. Append `uefi` to reboot into firmware setup. |
| `icedos session logout` | Terminate all sessions for the current user. |
| `icedos session poweroff` | Power off, ignoring inhibitors and other users. |
| `icedos session suspend` | Suspend, ignoring inhibitors and other users. |
| `icedos nixf [dir]` | Format all `.nix` files in the current (or given) directory. |
| `icedos pkgs list` | List installed packages. |
| `icedos pkgs build` | Build a package derivation (`--path/-p`, `--run/-r`). |
| `icedos pkgs run <attr>` | Build a nixpkgs attribute and exec its main binary (`--select/-s`, `--detach/-d`, `--insecure`). |
| `icedos repair` | Verify and repair the Nix store. |
| `icedos shell` | Spawn a `nix-shell` with an optimized env (`--insecure`). |
| `icedos gc` | Clean Nix + home-manager store and profiles, and purge leftover build dirs. |

### `icedos rebuild`

```bash
icedos rebuild [FLAGS] [--build-args <extra rebuild args...>]
```

Default behavior (no action flag) is equivalent to `switch`. After a `switch` that changed the kernel or initrd, IceDOS prompts you to reboot. Each successful rebuild also snapshots your `config.toml` and the generated flake files into a timestamped `.cache/` folder whenever they change.

#### Action flags

These choose the rebuild action mode:

| Flag | Effect | Typical use |
| --- | --- | --- |
| `--boot` | Uses `boot` action. New generation is prepared for next reboot. | Safer rollout when you don't want to activate immediately. |
| `--build` | Uses `build` action. Builds but does not activate. | CI checks or validation before switching. |
| `--build-vm` | Uses `build-vm` action. Builds a bootable QEMU VM image (`result/bin/run-<hostname>-vm`). | Sanity-check the config in a VM without touching the host. |
| `--run-vm` | Same as `--build-vm`, then `exec`s the generated VM script. | Quick interactive VM test. |
| `none` | Uses `switch` action. Builds and activates now. | Day-to-day system changes. |

#### Update flags

These control what gets updated before the build:

| Flag | Effect | Typical use |
| --- | --- | --- |
| `--update` | Enables every update path: core, nixpkgs, module repos, and module-declared transitive inputs. Runs a single `nix flake update --refresh` on the state lock for a blanket bump. | Full update workflow. |
| `--update-core` | Runs `nix flake update --refresh` in the config root, then re-runs the command once. | Update **IceDOS** core libraries/modules. |
| `--update-hooks` | Runs only the registered `preUpdate`/`postUpdate` hooks and exits. No nix build, no activation. Sets `ICEDOS_HOOKS_ONLY=1` so hooks know HM activation will not follow. | Refresh non-nix runtime resources (e.g. `flatpak update`) without a system rebuild. |
| `--update-nixpkgs` | Runs `nix flake update nixpkgs` in the state directory. | Update nixpkgs channel only. |
| `--update-repos` | Refreshes the direct **IceDOS** module-repo URLs during flake generation (`--refresh` + `ICEDOS_UPDATE=1`). Does **not** re-lock inputs declared inside module flakes — use `--update-repos-inputs` (or `--update`) for that. | Pull new revs of `icedos/hardware`, `icedos/apps`, etc. |
| `--update-repos-inputs` | Re-locks every `icedos-*` transitive input in the state lock (e.g. `icedos-github_icedos_hardware-cachyos-kernel-nix-cachyos-kernel`). Inputs declared inside module `icedos.nix` files are copied verbatim into the generated state flake and never carry a rev pin, so this is the only path that bumps them. | Bump all module inputs without bumping nixpkgs/home-manager. |

#### Behavior flags

| Flag | Effect | Typical use |
| --- | --- | --- |
| `--export-full-config` | Generates `.cache/full-config.json` and `.cache/config.json` in the state directory, then exits (no build). | Inspecting merged/evaluated configuration. |
| `--ask` | Adds `-a` to the `nh os` flow (interactive confirmation). | Manual confirmation before applying. |
| `--builder <host>` | Adds `--build-host <host>` to the `nh os` flow (build the system closure on a remote host). | Remote/distributed build host workflow. |
| `--target <host>` | Adds `--target-host <host>` to the `nh os` flow (deploy/activate the built closure on a remote host). Pairs with `--builder`. | Deploying to a remote machine. |
| `--logs` | Enables `ICEDOS_LOGGING=1` and passes `--show-trace` to evaluation/build commands. | Debugging eval/build failures with full traces. |
| `--nh-args ...` | Forwards arguments to the `nh os` command itself (before the `--` separator). Consumes args up to `--build-args` or end of line. | Passing extra `nh` flags not covered by dedicated flags (e.g. `--no-nom`). |
| `--build-args ...` | Forwards all remaining arguments to the final rebuild command. Must be last. | Passing extra `nixos-rebuild`/`nh` args (e.g. `-j`, `--keep-going`). |
| `--genflake-only` | *(advanced/internal)* Generates and locks the state flake, then exits without building. | Tooling that needs the generated flake (e.g. to query per-package output paths). |

### Important warnings

- **`--build-args` consumes the rest of the command line** — anything after it is forwarded as raw rebuild args and is not parsed as flags. Always put it last.

- **`--nh-args` consumes args until `--build-args` or end of line** — everything after it is forwarded to `nh os` and is not parsed as IceDOS flags, so place it after all other IceDOS flags. To pass both nh args and rebuild args, combine as `--nh-args ... --build-args ...`.

- **`--builder` and `--target` are remote-host knobs** — `--builder` builds the closure on a remote host; `--target` activates it on one. Both just add the corresponding `nh os` host flags; use them together to build and deploy remotely.

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
icedos rebuild --update

# Update module-declared inputs (e.g. nix-cachyos-kernel) without
# touching nixpkgs or home-manager
icedos rebuild --update-repos-inputs

# Refresh non-nix runtime resources only (no nix build)
icedos rebuild --update-hooks

# Build remotely and deploy to a target host
icedos rebuild --builder builder@192.168.1.2 --target deploy@192.168.1.3

# Pass-through rebuild arguments
icedos rebuild --logs --build-args -j 8

# Pass extra args to nh os itself (before the -- separator)
icedos rebuild --nh-args --no-nom

# Combine nh args and rebuild args
icedos rebuild --nh-args --no-nom --build-args -j 8

# Build and exec a package without installing it
icedos pkgs run firefox

# Format the Nix tree
icedos nixf .
```

## 🤝 Contributing

We welcome contributions! To ensure your PR is directed to the right place, please follow these guidelines:

- **Core Functionality:** PRs improving the framework core, CLI, or base modules should be made directly to this repository. Read [AGENTS.md](./AGENTS.md) first — it's the canonical reference for the framework's architecture, conventions, and rules.

- **Specific Apps/Configs:** PRs regarding specific software suites or specialized configurations should be submitted to their respective repositories within the **[IceDOS organization](https://github.com/IceDOS)** (see the [repository map](#-repository-map)).

- **Build your own module repos:** The **IceDOS** organization's repos are a *reference* — the modules we happen to use — not a requirement. The whole point is modularity: anyone can publish their own repositories of **IceDOS** modules and load them with `[[icedos.repositories]]` (`url = "github:you/your-repo"`). You're not limited to, or expected to upstream into, the official repos.

- **🙏 We need a logo, please! 🙏**
