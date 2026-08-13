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

`icedos` is a system-wide command (installed in `environment.systemPackages`), so run it
**from any directory** — it locates the config root itself (`icedos rebuild` internally
`cd`s to the baked `configurationLocation`). **Never `cd` into a repo checkout** — least of
all this `core` checkout — to build; a checkout is *not* the config root, and no `cd` is
needed regardless. And **never run a plain `icedos rebuild`** (that is a `switch`: it needs
`sudo` and mutates the live system). As an agent you only ever `icedos rebuild --build`; the
**user** performs the switch.

## 2. Repo map

| Repo | Kind | Purpose |
|---|---|---|
| **core** | framework | This repo. CLI (`icedos`), the `lib/` library, base modules, `build.sh`, flake-generation engine. The bible. |
| `apps` | module repo | ~70 application modules (`btop`, `steam`, `me3`, `sunshine`, …). Per-module dirs. |
| `hardware` | module repo | Kernel, graphics (`radeon`/`nvidia`), `pipewire`, `bluetooth`, `zram`, … |
| `desktop` | module repo | Cross-DE desktop glue: `gdm`, `stylix`, `displays`, portals, `entries`, `session`. |
| `gnome` | DE repo | GNOME desktop + extensions. Root `icedos.nix` + `modules/`. |
| `hyprland` | DE repo | Hyprland WM + plugins. Root `icedos.nix` + `modules/`. |
| `kde` | DE repo | KDE Plasma + in-tree KWin effects. `modules/`-only. |
| `cosmic` | DE repo | COSMIC desktop + upstream patches. `modules/`-only. |
| `tweaks` | module repo | Perf/behavior tweaks: `cachyos`, `gaming`, `kernel`, `dmem`. |
| `providers` | module repo | Extra package sources: `nur`, `jovian`. |
| `template` | starter | Minimal user config to fork when creating your own config root. Generic, no personal data. |
| *(your config)* | **user config** | The user's own config repo — **any name/location**, not an IceDOS-org repo. Holds `config.toml` + `flake.nix` + `modules/` + `configs/` and drives everything. Created by forking `template`. |
| `cache-server` | infra | Self-hosted Nix binary cache (atticd + nginx + caddy). **Not** a module repo. |

## 3. Build pipeline (mental model)

