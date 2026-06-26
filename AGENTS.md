# AGENTS.md — IceDOS **core** (the framework bible)

This is the **canonical reference for the entire IceDOS framework**. Every other
IceDOS repo's `AGENTS.md` points here. If you are an agent working anywhere in
IceDOS, read this first.

Upstream copy (authoritative): <https://github.com/IceDOS/core/blob/main/AGENTS.md>

> Paths in this file are **placeholders** (`/abs/path/to/<repo>`). IceDOS is consumed
> as flake inputs — most setups do **not** keep all repos as local siblings, and you may
> only have some of them checked out. Substitute your own checkout locations. Concrete,
> machine-specific paths belong only in a user's own config repo (named whatever they
> choose), never here.

---

## 1. What IceDOS is

An opinionated, gaming-focused **NixOS framework** spread across many small repos.
A user's machine is described almost entirely by a single **`config.toml`**; the
**`icedos` CLI** turns that into a NixOS system. You rarely write raw NixOS modules
as a user — you toggle and configure IceDOS modules from `config.toml`.

**Golden rule: never run `nixos-rebuild` directly.** IceDOS wraps it (state
generation, input masking, module resolution). Always go through `icedos rebuild`.

## 2. Repo map

| Repo | Kind | Purpose |
|---|---|---|
| **core** | framework | This repo. CLI (`icedos`), the `lib/` library, base modules, `build.sh`, flake-generation engine. The bible. |
| `apps` | module repo | ~70 application modules (`btop`, `steam`, `me3`, `sunshine`, …). Per-module dirs. |
| `hardware` | module repo | Kernel, graphics (`radeon`/`nvidia`), `pipewire`, `bluetooth`, bootloaders, `zram`, … |
| `desktop` | module repo | Cross-DE desktop glue: `gdm`, `stylix`, `displays`, portals, `entries`, `session`. |
| `gnome` | DE repo | GNOME desktop + extensions. Root `icedos.nix` + `modules/`. |
| `hyprland` | DE repo | Hyprland WM + plugins. Root `icedos.nix` + `modules/`. |
| `kde` | DE repo | KDE Plasma + in-tree KWin effects. `modules/`-only. |
| `cosmic` | DE repo | COSMIC desktop + upstream patches. `modules/`-only. |
| `tweaks` | module repo | Perf/behavior tweaks: `cachyos`, `gaming`, `kernel`, `dmem`. |
| `providers` | module repo | Extra package sources: `nur`, `jovian`. |
| `template` | starter | Minimal user config to fork when creating your own config root. Generic, no personal data. |
| *(your config)* | **user config** | The user's own config repo — **any name/location**, not an IceDOS-org repo. Holds `config.toml` + `flake.nix` + `extra-modules/` and drives everything. Created by forking `template`. |
| `cache-server` | infra | Self-hosted Nix binary cache (atticd + nginx + caddy). **Not** a module repo. |

## 3. Build pipeline (mental model)

```
<config-root>/config.toml (+ .private.toml)
        │  lib/load-user-config.nix   (parse TOML, strict-merge)
        ▼
icedos.* options                       modules/options.nix declares the schema
        │  lib/genflake.nix            (evalModules → validate every value)
        ▼
generated .state/flake.nix             (inputs masked, modules resolved & imported)
        │  build.sh                    (rsync to build dir)
        ▼
nh os <switch|boot|build|build-vm> path:.
```

- **`build.sh`** — the orchestrator. Parses flags, runs flake generation
  (`ICEDOS_STAGE=genflake nix eval … lib/genflake.nix`), refreshes `path:` inputs,
  formats the generated flake (`nixfmt`), then calls `nh`.
- **`lib/genflake.nix`** — evaluates the merged config through `evalModules`
  (this is where `validate.*` fires), resolves external repos, and emits the state
  flake as a Nix string (`flakeFinal`). Also exposes `evaluatedConfig` for
  `--export-full-config`.
- Core's own modules are auto-imported via `getModules "${inputs.icedos-core}/modules"`
  (see `lib/genflake.nix`). A user's `extra-modules/` is imported the same way.

## 4. The core library (`lib/`)

Exposed to every module as **`icedosLib`**.

| File | Key exports |
|---|---|
| `lib/options/helpers.nix` | The `mk*Option` family: `mkBoolOption`, `mkStrOption`, `mkStrListOption`, `mkNumberOption`, `mkEnumOption`, `mkIntBetweenOption`, `mkFloatBetweenOption`, `mkNullableOption`, `mkListOption`, `mkAttrsOfOption`, `mkSubmodule{,List,Attrs}Option`, `mkRecordOption`, `mkUsersOption`. |
| `lib/options/validate.nix` | `validate.{int,float,enum,str,nonEmpty,list,requires,abort}` — rich, path-aware error messages. |
| `lib/helpers.nix` | `getModules`, `scanModules`, `bash.prelude`, `bash.{blue,green,dim*}String`, `toolset.mk{Dispatcher,BashCompletion,ZshCompletion,FishCompletion}`, `generateAccent`, `users.{getNormal,genDefaults,mkGroupInjector}`, `pkgs.{mapper,mkConfig,overlaysFromChannel}`, `packaging.{extractAppImage,installDesktopEntry}`, `mkInputName`, flake-revision helpers. |
| `lib/icedos.nix` | `fetchModulesRepository`, `resolveExternalDependencyRecursively`, `modulesFromConfig` — the external-repo/dependency engine + input masking. |
| `lib/load-user-config.nix` | Parse `config.toml` + `.private.toml`, strict-merge (duplicate key across the two = error; lists concatenated). |
| `lib/common.nix` | `abortIf`, `filterByAttrs`, `findFirst`, `flatMap`, `generateAttrPath`, … |
| `lib/constants.nix` | `ICEDOS_*` env/stage constants, `INPUTS_PREFIX`. |
| `lib/logger.nix` | `log`/`logValue` — active when `ICEDOS_LOGGING=1`. |

