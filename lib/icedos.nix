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
    seq
    ;

  inherit (lib)
    elem
    filter
    flatten
    ;

  finalIcedosLib = icedosLib // rec {
    repositories = config.repositories or [ ];

    # repo baseUrl -> `fetchOptionalDependencies`: the flag applies to every
    # module of that repo, including transitively pulled ones.
    repoFetchOptional = builtins.listToAttrs (
      map (r: {
        name = (icedosLib._parseFlakeUrl r.url).baseUrl;
        value = r.fetchOptionalDependencies or false;
      }) repositories
    );

    # repo baseUrl -> `fetchDependencies`. False = that repo's modules pull no
    # declared dependencies at all; the listed modules still load.
    repoFetchDeps = builtins.listToAttrs (
      map (r: {
        name = (icedosLib._parseFlakeUrl r.url).baseUrl;
        value = r.fetchDependencies or true;
      }) repositories
    );

    # cache-server's published tracked-inputs.json (name -> rev | { rev; repo; }).
    # Resolved through the state lock chain root -> icedos-config -> icedos ->
    # cache-server, so it matches the tree the build evaluates. Genflake-only: the
    # revs are baked into the generated sub-flake text, keeping the pure build
    # stage free of fetches. Empty on a first build (no state lock yet), which
    # resolves fresh and self-heals on the next run.
    _cacheTrackedRevs =
      let
        lock = icedosLib._readFlakeLock;
        hop =
          attrs: name:
          let
            v = attrs.${name} or null;
          in
          if builtins.isString v then v else null;
        cfgKey = if lock == null then null else hop (lock.nodes.root.inputs or { }) "icedos-config";
        coreKey = if cfgKey == null then null else hop (lock.nodes.${cfgKey}.inputs or { }) "icedos";
        cacheKey =
          if coreKey == null then null else hop (lock.nodes.${coreKey}.inputs or { }) "cache-server";
        locked = if cacheKey == null then { } else (lock.nodes.${cacheKey} or { }).locked or { };
        tree = builtins.fetchTree {
          inherit (locked)
            type
            owner
            repo
            rev
            ;
        };
      in
      if
        (icedosLib.ICEDOS_STAGE != "genflake")
        || !((config.system.cache.pinInputs or false))
        || (locked.type or "") != "github"
      then
        { }
      else
        builtins.fromJSON (builtins.readFile "${tree}/tracked-inputs.json");

    # Patch a flake source into a realised, context-free store path usable as a
    # locked `path:` input (readDir realises it; --raw genflake forbids context).
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

    # Config-root-relative patch strings -> store paths: host copy at genflake,
    # the top-level `inputs.icedos-config` (never a shadowing one) at build.
    _resolveConfigPatches =
      patches:
      map (
        p:
        if (icedosLib.ICEDOS_STAGE == "genflake") then
          builtins.path { path = /. + "${icedosLib.ICEDOS_CONFIG_ROOT}/${p}"; }
        else
          inputs.icedos-config + "/${p}"
      ) patches;

    # config.toml input patches as "<repo url>|<module>|<input>" -> [patches];
    # `|` never appears in a flake url, module name or input name.
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

    # Fold every module's `lib` field into the base lib. Contributions are
    # phase-1 imports (base lib only) and must never force `modulesFromConfig`.
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

    # Fetch a repo (override- and patch-aware) and load its icedos modules.
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

        _fetchUrl = if (hasAttr url overrides) then overrides.${url} else url;

        # Name from the ORIGINAL url so input names stay stable across
        # overrideUrl toggles (otherwise every lock entry is renamed).
        nameParsed = icedosLib._parseFlakeUrl url;
        repoName = icedosLib.mkInputName { parts = [ nameParsed.baseUrl ]; };

        # Fetch from the OVERRIDE-APPLIED url; lock lookup stays keyed by
        # repoName, so an override toggle only re-pins this repo's own input.
        fetchParsed = icedosLib._parseFlakeUrl _fetchUrl;
        inherit (fetchParsed) baseUrl;
        inlineRef = fetchParsed.ref;

        lockRev = icedosLib._resolveFlakeRevision {
          url = baseUrl;
          inherit repoName;
        };

        # Lock rev wins; fall back to config.toml's inline ref so the first
        # build (no lock yet) still pins what the user asked for.
        flakeRev =
          if lockRev != "" then
            lockRev
          else if inlineRef != null then
            if icedosLib._urlIsGitScheme baseUrl then "?rev=${inlineRef}" else "/${inlineRef}"
          else
            "";

        flakeUrl = "${baseUrl}${flakeRev}";

        # Fresh at genflake, the locked input at build — where a patched repo's
        # input already IS the patched tree (see `fetchUrl`).
        baseFlake =
          if (icedosLib.ICEDOS_STAGE == "genflake") then (getFlake flakeUrl) else inputs.${repoName};

        # Whole-repo patches: the patched tree becomes the repo's own locked
        # `path:` input, so build stage never getFlakes an unlocked path.
        hasPatches = patches != [ ];

        patchedPath = _mkPatchedSource {
          name = "${repoName}-patched";
          src = baseFlake.outPath;
          patches = _resolveConfigPatches patches;
        };

        # Modules come from: upstream when unpatched, the freshly patched tree at
        # genflake (impure getFlake ok), the locked patched input at build.
        moduleFlake =
          if !hasPatches then
            baseFlake
          else if (icedosLib.ICEDOS_STAGE == "genflake") then
            getFlake "path:${patchedPath}"
          else
            inputs.${repoName};

        modules = moduleFlake.icedosModules { icedosLib = finalIcedosLib; };
      in
      {
        url = nameParsed.baseUrl;
        # Patched repo -> locked `path:` input; unpatched keeps its upstream url.
        fetchUrl = if hasPatches then "path:${patchedPath}" else baseUrl;
        # narHash of the realised tree; forcing it never touches `icedosModules`.
        inherit (moduleFlake) narHash;
        files = flatten modules;
      }
      // (optionalAttrs (!hasPatches && hasAttr "rev" baseFlake) { inherit (baseFlake) rev; });

    # External modules -> repo flake-input declarations (skipModuleAsInput filtered).
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
          # Original `url` names the input (stable across overrideUrl toggles);
          # `fetchUrl` (override-applied) is what the flake actually fetches.
          fetchUrl = _repoInfo.fetchUrl or url;
          flakeRev =
            if (hasAttr "rev" _repoInfo) then
              if icedosLib._urlIsGitScheme fetchUrl then "?rev=${_repoInfo.rev}" else "/${_repoInfo.rev}"
            else if (hasAttr "narHash" _repoInfo) && !(icedosLib.stringStartsWith "path:" fetchUrl) then
              "?narHash=${_repoInfo.narHash}"
            else
              "";
        in
        {
          name = icedosLib.mkInputName { parts = [ url ]; };

          value = {
            url = "${fetchUrl}${flakeRev}";
          };
        }
      ) (filter shouldIncludeAsInput modules);

    # Root inputs a module input's `follows` may target. MUST mirror genflake's
    # emission exactly, or a valid follows points at a non-existent root input.
    _ambientInputNames = [
      "nixpkgs"
      "home-manager"
      "icedos-config"
      "icedos-core"
    ]
    ++ lib.optional (pathExists /etc/icedos) "icedos-state"
    ++ (map (c: c.name) (config.system.channels or [ ]))
    ++ (map
      (
        e:
        icedosLib.mkInputName {
          parts = [
            "overlay"
            e.url
          ];
        }
      )
      (
        filter (e: (e.channel or "") == "" && (e.url or "") != "" && (e.packages or [ ]) != [ ]) (
          config.system.overlays.fromChannel or [ ]
        )
      )
    )
    ++ (map (f: f.name) extraFlakes);

    # One thin input-namespace sub-flake per module that declares inputs. Only
    # `text`/`input.value.url` resolve patched paths — never force at build stage.
    _getModuleInputs =
      modules:
      let
        inherit (builtins)
          attrNames
          filter
          getFlake
          listToAttrs
          ;
        modulesWithInputs = filter (m: (m.inputs or { }) != { }) modules;
      in
      map (
        {
          _repoInfo,
          inputs,
          meta,
          ...
        }:
        let
          subFlakeName = icedosLib.moduleSubFlakeName {
            repo = _repoInfo.url;
            module = meta.name;
          };
          declarer = "${_repoInfo.url}#${meta.name}";

          inputNames = attrNames inputs;

          # Author patches (store paths) then consumer patches (config.toml),
          # in that order, into one patched input.
          patchesFor =
            i:
            (inputs.${i}.patches or [ ])
            ++ _resolveConfigPatches (_consumerInputPatches."${_repoInfo.url}|${meta.name}|${i}" or [ ]);

          hasPatchesFor = i: patchesFor i != [ ];

          # Every authored `follows` at ANY depth (nix allows them nested), so
          # each first segment can be validated and slotted. Forces no urls.
          collectFollows =
            as:
            flatten (
              map (
                n:
                (lib.optional ((as.${n}.follows or null) != null) as.${n}.follows)
                ++ collectFollows (as.${n}.inputs or { })
              ) (attrNames as)
            );

          followsTargets = flatten (
            map (
              i:
              lib.optional ((inputs.${i}.follows or null) != null) inputs.${i}.follows
              ++ collectFollows (inputs.${i}.inputs or { })
            ) inputNames
          );

          firstSegments = lib.unique (map (f: head (lib.splitString "/" f)) followsTargets);

          # Nix rejects an input with both a flake reference and a follows, so
          # abort here instead of on an opaque lock error. Follows-only is legal.
          directFollowsInvalid = filter (
            i: (inputs.${i}.follows or null) != null && (inputs.${i} ? url)
          ) inputNames;

          directFollowsValid = icedosLib.abortIf (directFollowsInvalid != [ ]) ''
            ${declarer}: module input "${builtins.head directFollowsInvalid}" declares both url and follows.
            In a module's input-namespace sub-flake an input cannot both reference a source and follow another input (nix rejects a flake input with both a flake reference and a follows attribute). To pin just one of the input's own inputs, write the follows on it instead — e.g. inputs.${builtins.head directFollowsInvalid}.inputs.nixpkgs.follows. A url-less follows-only input remains legal.'';

          # Names emitted inside this sub-flake — a `_source` sibling is
          # followable only when it is actually emitted (i.e. the input is patched).
          siblings = flatten (map (i: [ i ] ++ lib.optional (hasPatchesFor i) "${i}_source") inputNames);

          invalidSegments = filter (s: !(elem s _ambientInputNames) && !(elem s siblings)) firstSegments;

          slotsValid = icedosLib.abortIf (invalidSegments != [ ]) ''
            ${declarer}: input `follows` target(s) "${lib.concatStringsSep "\", \"" invalidSegments}" cannot resolve inside the module's generated sub-flake.
            A follows first segment must name an ambient input of the generated flake (${lib.concatStringsSep ", " _ambientInputNames}) or a sibling input of the same module.
            Cross-module follows — e.g. built from icedosLib.moduleInputName, which now yields a sub-flake-relative path — are no longer supported.'';

          # A segment the module also declares is NOT a slot: the follows resolves
          # to that sibling, and a slot would collide with it in `listToAttrs`.
          slots = filter (s: elem s _ambientInputNames && !(elem s siblings)) firstSegments;

          perInput =
            i:
            let
              patches = patchesFor i;
              hasPatches = patches != [ ];

              # `override` is dead but still stripped: an old pinned repo would
              # otherwise leak the key into the sub-flake and fail opaquely.
              decl = removeAttrs inputs.${i} [
                "override"
                "patches"
              ];

              # The patched `src` and the `_source` url bake the same locked rev,
              # so a sub-flake re-lock cannot disagree with the realised tree.
              _patchSrcParsed = icedosLib._parseFlakeUrl inputs.${i}.url;

              # Pre-lock fallback pin (the author's `github:o/r/<ref>`); once the
              # lock has the rev it wins, so a first build self-heals next run.
              _patchSrcInlineRef = if _patchSrcParsed.ref != null then "/${_patchSrcParsed.ref}" else "";

              _patchSrcLockRev = icedosLib._resolveFlakeRevisionNested {
                url = _patchSrcParsed.baseUrl;
                inherit subFlakeName;
                inputName = "${i}_source";
              };

              # Rev cache-server last built for this leaf input, "" when untracked
              # or the url is not a github/gitlab/sourcehut reference.
              _cachePin =
                let
                  url = inputs.${i}.url or "";
                  rev = icedosLib._cacheRevLookup {
                    inherit url;
                    name = i;
                    revs = _cacheTrackedRevs;
                  };
                in
                if
                  rev == ""
                  || !(builtins.elem (head (lib.splitString ":" url)) [
                    "github"
                    "gitlab"
                    "sourcehut"
                  ])
                then
                  ""
                else
                  "/${rev}";

              # Lock rev wins (this config already resolved it), then the cache
              # pin (upstream published a newer built rev), then the author's ref.
              _patchSrcRev =
                if _patchSrcLockRev != "" then
                  _patchSrcLockRev
                else if _cachePin != "" then
                  _cachePin
                else
                  _patchSrcInlineRef;

              _patchSrcUrl = "${_patchSrcParsed.baseUrl}${_patchSrcRev}";

              patchedInputSource = _mkPatchedSource {
                name = "${subFlakeName}-${i}-patched";
                src = getFlake _patchSrcUrl |> toString;
                inherit patches;
              };

              # Verbatim when unpatched; `_source` (upstream, rev baked) plus a
              # `path:` node for the realised tree when patched.
              decls =
                if hasPatches then
                  [
                    {
                      name = "${i}_source";
                      value = decl // {
                        url = _patchSrcUrl;
                      };
                    }
                    {
                      name = i;
                      value = decl // {
                        url = "path:${patchedInputSource}";
                      };
                    }
                  ]
                else
                  [
                    {
                      name = i;
                      value =
                        if _cachePin == "" then
                          decl
                        else
                          decl
                          // {
                            url = "${(icedosLib._parseFlakeUrl inputs.${i}.url).baseUrl}${_cachePin}";
                          };
                    }
                  ];

              # Masked-mapping entries: the bare names every module's outputs
              # see (`<i>` — the patched tree when patched — plus `<i>_source`).
              maskedEntries =
                map
                  (e: {
                    _originalName = e;
                    _subFlake = subFlakeName;
                    name = icedosLib.moduleInputName {
                      repo = _repoInfo.url;
                      module = meta.name;
                      input = e;
                    };
                  })
                  (
                    if hasPatches then
                      [
                        "${i}_source"
                        i
                      ]
                    else
                      [ i ]
                  );
            in
            {
              inherit
                decls
                hasPatches
                maskedEntries
                ;
            };
        in
        let
          # The sub-flake's flake.nix: verbatim module inputs plus only the
          # ambient slots its authored follows reference.
          text = seq (slotsValid && directFollowsValid) ''
            {
              # Generated by icedos genflake — do not edit.
              inputs = ${
                lib.generators.toPretty
                  {
                    multiline = true;
                    allowPrettyValues = true;
                  }
                  (
                    listToAttrs (
                      (map (s: {
                        name = s;
                        value = { };
                      }) slots)
                      ++ flatten (map (i: (perInput i).decls) inputNames)
                    )
                  )
              };

              outputs = inputs: { inherit inputs; };
            }
          '';

          # Hashed over the flake.nix text, so a decl change flips the path and
          # `nix flake lock` re-locks just this root. Genflake-only (IFD).
          url =
            let
              storeDir = builtins.path {
                # `-subflake` marker: the build orchestrator classifies sub-flake roots by this
                # exact suffix, so a store-path root input is never mistaken for one.
                name = "${subFlakeName}-subflake";
                path = (pkgs.writeTextDir "flake.nix" text).outPath;
              };
            in
            "path:${seq (builtins.readDir storeDir) (builtins.unsafeDiscardStringContext (toString storeDir))}";
        in
        {
          inherit subFlakeName text url;

          # Root input decl: the sub-flake as a `path:` input, its slots rewired
          # to the parent's own inputs. Only genflake forces `value.url` (IFD).
          input = seq (slotsValid && directFollowsValid) {
            name = subFlakeName;
            value = {
              inherit url;
              inputs = listToAttrs (
                map (s: {
                  name = s;
                  value.follows = s;
                }) slots
              );
            };
          };

          masked = flatten (map (i: (perInput i).maskedEntries) inputNames);
        }
      ) modulesWithInputs;

    # Same bare input name with differing url/patches/decl would silently pick
    # one winner in the masked set — abort instead. Forces urls: genflake only.
    _checkDuplicateModuleInputs =
      modules:
      let
        declared = flatten (
          map (
            m:
            map (i: {
              name = i;
              url = m.inputs.${i}.url or "";
              # Effective patch set (author + consumer), JSON-encoded so two
              # store-path lists compare structurally.
              patches = builtins.toJSON (
                (m.inputs.${i}.patches or [ ])
                ++ _resolveConfigPatches (_consumerInputPatches."${m._repoInfo.url}|${m.meta.name}|${i}" or [ ])
              );
              # Rest of the decl (follows, nested overrides, ...): same url but
              # different overrides are still two different nodes, so they collide.
              declJson = builtins.toJSON (
                removeAttrs m.inputs.${i} [
                  "override"
                  "patches"
                ]
              );
              declarer = "${m._repoInfo.url}#${m.meta.name}";
            }) (attrNames (m.inputs or { }))
          ) modules
        );

        tree = d: "${d.url}::${d.patches}::${d.declJson}";

        colliding = lib.filterAttrs (_: decls: lib.length (lib.unique (map tree decls)) > 1) (
          lib.groupBy (d: d.name) declared
        );
      in
      icedosLib.abortIf (colliding != { }) (
        let
          lines = lib.mapAttrsToList (
            name: decls:
            "  input \"${name}\" is declared with different urls, patch sets, or input declarations by:\n"
            + lib.concatStringsSep "\n" (
              map (
                d:
                "    ${d.declarer} -> ${d.url}"
                + (if d.patches != "[]" then "  patches: ${d.patches}" else "")
                # Show the decl only when it adds something to the url, else the
                # two lines are byte-identical and hide what differs.
                + (if d.declJson != builtins.toJSON { url = d.url; } then "\n      decl: ${d.declJson}" else "")
              ) decls
            )
          ) colliding;
        in
        "module-declared inputs collide on a bare name with different urls, patch sets, or input declarations:\n"
        + lib.concatStringsSep "\n" lines
        + "\nRename one of them — every module's outputs share one masked input namespace."
      );

    # Two distinct modules can sanitize to one sub-flake name (`mkInputName`
    # keeps `-`), which would silently overwrite in `listToAttrs`. Names only.
    _checkDuplicateSubFlakeNames =
      modules:
      let
        declarer = m: "${m._repoInfo.url}#${m.meta.name}";
        withSubFlakes = filter (m: (m.inputs or { }) != { }) modules;
        groups = lib.groupBy (
          m:
          icedosLib.moduleSubFlakeName {
            repo = m._repoInfo.url;
            module = m.meta.name;
          }
        ) withSubFlakes;
        colliding = lib.filterAttrs (_: ms: lib.length (lib.unique (map declarer ms)) > 1) groups;
      in
      icedosLib.abortIf (colliding != { }) (
        let
          lines = lib.mapAttrsToList (
            name: ms: "  ${name} ← " + lib.concatStringsSep ", " (lib.unique (map declarer ms))
          ) colliding;
        in
        "module sub-flake names collide (two modules sanitize to the same root input name):\n"
        + lib.concatStringsSep "\n" lines
        + "\nRename one of them — each declaring module's inputs live under its own sub-flake root input."
      );

    # Sub-flake names must not collide with any other root input name.
    _checkSubFlakeReservedNames =
      modules:
      let
        subFlakeNames = map (r: r.subFlakeName) (_getModuleInputs modules);
        rootNames = (map (i: i.name) (_modulesToInputs modules)) ++ _ambientInputNames;
        colliding = lib.unique (lib.intersectLists subFlakeNames rootNames);
      in
      icedosLib.abortIf (colliding != [ ]) (
        "module sub-flake name(s) "
        + lib.concatStringsSep ", " colliding
        + " collide with a repository, reserved, channel, overlay, or extraFlake name — rename the module or the colliding root input"
      );

    # The input set a module's `outputs` sees: stable names regardless of how the
    # repo or input was fetched.
    _createMaskedInputs =
      {
        baseInputs,
        moduleInputs,
        repoInfo,
        isSkipModuleAsInput,
      }:
      let
        inherit (builtins) listToAttrs;
      in
      {
        inherit (baseInputs) nixpkgs home-manager;
        icedos-state = if (hasAttr "icedos-state" baseInputs) then baseInputs.icedos-state else null;

        self =
          if isSkipModuleAsInput then
            "icedos-config"
          else
            baseInputs.${icedosLib.mkInputName { parts = [ repoInfo.url ]; }};
      }
      // (
        # `_subFlake` entries resolve one hop down (`<sub>.inputs.<bare>`);
        # extraFlake entries are plain root inputs.
        listToAttrs (
          map (i: {
            name = i._originalName;
            value =
              if (i ? _subFlake) then
                baseInputs.${i._subFlake}.inputs.${i._originalName}
              else
                baseInputs.${i.name};
          }) moduleInputs
        )
      );

    _getModuleOptions =
      modules:
      map (
        { options, ... }:
        {
          inherit options;
        }
      ) (icedosLib.filterByAttrs [ "options" ] modules);

    # Structural dedup key, `null` = opaque (functions, derivations, `_type`
    # wrappers — never forced). Kind-tagged, so `{ }` != `[ ]` and 42 != 42.0.
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

    # Keep the first of each structurally-identical module value: nixpkgs keys by
    # the `setDefaultModuleLocation` shim's `_file`, so it never dedups these.
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
            # Only a PURE shim is unwrapped; anything with its own body is a real
            # module whose config would be dropped on collision.
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

    # `icedos.system.extraFlakes`: user-named root inputs, exposed to modules
    # under that bare name and optionally loaded via `modulesToLoad`.

    extraFlakes = config.system.extraFlakes or [ ];

    # Returns true so it chains with `seq`/`&&`. Scalar-tolerating name/url
    # checks run first, so a TOML typo aborts friendly, not on an attr miss.
    _validateExtraFlakes =
      flakes:
      icedosLib.abortIf
        (builtins.any (
          f:
          !(builtins.isString (f.name or ""))
          || builtins.match "^[a-zA-Z][a-zA-Z0-9_-]*$" (f.name or "") == null
        ) flakes)
        "icedos.system.extraFlakes: every entry's `name` must be non-empty and match ^[a-zA-Z][a-zA-Z0-9_-]*$"
      && icedosLib.abortIf (builtins.any (
        f: !(builtins.isString (f.url or "")) || (f.url or "") == ""
      ) flakes) "icedos.system.extraFlakes: every entry must set a non-empty `url`"
      && icedosLib.abortIf (builtins.any (
        f:
        builtins.any (
          k:
          !(builtins.elem k [
            "name"
            "url"
            "inputs"
            "modulesToLoad"
          ])
        ) (attrNames f)
      ) flakes) "icedos.system.extraFlakes: entries may only set `name`, `url`, `inputs`, `modulesToLoad`"
      && icedosLib.abortIf (builtins.any (
        f: builtins.any (p: p == "") (f.modulesToLoad or [ ])
      ) flakes) "icedos.system.extraFlakes: every `modulesToLoad` path must be non-empty"
      &&
        icedosLib.abortIf
          (builtins.any (
            n:
            builtins.elem n [
              "nixpkgs"
              "home-manager"
              "self"
              "icedos-config"
              "icedos-core"
              "icedos-state"
            ]
          ) (map (f: f.name) flakes))
          "icedos.system.extraFlakes: name is reserved (nixpkgs, home-manager, self, icedos-config, icedos-core, icedos-state)"
      && icedosLib.abortIf (
        builtins.length (lib.unique (map (f: f.name) flakes)) != builtins.length flakes
      ) "icedos.system.extraFlakes: `name` values must be unique";

    # Declared names colliding with an extraFlake `name`; shared by the masked-
    # input and repo/sub-flake-input guards. Pure, so tests can drive it.
    _extraFlakeNameCollisions =
      declaredNames: lib.intersectLists declaredNames (map (f: f.name) extraFlakes);

    # Root input decls; `value` keeps `url` + `inputs`, so a user's
    # `inputs.<x>.follows` passthrough survives into the locked flake.
    extraFlakeInputs =
      flakes:
      map (f: {
        name = f.name;
        value = removeAttrs f [
          "name"
          "modulesToLoad"
        ];
      }) flakes;

    # Masked entries exposing each extra flake under its bare `name`, in the
    # shape `_createMaskedInputs` consumes.
    extraFlakeMaskedInputs =
      flakes:
      map (f: {
        _originalName = f.name;
        name = f.name;
      }) flakes;

    # Resolve a dotted `modulesToLoad` path against the flake's outputs, naming
    # the missing input/segment instead of failing on a bare attr miss.
    _selectExtraFlakeOutput =
      flakeName: path: inputs:
      let
        segments = lib.splitString "." path;
        input = seq (icedosLib.abortIf (!(inputs ? ${flakeName}))
          "icedos.system.extraFlakes: input '${flakeName}' is not present in the flake inputs (registered as a top-level input via `name`)"
        ) inputs.${flakeName};
        walk =
          node: seg:
          seq (icedosLib.abortIf (!(node ? ${seg}))
            "icedos.system.extraFlakes: output path '${path}' on flake input '${flakeName}' is missing segment '${seg}'"
          ) node.${seg};
        selected = foldl' walk input segments;
        nullGuard = icedosLib.abortIf (
          selected == null
        ) "icedos.system.extraFlakes: output '${path}' on flake input '${flakeName}' is missing or null";
      in
      seq nullGuard selected;

    # Selected outputs as NixOS modules, in the same shim shape
    # `_extractNixosModules` emits so `_dedupeNixosModules` can key them.
    extraFlakeModules =
      params:
      seq (_validateExtraFlakes extraFlakes) (
        flatten (
          lib.imap0 (
            i: f:
            lib.imap0 (
              j: path:
              lib.setDefaultModuleLocation "icedos.system.extraFlakes[${toString i}].modulesToLoad[${toString j}]"
                (_selectExtraFlakeOutput f.name path params.inputs)
            ) (f.modulesToLoad or [ ])
          ) extraFlakes
        )
      );

    # Evaluate every module's `outputs.nixosModules` with its masked input set.
    _extractNixosModules =
      {
        inputs,
        modules,
      }:
      let
        inherit (lib) flatten;

        # Every module's declared inputs plus every extra flake, all under bare
        # names — so a collision between the two would silently overwrite.
        subFlakes = _getModuleInputs modules;
        colliding = _extraFlakeNameCollisions (
          lib.unique (
            (flatten (map (r: map (e: e._originalName) r.masked) subFlakes))
            ++ (map (r: r.subFlakeName) subFlakes)
          )
        );

        moduleInputs = seq (_validateExtraFlakes extraFlakes) (seq (
          icedosLib.abortIf (colliding != [ ])
            "module-declared input name(s) ${builtins.concatStringsSep ", " colliding} collide with an icedos.system.extraFlakes name — rename the module input or the extraFlake"
        )) (flatten (map (r: r.masked) subFlakes) ++ extraFlakeMaskedInputs extraFlakes);

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

            # Origin tag, so nixpkgs eval/type/conflict errors name the IceDOS
            # module instead of an anonymous generated location.
            location = "${_repoInfo.url}#${meta.name}";
          in
          map (lib.setDefaultModuleLocation location) (
            outputs.nixosModules {
              inputs = maskedInputs;
              # Lets `icedosLib.hasModule` resolve same-repo siblings without
              # hardcoding the url at every call site.
              repoUrl = _repoInfo.url;
            }
          );
      in
      # Two modules emitting the same value would otherwise load it twice.
      _dedupeNixosModules (
        flatten (
          map (processModuleOutputs { inherit inputs; }) (
            icedosLib.filterByAttrs [ "outputs" "nixosModules" ] modules
          )
        )
      );

    # All outputs of a module set: inputs, nixosModules, options, module text.
    getExternalModuleOutputs =
      modules:
      let
        inherit (lib) flatten listToAttrs;

        modulesAsInputs = _modulesToInputs modules;
        moduleSubFlakes = _getModuleInputs modules;
        options = _getModuleOptions modules;

        nixosModules =
          params:
          _extractNixosModules {
            inputs = params.inputs;
            inherit modules;
          };

        nixosModulesText = flatten (
          map (mod: mod.outputs.nixosModulesText) (
            icedosLib.filterByAttrs [ "outputs" "nixosModulesText" ] modules
          )
        );

        # Root input decls: repo inputs plus one sub-flake root per declaring module.
        inputs = modulesAsInputs ++ (map (r: r.input) moduleSubFlakes);

        # Genflake-only export: name -> flake.nix text. Names are forced here,
        # texts stay lazy (they resolve patched paths / getFlake).
        subFlakes = listToAttrs (
          map (r: {
            name = r.subFlakeName;
            value = r.text;
          }) moduleSubFlakes
        );
      in
      {
        inherit
          inputs
          nixosModules
          nixosModulesText
          options
          subFlakes
          ;
      };

    # url -> overrideUrl map from dependency entries.
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

    # url -> patches map. Must cover transitive fetches too: one repo is one
    # flake input, so an unpatched re-fetch would leak an unpatched tree.
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

    # Phase-1 import (BASE lib, only `meta` forced) with `_repoInfo` attached;
    # a `default` module is synthesized when the repo has none.
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

        hasDefault = icedosLib.findFirst (mod: mod.meta.name == "default") modules != null;
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

    _isModuleLoaded =
      existingDeps: url: name:
      elem (icedosLib._getModuleKey url name) existingDeps;

    # Requested (or `default`) modules that are not loaded yet.
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

    # A module's declared dependencies, optionals included per repo config.
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

          # Tagged so a missing dep can later be labelled required vs optional.
          tag = isOptional: map (d: d // { _optional = isOptional; });
          baseDeps = tag false (meta.dependencies or [ ]);
          optionalDeps =
            if fetchOptionalDependencies then tag true (meta.optionalDependencies or [ ]) else [ ];
        in
        baseDeps ++ optionalDeps;

    # Dependency metadata -> resolved entries, already-loaded modules dropped.
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
          modules = filter (mod: !elem (icedosLib._getModuleKey realUrl mod) allKnownKeys) modules;
        }
      ) deps;

    # Walk the whole dependency tree: fetch repos, dedupe, merge overrides/patches.
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

        overrides = _buildOverridesMap {
          inherit newDeps loadOverrides existingOverrides;
        };

        # Same for patches, so they follow a repo across the whole tree, not
        # just its top-level config entry.
        patchesMap = _buildPatchesMap {
          inherit newDeps loadOverrides existingPatches;
        };

        result =
          foldl'
            (
              acc: newDep:
              let
                missingModules = filter (mod: !_isModuleLoaded existingDeps newDep.url mod) (newDep.modules or [ ]);

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

                # Includes the synthesized `default` module.
                repoModules = icedosLib.flatMap _loadModulesFromRepo newRepo;
                availableNames = map (mod: mod.meta.name) repoModules;

                # Requested names the repo doesn't have. `origin` is structured so
                # the error can be grouped into per-source views downstream.
                missingHere = map (name: {
                  inherit name;
                  url = newDep.url;
                  override = overrides.${newDep.url} or null;
                  origin = newDep._requestedBy or { kind = "config"; };
                }) (filter (name: !elem name availableNames) missingModules);

                newModules = _filterNewModules {
                  inherit existingDeps;

                  modules = repoModules;
                  requestedNames = newDep.modules or [ ];
                };

                newModulesKeys = map (mod: icedosLib._getModuleKey mod._repoInfo.url mod.meta.name) newModules;
                allKnownKeys = unique (existingDeps ++ newModulesKeys);

                innerDeps = icedosLib.flatMap (
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

    # Config-root extra module, imported with the same argument set a repo module
    # gets: base lib in phase 1 (meta + contributions), closureLib in phase 2.
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

    # Every `icedos.nix` under the configured extra-module dirs; missing dirs
    # contribute nothing.
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

    # The config flake: the input at build stage, the live path at genflake.
    _getConfigFlake =
      if (hasAttr "icedos-config" inputs) then
        inputs.icedos-config
      else
        fetchTree {
          type = "path";
          path = icedosLib.ICEDOS_CONFIG_ROOT;
        };

    # Resolve every module the config asks for and combine external + extra
    # outputs. The only entry point genflake and the build stage use.
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

        # One error for every missing reference, split by origin: config.toml
        # names the user fixes, module dependencies they report upstream.
        mkMissingModulesError =
          missing:
          let
            # Show the active overrideUrl, so the user sees the path searched.
            overrideNote = override: if override != null then " (override: ${override})" else "";

            configMissing = filter (m: m.origin.kind == "config") missing;
            moduleMissing = filter (m: m.origin.kind == "module") missing;

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

            # One line per missing dependency; a dep resolving to another repo
            # also names that repo.
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

        externalResult = resolveExternalDependencyRecursively {
          newDeps = repositories;
          loadOverrides = true;
        };

        # Fail once, listing every missing reference.
        missingModules = unique externalResult.missing;

        externalModules = seq (icedosLib.abortIf (missingModules != [ ]) (
          mkMissingModulesError missingModules
        )) externalResult.modules;

        # Dedupe by (url, name).
        deduped = attrValues (
          listToAttrs (
            map (m: {
              name = "${m._repoInfo.url}-${m.meta.name}";
              value = m;
            }) (flatten externalModules)
          )
        );

        configFlake = _getConfigFlake;
        inherit (configFlake) narHash;

        # Phase 1 (BASE lib): contributions and `meta` must exist before the
        # merged lib can be computed.
        extraModulesP1 = _loadExtraModules {
          inherit configFlake narHash;
        };

        closureLib = _mergeModuleLibs (deduped ++ flatten extraModulesP1);

        # Phase 2: re-import every module file with `closureLib`, so its
        # options/outputs see transitive repos' helpers too.
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

        # Same for extra modules. Their `lib` field stays lazy here, so a
        # contribution is evaluated exactly once — in phase 1.
        extraModulesP2 = _loadExtraModules {
          inherit configFlake narHash;
          icedosLibValue = closureLib;
        };

        extraOutputs = getExternalModuleOutputs (flatten extraModulesP2);

        # repo url -> [names] over the fully-resolved closure (extra modules
        # under "config"); injected as `icedos.system.loadedModules`.
        loadedModules = mapAttrs (_: mods: map (m: m.meta.name) mods) (
          lib.groupBy (m: m._repoInfo.url) (deduped ++ flatten extraModulesP2)
        );

        # Each source dedups internally; dedupe again across the split so one
        # value emitted by two sources still loads once.
        nixosModules =
          params:
          _dedupeNixosModules (
            (externalOutputs.nixosModules params)
            ++ (extraOutputs.nixosModules params)
            ++ (extraFlakeModules params)
          );

        # An extraFlake name must not shadow a repo or sub-flake input name —
        # all are root inputs, and a duplicate silently wins in `listToAttrs`.
        extraFlakeNameGuard =
          icedosLib.abortIf
            (
              _extraFlakeNameCollisions (
                unique (
                  (map (i: i.name) (_modulesToInputs (deduped ++ flatten extraModulesP2)))
                  ++ (map (r: r.subFlakeName) (_getModuleInputs (deduped ++ flatten extraModulesP2)))
                )
              ) != [ ]
            )
            "an icedos.system.extraFlakes name collides with a repository input or module sub-flake name — rename the extraFlake";

        # Over the same combined set the masked inputs are built from. Forced
        # only here: it forces urls, which the build stage must never do.
        duplicateInputGuard = _checkDuplicateModuleInputs (deduped ++ flatten extraModulesP2);

        # Same set, names only (no url forcing).
        duplicateSubFlakeNameGuard = _checkDuplicateSubFlakeNames (deduped ++ flatten extraModulesP2);
        subFlakeReservedNameGuard = _checkSubFlakeReservedNames (deduped ++ flatten extraModulesP2);

        outputs = externalOutputs // {
          inherit nixosModules loadedModules closureLib;
          # `seq` chain: reaching the generated flake's inputs runs every
          # genflake-stage guard.
          inputs =
            externalOutputs.inputs
            ++ extraOutputs.inputs
            ++ (seq (_validateExtraFlakes extraFlakes) (
              seq extraFlakeNameGuard (
                seq duplicateInputGuard (
                  seq duplicateSubFlakeNameGuard (seq subFlakeReservedNameGuard (extraFlakeInputs extraFlakes))
                )
              )
            ));

          # Names are unique per declaring module, so a plain merge is exact.
          subFlakes = externalOutputs.subFlakes // extraOutputs.subFlakes;
          options = externalOutputs.options ++ extraOutputs.options;
          nixosModulesText = externalOutputs.nixosModulesText ++ extraOutputs.nixosModulesText;
        };
      in
      outputs;
  };
in
finalIcedosLib