```
<config-root>/config.toml? (+ configs/*.toml)   (config.toml optional; root marked by flake.nix)
        │  lib/config/load-user-config.nix   (parse TOML, strict-merge)
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
  flake as a Nix string (`flakeFinal`). Also exposes `optionsDoc` / `modulesDoc`
  (the search index behind `icedos configuration search`) and `evaluatedConfig`.
- Core's own modules are auto-imported via `getModules "${inputs.icedos-core}/modules"`
  (see `lib/genflake.nix`). A user's module dirs (`icedos.system.extraModules`, default
  `["modules"]`) are imported the same way.
- User config beyond `config.toml` is autoloaded from the `icedos.system.extraConfigs`
  dirs (default `["configs"]`): every `*.toml` (including hidden `.*.toml`) is enumerated
  by `lib/config/config-files.nix` and strict-merged in, with `config.toml` as the base. Hidden
  `.*.toml` are a **gitignore-only** channel — their values are plaintext in the store (and
  rollback snapshots), so treat them as private, not secret. Both
  options are bootstrap paths — read from `config.toml` only (like `system.arch`), or their
  defaults (`configs`/`modules`) when there is no `config.toml` (which is optional; the root
  is marked by `flake.nix`). An
  extra config file opts out of loading with a top-level `enable = false` (default true);
  `config-files.nix` strips the key so it never leaks into the raw passthrough.
- **Raw NixOS passthrough** — any top-level TOML table that is **not** `icedos` is
  injected verbatim as a NixOS `config` body. It declares **no** IceDOS schema;
  nixpkgs' own module system types and validates each option. `genflake.nix` injects it
  as `{ config = builtins.removeAttrs userConfig [ "icedos" ]; }` next to the
  extra-modules import. Use it for plain option toggles no IceDOS module exposes
  (e.g. `[services.joycond] enable = true`, or `[home-manager.users.ice.programs.git]`
  for a user); it complements `modules/` for anything that needs real Nix
  (packages, `null`, `mkForce`, `lib.*`). Because the namespace is "everything except
  `icedos`", a stray top-level key (e.g. a `[applications.btop]` missing its `icedos.`
  prefix) fails loud as an unknown NixOS option — which is the intended safety net.

## 4. The core library (`lib/`)

Exposed to every module as **`icedosLib`**.

| File | Key exports |
|---|---|
| `lib/options/helpers.nix` | The `mk*Option` family: `mkBoolOption`, `mkStrOption`, `mkStrListOption`, `mkNumberOption`, `mkEnumOption`, `mkIntBetweenOption`, `mkFloatBetweenOption`, `mkNullableOption`, `mkListOption`, `mkAttrsOfOption`, `mkSubmodule{,List,Attrs}Option`, `mkRecordOption`, `mkUsersOption`. |
| `lib/options/validate.nix` | `validate.{int,float,enum,str,nonEmpty,list,requires,abort}` — rich, path-aware error messages. |
| `lib/bash.nix` | `bash.{prelude,exportSystemPath,genHelpFlags,mkFlags,blueString,dimBlueString,greenString,dimGreenString,purpleString,dimPurpleString,redString,dimRedString,yellowString,dimYellowString,configSet,gcTimerCheckSnippet,requireConfigOwner}` — runtime shell helpers shared between Nix-embedded scripts and `prelude.sh` (color vars + the `*String` builders that emit `$(...)`-interpolated escape sequences — the **only** way the dispatcher/completions add color to command help text; `log_*`/`die`/`is_help_flag`; `bash.requireConfigOwner` is the permission guard for executing the baked `configurationLocation` — capture `ORIG_ARGS=("$@")` before arg parsing and only use where `$0` is the leaf command script). Also `injectIfExists` (emits `(<file>)` when a path exists — used by genflake for `/etc/nixos/extras.nix`). |
| `lib/toolset.nix` | `toolset.mk{Dispatcher,BashCompletion,ZshCompletion,FishCompletion}` — the CLI dispatcher generator (used to build `icedos` itself and every subcommand attrset that has children) + the per-shell completion generators. |
| `lib/users.nix` | `users.{getNormal,genDefaults,mkGroupInjector}`. |
| `lib/color.nix` | `color.hexToRgbInts`. |
| `lib/pkgs.nix` | `pkgs.{mapper,mkConfig,overlaysFromChannel}`. |
| `lib/packaging.nix` | `packaging.{extractAppImage,installDesktopEntry}` — shell-snippet builders for `installPhase`/`postFixup` bodies in icedos `package.nix` files. |
| `lib/scan.nix` | `getModules`, `scanModules`, `hasModule` — module discovery. `hasModule` aborts on a malformed call (no `name` and no `modules`, or an empty `modules = []`) — always pass a `name` or a non-empty `modules` list. |
| `lib/inputs.nix` | `moduleInputName` (sub-flake-relative path of a module-declared input — `"<sub-flake>/<input>"` — the string-context twin of `_getModuleInputs`; a **breaking change** from the old top-level name), `moduleSubFlakeName`, `mkInputName`, flake-revision helpers (`_resolveFlakeRevisionLocked` — pure tail given a lock + node key — and `_resolveFlakeRevisionNested`/`_resolveFlakeRevisionNestedLocked` — two-hop lookup for a sub-flake input, the latter driven directly by the tests), `_parseFlakeUrl`, `_getModuleKey`, `freshInputs`. |
| `lib/icedos.nix` | `fetchModulesRepository`, `resolveExternalDependencyRecursively`, `modulesFromConfig` — the external-repo/dependency engine + input masking. Stamps every module's emitted NixOS config with `<repo>#<module>` provenance (`setDefaultModuleLocation`) so nixpkgs eval/type/conflict errors name the source module instead of an anonymous generated location. Emitted module values are deduplicated (`_dedupeNixosModules`): each arrives wrapped in a `setDefaultModuleLocation` shim (`{ _file; imports = [ m ]; }`), and nixpkgs keys modules by `_file`/position, so two IceDOS modules emitting the SAME value would load it twice — core unwraps the shim (only pure `{ _file; imports = [ m ]; }` shims), keys the payload with `_opaqueOrKey` (a structural key, every shape tagged by `kind` (list/attrs/path/str/bool/int/float/null) so `{ }`≠`[ ]`, a path≠a plain string, and `42`≠`42.0`; functions, derivations, and `_type`-bearing property wrappers — `mkIf`/`mkMerge`/`mkForce`/option types — and anything containing them are opaque `null` and never merged; derivations are detected via `type` alone and never forced, since a derivation is cyclic and `drvPath` access can trigger instantiation, and `_type` wrappers are never descended into because the module system drops their unforced branches (`mkIf false`); depth-capped so any other cyclic value degrades to opaque instead of `max-call-depth exceeded`; and wrapped in `tryEval`, which degrades values that `throw`/`assert` when forced — an `abort`, missing attribute, or type error still propagates), and keeps the first occurrence per key at both the per-source flatten (`_extractNixosModules`) and the final external+extra combine (`modulesFromConfig.nixosModules`). Only the `nixosModules` output is deduplicated — `modulesFromConfig.options` (the option-doc index) is intentionally left as-is, and option-declaring payloads are opaque (`lib.mkOption` produces `{ _type = "option"; … }`), so duplicate option declarations still fail loudly rather than being silently merged. The common `inputs.<x>.nixosModules.default` case (a path) was already handled by nixpkgs' own identical-path dedup; this closes the identical-attrset-config-value gap (e.g. a shared function-free module emitted by two modules, or a future `nixosModules.default` that is a pure attrset). `modulesFromConfig` also exports `loadedModules` (repo url → module names, the fully-resolved set) which `genflake.nix` injects into the module system as the read-only `icedos.system.loadedModules`. Extra-modules share this: an `icedos.nix` extra-module is labeled `config#<name>`; a plain `default.nix` extra-module is imported by path, so it already carries its real on-disk location. **Module `lib` field contributions:** any `icedos.nix` module — a configured repo's module or a config-root extra module — may extend `icedosLib` with a top-level `lib` field, usually `lib = import ./lib.nix { inherit icedosLib lib; };`. Core folds every contribution into the module-facing lib via `_mergeModuleLibs` (guarded: non-attrset contribution or a duplicate name = a named error). The merge is **two-phase**: during dependency resolution module files are imported with the **base** lib (phase 1 — only `meta` + contributions are forced); once the closure is known, `modulesFromConfig` computes `closureLib = _mergeModuleLibs (deduped ++ extraModulesP1)` over the **fully-resolved closure** and re-imports each module file's outputs (`externalOutputs`) plus the extra modules (`extraModulesP2`) with that merged lib (phase 2). The generated flake's `outputs.icedosLib` **and** `specialArgs.icedosLib` both reuse `modulesFromConfig.closureLib`, so module files and the module system share one merged lib within a single flake evaluation; `repl-context.nix` reads `flake.icedosLib`. A repo pulled in as a dependency — e.g. desktop, a **required** dep of every DE repo — still contributes its helpers because its always-loaded `default` module carries the `lib` field. A contribution file must live inside the kept set of `genflake.nix`'s `configRootKeep`/`configRootKeepDirs` (extra-module/config dirs, declared patches — a `builtins.path` keep-list, **not** git tracking): genflake imports config live, the build stage from the filtered snapshot, so an import that escapes the kept set evaluates at genflake and then fails at build with a bare missing-path error. Upgrade note: the old magic auto-discovery of a config-root `lib.nix` is gone — a user extends `icedosLib` from their own config by adding a `lib` field to one of their extra modules instead. Tradeoffs (inherent): each external module file is imported twice per stage (meta + contributions in phase 1, outputs in phase 2); the merge is evaluated at genflake stage, build-stage `specialArgs`, and repl (fresh per-stage evaluations, but `flake.icedosLib` shares one value with `specialArgs`). The bare `icedosLib` name stays a static set — the merge is a lazy member, so the `default.nix` probe (`attrNames (import icedos.nix …)`) never forces it. A contribution sees only the base lib (passing the merged lib would recurse); repo-to-repo composition happens at the module layer. |
| `lib/config/load-user-config.nix` | Parse `config.toml` + every `configs/*.toml` (enumerated by `lib/config/config-files.nix`), strict-merge (duplicate scalar key across files = error; lists concatenated). Top-level `icedos` is schema-validated by `modules/options.nix`; **every other top-level table is applied as raw NixOS config** (see passthrough below). |
| `lib/config/extra-options.nix` | `extraOptions.{marker,declare,inject}` — translates a user's `[extraOptions]` TOML table into real NixOS option declarations + genflake-stage value injection (see §6). |
| `lib/config/config-files.nix` | Bare `configRoot: [{rel;content;}]` — the ordered, pre-parsed config set (`config.toml` + each enabled `configs/*.toml`), shared by `load-user-config.nix` and `modules/options.nix` so both load the identical set. Applies the per-file `enable = false` opt-out and strips the `enable` key. |
| `lib/common.nix` | `abortIf`, `filterByAttrs`, `findFirst`, `flatMap`, `generateAttrPath`, … |
| `lib/constants.nix` | `ICEDOS_*` env/stage constants, `INPUTS_PREFIX`, `ENABLE_LOGGING` (either `ICEDOS_LOGGING=1` in the env **or** the `enableLogging` flag baked into the generated flake's lib import at genflake time — so `--logs` stays active for the whole nixos build even though the env var doesn't reach it). |
| `lib/logger.nix` | `log`/`logValue`/`logAttrKeys` — active when `ENABLE_LOGGING` is set. |

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

  # 2. IMPLEMENTATION — a real NixOS module (gets config/lib/pkgs). The whole
  #    `outputs.nixosModules` function is called with the module's repo base url
  #    as `repoUrl` — use it for `icedosLib.hasModule { inherit config repoUrl; name = "…"; }`
  #    to recognise a same-repo sibling module (and `hasModule { inherit config;
  #    url = "github:icedos/<repo>"; … }` for a cross-repo one).
  outputs.nixosModules = { repoUrl, ... }: [
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
- `inputs = { foo = { url = "…"; patches = [ … ]; }; };` — extra flake
  inputs the module needs. Each declaring module gets one thin **input-namespace
  sub-flake** (`icedos-<repo>_<module>`, a **content-addressed** `/nix/store/<hash>-<name>-subflake`
  flake.nix — no per-sub-flake files are written to disk; the sub-flake's text is
  `pkgs.writeTextDir`'d + `builtins.path`'d at genflake time, so a decl change flips the
  store path and a plain `nix flake lock` re-locks the sub root — and declared as a single
  `path:` store input of the generated state flake); the module's declared inputs live inside it. The input's
  sub-flake-relative path is computed by `icedosLib.moduleInputName { repo; module; input; }`
  (`"<sub-flake>/<input>"` — the string-context twin of `_getModuleInputs`), and
  each input is exposed to every enabled module's `outputs.nixosModules` under the
  bare declared name `foo`. A module input's `follows` — at ANY depth: the
  input's own `follows`, or anywhere in its `inputs` tree (a nested two-level
  follows is legal flake syntax) — may only target an ambient top-level input
  of the generated flake (nixpkgs, home-manager, icedos-config,
  icedos-core, icedos-state, a configured channel, a url-mode overlay, an
  extraFlake, or a sibling input of the same module);   cross-module `follows` —
  e.g. built from `moduleInputName`, which now yields a sub-flake-relative path —
  abort at genflake naming the declarer. An input that declares both `url` and
  `follows` also aborts (nix rejects a flake input with both a flake reference
  and a follows attribute, so the sub-flake could not lock); a url-less
  follows-only input stays legal. Two modules declaring the same bare input
  name with **different** urls also abort (naming both declarers); the same url but
  **different** patch sets aborts too, since the two would realise different trees
  and the masked set (`listToAttrs` keyed by the bare name) would silently pick one.
  (Two byte-identical but separately-vendored patch files still count as different
  patch sets — the store paths differ — so an author should share one patch file,
  not copy it.) A legacy
  `override = true` key is accepted and ignored (naming is now always namespaced).
  **Shadowing:** a `follows` whose first segment is also a declared sibling input
  of the same module resolves to that declared input, *not* the ambient one — e.g.
  a module that declares its own `nixpkgs` input makes any `follows = "nixpkgs"`
  on its other inputs pull in the module's `nixpkgs`, not the generated flake's
  (a slot is not emitted for a name the module already declares, so the follows
  targets the sibling inside the sub-flake).