`abortIf cond msg` → throws `msg` when `cond` is true, otherwise returns `true`
(so it chains with `&&` and `assert`). The real value goes in the `then` branch of
the caller, not in `abortIf`.

## 5. How an IceDOS module is structured

Canonical example — `apps/modules/btop/icedos.nix` (abridged):

```nix
{ icedosLib, lib, ... }:
{
  # 1. OPTIONS — defaults are read from the sibling config.toml, never hardcoded twice.
  options.icedos.applications.btop =
    let
      inherit (lib) readFile;
      inherit (icedosLib) mkBoolOption mkStrListOption mkStrOption;
      inherit ((fromTOML (readFile ./config.toml)).icedos.applications.btop)
        colorTheme diskExclusions speedInBytes;
    in
    {
      colorTheme      = mkStrOption     { default = colorTheme; };
      diskExclusions  = mkStrListOption { default = diskExclusions; };
      speedInBytes    = mkBoolOption    { default = speedInBytes; };
    };

  # 2. IMPLEMENTATION — a real NixOS module (gets config/lib/pkgs).
  outputs.nixosModules = { ... }: [
    ({ config, lib, pkgs, ... }:
      let inherit (config.icedos.applications.btop) colorTheme; in
      { environment.systemPackages = [ /* … */ ]; })
  ];

  # 3. METADATA — name is the dedup key; declare cross-repo deps here.
  meta.name = "btop";
}
```

Each module's sibling **`config.toml`** holds the option defaults:

```toml
[icedos.applications.btop]
colorTheme = ""
diskExclusions = []
speedInBytes = true
```

Optional module fields:
- `inputs = { foo = { url = "…"; patches = [ … ]; override = true; }; };` — extra flake
  inputs the module needs (merged into the generated state flake; `override` keeps the
  input name stable instead of namespacing it).
- `meta.dependencies = [ { url?; modules = [ … ]; } ];` and `meta.optionalDependencies`
  — other modules this one needs (pulled automatically).

### Two physical layouts

- **Per-module-dir repos** (`apps`, `hardware`, `desktop`, `tweaks`, `providers`,
  `claude-icedos`): each module is `modules/<name>/{icedos.nix,config.toml}`. The repo's
  `flake.nix` exposes them via `icedosLib.scanModules { path = ./modules; filename = "icedos.nix"; }`.
- **DE repos**: `gnome`/`hyprland` scan `./.` and have a **root `icedos.nix`** (the
  DE-wide options) plus `modules/<feature>/icedos.nix`; `kde`/`cosmic` scan `./.` with
  modules under `modules/` only.

### Core modules differ

`core/modules/*.nix` are **direct NixOS modules** (no `outputs.nixosModules` wrapper,
no `meta.name`) — they declare `options`/`config` straight up and are loaded by
`getModules`. The `icedos` CLI subcommands live here as
`icedos.applications.toolset.commands` (see `modules/toolset.nix`, `modules/rebuild.nix`).

### Module rules (enforced / expected)

- **Defaults: `config.toml` must mirror the `icedos.nix` defaults.** The TOML is the
  source of the default; fix the TOML to match, not the other way around.
- **Use `validate.*`/`mk*Option` for every option — no untyped options.** The
  validating wrappers (`mkEnumOption`, `mkIntBetweenOption`, `mkFloatBetweenOption`)
  **require `path` + `source` + `default`**; plain wrappers
  (`mk{Bool,Str,StrList,Number}Option`) just take `default`. `validate.*` fires on the
  module's own `config.toml` default too, so a bad default surfaces with the same rich
  error a user would get.
- **Module repos declare no `enable` bool** — listing a module in that repo's
  `modules = [ … ]` (`config.toml`) enables it, and its `meta.dependencies` are pulled in
  with it. The repo's `default` module is always active, so its `dependencies` /
  `optionalDependencies` load even when **not** listed (gated by `fetchDependencies` /
  `fetchOptionalDependencies`), not by the `modules` list.
- `genUserDefaults`/per-user populates belong in the always-loaded module that owns the
  path, not in an optional feature module.
- Prefer upstream `services.<name>` (NixOS or home-manager) over hand-rolled
  `systemd.user.services`/wrapper daemons.
