{
  config,
  icedosLib,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (builtins)
    attrNames
    foldl'
    hasAttr
    head
    pathExists
    ;

  inherit (lib)
    elem
    filter
    flatten
    ;

  inherit (icedosLib)
    ICEDOS_CONFIG_ROOT
    ICEDOS_STAGE
    abortIf
    _getModuleKey
    _parseFlakeUrl
    _resolveFlakeRevision
    _urlIsGitScheme
    filterByAttrs
    findFirst
    flatMap
    mkInputName
    moduleInputName
    stringStartsWith
    ;

  finalIcedosLib = icedosLib // rec {
    # Map of repository baseUrl -> its config.toml `fetchOptionalDependencies`
    # flag, so a repo's setting applies to all of its modules, including ones
    # pulled in transitively as dependencies.

    repositories = config.repositories or [ ];

    repoFetchOptional = builtins.listToAttrs (
      map (r: {
        name = (_parseFlakeUrl r.url).baseUrl;
        value = r.fetchOptionalDependencies or false;
      }) repositories
    );

    # Map of repository baseUrl -> its config.toml `fetchDependencies` flag.
    # When false, that repo's modules pull NO declared dependencies at all
    # (required or optional); the listed modules themselves still load.
    repoFetchDeps = builtins.listToAttrs (
      map (r: {
        name = (_parseFlakeUrl r.url).baseUrl;
        value = r.fetchDependencies or true;
      }) repositories
    );

    # Apply patches to a flake source and return a realised, context-free store
    # path usable as a locked `path:` flake input. Realising (readDir/IFD) makes
    # the path exist when genflake renders the input; discarding context lets the
    # `nix eval --raw` genflake output accept it (it forbids store-path context).
    # Shared by whole-repo patches (fetchModulesRepository) and input patches
    # (_getModuleInputs) so the three pure-eval gotchas are handled in one place.
    _mkPatchedSource =
      {
        name,
        src,
        patches,
      }:
      let
        inherit (builtins) readDir seq unsafeDiscardStringContext;
        patched = pkgs.applyPatches { inherit name src patches; };
      in
      seq (readDir patched) (unsafeDiscardStringContext (toString patched));

    # Resolve config-root-relative patch strings (from config.toml) to store
    # paths the applyPatches builder can read in its sandbox. Stage-aware:
    #   - genflake: impure `--file` eval with `inputs` empty → copy from the host
    #     config root via builtins.path.
    #   - build: pure flake eval where host paths are unreadable and
    #     ICEDOS_CONFIG_ROOT is masked → read from the config flake input
    #     (genflake keeps these files in `filteredConfigRoot`).
    # Used for whole-repo patches and consumer-declared input patches; author
    # input patches are Nix path literals and bypass this (already store paths).
    # Closes over the top-level `inputs`, so callers that shadow `inputs` (e.g.
    # _getModuleInputs, where `inputs` is a module's input set) still resolve
    # icedos-config correctly.
    _resolveConfigPatches =
      patches:
      map (
        p:
        if (ICEDOS_STAGE == "genflake") then
          builtins.path { path = /. + "${ICEDOS_CONFIG_ROOT}/${p}"; }
        else
          inputs.icedos-config + "/${p}"
      ) patches;

    # Consumer-declared input patches from config.toml, as a flat
    # "<repo url>|<module>|<input>" -> [patch strings] lookup. Lets a user patch a
    # module's flake input without forking the module — the consumer-facing analog
    # of a module author's `inputs.<x>.patches`. Separator `|` never appears in a
    # flake url / module name / input name.
    _consumerInputPatches = builtins.listToAttrs (
      flatten (
        map (
          repo:
          map (ip: {
            name = "${repo.url}|${ip.module}|${ip.input}";
            value = ip.patches;
          }) (repo.inputPatches or [ ])
        ) repositories
      )
    );

    # --- module `lib` contributions --------------------------------------
    # Any `icedos.nix` module may extend `icedosLib` by shipping a top-level
    # `lib = { ... }` field — a repo module (e.g. `desktop/modules/default`
    # contributing the desktop/DE helpers) or a config-root extra module (the
    # user's local extension point, replacing the old repo/config-root
    # `lib.nix` auto-discovery). Core merges every contribution via
    # `_mergeModuleLibs` into the module-facing lib (see the generated flake's
    # `specialArgs` and its `icedosLib` output, plus repl-context).

    # Fold module `lib` field contributions into the base lib. Every record in
    # `mods` is a phase-1 import (base `finalIcedosLib`), so a contribution
    # sees ONLY the base lib — identical to the old repo/config-root `lib.nix`
    # imports; passing the merged value would make the merge's construction
    # depend on the very imports it builds, so contributions are
    # self-reference-free by construction. Repo-to-repo composition happens at
    # the MODULE layer, where the full merged lib is already visible. Fails
    # loud on a non-attrset `lib` field or any name collision — against the
    # core name set or another module — so a helper can't silently shadow
    # another. The seed is the base `finalIcedosLib`, which also carries the
    # resolution machinery (`modulesFromConfig`, `_mergeModuleLibs`,
    # `fetchModulesRepository`, …) — a contribution must not force those
    # members: `modulesFromConfig.closureLib` IS the merged result, so forcing
    # it from a contribution (or deep-forcing the merged lib, which reaches
    # `closureLib.modulesFromConfig.closureLib`) is the one self-reference
    # that never terminates. Self-reference-freedom holds for the helper names
    # a contribution uses, not for the machinery.
    _mergeModuleLibs =
      mods:
      foldl' (
        acc: m:
        let
          contribution = m.lib or { };
          dupes = filter (n: elem n (attrNames contribution)) (attrNames acc);
        in
        if !(builtins.isAttrs contribution) then
          throw "icedosLib contribution from module '${m._repoInfo.url}#${m.meta.name}' must be an attrset (lib = { ... }), got ${builtins.typeOf contribution}"
        else if dupes == [ ] then
          acc // contribution
        else
          throw "Duplicate icedosLib name '${head dupes}' across icedosLib contributions (base lib + module '${m._repoInfo.url}#${m.meta.name}')"
      ) finalIcedosLib mods;

    # The module-facing `icedosLib` is the base lib merged with every module's
    # `lib` field contribution. The two-phase resolution in `modulesFromConfig`
    # computes `closureLib` — `_mergeModuleLibs` over the fully-resolved
    # closure (`deduped` repo modules + phase-1 extra modules) — and
    # re-imports module files and extra modules with it, so a repo pulled in
    # as a dependency (e.g. desktop, a required dep of every DE repo) still
    # contributes its helpers. `specialArgs` reuses that value, so the whole
    # module system sees one merged lib. `_mergeModuleLibs` is a plain lazy
    # member of this rec — never forced by `attrNames` — so the probe in
    # lib/default.nix (`attrNames (import icedos.nix (icedosLibInputs //
    # { icedosLib = {}; }))`) keeps succeeding: forcing the key set never
    # forces the merge, and `icedos.nix`'s own `inherit (icedosLib)` (with
    # `{}`) only needs the static names.

    # Fetch a modules repository, resolving the URL and loading its icedos modules
    # Handles overrides, flake resolution, and module file loading
    fetchModulesRepository =
      {
        url,
        overrides,
        patches ? [ ],
        ...
      }:
      let
        inherit (builtins) getFlake;
        inherit (lib) optionalAttrs;

        # Apply override URL if available
        _fetchUrl = if (hasAttr url overrides) then overrides.${url} else url;

        # Naming: parse the ORIGINAL `url` so input names (and the
        # moduleIdentifier prefix derived from `_repoInfo.url`) are
        # stable across overrideUrl toggles. Without this, flipping
        # an override to e.g. `path:/local` renames every transitive
        # `icedos-<repo>-<input>` entry in flake.lock, forcing a full
        # re-fetch even though the upstreams haven't changed.
        nameParsed = _parseFlakeUrl url;
        repoName = mkInputName { parts = [ nameParsed.baseUrl ]; };

        # Fetching: parse the OVERRIDE-APPLIED url. flakeUrl + getFlake
        # see the override; lock resolution is keyed against repoName
        # (still original-derived) so toggling override only affects
        # the pin for THIS repo's own input — transitive inputs keep
        # their lock entries unchanged.
        fetchParsed = _parseFlakeUrl _fetchUrl;
        inherit (fetchParsed) baseUrl;
        inlineRef = fetchParsed.ref;

        # Resolve the flake revision from lock file
        lockRev = _resolveFlakeRevision {
          url = baseUrl;
          inherit repoName;
        };

        # Prefer the rev recorded in flake.lock; fall back to the inline ref the
        # user wrote in config.toml so the first build (before the lock exists)
        # still pins to what they asked for.
        flakeRev =
          if lockRev != "" then
            lockRev
          else if inlineRef != null then
            if icedosLib._urlIsGitScheme baseUrl then "?rev=${inlineRef}" else "/${inlineRef}"
          else
            "";

        # Build complete flake URL with revision
        flakeUrl = "${baseUrl}${flakeRev}";

        # Resolve the repo flake: fresh at genflake, from the locked input at
        # build. For a patched repo the build-stage input already resolves to the
        # patched tree (see `fetchUrl` below), so `baseFlake` is the patched flake
        # there — fine, since the patch machinery is only forced at genflake.
        baseFlake = if (ICEDOS_STAGE == "genflake") then (getFlake flakeUrl) else inputs.${repoName};

        # Optional whole-repo patches — the repo analog of `_getModuleInputs`'
        # input patching. The patched tree is emitted as the repo's own `path:`
        # flake input (see `fetchUrl`): nix locks that input (narHash in
        # flake.lock), so the build stage consumes it as a normal locked input
        # rather than via `getFlake`, which pure eval rejects for an unlocked
        # path. The diff stays on the locked rev since it is applied to the
        # upstream `baseFlake` resolved at genflake.
        hasPatches = patches != [ ];

        # Realised, context-free patched tree (see `_mkPatchedSource`); patch
        # files are config-root-relative strings resolved via the shared helper.
        # Emitted below as the repo's own locked `path:` input.
        patchedPath = _mkPatchedSource {
          name = "${repoName}-patched";
          src = baseFlake.outPath;
          patches = _resolveConfigPatches patches;
        };

        # icedos modules come from: upstream when unpatched; the freshly patched
        # tree at genflake (impure getFlake ok); the locked patched input at build.
        moduleFlake =
          if !hasPatches then
            baseFlake
          else if (ICEDOS_STAGE == "genflake") then
            getFlake "path:${patchedPath}"
          else
            inputs.${repoName};

        # Extract icedos modules from the (possibly patched) flake
        modules = moduleFlake.icedosModules { icedosLib = finalIcedosLib; };
      in
      {
        url = nameParsed.baseUrl;
        # Patched repos are emitted as a locked `path:` input pointing at the
        # realised patched tree; unpatched repos keep their upstream url.
        fetchUrl = if hasPatches then "path:${patchedPath}" else baseUrl;
        # Realised repo tree: the (possibly patched) flake's store path and
        # narHash. Forcing `outPath`/`narHash` never touches `icedosModules`.
        inherit (moduleFlake) narHash;
        files = flatten modules;
      }
      // (optionalAttrs (!hasPatches && hasAttr "rev" baseFlake) { inherit (baseFlake) rev; });

    # Convert external modules into flake input declarations
    # Filters out modules marked to skip as inputs
    _modulesToInputs =
      modules:
      let
        inherit (builtins) filter;
        shouldIncludeAsInput =
          mod: !(hasAttr "skipModuleAsInput" mod._repoInfo && mod._repoInfo.skipModuleAsInput);
      in
      map (
        { _repoInfo, ... }:
        let
          inherit (_repoInfo) url;
          # Original `url` drives the input NAME (stable across overrideUrl
          # toggles); `fetchUrl` (override-applied) drives the input VALUE
          # so the generated flake actually fetches from the override.
          # `or url` keeps backward compatibility with any _repoInfo not
          # produced by fetchModulesRepository (e.g. extra-modules).
          fetchUrl = _repoInfo.fetchUrl or url;
          flakeRev =
            if (hasAttr "rev" _repoInfo) then
              if _urlIsGitScheme fetchUrl then "?rev=${_repoInfo.rev}" else "/${_repoInfo.rev}"
            else if (hasAttr "narHash" _repoInfo) && !(stringStartsWith "path:" fetchUrl) then
              "?narHash=${_repoInfo.narHash}"
            else
              "";
        in
        {
          name = mkInputName { parts = [ url ]; };

          value = {
            url = "${fetchUrl}${flakeRev}";
          };
        }
      ) (filter shouldIncludeAsInput modules);

    # Extract input dependencies from modules and create properly namespaced input declarations
    # Input names come from `icedosLib.moduleInputName` (single source of truth), so a consumer
    # computing a module input's top-level name for a string context (e.g. `follows`) gets the
    # exact same name the generated flake uses.
    _getModuleInputs =
      modules:
      let
        inherit (builtins) attrNames filter getFlake;
        modulesWithInputs = filter (hasAttr "inputs") modules;
      in
      flatten (
        map (
          {
            _repoInfo,
            inputs,
            meta,
            ...
          }:
          map (
            i:
            let
              # Author patches (Nix path literals in the module, already store
              # paths) + consumer patches (config.toml strings declared via
              # `[[icedos.repositories.inputPatches]]`, resolved here). Both feed
              # one patched input; author patches apply first.
              _authorPatches = inputs.${i}.patches or [ ];
              _consumerPatches = _resolveConfigPatches (
                _consumerInputPatches."${_repoInfo.url}|${meta.name}|${i}" or [ ]
              );
              patches = _authorPatches ++ _consumerPatches;
              hasPatches = patches != [ ];

              moduleIdentifier = mkInputName {
                parts = [
                  _repoInfo.url
                  meta.name
                ];
              };

              normalInput = rec {
                _originalName = if hasPatches then "${i}_source" else i;
                name = moduleInputName {
                  repo = _repoInfo.url;
                  module = meta.name;
                  input = _originalName;
                };
                # "override" is deprecated (naming is now always namespaced) but
                # kept stripped so repos pinned at older revs don't leak the key
                # into the generated flake input and fail opaquely.
                value = removeAttrs inputs.${i} [
                  "override"
                  "patches"
                ];
              };

              # Resolve the upstream URL against the state lock so the patched
              # derivation's `src` matches the rev pinned in flake.lock under
              # `normalInput.name`. Mirrors fetchModulesRepository's contract.
              _patchSrcParsed = _parseFlakeUrl inputs.${i}.url;

              _patchSrcLockRev = _resolveFlakeRevision {
                url = _patchSrcParsed.baseUrl;
                repoName = normalInput.name;
              };

              _patchSrcRev =
                if _patchSrcLockRev != "" then
                  _patchSrcLockRev
                else if _patchSrcParsed.ref != null then
                  "/${_patchSrcParsed.ref}"
                else
                  "";

              _patchSrcUrl = "${_patchSrcParsed.baseUrl}${_patchSrcRev}";

              patchedInputSource = _mkPatchedSource {
                name = "${moduleIdentifier}-${i}-patched";
                src = getFlake _patchSrcUrl |> toString;
                inherit patches;
              };

              patchedInput = rec {
                _originalName = i;
                name = moduleInputName {
                  repo = _repoInfo.url;
                  module = meta.name;
                  input = _originalName;
                };
                value =
                  (removeAttrs inputs.${i} [
                    "override"
                    "patches"
                  ])
                  // {
                    url = "path:${patchedInputSource}";
                  };
              };
            in
            if hasPatches then
              [
                normalInput
                patchedInput
              ]
            else
              normalInput
          ) (attrNames inputs)
        ) modulesWithInputs
      );

    # Create a masked inputs set for nixos module evaluation
    # Ensures modules use consistent input names and see appropriate dependencies
    _createMaskedInputs =
      {
        baseInputs,
        moduleInputs,
        repoInfo,
        isSkipModuleAsInput,
      }:
      {
        inherit (baseInputs) nixpkgs home-manager;
        icedos-state = if (hasAttr "icedos-state" baseInputs) then baseInputs.icedos-state else null;

        self =
          if isSkipModuleAsInput then
            "icedos-config"
          else
            baseInputs.${mkInputName { parts = [ repoInfo.url ]; }};
      }
      // (
        let
          inherit (builtins) listToAttrs;
        in
        listToAttrs (
          map (i: {
            name = i._originalName;
            value = baseInputs.${i.name};
          }) moduleInputs
        )
      );

    # Extract all options declarations from modules that define them
    _getModuleOptions =
      modules:
      map (
        { options, ... }:
        {
          inherit options;
        }
      ) (filterByAttrs [ "options" ] modules);

    # Compute a structural dedup key for a NixOS module *value*, or `null` when
    # the value is opaque and must never be deduplicated. A function is opaque
    # (two syntactically-identical closures may capture different scopes and
    # there is no way to compare them); opacity bubbles up, so a list/attrset
    # containing any function yields `null` — two module values are only ever
    # merged when they are provably identical. A derivation is opaque too —
    # keying never forces it (`v.type` alone is inspected; `drvPath` is
    # *not*): a derivation is a cyclic attrset (`d.all = [ d.out ]`,
    # `d.out = d`) that deep-traversal would recurse forever on, and forcing
    # `drvPath` can eagerly instantiate or trigger IFD for packages the module
    # system would never build. Any attrset carrying `_type` (the module
    # system's property wrappers — `mkIf`, `mkMerge`, `mkForce`, `mkDefault`,
    # option types, …) is opaque too: those are exactly the values whose
    # branches the module system may never force (`mkIf false` content is
    # dropped without forcing), so keying must not descend into them. Depth is
    # capped so any other self-referential value degrades to opaque instead of
    # `max-call-depth exceeded`. The whole computation runs under `tryEval`,
    # which degrades values that `throw` or `assert` when forced to opaque
    # rather than aborting the system evaluation — never-dedup is always the
    # safe fallback. `tryEval` does NOT catch `abort`, a missing attribute, a
    # type error, or infinite recursion; the depth cap bounds recursion, and
    # the `_type`/derivation guards keep keying out of the module system's
    # conditional branches. The remaining exposure is strictness: keying IS
    # strict over function-free, `_type`-free, derivation-free payloads,
    # including a definition for an option a real build would never force (an
    # option no module reads — a `mkIf`-wrapped branch is `_type`-guarded, but
    # a plain definition under an unread option is not). An uncatchable error
    # hidden there surfaces at build-stage eval instead of never; it is a real
    # config bug either way, and the module system would hit it too once the
    # option was read. Nix's `==` on strings also ignores string context, so a
    # payload carrying a store-path reference (context) could key equal to an
    # otherwise-identical bare literal — contrived, but dedup only ever keeps
    # the first occurrence, so if the context-free literal loads first, the
    # copy that carried the store reference is silently dropped.
    # Every keyed value is tagged with its `kind` (list/attrs/path/str/bool/
    # int/float/null), so structurally different shapes can never compare
    # equal: `{ }` ≠ `[ ]`, a path ≠ a plain string, `42` ≠ `42.0` (Nix treats
    # `int == float` as equal). `==` on the result mirrors value equality
    # within each kind, for the keyable subset of Nix. `setDefaultModuleLocation`
    # shims are NOT unwrapped here — callers do that first
    # (`_dedupeNixosModules`), otherwise two shims with different `_file`
    # strings would never compare equal.
    _opaqueOrKey =
      value:
      let
        maxDepth = 50;

        go =
          depth: v:
          if depth > maxDepth then
            null
          else if builtins.isFunction v then
            null
          else if builtins.isAttrs v && v ? _type then
            null
          else if builtins.isAttrs v && v ? type && v.type == "derivation" then
            null
          else if builtins.isList v then
            let
              keys = map (go (depth + 1)) v;
            in
            if builtins.any (k: k == null) keys then
              null
            else
              {
                kind = "list";
                inherit keys;
              }
          else if builtins.isAttrs v then
            let
              keys = map (name: {
                inherit name;
                key = go (depth + 1) v.${name};
              }) (builtins.attrNames v);
            in
            if builtins.any (e: e.key == null) keys then
              null
            else
              {
                kind = "attrs";
                inherit keys;
              }
          else if builtins.isPath v then
            {
              kind = "path";
              value = toString v;
            }
          else if builtins.isString v then
            {
              kind = "str";
              value = v;
            }
          else if builtins.isBool v then
            {
              kind = "bool";
              value = v;
            }
          else if builtins.isInt v then
            {
              kind = "int";
              value = v;
            }
          else if builtins.isFloat v then
            {
              kind = "float";
              value = v;
            }
          else if v == null then
            {
              kind = "null";
            }
          else
            null;

        result = builtins.tryEval (go 0 value);
      in
      if result.success then result.value else null;

    # Deduplicate a flat list of NixOS module values. Every module emitted by an
    # IceDOS module arrives wrapped in a `setDefaultModuleLocation` shim
    # (`{ _file = "<repo>#<module>"; imports = [ m ]; }`), so nixpkgs keys each
    # module by its own `_file`/position and never dedups them — two IceDOS
    # modules emitting the SAME module value (e.g. a shared pure-attrset module,
    # or a common `inputs.<x>.nixosModules.default` that is a path) load it
    # twice. Unwrap the shim, key the payload with `_opaqueOrKey`, and keep the
    # FIRST occurrence of each structurally-identical value (the surviving shim
    # keeps its `_file`, so provenance errors still name the declarer that was
    # kept). Functions, derivations, `_type` wrappers, and anything containing
    # one are opaque and never merged — this includes any payload that DECLARES
    # options, since `lib.mkOption` produces `{ _type = "option"; … }`: duplicate
    # option declarations still fail loudly ("The option `x' is already
    # declared"), which is correct, never masked by dedup. The common path case
    # (`inputs.jovian.nixosModules.default` = a directory) is already
    # deduplicated by nixpkgs' own identical-path handling; this closes the
    # identical-attrset-config-value gap. Only the `nixosModules` output is
    # deduplicated — `modulesFromConfig.options` (the option-doc index) is
    # intentionally left as-is.
    _dedupeNixosModules =
      modules:
      let
        unwrap =
          m:
          if
            m ? _file
            && (builtins.isString m._file || builtins.isPath m._file)
            && m ? imports
            && builtins.isList m.imports
            && builtins.length m.imports == 1
            # Only a *pure* `setDefaultModuleLocation` shim (`{ _file;
            # imports = [ m ]; }`) is unwrapped. A value shaped `{ _file = …;
            # imports = [ x ]; config = …; }` is a real module with its own
            # body, not a shim — unwrapping would key on `x` alone and silently
            # drop its `config` on collision.
            &&
              builtins.attrNames m == [
                "_file"
                "imports"
              ]
          then
            builtins.head m.imports
          else
            m;

        step =
          seen: acc: mods:
          if mods == [ ] then
            acc
          else
            let
              m = builtins.head mods;
              key = _opaqueOrKey (unwrap m);
              rest = builtins.tail mods;
            in
            if key != null && builtins.any (k: k == key) seen then
              step seen acc rest
            else
              step (if key == null then seen else seen ++ [ key ]) (acc ++ [ m ]) rest;
      in
      step [ ] [ ] modules;

    # Process output modules into nixos modules with proper input masking
    # Each module's outputs are evaluated with its appropriate input set
    _extractNixosModules =
      {
        inputs,
        modules,
      }:
      let
        inherit (lib) flatten;

        moduleInputs = _getModuleInputs modules;

        processModuleOutputs =
          { inputs, ... }:

          {
            _repoInfo,
            meta,
            outputs,
            ...
          }:

          let
            maskedInputs = _createMaskedInputs {
              baseInputs = inputs;
              inherit moduleInputs;
              repoInfo = _repoInfo;
              isSkipModuleAsInput = hasAttr "skipModuleAsInput" _repoInfo && _repoInfo.skipModuleAsInput;
            };

            # Tag every emitted module with its origin (`<repo>#<module>`) so
            # nixpkgs eval/type/conflict errors point back at the IceDOS module
            # instead of an anonymous generated location. setDefaultModuleLocation
            # only stamps modules that don't already declare their own location.
            location = "${_repoInfo.url}#${meta.name}";
          in
          map (lib.setDefaultModuleLocation location) (
            outputs.nixosModules {
              inputs = maskedInputs;
              # The calling module's own repo base url, so `icedosLib.hasModule`
              # (with `repoUrl`) can resolve same-repo sibling modules without
              # hardcoding the url at every call site.
              repoUrl = _repoInfo.url;
            }
          );
      in
      # Dedupe within this module set: two modules emitting the same module
      # value (function-free) would otherwise load it twice — nixpkgs keys
      # modules by `_file`/position, so identical values in two
      # `setDefaultModuleLocation` shims never dedup.
      _dedupeNixosModules (
        flatten (
          map (processModuleOutputs { inherit inputs; }) (filterByAttrs [ "outputs" "nixosModules" ] modules)
        )
      );

    # Main function to extract all outputs from external modules
    # Combines inputs, nixos modules, options, and module text outputs
    getExternalModuleOutputs =
      modules:
      let
        inherit (lib) flatten;

        modulesAsInputs = _modulesToInputs modules;
        moduleInputs = _getModuleInputs modules;
        options = _getModuleOptions modules;

        nixosModules =
          params:
          _extractNixosModules {
            inputs = params.inputs;
            inherit modules;
          };

        nixosModulesText = flatten (
          map (mod: mod.outputs.nixosModulesText) (filterByAttrs [ "outputs" "nixosModulesText" ] modules)
        );
      in
      {
        inputs = modulesAsInputs ++ moduleInputs;

        inherit
          nixosModules
          nixosModulesText
          options
          ;
      };

    # Build a set of override URL mappings from dependencies that define overrides
    _buildOverridesMap =
      {
        newDeps,
        loadOverrides,
        existingOverrides,
      }:
      let
        inherit (builtins) filter listToAttrs;
        filteredDeps = filter (hasAttr "overrideUrl") newDeps;
      in
      if loadOverrides then
        listToAttrs (
          map (dep: {
            name = dep.url;
            value = dep.overrideUrl;
          }) filteredDeps
        )
      else
        existingOverrides;

    # Build a set of repo-url -> patch-list mappings from config repositories.
    # Mirrors `_buildOverridesMap` so a repository's `patches` apply to EVERY
    # fetch of that url — including transitive (self-)dependency fetches, which
    # otherwise re-fetch the repo unpatched and leak an unpatched input (the repo
    # maps to a single flake input, so its patch set must be consistent).
    _buildPatchesMap =
      {
        newDeps,
        loadOverrides,
        existingPatches,
      }:
      let
        inherit (builtins) filter listToAttrs;
        filteredDeps = filter (dep: (dep.patches or [ ]) != [ ]) newDeps;
      in
      if loadOverrides then
        listToAttrs (
          map (dep: {
            name = dep.url;
            value = dep.patches;
          }) filteredDeps
        )
      else
        existingPatches;

    # Load module files from a repository and ensure a default module exists
    # Returns list of modules with _repoInfo attached to each. Phase-1 import:
    # module files see the BASE `finalIcedosLib` here — resolution only forces
    # `meta`; the closure-aware merge is applied later when `modulesFromConfig`
    # re-imports each file's outputs via `_sourceFile`.
    _loadModulesFromRepo =
      repo:
      let
        modules = map (
          f:
          {
            _repoInfo = repo;
            _sourceFile = f;
          }
          // import f {
            inherit config lib;
            icedosLib = finalIcedosLib;
          }
        ) repo.files;

        hasDefault = findFirst (mod: mod.meta.name == "default") modules != null;
      in
      if hasDefault then
        modules
      else
        modules
        ++ [
          {
            _repoInfo = repo;
            meta.name = "default";
          }
        ];

    # Check if a module is already loaded (by key)
    _isModuleLoaded =
      existingDeps: url: name:
      elem (_getModuleKey url name) existingDeps;

    # Filter new modules to only include those that are needed and not already loaded
    _filterNewModules =
      {
        modules,
        existingDeps,
        requestedNames,
      }:
      let
        inherit (builtins) filter;

        isRequested = mod: (mod.meta.name == "default") || (elem mod.meta.name requestedNames);
        isNew = mod: !_isModuleLoaded existingDeps mod._repoInfo.url mod.meta.name;
      in
      filter (mod: isRequested mod && isNew mod) modules;

    # Extract internal dependencies from a module's metadata
    # Optionally includes optional dependencies based on flag
    _getModuleDependencies =
      {
        mod,
        fetchDependencies,
        fetchOptionalDependencies,
      }:
      if !fetchDependencies then
        [ ]
      else
        let
          inherit (mod) meta;

          # Tag each dep group so it can later be labelled required vs optional
          tag = isOptional: map (d: d // { _optional = isOptional; });
          baseDeps = tag false (meta.dependencies or [ ]);
          optionalDeps =
            if fetchOptionalDependencies then tag true (meta.optionalDependencies or [ ]) else [ ];
        in
        baseDeps ++ optionalDeps;

    # Convert dependency metadata to resolved dependency entries (filtering already-loaded modules)
    _resolveDependencyEntries =
      {
        deps,
        sourceUrl,
        allKnownKeys,
        requestedBy,
      }:
      map (
        {
          url ? sourceUrl,
          modules ? [ ],
          _optional ? false,
        }:
        let
          realUrl = if (url == "self") then sourceUrl else url;
        in
        {
          url = realUrl;
          _requestedBy = requestedBy // {
            optional = _optional;
          };
          modules = filter (mod: !elem (_getModuleKey realUrl mod) allKnownKeys) modules;
        }
      ) deps;

    # Recursively resolve external dependencies, fetching repositories and extracting modules
    # Handles deduplication and override merging across the entire dependency tree
    resolveExternalDependencyRecursively =
      {
        newDeps,
        existingDeps ? [ ],
        existingOverrides ? [ ],
        existingPatches ? { },
        loadOverrides ? false,
      }:
      let
        inherit (builtins)
          filter
          foldl'
          length
          ;

        inherit (lib) optional unique;

        # Build override map from new dependencies or use existing
        overrides = _buildOverridesMap {
          inherit newDeps loadOverrides existingOverrides;
        };

        # Build patch map (repo url -> patch list) the same way, so a repo's
        # patches follow it across the whole dependency tree, not just its
        # top-level config entry.
        patchesMap = _buildPatchesMap {
          inherit newDeps loadOverrides existingPatches;
        };

        # Process each dependency and accumulate modules + missing-reference diagnostics
        result =
          foldl'
            (
              acc: newDep:
              let
                # Determine which modules are not yet loaded
                missingModules = filter (mod: !_isModuleLoaded existingDeps newDep.url mod) (newDep.modules or [ ]);

                # Fetch repository if new modules are needed or default isn't loaded
                newRepo =
                  optional (((length missingModules) > 0) || !_isModuleLoaded existingDeps newDep.url "default")
                    (
                      fetchModulesRepository (
                        newDep
                        // {
                          inherit overrides;
                          patches = patchesMap.${newDep.url} or [ ];
                        }
                      )
                    );

                # All modules present in the fetched repository (includes synthesized "default")
                repoModules = flatMap _loadModulesFromRepo newRepo;
                availableNames = map (mod: mod.meta.name) repoModules;

                # Requested-but-not-loaded names that don't exist in the repo are missing references.
                # `origin` is structured so the error can be grouped into views downstream.
                missingHere = map (name: {
                  inherit name;
                  url = newDep.url;
                  override = overrides.${newDep.url} or null;
                  origin = newDep._requestedBy or { kind = "config"; };
                }) (filter (name: !elem name availableNames) missingModules);

                # Filter loaded modules to only the requested, not-yet-loaded ones
                newModules = _filterNewModules {
                  inherit existingDeps;

                  modules = repoModules;
                  requestedNames = newDep.modules or [ ];
                };

                # Build set of all known module keys (existing + new)
                newModulesKeys = map (mod: _getModuleKey mod._repoInfo.url mod.meta.name) newModules;
                allKnownKeys = unique (existingDeps ++ newModulesKeys);

                # Extract and resolve nested dependencies from new modules
                innerDeps = flatMap (
                  mod:
                  _resolveDependencyEntries {
                    deps = _getModuleDependencies {
                      inherit mod;
                      fetchDependencies = repoFetchDeps.${mod._repoInfo.url} or true;
                      fetchOptionalDependencies = repoFetchOptional.${mod._repoInfo.url} or false;
                    };

                    sourceUrl = newDep.url;
                    requestedBy = {
                      kind = "module";
                      module = mod.meta.name;
                      repo = mod._repoInfo.url;
                      repoOverride = overrides.${mod._repoInfo.url} or null;
                    };
                    inherit allKnownKeys;
                  }
                ) newModules;

                # Recursively resolve inner dependencies if any
                resolved =
                  if (length innerDeps) > 0 then
                    resolveExternalDependencyRecursively {
                      newDeps = innerDeps;
                      existingDeps = allKnownKeys;
                      existingOverrides = overrides;
                      existingPatches = patchesMap;
                    }
                  else
                    {
                      modules = [ ];
                      missing = [ ];
                    };
              in
              {
                modules = acc.modules ++ newModules ++ resolved.modules;
                missing = acc.missing ++ missingHere ++ resolved.missing;
              }
            )
            {
              modules = [ ];
              missing = [ ];
            }
            newDeps;
      in
      {
        modules = flatten result.modules;
        missing = result.missing;
      };

    # Import an extra module file and attach repository info
    # Extra modules are stored locally in the config directory. The file is
    # imported with `config` + nixpkgs `lib` + `icedosLibValue` — the same
    # argument set a repo module file gets in phase 1 (`_loadModulesFromRepo`),
    # so an extra module can use nixpkgs `lib` at its top level (e.g. a
    # `lib = import ./lib.nix { inherit icedosLib lib; };` contribution).
    # `icedosLibValue` is the lib passed to the file — the base lib in phase 1
    # (contributions + meta), the closure-aware merge
    # (`modulesFromConfig.closureLib`) in phase 2 (outputs).
    _importExtraModule =
      {
        filePath,
        narHash,
        extraModulesPath,
        icedosLibValue ? finalIcedosLib,
      }:
      let
        inherit (builtins) unsafeDiscardStringContext;
        inherit (lib) removePrefix;

        imported = import filePath {
          inherit config lib;
          icedosLib = icedosLibValue;
        };
        relPath = removePrefix "${extraModulesPath}/" filePath;
        fallbackName = unsafeDiscardStringContext (dirOf relPath);
      in
      imported
      // {
        _repoInfo = {
          inherit narHash;
          url = "config";
          skipModuleAsInput = true;
        };
        meta = (imported.meta or { }) // {
          name = imported.meta.name or fallbackName;
        };
      };

    # Load all IceDOS-style extra modules (icedos.nix) from every configured
    # extra-module directory (config.system.extraModules, default `modules`).
    # Missing directories contribute nothing; returns [] when none exist.
    # `icedosLibValue` is threaded into every file import: the base lib in
    # phase 1 (`extraModulesP1` — contributions + meta), `closureLib` in
    # phase 2 (`extraModulesP2` — outputs). `config` and nixpkgs `lib` are
    # always threaded too (see `_importExtraModule`).
    _loadExtraModules =
      {
        configFlake,
        narHash,
        icedosLibValue ? finalIcedosLib,
      }:
      let
        dirs = config.system.extraModules or [ "modules" ];

        loadDir =
          dir:
          let
            extraModulesPath = "${configFlake}/${dir}";
          in
          if !(pathExists extraModulesPath) then
            [ ]
          else
            map
              (
                filePath:
                _importExtraModule {
                  inherit
                    filePath
                    narHash
                    extraModulesPath
                    icedosLibValue
                    ;
                }
              )
              (
                flatten (
                  icedosLib.scanModules {
                    path = extraModulesPath;
                    filename = "icedos.nix";
                  }
                )
              );
      in
      flatten (map loadDir dirs);

    # Get the configuration flake (either from inputs or local filesystem)
    _getConfigFlake =
      if (hasAttr "icedos-config" inputs) then
        inputs.icedos-config
      else
        fetchTree {
          type = "path";
          path = ICEDOS_CONFIG_ROOT;
        };

    # Main function to resolve and process all modules from config
    # Deduplicates modules, extracts outputs, and combines external + extra modules
    modulesFromConfig =
      let
        inherit (builtins)
          attrValues
          listToAttrs
          seq
          ;

        inherit (lib)
          concatStringsSep
          flatten
          mapAttrs
          optional
          unique
          ;

        # Format every missing reference into one error, split into views by
        # origin so each is actionable on its own:
        #   - config.toml view: names from a repository's `modules` list —
        #     the user fixes/removes them.
        #   - module-dependency view: names a module declares as a (optional)
        #     dependency — reported upstream.
        mkMissingModulesError =
          missing:
          let
            # Note the active overrideUrl so the user sees which path was
            # actually searched (config.toml `overrideUrl`, for local testing).
            overrideNote = override: if override != null then " (override: ${override})" else "";

            configMissing = filter (m: m.origin.kind == "config") missing;
            moduleMissing = filter (m: m.origin.kind == "module") missing;

            # config.toml view, one "<repo> -> module "<name>"" line per missing name
            configView =
              let
                configLine = m: "  ${m.url}${overrideNote m.override} -> module \"${m.name}\"";
              in
              concatStringsSep "\n" (
                [
                  "config.toml — remove or fix these in your repository `modules` lists:"
                  ""
                ]
                ++ map configLine configMissing
              );

            # module-dependency view, one line per missing dependency:
            #   "<repo> -> module "<declaring>" -> [optional ]dependency "<name>""
            # The declaring repo's override is shown; a dependency resolving to a
            # different repo also notes that repo (and its override).
            moduleView =
              let
                depKind = origin: if origin.optional then "optional dependency" else "dependency";
                moduleLine =
                  m:
                  let
                    inherit (m) origin;
                  in
                  "  ${origin.repo}${overrideNote origin.repoOverride} -> module \"${origin.module}\" -> ${depKind origin} \"${m.name}\""
                  + (if m.url != origin.repo then " (expected in ${m.url}${overrideNote m.override})" else "");
              in
              concatStringsSep "\n" (
                [
                  "module dependencies — declared by a module, report upstream:"
                  ""
                ]
                ++ map moduleLine moduleMissing
              );

            views = optional (configMissing != [ ]) configView ++ optional (moduleMissing != [ ]) moduleView;
          in
          ''
            referenced icedos modules do not exist

            ${concatStringsSep "\n\n" views}'';

        # Resolve external dependencies from config repositories
        externalResult = resolveExternalDependencyRecursively {
          newDeps = repositories;
          loadOverrides = true;
        };

        # Fail fast, listing every missing reference at once
        missingModules = unique externalResult.missing;

        externalModules = seq (abortIf (missingModules != [ ]) (
          mkMissingModulesError missingModules
        )) externalResult.modules;

        # Deduplicate modules by (url, name) pair
        deduped = attrValues (
          listToAttrs (
            map (m: {
              name = "${m._repoInfo.url}-${m.meta.name}";
              value = m;
            }) (flatten externalModules)
          )
        );

        # The closure-aware merged lib: base `finalIcedosLib` plus every
        # module's top-level `lib` field contribution over the FULLY-RESOLVED
        # closure — every deduped repo module plus every phase-1 extra module.
        # A repo pulled in as a dependency (e.g. desktop, required by every DE
        # repo) still contributes its helpers through its (always-loaded)
        # `default` module. Phase-1 imports force only `meta` and the `lib`
        # field with the BASE lib, so contributions see the same view the old
        # repo/config-root `lib.nix` imports saw.
        configFlake = _getConfigFlake;
        inherit (configFlake) narHash;

        # Phase-1 extra-module load: `icedos.nix` extra modules imported with
        # the BASE lib, so their `lib` field contributions (and `meta`) exist
        # before any merged value is computed. Only `meta` and the `lib` field
        # are forced here; `outputs` is re-imported with the merged lib in
        # phase 2 below.
        extraModulesP1 = _loadExtraModules {
          inherit configFlake narHash;
        };

        closureLib = _mergeModuleLibs (deduped ++ flatten extraModulesP1);

        # Phase-2 re-import: every external module file is imported AGAIN with
        # the closure-aware lib, so options/outputs (forced here, not during
        # resolution) see the helpers of transitive repos too. Repo-synthesized
        # `default` records (no `_sourceFile`, no `outputs`/`options` — see
        # `_loadModulesFromRepo`) pass through untouched; `getExternalModuleOutputs`
        # drops them via its `options`/`outputs` filters, exactly as today.
        externalOutputs = getExternalModuleOutputs (
          map (
            m:
            if m ? _sourceFile then
              (import m._sourceFile {
                inherit config lib;
                icedosLib = closureLib;
              })
              // {
                inherit (m) _repoInfo _sourceFile;
              }
            else
              m
          ) deduped
        );

        # Phase-2 extra-module load: re-import every extra module file with
        # the closure-aware lib so its `outputs` see the merged helpers. The
        # `lib` field stays lazy here (`getExternalModuleOutputs` never forces
        # it), so a contribution is evaluated exactly once, against the base
        # lib in phase 1.
        extraModulesP2 = _loadExtraModules {
          inherit configFlake narHash;
          icedosLibValue = closureLib;
        };

        # Get outputs from extra modules
        extraOutputs = getExternalModuleOutputs (flatten extraModulesP2);

        # Fully-resolved loaded module set: repo base url -> [names].
        # Explicit + transitive deps, synthesized `default` included (it is
        # always requested by `_filterNewModules`). Extra-modules (repo key
        # "config", so a user's extra module can `hasModule { inherit config
        # repoUrl; }` against its own repo) are included too. Injected into the
        # module system as the read-only `icedos.system.loadedModules` option
        # and consumed by `icedosLib.hasModule`.
        loadedModules = mapAttrs (_: mods: map (m: m.meta.name) mods) (
          lib.groupBy (m: m._repoInfo.url) (deduped ++ flatten extraModulesP2)
        );

        # Combine nixos modules from both external and extra sources. Each
        # source dedups internally (`_extractNixosModules`); dedupe again
        # across the split so the same identical module value emitted by one
        # external and one extra module loads only once.
        nixosModules =
          params:
          _dedupeNixosModules ((externalOutputs.nixosModules params) ++ (extraOutputs.nixosModules params));

        # Final combined outputs
        outputs = externalOutputs // {
          inherit nixosModules loadedModules closureLib;
          inputs = externalOutputs.inputs ++ extraOutputs.inputs;
          options = externalOutputs.options ++ extraOutputs.options;
          nixosModulesText = externalOutputs.nixosModulesText ++ extraOutputs.nixosModulesText;
        };
      in
      outputs;
  };
in
finalIcedosLib