- `meta.dependencies = [ { url?; modules = [ … ]; } ];` and `meta.optionalDependencies`
  — other modules this one needs (pulled automatically).

### Two physical layouts

- **Per-module-dir repos** (`apps`, `hardware`, `desktop`, `tweaks`, `providers`): each module is `modules/<name>/{icedos.nix,config.toml}`. The repo's
  `flake.nix` exposes them via `icedosLib.scanModules { path = ./modules; filename = "icedos.nix"; }`.
- **DE repos**: `gnome`/`hyprland` scan `./.` and have a **root `icedos.nix`** (the
  DE-wide options) plus `modules/<feature>/icedos.nix`; `kde`/`cosmic` scan `./.` with
  modules under `modules/` only.

### Core modules differ

`core/modules/*.nix` are **direct NixOS modules** (no `outputs.nixosModules` wrapper,
no `meta.name`) — they declare `options`/`config` straight up and are loaded by
`getModules`. The `icedos` CLI subcommands live here as
`icedos.system.toolset.commands` (see `modules/toolset.nix`, `modules/rebuild.nix`).

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
- **Reference contributed `icedosLib` helpers only inside `outputs.nixosModules`
  bodies.** Module files are imported twice: phase 1 (dependency resolution)
  passes the **base** `icedosLib` and forces only `meta`; phase 2 re-imports the
  file with the closure-aware merged lib and forces `outputs`. A helper from a
  repo's `lib.nix` (e.g. `icedosLib.desktop.*`) is therefore only guaranteed to
  resolve inside `outputs.nixosModules` — not in `meta` or in file-top-level
  code forced at import. Core-base helpers are fine anywhere.