- **Style:** inherit-fold any repeated parent (`inherit (lib) mkIf mkForce;`,
  `inherit (config.icedos.applications.x) …;`). Multi-level chain when intermediates
  repeat. Blank lines around multiline `let` bindings.
- **Format with `icedos nixf .`** (a core toolset command, `modules/toolset.nix`) after
  editing any `.nix`.

## 6. How config + dependencies load

In `config.toml`, each external repo is a `[[icedos.repositories]]`:

```toml
[[icedos.repositories]]
url = "github:icedos/apps"
overrideUrl = "path:/abs/path/to/apps"   # optional: local checkout for dev
fetchOptionalDependencies = true          # also pull optionalDependencies
modules = [ "btop", "steam", "me3" ]      # which modules to enable
```

- `lib/icedos.nix:resolveExternalDependencyRecursively` walks each module's
  `meta.dependencies` so you only list what you directly want; deps come along.
- A module's declared `inputs` become flake inputs of the generated state flake
  (patched via `pkgs.applyPatches` if `patches` is set). **Input masking** gives modules
  stable names (`inputs.<channel>`, `inputs.self`) regardless of how the repo was fetched.
- Channels/overlays: `[[icedos.system.channels]]` and
  `[[icedos.system.overlays.fromChannel]]` add extra nixpkgs instances/overlays.

## 7. Testing a change — the agent workflow

This is how you (the agent) validate edits **safely**. Paths are placeholders.

0. **Locate the config root.** It's the directory holding `config.toml` plus a `flake.nix`
   that calls `icedos.lib.mkIceDOS`. It can live anywhere and be named anything (it's the
   user's own repo, not an IceDOS-org repo). **If you can't find it, ask the user** —
   don't guess. Likewise, if the repo you need to edit isn't checked out locally, ask the
   user for its path or for permission to clone it (see §8).
1. **Point at your local checkout.** In the config root, set the target repo's
   `overrideUrl = "path:/abs/path/to/<repo>"` in `config.toml` (uncomment if present).
   For **core** edits, uncomment the `path:/abs/path/to/core` line in the config root's
   `flake.nix` instead. You may freely toggle these on/off.
2. **Build without activating** — the safe default:
   ```bash
   icedos rebuild --build        # evaluates + builds, NO activation, NO sudo
   icedos rebuild --build --logs # add --show-trace on eval/build failure
   ```
3. **Core edits need `--update-core`.** Anything under `core/` (especially `core/lib/`)
   needs `icedos rebuild --update-core --build` — the lock otherwise keeps the old core
   store snapshot *even with the path pin*. `path:` inputs for the other repos
   auto-refresh on every build, so no extra flag is needed for them.
4. **Inspect without building:** `icedos rebuild --export-full-config` writes the merged,
   evaluated config to `.state/.cache/full-config.json`.
5. **Activation is the user's call.** A plain `icedos rebuild` (`switch`) mutates the
   **live system**. Only run it on explicit user request; default to `--build`.
6. **Missing a binary?** Use `nix-shell -p <pkg> --run "…"` — don't report a tool as
   unavailable.

`icedos rebuild` flags (full list in `README.md`): `--boot`, `--build`, `--build-vm`,
`--run-vm`, `--update`, `--update-core`, `--update-nixpkgs`, `--update-repos`,
`--update-repos-inputs`, `--update-hooks`, `--export-full-config`, `--ask`,
`--builder <host>`, `--logs`, `--nh-args …`, `--build-args …` (must be last).

## 8. Hard rules (do not violate)

- **Never** `sudo nixos-rebuild` — only the `icedos` CLI.
- **Never** `git commit` / `stash` / `reset` / `pull` / `push` in any IceDOS repo. The
  user manages git between turns. Make the edits and stop.
- If a repo (or the config root) you need isn't checked out locally, **ask the user** for
  its path or for permission to `git clone` it — never clone, or assume a location,
  unprompted.
- **Never** add untyped options — always a `validate.*`/`mk*Option` helper with
  `path` + `source` where required.
- **Always** `icedos nixf .` after editing `.nix`.
- Don't remove safety checks or rewrite working shell scripts wholesale; be conservative.

## 9. Gotchas

- `core/` edits don't land without `--update-core` (lock snapshot), even with a path pin.
- A module's `config.toml` default must equal its `icedos.nix` default; reconcile by
  fixing the `config.toml`.
- Reuse an existing cross-package patch toggle if its name still fits — don't add a
  per-package duplicate.
- `writeShellApplication` bash is built `--disable-progcomp`: `compgen`/`complete` are
  missing at runtime (shellcheck still passes). Use `nullglob` arrays instead.
- hm-managed `xdg.desktopEntries` land in `~/.nix-profile/share/applications/` via a
  symlink chain inotify can't track — cache-on-startup daemons need a `home.activation`
  restart hook.
- Module repos have no `enable` option — membership in the repo's `modules` list is the
  switch. Exception: a module's `meta.dependencies` auto-load, so anything that is a
  (optional)dependency of the repo's always-on `default` module loads without being
  listed.
