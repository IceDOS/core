# 🧊 IceDOS

**Set up your whole Linux PC by editing one text file — then undo any change in a single command.**

IceDOS is a ready-made, gaming-friendly computer setup built on top of **NixOS** (a version of Linux where your entire system lives in text files, so every change is saved and reversible). You describe your machine in one file — `config.toml` — and the `icedos rebuild` command turns it into a working system. Enable **Steam**, pick a desktop, tune your hardware, install apps: you flip options instead of writing code. If an update ever breaks something, you roll the whole system **and** your settings back to the last version that worked.

**Who it's for:** gamers who want a fast, no-fuss desktop; developers who want a reproducible machine — desktop, server, or headless — they can rebuild anywhere; and anyone who wants a PC they can reset or roll back without fear. You do **not** need to know the Nix programming language for everyday use.

> **New to Linux/NixOS?** Start at [Requirements](#-requirements) — IceDOS runs *on top of* NixOS, so you install NixOS first.
>
> **Already fluent in Nix?** The [Configuration](#️-configuration) and [Usage](#️-usage-the-icedos-command) sections are your reference. New Nix term? The [glossary](#-nix-terms-in-plain-english) explains every one in a line.
>
> **Contributor/agent?** [AGENTS.md](./AGENTS.md) is the deep, canonical reference for the framework internals.

## Contents

- [What you get](#-what-you-get)
- [Requirements](#-requirements)
- [Quick start](#-quick-start)
- [Nix terms in plain English](#-nix-terms-in-plain-english)
- [How IceDOS is organized](#-how-icedos-is-organized)
- [Configuration](#️-configuration)
- [Usage: the `icedos` command](#️-usage-the-icedos-command)
- [Troubleshooting & FAQ](#-troubleshooting--faq)
- [Contributing](#-contributing)
- [License](#-license)

## ✨ What you get

Each point leads with the benefit; the technical term is in parentheses for people who want it.

- **🎮 Gaming that just works** — curated kernels, graphics drivers, and low-latency tweaks, plus one-line app enablement (Steam, MangoHud, emulators, and more) from the [tweaks](https://github.com/IceDOS/tweaks), [hardware](https://github.com/IceDOS/hardware), and [apps](https://github.com/IceDOS/apps) module repos.
- **📝 One file to rule it all** — your whole machine is described in `config.toml`. Turn features on by name; you don't hand-write system code for the common cases.
- **↩️ Undo anything** — every rebuild is saved, and `icedos configuration rollback` restores the last working system **and** the `config.toml` that built it, in one command *(generations + config snapshots)*.
- **⚡ No waiting for compiles** — packages download pre-built from the IceDOS server instead of building on your machine *(self-hosted binary cache)*. On by default.
- **🩺 Built-in health check** — `icedos doctor` inspects your system and tells you, in plain language, what to fix.
- **🔎 Discover every setting** — `icedos configuration show options` fuzzy-searches everything you can change and hands you a ready-to-paste snippet.
- **✅ Typo-proof settings** — options are validated with error messages that name the exact setting and file, catching mistakes before a full rebuild *(path-aware validation)*.
- **🧪 Try changes safely** — build a throwaway virtual machine of your config to test it without touching your real system *(`--build-vm`)*.
- **🧹 Stays tidy on its own** — old versions are cleaned up automatically on a schedule *(automatic garbage collection)*, and the generated build files are tucked away in a `.state/` folder so your own files stay clean.
- **🏠 Your apps and dotfiles too** — per-user settings are managed alongside the system from the same file *(home-manager integrated)*.
- **🧩 Add anything, fork nothing** — mix in modules from any IceDOS-style repository, drop to raw NixOS options for anything a module doesn't cover, or patch a dependency straight from your config *(layered configuration + patching)*.
- **🚀 Remote-friendly** — build on a beefy machine and deploy to another over the network *(`--builder`/`--target`)*.

## 🧰 Requirements

IceDOS is a **layer on top of NixOS**, not an OS installer. Before you start you need:

- **A machine already running NixOS.** New to it? Install NixOS first from [nixos.org/download](https://nixos.org/download) (there's a graphical installer), then come back here. IceDOS then takes over configuring it.
- **`/etc/nixos/hardware-configuration.nix`.** The NixOS installer creates this file (it describes your disks and drivers). IceDOS reads it automatically so your machine keeps booting — just don't delete it.
- **Flakes enabled.** Nothing to set up in advance — the install command below switches on the Nix features IceDOS needs, just for that command.
- **Room to work:** roughly **15 GB+ free disk** and a **64-bit (x86-64) CPU**.
- **Basic terminal comfort:** you'll open a terminal and edit a text file. That's the floor — the Nix *language* is optional and only needed for advanced tweaks.

## 🚀 Quick start

### 1. Get your starter config

```bash
git clone https://github.com/icedos/template icedos
cd icedos
```

[`template`](https://github.com/IceDOS/template) is a tiny starter you copy and make your own. From now on, **this folder is your machine's configuration** — keep it (put it in your own git repo).

### 2. Build your `config.toml`

**The template is a skeleton, not a ready-to-use system** — out of the box it sets only a bootloader mount point, a NixOS version, and an empty user. Before the first build, flesh out `config.toml` to describe the machine you want. IceDOS runs **desktops, servers, and headless boxes** alike:

- **Desktop / gaming PC:** your user, a desktop environment **and a login manager**, the graphics/hardware modules for your machine, and any apps.
- **Server / headless:** your user, the bootloader + hardware modules, and the services you need — no desktop required.

Here's a minimal but complete **desktop** example — KDE Plasma on an AMD machine. Adjust the modules for your own hardware and taste:

```toml
# --- your user -------------------------------------------------------
[icedos.users.you]                 # rename "you" to your login name
# defaultPassword = "1"            # initial password; change after first login with passwd

[icedos.system]
version = "25.11"                  # keep the template's value

# --- hardware: GPU, audio, kernel ------------------------------------
[[icedos.repositories]]
url = "github:icedos/hardware"
modules = [
  "radeon",                        # AMD GPU — use "nvidia" or "intel" for your card
  "pipewire",                      # audio
  "kernel",
]

[icedos.system.bootloaders.systemd-boot]  # bootloader is a core module (systemd-boot on by default)
mountPoint = "/boot"               # where your EFI partition is mounted

# --- a desktop -------------------------------------------------------
[[icedos.repositories]]
url = "github:icedos/desktop"      # shared desktop glue: login screen, theming, portals

[[icedos.repositories]]
url = "github:icedos/kde"          # the desktop itself — or gnome / hyprland / cosmic
fetchOptionalDependencies = true   # also pull the desktop's matching login manager (see below)

# --- apps you want ---------------------------------------------------
[[icedos.repositories]]
url = "github:icedos/apps"
modules = [ "steam", "btop" ]      # add whatever you like
```

**A desktop needs a login manager.** Turning on a desktop doesn't automatically give you the graphical login screen — each desktop repo declares its best-suited display/login manager as an *optional dependency*. Set `fetchOptionalDependencies = true` on the desktop's repo entry (as shown above for `kde`) to pull it in automatically; without it you'd boot into the desktop's pieces with no graphical way to log in. Prefer a different login screen than the desktop's default? List a display-manager module from the [`desktop`](https://github.com/IceDOS/desktop) repo yourself — e.g. `modules = [ "gdm" ]` (also `cosmic-greeter`, or `plm` for Plasma) on the `github:icedos/desktop` entry — instead of relying on the optional dependency.

**No desktop? (servers & headless)** Drop the `desktop` and `kde` entries (and the login manager) — none of it is required; keep the `hardware` repo and your user. **SSH is opt-in** — set `ssh = true` under `[icedos.system]` to run `sshd` (core's `ssh` module), so a headless box is reachable. Add any other services as plain NixOS options (any non-`icedos` table — see [Configuration](#️-configuration)):

```toml
[services.tailscale]
enable = true
```

Users are created with the password `1` — set `defaultPassword` above, or change it after first login (see [How do I set a password?](#how-do-i-set-a-password)).

**Finding modules and options:** browse the [repository map](#-how-icedos-is-organized), then open each repo's own example `config.toml` on GitHub for the module names and settings it offers. (The `icedos configuration show options` search is easier — but it needs a built system, so use the repos for this first setup.)

### 3. Build it for the first time

```bash
nix --extra-experimental-features "flakes nix-command pipe-operators" run path:. -- --boot
```

In plain English:

- `nix … run path:.` — run the IceDOS builder from the current folder.
- `--extra-experimental-features "…"` — switch on the Nix features IceDOS needs, just for this one command.
- `-- --boot` — everything after `--` goes to IceDOS. `--boot` prepares your new system for the **next reboot** (gentler than switching live on the very first run).

### 4. Reboot

Restart, and pick the newest entry in the boot menu — you'll land in your new system (the desktop you configured, or a console login on a headless box). The `icedos` command is now available.

### 5. Change things later

From now on the loop is always the same: **edit `config.toml`, then run `icedos rebuild`.**

- `icedos configuration show options` — search everything you can set (fuzzy, with paste-ready TOML). Works now that you have a built system.
- `icedos doctor` — a quick health check.
- Broke something? `icedos configuration rollback` restores the last working system **and** the `config.toml` that built it.

## 📖 Nix terms in plain English

The rest of this document uses a few Nix words. Here's what each means, once:

| Term | In one line |
| --- | --- |
| **NixOS** | A Linux system defined entirely in text files and built reproducibly. Every build is saved, so you can always boot an older, working one. IceDOS runs on top of it. |
| **Nix** | The package manager and language under NixOS. IceDOS mostly hides it — you edit `config.toml` instead. |
| **`config.toml`** | Your machine's single settings file. Editing it and running `icedos rebuild` is ~95% of using IceDOS. |
| **Module** | A feature you switch on by name (e.g. `steam`, `btop`). Modules come from IceDOS repositories. |
| **Repository (repo)** | A collection of modules you pull in by URL (e.g. `github:icedos/apps`). You list the repos and modules you want. |
| **Flake reference (`url`)** | How you point at a source such as a repo — a short scheme-prefixed string: `github:owner/repo`, `gitlab:owner/repo`, `git+https://…`, or a local `path:/abs/dir`. This is what `url` takes in `[[icedos.repositories]]` (and in channels/overlays). |
| **Generation** | One saved version of your whole system. Every rebuild makes a new one; older ones stay bootable (they show up in the boot menu) — that's how "undo" works. |
| **Rebuild / switch** | Turning `config.toml` into a running system. `icedos rebuild` builds the new generation and switches to it. |
| **Flake** | The format Nix uses to pin exact versions of everything, so your system is reproducible. IceDOS generates it for you. |
| **Binary cache / substituter** | A server of pre-built packages, so you download instead of compiling. IceDOS ships one, enabled by default. |
| **home-manager** | The part that manages your *user* stuff (dotfiles, per-user apps), configured from the same `config.toml`. |
| **Channel** | A version/branch of the package collection (e.g. `nixos-unstable` = newest; a release like `nixos-25.11` = steadier). |
| **Overlay** | A rule that changes where a package comes from (e.g. pull `mesa` from a newer channel). |
| **Derivation** | Nix's word for a build recipe/result of a package. You'll rarely need it. |
| **`nh`** | A friendly Nix helper IceDOS drives under the hood to build and switch. You won't call it directly. |
| **stateVersion** (`icedos.system.version`) | The NixOS release your machine was first set up against; it protects your data across upgrades. Set once and leave it — see the [NixOS docs](https://search.nixos.org/options?show=system.stateVersion). |

## 🧩 How IceDOS is organized

IceDOS is split into small repositories, pulled in as needed. You don't check them out — you just list the ones you want in `config.toml`.

| Repo | What it is | What it holds |
| --- | --- | --- |
| **[core](https://github.com/IceDOS/core)** | the engine (**this repo**) | The `icedos` command, the `lib/` library, base modules, and the flake generator. |
| [apps](https://github.com/IceDOS/apps) | modules | ~70 application modules (`btop`, `steam`, `sunshine`, …) with sensible defaults and extra options. |
| [hardware](https://github.com/IceDOS/hardware) | modules | Kernels, graphics (`radeon`/`nvidia`), audio (`pipewire`), `bluetooth`, `zram`, the CachyOS kernel, and more. |
| [virtualisation](https://github.com/IceDOS/virtualisation) | modules | Containers & VMs: `docker`, `podman`, `virt-manager`, `virtualbox`, `waydroid`. |
| [desktop](https://github.com/IceDOS/desktop) | modules | Cross-desktop glue: login screen (`ex. gdm, plm, cosmic-greeter...`), theming (`stylix`), displays, portals, desktop entries, sessions. |
| [gnome](https://github.com/IceDOS/gnome) · [hyprland](https://github.com/IceDOS/hyprland) · [kde](https://github.com/IceDOS/kde) · [cosmic](https://github.com/IceDOS/cosmic) | modules | Desktop environments / window managers and their integrations. |
| [tweaks](https://github.com/IceDOS/tweaks) | modules | Performance and behavior tweaks: `cachyos`, `gaming`, `kernel`, … |
| [providers](https://github.com/IceDOS/providers) | modules | Extra package sources: `nur`, `jovian`. |
| [template](https://github.com/IceDOS/template) | starter | The minimal config you copy to create your own. |
| [cache-server](https://github.com/IceDOS/cache-server) | infrastructure | The pre-built-package server (not a module repo). |
| *(your config)* | **you** | **Your own folder/repo** — holds `config.toml`, `flake.nix`, and any `extra-modules/`, and drives everything. |

> The official repos are the modules *we* happen to use — a reference, not a requirement. Anyone can publish their own IceDOS-style module repository and load it with `[[icedos.repositories]]`.

## ⚙️ Configuration

You customize IceDOS at three levels, in increasing order of power. Most people never leave level 1.

1. **Simple — edit `config.toml`.** Flip the high-level options that IceDOS modules expose. Discover them any time with `icedos configuration show options`, or read each module's example `config.toml` in its repo.

2. **Raw NixOS options.** Any top-level table in `config.toml` (or `.private.toml`) that **isn't** `icedos` is applied directly as NixOS configuration — no module needed. NixOS itself checks these for you.

   ```toml
   [services.joycond]
   enable = true

   # home-manager (your per-user settings) is reachable the usual way
   [home-manager.users.alice.programs.git]
   enable = true
   ```

   This covers anything TOML can express. For values TOML can't (packages, `null`, `lib.*`), use level 3.

3. **Advanced — custom [modules](#-nix-terms-in-plain-english).** Drop real Nix into the `extra-modules/` folder for full control. Two kinds are picked up automatically:

   - **Plain NixOS module** — `extra-modules/<name>/default.nix` (or a loose `extra-modules/<name>.nix`). A standard module receiving `{ config, lib, pkgs, ... }`.
   - **IceDOS module** — `extra-modules/<name>/icedos.nix`. A full IceDOS module (may declare `options`, `inputs`, `outputs.nixosModules`, `meta`) exactly like one from a repo (see [AGENTS.md](./AGENTS.md)). It **must** live in its own subfolder.

   ```text
   extra-modules/
   ├── my-tweak/
   │   └── default.nix     # plain NixOS module
   └── my-feature/
       └── icedos.nix      # full IceDOS module (options + outputs)
   ```

### Enabling modules

[Modules](#-nix-terms-in-plain-english) come from IceDOS [repositories](#-nix-terms-in-plain-english). Add the repo as a `[[icedos.repositories]]` entry and list what you want — dependencies come along automatically.

```toml
[[icedos.repositories]]
url = "github:icedos/apps"
modules = [ "btop", "steam" ]          # which modules to enable

# overrideUrl = "path:/abs/path/to/apps"  # use a local checkout (dev/testing)
# fetchDependencies = true                # pull each module's dependencies (default: true)
# fetchOptionalDependencies = false       # also pull optional dependencies (default: false)
# patches = [ "patches/apps.patch" ]      # patch the whole repo source
```

`url` accepts any Nix flake reference — `github:`, `gitlab:`, `git+https://…`, or a local `path:/…`, not just GitHub. (`overrideUrl` is a separate knob for *swapping* a repo's source during local testing while keeping its lock identity — you don't need it just to load a `path:` repo.)

### `config.toml` at a glance

Everything under `icedos` is IceDOS's own, checked settings. The top-level groups:

| Key | What it controls |
| --- | --- |
| `icedos.repositories` | Which module repos to load and which modules to enable (see above). |
| `icedos.system` | System-wide settings: `arch`, `version` (stateVersion), `nixpkgsChannel`, `allowUnfree`, `generations`, `packages`, `permittedInsecurePackages`, `loadHardwareConfiguration`, the binary `cache`, `gc` (auto-cleanup), the `toolset` (CLI + hooks), extra `channels`/`overlays`, and `buildVm`. |
| `icedos.users` | User accounts (home-manager integrated): password, groups, sudo, packages, … |
| `icedos.<category>.*` | Options exposed by the module repos you load, grouped by category — e.g. `icedos.applications.*` (apps like `btop`, `steam`), `icedos.hardware.*`, `icedos.desktop.*`, `icedos.tweaks.*`. Which categories exist depends on which repos you enable. |

Per-option details live in each module's sibling `config.toml`, and are searchable with `icedos configuration show options`.

### Channels & overlays

Register an extra [channel](#-nix-terms-in-plain-english) (another version of the package set) with `[[icedos.system.channels]]`. Its packages become reachable as `<channel>.<package>`:

```toml
[[icedos.system.channels]]
name = "stable"
url = "github:nixos/nixpkgs/nixos-26.05" # current stable when written
```

To instead **replace** a package's source everywhere (so a plain `obs-studio` resolves to the other source), use an [overlay](#-nix-terms-in-plain-english). `[[icedos.system.overlays.fromChannel]]` lifts named packages from a declared `channel` or straight from a flake `url`:

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

> **ℹ️ Note**
> Neither a channel nor an overlay installs anything by itself. A channel only makes a source *reachable* (as `<channel>.<package>`); an overlay only *swaps* a package's default source. They matter once the package is actually used — as a system package (`icedos.system.packages`), a user package (`icedos.users.<name>.packages`), or by a module. Reference a channel package by its `<channel>.<package>` name (e.g. `stable.obs-studio`); an overlaid package keeps its plain name (e.g. `obs-studio`) and is swapped everywhere it's already used, including indirect pulls like `mesa` from the graphics stack.

### Hardware configuration

Your machine's `/etc/nixos/hardware-configuration.nix` is loaded into the system automatically, so the essentials (filesystems, kernel modules, microcode) always apply and the machine stays bootable. This is `icedos.system.loadHardwareConfiguration`, **`true` by default**:

```toml
[icedos.system]
loadHardwareConfiguration = true   # default; set false to opt out
```

Only set it to `false` if you provide the equivalent hardware settings another way (a module or `extra-modules/`).

### Users

Declare user accounts under `icedos.users.<name>`. A minimal entry is just the name:

```toml
[icedos.users.alice]
sudo = true                       # in the wheel group (admin), default: true
extraGroups = [ "networkmanager" ]
packages = [ "firefox" ]          # apps just for this user
# defaultPassword = "change-me"   # login password (default: "1")
```

See [How do I set a password?](#how-do-i-set-a-password) for the security caveat.

### Try it in a VM

`icedos rebuild --build-vm` / `--run-vm` build a throwaway virtual machine of your configuration so you can test changes without touching the host. `[icedos.system.buildVm]` tunes that VM image — it never affects your real system:

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

### `.private.toml` (secrets & per-host values)

`.private.toml` has the same shape as `config.toml` and is **merged strictly** with it (lists are joined; defining the same key in both files is an error). Use it to keep secrets or machine-specific values out of your main, shareable config.

### Hooks (run commands around rebuilds/cleanup)

Run your own commands around the rebuild and garbage-collection lifecycle:

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

`preUpdate`/`postUpdate` only fire when `--update` is passed. You can also run them on their own — without a system rebuild — via `icedos rebuild --update-hooks` (handy for refreshing non-Nix things like `flatpak update`).

### Patches (without forking)

IceDOS can apply patches at three levels, all from your config, without forking anything:

- **Whole-repo** — `[[icedos.repositories]].patches`: patch an entire module repo's source.
- **Module-author input** — a module's `inputs.<name>.patches`: shipped by the module itself.
- **Consumer input** — `[[icedos.repositories.inputPatches]]`: patch a specific module's specific dependency from your config.

See [AGENTS.md](./AGENTS.md) for the full patching model.

## 🛠️ Usage: the `icedos` command

> **⚠️ While using IceDOS, don't run `nixos-rebuild` directly.** IceDOS wraps the build to manage its modular setup and saved state — use `icedos rebuild` instead. (`nixos-rebuild` is only for *leaving* IceDOS; see the [FAQ](#how-do-i-go-back-to-plain-nixos).)

Run `icedos` to list commands, or `icedos --tree` to list every command and subcommand.

### The essentials

New here? These cover almost everything:

| Command | What it does |
| --- | --- |
| `icedos rebuild` | Apply your `config.toml` changes to the system. |
| `icedos configuration show options` | Search what you can set (fuzzy, with paste-ready TOML). |
| `icedos configuration diff` | See what you've changed since the last rebuild. |
| `icedos configuration rollback` | Undo — restore the last working system **and** its `config.toml`. |
| `icedos doctor` | Health check with plain-language fixes. |
| `icedos gc` | Free up disk space. |

### Full command reference

| Command | Description |
| --- | --- |
| `icedos` | List top-level commands. |
| `icedos --tree` | Recursively list every command and subcommand. |
| `icedos rebuild` | Apply configuration changes to the system (see flags below). |
| `icedos configuration show options` | Fuzzy-search IceDOS options (fzf) with a paste-ready TOML snippet. |
| `icedos configuration show modules` | Browse modules — enabled / available / dependencies. |
| `icedos configuration diff` | Show how your working `config.toml` differs from the one that built the current system (your pending changes). |
| `icedos configuration rollback [--to <gen>] [--dry]` | Roll the system **and** `config.toml` back to a previous generation. `--to` targets a generation number (default: the previous one); `--dry` shows the plan without changing anything. Your current `config.toml` is backed up first. |
| `icedos doctor` | Health checklist: substituters, cache key, hardware config, store space, generations, gc, input freshness. |
| `icedos session reboot [uefi]` | Reboot, ignoring inhibitors and other users. Append `uefi` to reboot into firmware setup. |
| `icedos session logout` | Terminate all sessions for the current user. |
| `icedos session poweroff` | Power off, ignoring inhibitors and other users. |
| `icedos session suspend` | Suspend, ignoring inhibitors and other users. |
| `icedos nixf [dir]` | Format all `.nix` files in the current (or given) directory. |
| `icedos pkgs list` | List installed packages. |
| `icedos pkgs build` | Build a package derivation (`--path/-p`, `--run/-r`). |
| `icedos pkgs run <attr>` | Build a package and run it **without installing** (`--select/-s`, `--detach/-d`, `--insecure`). |
| `icedos repair` | Verify and repair the Nix store. |
| `icedos shell` | Spawn a `nix-shell` with an optimized env (`--insecure`). |
| `icedos gc` | Clean the Nix + home-manager store and profiles, and purge leftover build dirs. |

### `icedos rebuild`

```bash
icedos rebuild [FLAGS] [--build-args <extra rebuild args...>]
```

With no flags this is a `switch`: it builds your configuration and activates it now. After a switch that changed the kernel or initrd, IceDOS offers to reboot. Each successful rebuild also snapshots your `config.toml` and generated flake files into a timestamped `.cache/` folder whenever they change — that's what `configuration rollback` restores.

#### Action flags — *what kind of build*

| Flag | Effect | Typical use |
| --- | --- | --- |
| *(none)* | `switch`: build and activate now. | Day-to-day changes. |
| `--boot` | `boot`: prepare the new generation for next reboot, don't activate now. | Safer rollout; kernel changes. |
| `--build` | `build`: build but don't activate. | Check a config compiles before switching. |
| `--build-vm` | Build a bootable test VM (`result/bin/run-<hostname>-vm`). | Try the config in a VM without touching the host. |
| `--run-vm` | Same as `--build-vm`, then launch the VM. | Quick interactive VM test. |

#### Update flags — *what to refresh first*

| Flag | Effect | Typical use |
| --- | --- | --- |
| `--update` | Update everything (core, nixpkgs, module repos, and module-declared inputs) in one blanket bump. | Full update. |
| `--update-core` | Update IceDOS core, then re-run the command once. | Update IceDOS itself. |
| `--update-nixpkgs` | Update the nixpkgs channel only. | Newer packages without touching modules. |
| `--update-repos` | Pull new revisions of the IceDOS module repos (e.g. `apps`, `hardware`). Does **not** re-lock inputs declared *inside* those modules. | Get the latest modules. |
| `--update-repos-inputs` | Re-lock every module-declared dependency. The only way to bump inputs defined inside module files. | Bump module dependencies without bumping nixpkgs. |
| `--update-hooks` | Run only the `preUpdate`/`postUpdate` hooks and exit — no build, no activation. | Refresh non-Nix things (e.g. `flatpak update`). |

#### Behavior flags

| Flag | Effect |
| --- | --- |
| `--ask` | Ask for confirmation before applying (`nh os -a`). |
| `--logs` | Verbose logging + full traces — use when a build fails. |
| `--builder <host>` | Build the system on a remote host. |
| `--target <host>` | Deploy/activate the built system on a remote host (pairs with `--builder`). |
| `--nh-args ...` | Forward extra args to `nh os` (place after other flags; consumes until `--build-args`). |
| `--build-args ...` | Forward all remaining args to the final rebuild command. **Must be last.** |
| `--genflake-only` | *(advanced)* Generate and lock the state flake, then exit without building. |

#### Good to know

- **`--build-args` swallows the rest of the line** — put it last; everything after it is passed straight through.
- **`--nh-args` swallows args until `--build-args`** — place it after your other IceDOS flags. To pass both, use `--nh-args … --build-args …`.
- **Unknown flags fail fast** — an unsupported flag prints `Unknown arg: …` and exits `1`.
- **A failed build changes nothing** — your current system keeps running until a switch actually succeeds.

### Examples

```bash
# Standard apply
icedos rebuild

# Build only, no activation (does this config compile?)
icedos rebuild --build

# Prepare next boot, with verbose logs
icedos rebuild --boot --logs

# Full update + apply
icedos rebuild --update

# See pending changes, then apply
icedos configuration diff
icedos rebuild

# Something broke — undo the last change
icedos configuration rollback

# Health check
icedos doctor

# Run a package once, without installing it
icedos pkgs run firefox

# Build remotely and deploy to another machine
icedos rebuild --builder builder@192.168.1.2 --target deploy@192.168.1.3

# Format the Nix tree
icedos nixf .
```

## ❓ Troubleshooting & FAQ

### A rebuild failed — what do I do?

**Most failures are a mistake in your own `config.toml`** — a typo, a wrong option name or value, or a module not spelled the way its repo names it. Check that first, before assuming a deeper problem:

1. **Read the last lines of the error.** IceDOS validation messages name the exact option and file that's wrong, so the fix is usually one line.
2. **See what you changed.** `icedos configuration diff` shows how your working `config.toml` differs from the last build that worked — the culprit is almost always in there.
3. **Run `icedos doctor`** for common environment issues (cache, disk space, missing hardware config).
4. **Still stuck?** Re-run with `icedos rebuild --logs` for a full trace — and only then suspect a module bug worth reporting upstream.

**If your config checks out, it might not be you.** IceDOS follows the `nixos-unstable` channel by default for fresh packages, and every so often an upstream package fails to build there for a day or two. When the error is a *package build failure* rather than a config/validation error, it's often transient — try again later, or `icedos rebuild --update` once upstream ships a fix. Prefer stability over bleeding edge? You can point `icedos.system.nixpkgsChannel` at a stable release (e.g. `github:nixos/nixpkgs/nixos-26.05`) — but **the IceDOS modules are written and tested against the latest (unstable) nixpkgs**, so pinning stable can itself cause breakage (missing packages, renamed options). It's a tradeoff, not a guaranteed fix — treat it as an advanced move.

Your current system keeps running the whole time — a failed build activates nothing.

### I changed something and the system misbehaves

Undo it: `icedos configuration rollback` restores the last generation (system **and** `config.toml`), or `icedos configuration rollback --to <N>` targets a specific one. Add `--dry` to preview first. You can also pick an older generation in the boot menu at startup.

### How do I find out what a setting does, or what I can set?

`icedos configuration show options` — a fuzzy search over every option, with type and a paste-ready TOML snippet. Browse features with `icedos configuration show modules`.

### `doctor` says `hardware-configuration.nix` is missing

Regenerate it:

```bash
nixos-generate-config --show-hardware-config | sudo tee /etc/nixos/hardware-configuration.nix
```

### I'm running low on disk

`icedos gc` reclaims space (old generations + store garbage). Automatic weekly cleanup is on by default (`icedos.system.gc`).

### How do I set a password?

Each user's login password comes from `defaultPassword` under `[icedos.users.<name>]` (default: `1`). It's the password the account is **created** with — set it to something of your own:

```toml
[icedos.users.alice]
defaultPassword = "something-better"
```

> **⚠️ Security note:** `defaultPassword` sets the account's *initial* password (the one it's created with). Because IceDOS leaves `users.mutableUsers` at its default (`true`), you can change it afterwards with `passwd` and that change **persists** across rebuilds. But the value written here is plain text and world-readable in the Nix store, so treat the *initial* password as non-secret: **keep your config repo private** (put it in `.private.toml`), don't reuse an important password, and consider running `passwd` after first login to set the real one.

### How do I go back to plain NixOS?

IceDOS doesn't install anything outside the normal Nix store — it just manages generations like any NixOS system. To leave, write your own `/etc/nixos/configuration.nix` and switch to it with `sudo nixos-rebuild switch`, or simply keep booting a pre-IceDOS generation from the boot menu.

## 🤝 Contributing

Contributions welcome! To land your PR in the right place:

- **Framework core, CLI, or base modules** → this repository. Read [AGENTS.md](./AGENTS.md) first — it's the canonical reference for the architecture, conventions, and rules.
- **A specific app or specialized config** → its own repo in the [IceDOS organization](https://github.com/IceDOS) (see [How IceDOS is organized](#-how-icedos-is-organized)).
- **Your own modules** → the official repos are a *reference*, not a requirement. Publish your own IceDOS-style repository and load it with `[[icedos.repositories]]` — `url` takes any Nix flake reference (`github:`, `gitlab:`, `git+https://…`, a local `path:/…`, …), not just GitHub. You're never expected to upstream into the official repos.
- **🙏 Help of any kind is always welcome — and we'd love a logo! 🙏**

## 📜 License

IceDOS is free software licensed under the **GNU General Public License v3.0** — see [LICENSE](./LICENSE).