- **`icedosLib.hasModule` needs the real NixOS module `config`** — it reads
  `config.icedos.system.loadedModules`. Call it inside an `outputs.nixosModules`
  body with the module-system `config`, never against the raw TOML-derived
  config a module file's top level/meta receives at import (it has no
  `icedos.system.loadedModules`).
- **Per-user options must always be materialised with `genDefaults`** — see
  *Per-user (`users`) options* below. The populate belongs in the always-loaded module
  that owns the path, not in an optional feature module.
- Prefer upstream `services.<name>` (NixOS or home-manager) over hand-rolled
  `systemd.user.services`/wrapper daemons.
- **Style:** inherit-fold any repeated parent (`inherit (lib) mkIf mkForce;`,
  `inherit (config.icedos.applications.x) …;`). Multi-level chain when intermediates
  repeat. Blank lines around multiline `let` bindings.
- **Format with `icedos nixf .`** (a core toolset command, `modules/toolset.nix`) after
  editing any `.nix`.

### Per-user (`users`) options

A per-user option is an `attrsOf submodule` keyed by username —
`mkUsersOption {...}` (≡ `mkSubmoduleAttrsOption { default = {}; } {...}`). Its default
is `{}`, so **it populates no user by itself**: field defaults only materialise for a
user once that user's key exists in the attrset.

**Rule 1 — always materialise with `genDefaults`.** The always-loaded module that owns
the path must fill every normal user, in its `outputs.nixosModules` config:

```nix
icedos.<path>.users = icedosLib.users.genDefaults { inherit (config.icedos) users; };
```

`genDefaults` (`lib/users.nix`, `users.genDefaults`) writes `{ <normalUser> = {}; … }`
for every `isNormalUser`, which triggers each submodule's own field defaults; explicit
`[icedos.<path>.users.<name>]` TOML stanzas still merge on top (submodule attrs merge).
**Without it**, a user must hand-write an empty per-user stanza just to get defaults, and
any consumer that reads `users.${name}` without an `or null` guard hard-errors on eval.
Reference callers: `core/modules/git.nix`, `apps/modules/codium/icedos.nix`,
`desktop/modules/default/icedos.nix`, `gnome/icedos.nix`(via desktop).

**Rule 2 — nest a sub-feature under the parent user submodule ONLY when it is genuinely
part of that parent; a standalone module keeps its OWN `.users` tree and is *consumed*.**
- **Nest** when the feature belongs to one parent (e.g. `climit` is part of claude-code):
  the feature's module contributes a **nested** sub-option — declares
  `options.icedos.<parent>.users = mkSubmoduleAttrsOption <args> { <feature> = {…}; }` —
  rather than a parallel `icedos.<parent>.<feature>.users`; the always-loaded parent's
  `genDefaults` materialises it (see Rule 2a for the `default` caveat). Also applies to the
  DE per-user contributions (`gnome`, `cosmic` → `desktop.users.<n>.…`).
- **Do NOT nest** a standalone module that several parents use. `peon-ping` is its own apps
  module (`icedos.applications.peon-ping.users.<n>`) with its own upstream package;
  claude-code and opencode **consume** it — they read `config.icedos.applications.peon-ping.users`
  to detect it (`builtins.hasAttr user peonPingUsers` / `peonPingUsers != {}`) and wire their
  own hooks/plugins — they do not own its config.

| Feature | Path | Materialised by |
|---|---|---|
| climit (part of claude-code) | `applications.claude-code.users.<n>.climit` | claude-code `default` (nested) |
| gnome per-user | `desktop.users.<n>.gnome` | `desktop/default` (nested) |
| cosmic per-user | `desktop.users.<n>.cosmic` | `desktop/default` (nested) |
| peon-ping (standalone module) | `applications.peon-ping.users.<n>` | peon-ping itself (own `genDefaults`) |

(Option-path segments are **kebab-case** — `peon-ping`, not `peonPing`; `-` is a valid Nix
identifier char, so it works unquoted in declarations, `.` selection, and the `?` operator.
Last-level leaf options keep their existing casing, e.g. `defaultPack`, `fontSize`.)

> **⚠ Rule 2a — exactly ONE declaration per path may set `default`.** When two modules
> declare the same `attrsOf submodule` option (e.g. `default` + `climit` both declaring
> `claude-code.users`), nixpkgs must `typeMerge` them. Two declarations that **both**
> carry `default = {}` do **not** merge — eval dies with
> `The option '…' is already declared in '…'` (surfacing as a `head`/`assertions` trace).
> The fix: only the **always-loaded owner** uses `mkSubmoduleAttrsOption { default = {}; }`
> (or `mkUsersOption`); every **child** contribution omits it — `mkSubmoduleAttrsOption { } {…}`.
> One default + N no-default children merge cleanly (the child still gets its per-field
> defaults; it only forgoes the attrset-level `{}`). This mirrors the shipped
> `desktop.users` pair: `desktop/default` uses `mkUsersOption` (has default), `startup`
> uses `mkSubmoduleAttrsOption { }` (no default).

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
- A module's declared `inputs` live inside its per-module **input-namespace
  sub-flake** (a **content-addressed** `/nix/store/<hash>-<name>-subflake/flake.nix` — the
  sub-flake text is `pkgs.writeTextDir`'d + `builtins.path`'d at genflake time, never
  written to disk under `.state/`, and declared as a single `path:` store input of the
  generated state flake — rewired to
  the parent's ambient inputs via `inputs.<sub>.inputs.<slot>.follows`; patched
  inputs become a `path:` node for the realised tree plus an upstream `<input>_source`
  node — see §5). `genflake.nix` emits the sub-flakes directly as the generated
  `flake.nix`'s root `path:` inputs (no `subflakes.json` export — build.sh derives
  sub-flake roots and their declared inputs from the resulting `flake.lock`), and
  `--update-repos-inputs` refreshes
  sub-flake inputs via `nix flake update "<sub>/<input>" --refresh`. All lock steps run
  against a **detached** copy of the state flake — `build.sh` rsyncs `.state` into a temp
  dir (`mktemp`) and copies only the resulting `flake.lock` back, because a git flake
  refuses to lock/refresh untracked `path:` inputs (`nix` says "git add ..."): locking in
  `.state` would force every new or changed module input to be staged/committed. Sub-flakes
  are never written as files and never committed; a changed sub-flake materializes a new
  content-addressed store path, so a plain `nix flake lock` picks up new/edited module
  inputs (preserving unchanged nested pins). Their nested inputs are inlined into the parent
  `flake.lock`, so only that one file needs syncing. **Input masking**
  gives modules stable names (`inputs.<channel>`, `inputs.self`) regardless of how the
  repo was fetched.
- Channels/overlays: `[[icedos.system.channels]]` and
  `[[icedos.system.overlays.fromChannel]]` add extra nixpkgs instances/overlays.

### Declaring user options from TOML: `[extraOptions]`

A user can declare their **own** typed NixOS options without writing a Nix module —
purely from `config.toml` / `configs/*.toml`. `lib/config/extra-options.nix` translates the
`[extraOptions]` table into real option declarations:

- A node **with a `type` key** is a **leaf** — one declared option at its full dotted
  path from the config root. Meta keys: `type`, `default`, `description`, plus the
  type's own constraints (`min`/`max`, `choices`, `minLength`/`maxLength`/`regex`).
- A node **without `type`** is a **namespace** — every key must be another table.
- `[extraOptions.icedos.applications.myapp]` declares `options.icedos.applications.myapp`;
  `[extraOptions.services.myapp]` declares `options.services.myapp`. Non-`icedos.*`
  paths are allowed and merge with nixpkgs / IceDOS options, but redeclaring an
  existing option path is a loud nixpkgs "already declared" error in practice: every
  custom option carries a `description`, and nixpkgs rejects two declarations that
  both set `default`/`description`/`example`/`apply` regardless of type compatibility.
  An option without a schema `default` follows the standard nixpkgs contract: resolve
  the user value if set, else "was accessed but has no value defined" when read
  (rendered as null in the search index) — except `list`/`attrs`/`record`, below.

Values reach the running system by the same routes as ordinary config — `icedos.*`
options through the per-file `config.icedos` imports in `modules/options.nix`, and
non-`icedos.*` options through the raw NixOS passthrough. At the **genflake stage** that
passthrough is absent, so `inject` re-applies the declared non-`icedos.*` values per-path
(`config.<path> = <raw value>` read from the merged user config) — that's what makes the
search index show real values instead of null. Options are stamped with `extraOptions`
marker in their `declarations`, which genflake's optionsDoc keep-filter matches on
(`isExtraOption`) to include non-`icedos.*` custom options in the index. The
`extraOptions` table itself is excluded from the raw NixOS passthrough (it holds
schema, not values).

`evaluatedConfig` (a `toJSON` of the whole genflake-stage eval) is not tryEval-rescuable
and would throw if forced on a no-default custom option the user never sets — nothing
in-tree forces it (build.sh only consumes `optionsDoc`/`modulesDoc`/`userConfigRaw`, and
the index's `renderValue` tryEvals each option individually), so that stays latent.

Example (`configs/*.toml`):

```toml
[extraOptions.services.myapp]        # namespace
  [extraOptions.services.myapp.enable]
    type = "bool"
    default = true
    description = "Enable myapp"

[services.myapp]                      # value, set like any other config
enable = false
```

Supported `type`s mirror the `mk*Option` family: scalars `bool`, `string`,
`nonEmptyString`, `lines`, `number` (int or float), `int`, `float`; `enum` (with
`choices`); lists `stringList`, `numberList`, `intList`, `floatList`, or a generic
`list`; `attrs` (map of a leaf type); and `record` (arbitrary nested schema, like a
submodule). `list`/`attrs` require an `item` descriptor (a bare scalar name such as
`"string"`, or a descriptor table with its own `type`/constraints/`enum`/`record`);
`record` requires a `fields` table of typed descriptors. Unset `list`/`attrs` leaves
with no schema default resolve to `[]`/`{}` (nixpkgs' `type.emptyValue` —
`mergeDefinitions`' `else if type.emptyValue ? value then type.emptyValue.value`)
instead of erroring; an unset `record` resolves to `{}` whose no-default fields then
throw individually. The `emptyValue` branch requires a 2026-era nixpkgs (core's
flake.lock; the 25.11-era `nix-instantiate --find-file nixpkgs` root channel lacks it
and would throw) — the tests pin the modern behavior. A bad schema `default` **and** a
bad injected user value both fail loudly at genflake with a rich, path-aware error:
constraint-carrying types (string/number/int/float/enum) go through their
`validate.*` validator, every other type through `leafType.check` (covers bool /
list / attrs shapes nixpkgs would otherwise only check lazily when the option is
read). Composite values are checked **one level deep** at that point too:
`list`/`*List` elements and `attrs` values against their `item` type, and `record`
values against their declared `fields` (undeclared fields are rejected) — so a bad
element/field surfaces at genflake, not at build time. Nested `item`/`field`
sub-structures beyond that first level are still validated lazily by nixpkgs when
the option is read.

## 7. Testing a change — the agent workflow

This is how you (the agent) validate edits **safely**. Paths are placeholders.

**TL;DR:** edit the repo source → wire it into the user's `config.toml` (point `overrideUrl`
at your checkout, and enable/configure the module you touched) → run `icedos rebuild --build`
**from wherever you are**. No `cd`, no `sudo`, no activation. You never switch — the user does.

Core lib tests run as a flake check: `nix flake check` in the core repo evaluates
`tests/tests.nix` and fails if any result is not "ok" (or the eval throws).
Core's `flake.lock` is gitignored and generated on demand (it is a library flake
consumed via flake inputs, and a committed lock would pin core's own inputs —
`nixpkgs`, `cache-server` — for consumers without `follows`).

> **First install:** On a fresh machine with no built system, `icedos` isn't on PATH yet.
> Run `nix develop` in the config root to enter the dev shell, which provides a limited
> `icedos` command (only `rebuild` subcommand, no `configuration`/`status`/etc.). After the
> first system install, the full `icedos` CLI is available everywhere.

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
4. **Inspect without building:** `icedos configuration search --options` browses every
   option with its effective value (regenerates `.state/.cache/options-doc.json` on
   demand).
5. **You never activate — the user does.** A plain `icedos rebuild` is a `switch`: it needs
   `sudo` and mutates the **live** system. Don't run it, don't try to (you have no `sudo`),
   and don't otherwise touch the running Nix system. Always stop at `--build` and hand off to
   the user to switch.
6. **Missing a binary?** Use `nix-shell -p <pkg> --run "…"` — don't report a tool as
   unavailable.

`icedos rebuild` flags (full list in `README.md`): `--boot`, `--build`, `--build-vm`, `--dry`/`-n`/`--dry-run`,
`--run-vm`, `--update`, `--update-core`, `--update-nixpkgs`, `--update-repos`,
`--update-repos-inputs`, `--update-hooks`, `--ask`,
`--builder <host>`, `--logs`, `--nh-args …`, `--build-args …` (must be last).

## 8. Hard rules (do not violate)

- **Never** `sudo nixos-rebuild`, and **never** a plain `icedos rebuild` (`switch`) — it
  needs `sudo` and mutates the live system. Agents only ever `icedos rebuild --build`
  (no `cd`, no `sudo`, no activation); the user performs the switch.
- **Never** `git commit` / `stash` / `reset` / `pull` / `push` in any IceDOS repo. The
  user manages git between turns. Make the edits and stop.
- If a repo (or the config root) you need isn't checked out locally, **ask the user** for
  its path or for permission to `git clone` it — never clone, or assume a location,
  unprompted.
- **Never** add untyped options — always a `validate.*`/`mk*Option` helper with
  `path` + `source` where required.
- **Always** `icedos nixf .` after editing `.nix`.
- **Keep docs in lockstep with code.** Whenever a feature, option path, module layout,
  default, or CLI surface changes — or you learn something worth recording — update the
  relevant `AGENTS.md` (this bible for framework-wide rules; the repo's own `AGENTS.md`
  for repo-specific detail) in the **same** change. Stale docs are treated as bugs; a
  change that alters behaviour but not its docs is incomplete.
- Don't remove safety checks or rewrite working shell scripts wholesale; be conservative.

## 9. Gotchas

- `core/` edits don't land without `--update-core` (lock snapshot), even with a path pin.
- A module's `config.toml` default must equal its `icedos.nix` default; reconcile by
  fixing the `config.toml`.
- Reuse an existing cross-package patch toggle if its name still fits — don't add a
  per-package duplicate.
- `writeShellApplication` bash is built `--disable-progcomp`: `compgen`/`complete` are
  missing at runtime (shellcheck still passes). Use `nullglob` arrays instead.
- `home-manager.useGlobalPkgs = true` (set in `modules/users.nix`): hm user envs use the
  system pkgs — system `nixpkgs.config` (allowUnfree, permittedInsecurePackages) and
  `nixpkgs.overlays` apply in user envs; per-user hm `nixpkgs.*` options are disabled.
- hm-managed `xdg.desktopEntries` land in `/etc/profiles/per-user/<user>/share/applications/`
  (via `home-manager.useUserPackages`) through a symlink chain inotify can't track —
  cache-on-startup daemons need a `home.activation` restart hook.
- Module repos have no `enable` option — membership in the repo's `modules` list is the
  switch. Exception: a module's `meta.dependencies` auto-load, so anything that is a
  (optional)dependency of the repo's always-on `default` module loads without being
  listed.

## 10. Extending the `icedos` CLI

Any module adds subcommands by appending to `icedos.system.toolset.commands`
(core modules do it directly; repo modules do it inside `outputs.nixosModules`). A
command is a `toolsetCommandType` submodule (`modules/options.nix`):

| Field | Type | Meaning |
|---|---|---|
| `command` | string (required) | subcommand name; must match `[a-zA-Z0-9_-]+`. |
| `help` | string (required) | one-line help, shown in the parent listing and `icedos --tree`. |
| `script` | lines | inline bash. **Auto-prefixed with `bash.prelude`** (`modules/toolset.nix`), so `log_ok`/`log_warn`/`log_fail`/`log_info`/`log_step`/`die`/`is_help_flag` + colour vars are available. |
| `bin` | string | absolute path to an executable instead of `script` (e.g. a `pkgs.writeShellScript`). |
| `commands` | list | nested subcommands — arbitrarily deep. |
| `completion.files` | bool | offer file-path completion for this leaf's arguments. |
| `completion.command` | string | shell snippet printing newline-separated candidates for this leaf's arguments (e.g. generation numbers, cached option names). Runs at completion time; must never block or fail loudly. |

Asserted in `modules/toolset.nix`: a node with `commands` must **not** also set
`script`/`bin` (a branch dispatches, a leaf runs); a leaf sets exactly one of the two.
Nesting just nests `commands`; branch nodes auto-dispatch and render an indented help
tree. Example — `icedos weather now`:

```nix
icedos.system.toolset.commands = [{
  command = "weather";
  help = "weather utilities";
  commands = [{
    command = "now";
    help = "print current weather";
    script = ''curl -s "wttr.in/?format=3"'';   # prelude already injected
    completion.files = false;
  }];
}];
```

- **Completions are free.** bash/zsh/fish completion files are generated from the whole
  command tree (`toolset.{mkBashCompletion,mkZshCompletion,mkFishCompletion}` →
  `/share/{bash-completion,zsh,fish}/…`). Authors never write completion code.
- **Reference tools by store path.** Command scripts run from `environment.systemPackages`,
  where the build PATH (`jq`, `nh`, `nixfmt`, …) is **absent** — splice `${pkgs.jq}/bin/jq`,
  not bare `jq`. (Only `build.sh` itself runs with those on PATH.)
- **No `compgen`** — `writeShellScript` bash lacks it (see §9); parse args with
  `while`/`case` + `nullglob` arrays.
- **Two built-in extension points:**
  - `icedos.system.toolset.sessionCommands` (list, default `[]`) — concatenated into
    the `session` command's children, so a module can add `icedos session <x>` without
    redeclaring the group (`modules/toolset.nix`).
  - `icedos.system.toolset.desktopEntries` (bool, default `false`) — when true, the
    session lifecycle actions (reboot, reboot-to-UEFI, logout, poweroff, suspend) are also
    installed as `xdg.desktopEntries`. Modules adding session actions gate their own
    entries on the same flag.

## 11. Hook authoring contract

`icedos.system.toolset.rebuild.hooks.{preRebuild,postRebuild,preUpdate,postUpdate}`
and `icedos.system.gc.hooks.{preGc,postGc}` are lists of shell snippets. Each
snippet is compiled to its **own** `pkgs.writeShellScript` with `bash.prelude` prepended
(`modules/rebuild.nix`, `modules/nh.nix`), so it runs in a fresh shell with the same
helpers a command gets (`log_*`, `die`, `is_help_flag`, colour vars; colours auto-strip
when stdout isn't a TTY).

### Execution identity — hooks don't run as root by default

| Hook | Invoked by | Runs as |
|---|---|---|
| `preRebuild` / `postRebuild` | `icedos rebuild` | the **invoking user** |
| `preUpdate` / `postUpdate` | `icedos rebuild --update` / `--update-hooks` | the **invoking user** |
| `preGc` / `postGc` | `icedos gc` | **once per normal user**, as that user (self-elevates with `sudo` when not already root) |
| `preGc` / `postGc` | `nh-clean.service` (automatic timer) | **once per normal user**, as that user (`runuser -u <user> --`) |

Gc hooks run identically from `icedos gc` and from the timer: once per normal user,
as that user. They are **not** run as root by default — the timer (already root) uses
`runuser`; the `icedos gc` command elevates a single time with `sudo` and runs every
per-user invocation inside that one root context. Rebuild hooks always run as the
invoking user. A hook may still **escalate itself with `sudo`** where the user it runs
as has permission (e.g. NOPASSWD) — the service/command only control the starting
identity. Each per-user invocation is wrapped in `env -i` with the target user's
`HOME`/`USER`/`LOGNAME` and a NixOS login `PATH` (`runuser -l` is mutually exclusive
with `-u` and, without `/etc/login.defs`, sets a bare non-NixOS PATH), so hooks see
the same deterministic env whether they came from the timer or from `icedos gc` run
by any user — no `XDG_*`/`DBUS_*`/invoker-PATH leakage into other users' hooks. The
`nh clean all` call self-elevates to root via
sudo internally (nh's own store-GC step, `crates/nh-clean/src/clean.rs`), but that is
nh's process, not the hooks. Write **identity-independent** hooks (e.g. `unshade --all`
sweeping `~/.cache`) that make sense for any user rather than assuming a specific
`$USER`/`$HOME`. A config with no normal users skips gc hooks in both paths.

Environment a hook can rely on:

| Var | Set by | Notes |
|---|---|---|
| `ICEDOS_CONFIG_ROOT` | build app (`flake.nix`) | the config root. |
| `ICEDOS_STATE_DIR` | build app | the `.state` dir. |
| `ICEDOS_ROOT` | build app | the core store path. |
| `ICEDOS_BUILD_DIR` | `build.sh` | temp build dir — set **after** `build.sh` starts, so **not** available in `preRebuild`/`preUpdate` (they run before it). |
| `ICEDOS_HOOKS_ONLY=1` | `--update-hooks` only | tells `pre/postUpdate` that no HM activation follows, so they must complete standalone. |
| `ICEDOS_LOGGING` / `ICEDOS_STAGE` / `ICEDOS_UPDATE` / `ICEDOS_UPDATE_MODULE_INPUTS` | eval-internal | don't depend on these in runtime hooks. |

Order (`modules/rebuild.nix`): `--update-hooks` short-circuit (pre+postUpdate, then
exit) → `preRebuild` → `preUpdate` (only with `--update`) → `build.sh` → `postUpdate`
(only with `--update`) → config snapshot → `postRebuild` → reboot check. `preUpdate`/
`postUpdate` fire only with `--update`; run them alone (no build) via
`icedos rebuild --update-hooks` (e.g. `flatpak update`).
