# Eval-only lib tests; every value must be "ok". Run with `nix flake check`, or
# `nix eval --impure --json --expr '(import ./tests/tests.nix) { }'`.

{
  lib ? import <nixpkgs/lib>,
}:

let
  icedosLib = {
    abortIf = condition: message: if condition then throw message else true;
    # Real semantics: `_getRevisionFromLock` / `_resolveFlakeRevisionNested` force
    # them via `_readFlakeLock` / `_urlIsGitScheme`.
    stringStartsWith = prefix: str: lib.strings.hasPrefix prefix str;
    # Track the real constants so a constants.nix change fails the test instead
    # of silently passing; the rest of icedosLib is lazy, so it never evaluates.
    ICEDOS_STAGE = (import ../lib/constants.nix { }).ICEDOS_STAGE;
    ICEDOS_STATE_DIR = (import ../lib/constants.nix { }).ICEDOS_STATE_DIR;
    INPUTS_PREFIX = (import ../lib/constants.nix { }).INPUTS_PREFIX;
    generateAttrPath = throw "generateAttrPath is not stubbed in tests";
  };

  validate = (import ../lib/options/validate.nix { inherit icedosLib lib; }).validate;

  # extraOptions (lib/config/extra-options.nix) with the real abortIf/validate stubs.
  extraOptions =
    (import ../lib/config/extra-options.nix {
      inherit lib;
      icedosLib = {
        abortIf = icedosLib.abortIf;
        validate = validate;
      };
    }).extraOptions;

  extraSchema = {
    services.myapp = {
      enable = {
        type = "bool";
      };
      port = {
        type = "int";
        default = 8080;
      };
      name = {
        type = "string";
        minLength = 2;
        default = "app";
      };
    };
  };

  extraUserConfig = {
    services.myapp = {
      enable = true;
      port = 9000;
    };
  };

  extraEval =
    modules:
    (lib.evalModules {
      modules = [ e2eBase ] ++ modules;
    }).config;

  helpers = import ../lib/inputs.nix {
    inherit icedosLib lib;
    self = "tests";
  };

  expectOk = expr: if expr == true then "ok" else "FAIL: expected true, got ${builtins.toJSON expr}";

  expectEq =
    expected: expr:
    if expr == expected then
      "ok"
    else
      "FAIL: expected ${builtins.toJSON expected}, got ${builtins.toJSON expr}";

  expectThrow =
    expr:
    let
      r = builtins.tryEval expr;
    in
    if r.success then "FAIL: expected throw, got value ${builtins.toJSON r.value}" else "ok";

  expectThrowMatch =
    expr: needle:
    let
      r = builtins.tryEval expr;
    in
    if r.success then
      "FAIL: expected throw, got value ${builtins.toJSON r.value}"
    else
      # tryEval cannot inspect the thrown message, so we only confirm a throw.
      # The needle arg is documentation of the expected message fragment.
      "ok";

  # --- icedosLib.hasModule (scan.nix) ------------------------------------
  # Only the members hasModule forces are stubbed, with real semantics.
  hasModule =
    (import ../lib/scan.nix {
      inherit lib;
      self = "";
      icedosLib = {
        generateAttrPath = throw "stub: generateAttrPath";
        abortIf = condition: message: if condition then throw message else true;
        ICEDOS_STAGE = "";
        ICEDOS_STATE_DIR = "";
        INPUTS_PREFIX = "";
        stringStartsWith = prefix: str: lib.hasPrefix prefix str;
      };
    }).hasModule;

  # --- _mergeModuleLibs (icedos.nix) -------------------------------------
  # Stubbed base lib; only `_mergeModuleLibs` is forced (the rest is lazy).
  merge =
    (import ../lib/icedos.nix {
      inherit lib;
      config = { };
      inputs = { };
      pkgs = { };
      icedosLib = {
        foo = "baseFoo";
      };
    })._mergeModuleLibs;

  # --- _opaqueOrKey / _dedupeNixosModules (icedos.nix) ---------------------
  icedos = import ../lib/icedos.nix {
    inherit lib;
    config = { };
    inputs = { };
    pkgs = { };
    icedosLib = {
      foo = "baseFoo";
    };
  };

  # The real, fully-loaded lib for the e2e tests. `pkgs`/`inputs`/`config` stay
  # empty — nothing the driven functions force needs them.
  fullIcedos =
    let
      realLib = import ../lib/default.nix {
        inherit lib;
        config = { };
        inputs = { };
        pkgs = { };
        enableLogging = false;
        self = "tests";
      };
    in
    realLib;

  # `fullIcedos` with a caller-supplied config (forcing `modulesFromConfig` would
  # need a config root); `writeTextDir` stubbed so sub-flake urls need no build.
  mkIcedos =
    config:
    import ../lib/default.nix {
      inherit lib config;
      inputs = { };
      pkgs = {
        writeTextDir = _name: _text: {
          outPath = toString ../.;
        };
      };
      enableLogging = false;
      self = "tests";
    };

  # One extra flake configured (input + module load) and one input-only.
  efIcedos = mkIcedos {
    system.extraFlakes = [
      {
        name = "jovian";
        url = "github:jovian-experiments/jovian-nixos";
        inputs = {
          nixpkgs = {
            follows = "nixpkgs";
          };
        };
        modulesToLoad = [ "nixosModules.default" ];
      }
    ];
  };
  efBare = mkIcedos {
    system.extraFlakes = [
      {
        name = "jovian";
        url = "u";
      }
    ];
  };

  opaqueOrKey = icedos._opaqueOrKey;
  dedupe = icedos._dedupeNixosModules;

  # What the module system actually loaded. Option declarations stay out of the
  # emitted values, so those remain function-free and comparable.
  e2eEntries =
    emitted:
    (lib.evalModules {
      modules = [ e2eBase ] ++ emitted;
    }).config.entries;

  # Option declarations live here, not in the payloads: a `lib.types.*` value
  # carries a `merge` function and would make a payload opaque for the wrong reason.
  e2eBase = {
    options.entries = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };
  e2eEntriesWith =
    extra: emitted:
    (lib.evalModules {
      modules = [ e2eBase ] ++ extra ++ emitted;
    }).config.entries;

  # A function-free module value, emitted identically by two IceDOS modules.
  shared = {
    config.entries = [ "S" ];
  };

  # A derivation-shaped value (a real derivation is a cyclic attrset; keying
  # must never force one — `type` alone is inspected, no `drvPath` access).
  fakeDrv = {
    type = "derivation";
    name = "fake";
    drvPath = "/nix/store/00000000000000000000000000000000-fake.drv";
    out = { };
  };

  mod = url: name: contrib: {
    _repoInfo = { inherit url; };
    meta = { inherit name; };
    lib = contrib;
  };

  fakeConfig = loaded: { icedos.system.loadedModules = loaded; };
  loaded = {
    "github:icedos/apps" = [
      "btop"
      "steam"
    ];
    "github:icedos/desktop" = [ "default" ];
  };

  # --- module-input sub-flake fixtures (_getModuleInputs) -------------------
  # Empty config, so `_ambientInputNames` is the static set; `text` stays unforced.
  miMod =
    inputs:
    let
      r = (mkIcedos { })._getModuleInputs [
        {
          _repoInfo = {
            url = "github:icedos/hardware";
          };
          meta = {
            name = "aagl";
          };
          inherit inputs;
        }
      ];
    in
    builtins.head r;

  miAagl = miMod {
    aagl = {
      url = "github:ezKEa/aagl-gtk-on-nix";
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
    };
  };

  miSibling = miMod {
    base = {
      url = "github:x/base";
    };
    patched = {
      url = "github:x/patched";
      inputs = {
        nixpkgs = {
          follows = "base/nixpkgs";
        };
      };
    };
  };

  miShadow = miMod {
    nixpkgs = {
      url = "github:nixos/nixpkgs";
    };
    other = {
      url = "github:x/other";
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
    };
  };

  miCross = miMod {
    jovian = {
      url = "github:jovian-experiments/jovian-nixos";
      inputs = {
        nixpkgs = {
          follows = "icedos-github_icedos_providers-jovian/jovian";
        };
      };
    };
  };

  miUnknown = miMod {
    foo = {
      url = "github:x/foo";
      inputs = {
        nixpkgs = {
          follows = "unknown";
        };
      };
    };
  };

  miSelf = miMod {
    foo = {
      url = "github:x/foo";
      inputs = {
        nixpkgs = {
          follows = "self";
        };
      };
    };
  };

  # A follows nested two levels deep is valid flake syntax and must still be
  # collected, or it dangles in the sub-flake.
  miDeepFollows = miMod {
    foo = {
      url = "github:x/foo";
      inputs = {
        bar = {
          url = "github:x/bar";
          inputs = {
            baz = {
              follows = "nixpkgs";
            };
          };
        };
      };
    };
  };

  # A follows written directly on the input (not under `.inputs`) is collected
  # too, so its slot is emitted.
  miUrllessFollows = miMod {
    foo = {
      follows = "nixpkgs";
    };
  };

  # url + follows on one input is unrepresentable — genflake must abort instead
  # of emitting an un-lockable flake.
  miDirectFollows = miMod {
    foo = {
      url = "github:x/foo";
      follows = "nixpkgs";
    };
  };

  miPatched = miMod {
    foo = {
      url = "github:x/foo";
      patches = [ "dummy-patch" ];
    };
  };

  mockLock = original: locked: {
    nodes.apps = { inherit original locked; };
  };

  # Two-level lock shaped like the generated state flake's: sub-flake inputs are
  # either a node key (string) or a follows path (array).
  nestedLock = {
    nodes = {
      root = {
        inputs = {
          "icedos-github_icedos_providers-jovian" = "icedos-github_icedos_providers-jovian";
        };
        locked = { };
      };
      "icedos-github_icedos_providers-jovian" = {
        inputs = {
          jovian = "github:jovian-experiments/jovian-nixos";
          nixpkgs = [ "nixpkgs" ];
          missing_target = "github:missing/missing";
          gitinput = "git:https://x/y";
        };
        locked = {
          type = "path";
          path = "./subflakes/icedos-github_icedos_providers-jovian";
        };
      };
      "github:jovian-experiments/jovian-nixos" = {
        original = {
          type = "github";
          owner = "jovian-experiments";
          repo = "jovian-nixos";
        };
        locked = {
          type = "github";
          owner = "jovian-experiments";
          repo = "jovian-nixos";
          rev = "abcdef";
        };
      };
      "github:missing/missing" = {
        original = {
          type = "github";
          owner = "missing";
          repo = "missing";
        };
        locked = {
          type = "github";
          owner = "missing";
          repo = "missing";
          narHash = "h2";
        };
      };
      "git:https://x/y" = {
        original = {
          type = "git";
          url = "https://x/y";
        };
        locked = {
          type = "git";
          url = "https://x/y";
          rev = "beef";
        };
      };
    };
  };

  # Trivial module + root-input-shaped baseInputs, so forcing the result forces
  # `_extractNixosModules`' extraFlake/masked-name collision guard.
  extractJovian =
    base: extra:
    (mkIcedos (lib.optionalAttrs (extra != { }) { system.extraFlakes = [ extra ]; }))
    ._extractNixosModules
      {
        inputs = base;
        modules = [
          {
            _repoInfo = {
              url = "github:icedos/providers";
            };
            meta = {
              name = "jovian";
            };
            inputs.jovian = {
              url = "github:jovian-experiments/jovian-nixos";
            };
            outputs.nixosModules =
              { inputs, ... }:
              builtins.seq (builtins.attrNames inputs) [ ];
          }
        ];
      };

  extractBase = {
    nixpkgs = { };
    home-manager = { };
    "icedos-github_icedos_providers" = { };
    "icedos-github_icedos_providers-jovian" = {
      inputs = {
        jovian = { };
      };
    };
  };
in
{
  intHappy = expectOk (
    validate.int {
      min = 0;
      max = 100;
    } "icedos.test.int" null 50
  );

  intHappyNoBounds = expectOk (validate.int { } "icedos.test.int" null 999);

  intHappyMinOnly = expectOk (validate.int { min = 0; } "icedos.test.int" null 5);

  intHappyMaxOnly = expectOk (validate.int { max = 100; } "icedos.test.int" null 5);

  intLow = expectThrowMatch (validate.int {
    min = 0;
    max = 100;
  } "icedos.test.int" null (-1)) "below min";

  intHigh = expectThrowMatch (validate.int {
    min = 0;
    max = 100;
  } "icedos.test.int" null 150) "above max";

  intWrongType = expectThrowMatch (validate.int { } "icedos.test.int" null "abc") "expected int";

  intFloatRejected = expectThrow (validate.int { } "icedos.test.int" null 1.5);

  floatHappy = expectOk (
    validate.float {
      min = 0.0;
      max = 1.0;
    } "icedos.test.float" null 0.5
  );

  floatAcceptsInt = expectOk (
    validate.float {
      min = 0;
      max = 10;
    } "icedos.test.float" null 5
  );

  floatLow = expectThrow (
    validate.float {
      min = 0.0;
      max = 1.0;
    } "icedos.test.float" null (-0.5)
  );

  floatHigh = expectThrow (
    validate.float {
      min = 0.0;
      max = 1.0;
    } "icedos.test.float" null 2.0
  );

  enumHappy = expectOk (validate.enum [ "a" "b" "c" ] "icedos.test.enum" null "b");

  enumBad = expectThrowMatch (validate.enum [ "a" "b" ] "icedos.test.enum" null "z") "not in";

  enumIntChoices = expectOk (validate.enum [ 1 2 3 ] "icedos.test.enum" null 2);

  strHappy = expectOk (validate.str { minLen = 1; } "icedos.test.str" null "hi");

  strHappyNoConstraints = expectOk (validate.str { } "icedos.test.str" null "anything");

  strTooShort = expectThrow (validate.str { minLen = 5; } "icedos.test.str" null "ab");

  strTooLong = expectThrow (validate.str { maxLen = 3; } "icedos.test.str" null "toolong");

  strRegexHappy = expectOk (validate.str { regex = "[a-z]+"; } "icedos.test.str" null "abc");

  strRegexBad = expectThrow (validate.str { regex = "[a-z]+"; } "icedos.test.str" null "ABC");

  strWrongType = expectThrow (validate.str { } "icedos.test.str" null 42);

  nonEmptyHappyStr = expectOk (validate.nonEmpty "icedos.test.ne" null "hi");

  nonEmptyHappyList = expectOk (validate.nonEmpty "icedos.test.ne" null [ 1 ]);

  nonEmptyHappyAttrs = expectOk (validate.nonEmpty "icedos.test.ne" null { a = 1; });

  nonEmptyBadStr = expectThrow (validate.nonEmpty "icedos.test.ne" null "");

  nonEmptyBadList = expectThrow (validate.nonEmpty "icedos.test.ne" null [ ]);

  nonEmptyBadAttrs = expectThrow (validate.nonEmpty "icedos.test.ne" null { });

  listHappy = expectOk (
    validate.list
      {
        minLen = 1;
        maxLen = 3;
      }
      "icedos.test.list"
      null
      [
        1
        2
      ]
  );

  listEmptyOk = expectOk (validate.list { } "icedos.test.list" null [ ]);

  listEmptyMinViolation = expectThrow (validate.list { minLen = 1; } "icedos.test.list" null [ ]);

  listTooLong = expectThrow (
    validate.list { maxLen = 2; } "icedos.test.list" null [
      1
      2
      3
    ]
  );

  listWrongType = expectThrow (validate.list { } "icedos.test.list" null "not-a-list");

  listItemHappy = expectOk (
    validate.list
      {
        itemValidator = validate.int {
          min = 0;
          max = 10;
        };
      }
      "icedos.test.list"
      null
      [
        0
        5
        10
      ]
  );

  listItemBad = expectThrow (
    validate.list
      {
        itemValidator = validate.int {
          min = 0;
          max = 10;
        };
      }
      "icedos.test.list"
      null
      [
        5
        99
      ]
  );

  requiresSatisfied = expectOk (
    validate.requires {
      when = true;
      require = true;
      path = "icedos.test.req";
      msg = "must";
    }
  );

  requiresGateClosed = expectOk (
    validate.requires {
      when = false;
      require = false;
      path = "icedos.test.req";
      msg = "must";
    }
  );

  requiresViolated = expectThrowMatch (validate.requires {
    when = true;
    require = false;
    path = "icedos.test.req";
    msg = "customDnsServers must be non-empty when customDns is true";
  }) "customDnsServers";

  pathPlaceholder = expectThrow (
    validate.int {
      min = 0;
      max = 10;
    } null null 99
  );

  sourceIncluded = expectThrow (
    validate.int {
      min = 0;
      max = 10;
    } "p" "/some/file.toml" 99
  );

  # moduleInputName — the `<sub-flake>/<input>` path form, mirroring
  # `_getModuleInputs` (single source of truth).
  moduleInputNameJovian = expectEq "icedos-github_icedos_providers-jovian/jovian" (
    helpers.moduleInputName {
      repo = "github:icedos/providers";
      module = "jovian";
      input = "jovian";
    }
  );

  moduleInputNameNur = expectEq "icedos-github_icedos_providers-nur/nur" (
    helpers.moduleInputName {
      repo = "github:icedos/providers";
      module = "nur";
      input = "nur";
    }
  );

  # repo/module pass through mkInputName's URL-char sanitization; `input` is a Nix
  # attr identifier in production and is appended verbatim.
  moduleInputNameSanitizesUrlChars =
    expectEq "icedos-https___example_com_blog_from_1-the_post/nixpkgs"
      (
        helpers.moduleInputName {
          repo = "https://example.com/blog?from=1";
          module = "the.post";
          input = "nixpkgs";
        }
      );

  # A patched module's inputs split into an unpatched node (named `<input>_source`)
  # and a patched node — the `_source` variant mirrors _getModuleInputs' normalInput.
  moduleInputNamePatchedSource = expectEq "icedos-github_icedos_providers-jovian/jovian_source" (
    helpers.moduleInputName {
      repo = "github:icedos/providers";
      module = "jovian";
      input = "jovian_source";
    }
  );

  # moduleSubFlakeName — the root input name a module's inputs live under.
  moduleSubFlakeNameJovian = expectEq "icedos-github_icedos_providers-jovian" (
    helpers.moduleSubFlakeName {
      repo = "github:icedos/providers";
      module = "jovian";
    }
  );

  # The path form is exactly the sub-flake name plus "/" plus the input name.
  moduleInputNameComposesFromSubFlakeName = expectOk (
    helpers.moduleInputName {
      repo = "github:icedos/providers";
      module = "jovian";
      input = "nur";
    } == "${
      helpers.moduleSubFlakeName {
        repo = "github:icedos/providers";
        module = "jovian";
      }
    }/nur"
  );

  # --- module-input sub-flakes: _getModuleInputs / _checkDuplicateModuleInputs ----
  # The root's `-subflake` suffix is load-bearing: build.sh keys on it.
  subFlakeNameAagl = expectEq "icedos-github_icedos_hardware-aagl" miAagl.subFlakeName;
  subFlakeRootDeclIsStorePath = expectOk (
    lib.strings.hasPrefix "path:/nix/store/" miAagl.input.value.url
  );
  subFlakeRootDeclNamed = expectOk (
    lib.strings.hasSuffix "icedos-github_icedos_hardware-aagl-subflake" miAagl.input.value.url
  );
  subFlakeSlotFollows = expectEq "nixpkgs" miAagl.input.value.inputs.nixpkgs.follows;

  # Masked mapping: sub-flake tag + original bare name + path-form `name`.
  subFlakeMasked = expectEq {
    _originalName = "aagl";
    _subFlake = "icedos-github_icedos_hardware-aagl";
    name = "icedos-github_icedos_hardware-aagl/aagl";
  } (builtins.head miAagl.masked);

  # The slot assertion targets the empty decl (`nixpkgs = { }`), not the bare
  # name — the decl's own follows contains "nixpkgs" too.
  subFlakeTextHasUrl = expectOk (lib.strings.hasInfix "github:ezKEa/aagl-gtk-on-nix" miAagl.text);
  subFlakeTextHasSlot = expectOk (lib.strings.hasInfix "nixpkgs = { }" miAagl.text);

  # Config-root extra modules export sub-flakes too; if one goes missing,
  # genflake emits no root input and the module's input stops resolving.
  extraSourceSubFlake = expectOk (
    (fullIcedos.getExternalModuleOutputs [
      (
        mod "config" "extra-with-input" null
        // {
          inputs.foo = {
            url = "github:x/foo";
          };
        }
      )
    ]).subFlakes ? icedos-config-extra-with-input
  );
  # Multi-segment follows whose first segment is a *sibling* input is legal and
  # emits no slot (base is not ambient).
  subFlakeSiblingFollowsLegal = expectOk (miSibling.input ? value);
  subFlakeSiblingFollowsNoSlot = expectEq { } miSibling.input.value.inputs;

  # A module declaring its own `nixpkgs` shadows the ambient name: legal, but no
  # slot is emitted for it (the follows resolves to the module's own input).
  subFlakeAmbientShadowed = expectOk (miShadow.input ? value);
  subFlakeAmbientShadowedNoSlot = expectEq { } miShadow.input.value.inputs;

  # Cross-module follows (first segment a sub-flake name) and unknown segments
  # abort when the root input decl is forced (genflake naming the declarer).
  subFlakeCrossModuleAbort = expectThrow miCross.input;
  subFlakeUnknownSegmentAbort = expectThrow miUnknown.input;

  # `self` is not ambient either (the generated flake has no `inputs.self`) →
  # aborts like any unresolvable first segment.
  subFlakeSelfAbort = expectThrow miSelf.input;

  # A nested follows' first segment still becomes a slot the parent rewires.
  subFlakeDeepFollowsSlot = expectEq "nixpkgs" miDeepFollows.input.value.inputs.nixpkgs.follows;
  subFlakeDeepFollowsText = expectOk (lib.strings.hasInfix "nixpkgs = { }" miDeepFollows.text);

  # Url-less follows-only input: the input's OWN `follows` is collected (not just
  # `inputs.*.follows`), emitting the ambient slot it shadows.
  subFlakeUrllessFollowsSlot = expectEq "nixpkgs" miUrllessFollows.input.value.inputs.nixpkgs.follows;

  # url + follows on the same input is unrepresentable in a sub-flake — abort
  # (naming the declarer) rather than emit an un-lockable flake.
  subFlakeDirectFollowsAbort = expectThrow miDirectFollows.input;

  # Pin `_ambientInputNames` against genflake's root-input emission, so drift in
  # either direction fails here. Subset-based: /etc/icedos is machine-dependent.
  ambientSetStatic = expectOk (
    lib.all (n: lib.elem n (mkIcedos { })._ambientInputNames) [
      "nixpkgs"
      "home-manager"
      "icedos-config"
      "icedos-core"
    ]
  );
  ambientSetMirrorsConfig = expectOk (
    let
      s =
        (mkIcedos {
          system = {
            channels = [
              {
                name = "mychannel";
                url = "github:x/y";
              }
            ];
            overlays = {
              fromChannel = [
                {
                  url = "https://example.com/overlay";
                  packages = [ "foo" ];
                }
                # Empty-packages and channel-mode overlay entries are not root
                # inputs in genflake — and must not be followable slots either.
                {
                  url = "https://example.com/dropped";
                  packages = [ ];
                }
                {
                  channel = "mychannel";
                  packages = [ "bar" ];
                }
              ];
            };
            extraFlakes = [
              {
                name = "myflake";
                url = "u";
              }
            ];
          };
        })._ambientInputNames;
    in
    lib.all (n: lib.elem n s) [
      "mychannel"
      # `mkInputName { parts = [ "overlay" url ] }` → prefix "icedos-" + part
      # "overlay" joined by "_" → dash after "overlay", underscore before url.
      "icedos-overlay-https___example_com_overlay"
      "myflake"
    ]
    && !lib.elem "icedos-overlay-https___example_com_dropped" s
    && !lib.elem "icedos-overlay-mychannel" s
  );

  # An extraFlake named like a module's sub-flake aborts; without it the same
  # module extracts cleanly.
  subFlakeExtraFlakeCollision = expectThrow (
    extractJovian extractBase {
      name = "icedos-github_icedos_providers-jovian";
      url = "u";
    }
  );
  subFlakeExtraFlakeNoCollision = expectEq [ ] (extractJovian extractBase { });

  # Patched input: `masked` carries both the `_source` and the patched node (the
  # real sub-flake name / manifest key), without forcing the patched store path.
  subFlakePatchedMasked = expectEq [
    {
      _originalName = "foo_source";
      _subFlake = "icedos-github_icedos_hardware-aagl";
      name = "icedos-github_icedos_hardware-aagl/foo_source";
    }
    {
      _originalName = "foo";
      _subFlake = "icedos-github_icedos_hardware-aagl";
      name = "icedos-github_icedos_hardware-aagl/foo";
    }
  ] miPatched.masked;

  # Duplicate bare input name: same url across declarers is fine (lock dedups the
  # node), different urls abort naming both declarers.
  dupInputSameUrl = expectOk (
    (mkIcedos { })._checkDuplicateModuleInputs [
      {
        _repoInfo = {
          url = "github:icedos/apps";
        };
        meta = {
          name = "a";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/desktop";
        };
        meta = {
          name = "b";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
    ]
  );
  dupInputDiffUrl = expectThrow (
    (mkIcedos { })._checkDuplicateModuleInputs [
      {
        _repoInfo = {
          url = "github:icedos/apps";
        };
        meta = {
          name = "a";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/desktop";
        };
        meta = {
          name = "b";
        };
        inputs = {
          foo = {
            url = "github:p/q";
          };
        };
      }
    ]
  );
  # Same url but DIFFERENT patch sets realise two different trees, and the masked
  # set (`listToAttrs` keyed by bare name) would silently pick one — abort.
  dupInputSameUrlDiffPatches = expectThrow (
    (mkIcedos { })._checkDuplicateModuleInputs [
      {
        _repoInfo = {
          url = "github:icedos/apps";
        };
        meta = {
          name = "a";
        };
        inputs = {
          foo = {
            url = "github:x/y";
            patches = [ ../lib/icedos.nix ];
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/desktop";
        };
        meta = {
          name = "b";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
    ]
  );
  # Same url AND the same patch set is still fine (lock dedups the node).
  dupInputSameUrlSamePatches = expectOk (
    (mkIcedos { })._checkDuplicateModuleInputs [
      {
        _repoInfo = {
          url = "github:icedos/apps";
        };
        meta = {
          name = "a";
        };
        inputs = {
          foo = {
            url = "github:x/y";
            patches = [ ../lib/icedos.nix ];
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/desktop";
        };
        meta = {
          name = "b";
        };
        inputs = {
          foo = {
            url = "github:x/y";
            patches = [ ../lib/icedos.nix ];
          };
        };
      }
    ]
  );

  # Same url AND the same follow/override decl is still fine — the lock dedups
  # the node and the masked mapping is unambiguous.
  dupInputSameUrlSameDecl = expectOk (
    (mkIcedos { })._checkDuplicateModuleInputs [
      {
        _repoInfo = {
          url = "github:icedos/apps";
        };
        meta = {
          name = "a";
        };
        inputs = {
          foo = {
            url = "github:x/y";
            follows = "nixpkgs";
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/desktop";
        };
        meta = {
          name = "b";
        };
        inputs = {
          foo = {
            url = "github:x/y";
            follows = "nixpkgs";
          };
        };
      }
    ]
  );
  # Same name and url but different nested decls are two different nodes, and
  # the masked set could only keep one — abort.
  dupInputSameUrlDiffDecl = expectThrow (
    (mkIcedos { })._checkDuplicateModuleInputs [
      {
        _repoInfo = {
          url = "github:icedos/apps";
        };
        meta = {
          name = "a";
        };
        inputs = {
          foo = {
            url = "github:x/y";
            follows = "nixpkgs";
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/desktop";
        };
        meta = {
          name = "b";
        };
        inputs = {
          foo = {
            url = "github:x/y";
            follows = "home-manager";
          };
        };
      }
    ]
  );

  # `mkInputName` keeps `-`, so `hardware#cachyos-kernel` and
  # `hardware-cachyos#kernel` sanitize to one root name — abort.
  subFlakeNameDistinctOk = expectOk (
    (mkIcedos { })._checkDuplicateSubFlakeNames [
      {
        _repoInfo = {
          url = "github:icedos/hardware";
        };
        meta = {
          name = "cachyos-kernel";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/apps";
        };
        meta = {
          name = "aagl";
        };
        inputs = {
          bar = {
            url = "github:p/q";
          };
        };
      }
    ]
  );
  subFlakeNameSameDeclarerOk = expectOk (
    (mkIcedos { })._checkDuplicateSubFlakeNames [
      {
        _repoInfo = {
          url = "github:icedos/hardware";
        };
        meta = {
          name = "cachyos-kernel";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/hardware";
        };
        meta = {
          name = "cachyos-kernel";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
    ]
  );
  # Same sub-flake name from different repos whose names differ only in a
  # `-`/`.`-split: both declarers abort.
  subFlakeNameCollisionAcrossRepos = expectThrow (
    (mkIcedos { })._checkDuplicateSubFlakeNames [
      {
        _repoInfo = {
          url = "github:icedos/hardware";
        };
        meta = {
          name = "cachyos-kernel";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/hardware-cachyos";
        };
        meta = {
          name = "kernel";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
    ]
  );
  # Same repo, two module names differing only in sanitized characters.
  subFlakeNameCollisionWithinRepo = expectThrow (
    (mkIcedos { })._checkDuplicateSubFlakeNames [
      {
        _repoInfo = {
          url = "github:icedos/apps";
        };
        meta = {
          name = "my.mod";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/apps";
        };
        meta = {
          name = "my_mod";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
    ]
  );
  # The second module declares no inputs → no sub-flake → no collision.
  subFlakeNameInputlessIgnored = expectOk (
    (mkIcedos { })._checkDuplicateSubFlakeNames [
      {
        _repoInfo = {
          url = "github:icedos/hardware";
        };
        meta = {
          name = "cachyos-kernel";
        };
        inputs = {
          foo = {
            url = "github:x/y";
          };
        };
      }
      {
        _repoInfo = {
          url = "github:icedos/hardware-cachyos";
        };
        meta = {
          name = "kernel";
        };
      }
    ]
  );

  # --- _resolveFlakeRevisionLocked / _resolveFlakeRevisionNested (inputs.nix) ---
  # The pure tail resolves a pinned rev from a lock + node key.
  revLockedGithub = expectEq "/abc" (
    helpers._resolveFlakeRevisionLocked {
      url = "github:icedos/apps";
      nodeKey = "apps";
      lock =
        mockLock
          {
            type = "github";
            owner = "icedos";
            repo = "apps";
          }
          {
            type = "github";
            owner = "icedos";
            repo = "apps";
            rev = "abc";
            narHash = "h0";
          };
    }
  );

  # git+ url: git scheme → `?rev=` form (with the git+ prefix kept in the url).
  revLockedGitScheme = expectEq "?rev=abc" (
    helpers._resolveFlakeRevisionLocked {
      url = "git+https://example.com/x";
      nodeKey = "apps";
      lock =
        mockLock
          {
            type = "git";
            url = "https://example.com/x";
          }
          {
            type = "git";
            url = "https://example.com/x";
            rev = "abc";
          };
    }
  );

  # The node's `original` no longer describes `url` (overrideUrl toggled) → the
  # pin is invalidated and "" is returned so the input re-resolves from scratch.
  revLockedMismatch = expectEq "" (
    helpers._resolveFlakeRevisionLocked {
      url = "github:icedos/apps";
      nodeKey = "apps";
      lock =
        mockLock
          {
            type = "github";
            owner = "other";
            repo = "apps";
          }
          {
            type = "github";
            owner = "other";
            repo = "apps";
            rev = "abc";
          };
    }
  );

  revLockedPath = expectEq "/abc" (
    helpers._resolveFlakeRevisionLocked {
      url = "path:/abs/x";
      nodeKey = "apps";
      lock =
        mockLock
          {
            type = "path";
            path = "/abs/x";
          }
          {
            type = "path";
            path = "/abs/x";
            rev = "abc";
          };
    }
  );

  revLockedNarHashOnly = expectEq "?narHash=h1" (
    helpers._resolveFlakeRevisionLocked {
      url = "github:icedos/apps";
      nodeKey = "apps";
      lock =
        mockLock
          {
            type = "github";
            owner = "icedos";
            repo = "apps";
          }
          {
            type = "github";
            owner = "icedos";
            repo = "apps";
            narHash = "h1";
          };
    }
  );

  # Two-hop nested lookup with no lock present: ICEDOS_STATE_DIR is empty in
  # tests, so `_readFlakeLock` returns null → "" (fallback to latest).
  revNestedNoLock = expectEq "" (
    helpers._resolveFlakeRevisionNested {
      url = "github:x/y";
      subFlakeName = "icedos-github_icedos_providers-jovian";
      inputName = "jovian";
    }
  );

  # Two-hop nested lookup over a mock lock (`_resolveFlakeRevisionNestedLocked`):
  # root → sub-flake node key → input node key, then the shared locked tail.
  revNestedStringHops = expectEq "/abcdef" (
    helpers._resolveFlakeRevisionNestedLocked {
      url = "github:jovian-experiments/jovian-nixos";
      subFlakeName = "icedos-github_icedos_providers-jovian";
      inputName = "jovian";
      lock = nestedLock;
    }
  );
  # A follows-array where a node key was expected (e.g. `nixpkgs = [ "nixpkgs" ]`)
  # is not a resolvable hop → "".
  revNestedFollowsArray = expectEq "" (
    helpers._resolveFlakeRevisionNestedLocked {
      url = "github:nixos/nixpkgs";
      subFlakeName = "icedos-github_icedos_providers-jovian";
      inputName = "nixpkgs";
      lock = nestedLock;
    }
  );
  # Unknown sub-flake name → first hop misses → "".
  revNestedMissingSub = expectEq "" (
    helpers._resolveFlakeRevisionNestedLocked {
      url = "github:x/y";
      subFlakeName = "no-such-sub";
      inputName = "jovian";
      lock = nestedLock;
    }
  );
  # Sub-flake node without the input → second hop misses → "".
  revNestedMissingInput = expectEq "" (
    helpers._resolveFlakeRevisionNestedLocked {
      url = "github:x/y";
      subFlakeName = "icedos-github_icedos_providers-jovian";
      inputName = "no-such-input";
      lock = nestedLock;
    }
  );
  # The resolved leaf has only a narHash → "?narHash=…" (same tail as the
  # single-hop case).
  revNestedNarHashOnly = expectEq "?narHash=h2" (
    helpers._resolveFlakeRevisionNestedLocked {
      url = "github:missing/missing";
      subFlakeName = "icedos-github_icedos_providers-jovian";
      inputName = "missing_target";
      lock = nestedLock;
    }
  );
  # Git-scheme leaf (git+…) encodes the rev as a query param.
  revNestedGitScheme = expectEq "?rev=beef" (
    helpers._resolveFlakeRevisionNestedLocked {
      url = "git+https://x/y";
      subFlakeName = "icedos-github_icedos_providers-jovian";
      inputName = "gitinput";
      lock = nestedLock;
    }
  );
  # The leaf's `original` no longer describes `url` → pin invalidated, "".
  revNestedMismatch = expectEq "" (
    helpers._resolveFlakeRevisionNestedLocked {
      url = "github:other/nixos";
      subFlakeName = "icedos-github_icedos_providers-jovian";
      inputName = "jovian";
      lock = nestedLock;
    }
  );
  # --- hasModule (scan.nix) ---------------------------------------------

  hasModuleNamePresent = expectOk (hasModule {
    config = fakeConfig loaded;
    name = "steam";
  });
  hasModuleNameAbsent = expectOk (
    !(hasModule {
      config = fakeConfig loaded;
      name = "ghost";
    })
  );
  hasModuleUrlMatch = expectOk (hasModule {
    config = fakeConfig loaded;
    url = "github:icedos/apps";
    name = "btop";
  });
  # url branch: name not in that repo -> false (it is in another repo)
  hasModuleUrlWrongRepo = expectOk (
    !(hasModule {
      config = fakeConfig loaded;
      url = "github:icedos/desktop";
      name = "steam";
    })
  );
  hasModuleUrlNoSuchRepo = expectOk (
    !(hasModule {
      config = fakeConfig loaded;
      url = "github:icedos/ghost";
      name = "btop";
    })
  );
  hasModuleRepoUrlMatch = expectOk (hasModule {
    config = fakeConfig loaded;
    repoUrl = "github:icedos/desktop";
    modules = [ "default" ];
  });
  hasModuleModulesAll = expectOk (hasModule {
    config = fakeConfig loaded;
    modules = [
      "btop"
      "steam"
    ];
  });
  hasModuleModulesPartial = expectOk (
    !(hasModule {
      config = fakeConfig loaded;
      modules = [
        "btop"
        "ghost"
      ];
    })
  );
  # empty loadedModules + valid call -> false, not an abort (the vacuous-truth hole)
  hasModuleEmptyLoadedValid = expectOk (
    !(hasModule {
      config = fakeConfig { };
      name = "btop";
    })
  );
  # empty modules list -> abort (vacuous-truth guard)
  hasModuleEmptyModulesAbort = expectThrow (hasModule {
    config = fakeConfig loaded;
    modules = [ ];
  });
  hasModuleNeitherAbort = expectThrow (hasModule {
    config = fakeConfig loaded;
  });
  # empty loadedModules + malformed call -> still aborts (seq forces the guard)
  hasModuleEmptyLoadedMalformed = expectThrow (hasModule {
    config = fakeConfig { };
  });

  mergeHappy = expectOk (
    (merge [
      (mod "github:icedos/a" "m1" { alpha = 1; })
      (mod "github:icedos/b" "m2" { beta = 2; })
    ]).beta == 2
  );
  mergeCollidesBase = expectThrowMatch (merge [
    (mod "github:icedos/a" "m1" { foo = "shadow"; })
  ]) "Duplicate icedosLib name 'foo'";
  mergeCollidesAcross = expectThrowMatch (merge [
    (mod "github:icedos/a" "m1" { bar = 1; })
    (mod "github:icedos/b" "m2" { bar = 2; })
  ]) "Duplicate icedosLib name 'bar'";
  # a non-attrset `lib` field -> friendly throw (never `attrNames` on a string)
  mergeNotAttrs = expectThrowMatch (merge [
    (mod "github:icedos/a" "m1" "not-an-attrset")
  ]) "must be an attrset";

  # --- _opaqueOrKey (icedos.nix) ------------------------------------------
  # A function is opaque (closures cannot be compared) — never a dedup key.
  opaqueFn = expectEq null (opaqueOrKey (x: x));
  # Scalars key as tagged `kind` values (so 42 ≠ 42.0, "abc" ≠ a path, …).
  opaqueString = expectEq {
    kind = "str";
    value = "abc";
  } (opaqueOrKey "abc");
  opaqueInt = expectEq {
    kind = "int";
    value = 42;
  } (opaqueOrKey 42);
  opaqueBool = expectEq {
    kind = "bool";
    value = true;
  } (opaqueOrKey true);
  opaqueFloat = expectEq {
    kind = "float";
    value = 1.5;
  } (opaqueOrKey 1.5);
  # A path keys to a `path`-tagged store string (two refs to the same file
  # dedup, and a path never collides with an equal-looking plain string).
  opaquePath = expectEq {
    kind = "path";
    value = toString ./fixtures/tests-fixture-module.nix;
  } (opaqueOrKey ./fixtures/tests-fixture-module.nix);
  # `null` keys as its own kind (a module value carrying `null` can dedup).
  opaqueNull = expectEq { kind = "null"; } (opaqueOrKey null);
  # Keying inspects `type` alone and never forces a derivation (cyclic attrset;
  # forcing `drvPath` could instantiate).
  opaqueDerivation = expectEq null (opaqueOrKey {
    type = "derivation";
    name = "fake";
    drvPath = "/nix/store/00000000000000000000000000000000-fake.drv";
    out = { };
  });
  # A derivation inside a larger value makes the whole value opaque.
  opaqueDerivationInValue = expectEq null (opaqueOrKey {
    p = fakeDrv;
  });
  # `_type` wrappers are opaque: keying must not descend into branches the module
  # system may drop. `abort` is not caught by tryEval, so only the guard saves this.
  opaquePropertyWrapper = expectEq null (opaqueOrKey (lib.mkIf false (abort "unforced")));
  # Option declarations are `_type`-tagged, so duplicates still fail loudly
  # instead of being silently merged.
  opaqueOptionDecl = expectEq null (opaqueOrKey {
    options.x = lib.mkOption { type = lib.types.str; };
  });
  # A self-referential (cyclic) value degrades to opaque, not `max-call-depth`.
  opaqueCycle = expectEq null (
    opaqueOrKey (
      let
        self = { inherit self; };
      in
      self
    )
  );
  # A value that throws when forced degrades to opaque (never-fetch = opaque).
  opaqueThrows = expectEq null (opaqueOrKey (throw "broken"));
  # Depth-cap boundary on an acyclic value: a 50-deep nest is still keyed, a
  # 51-deep nest exceeds `maxDepth = 50` and degrades to opaque.
  opaqueDepthCap = expectOk (
    opaqueOrKey (builtins.foldl' (acc: _: [ acc ]) 0 (builtins.genList (x: x) 50)) != null
    && opaqueOrKey (builtins.foldl' (acc: _: [ acc ]) 0 (builtins.genList (x: x) 51)) == null
  );
  opaqueList =
    expectEq
      {
        kind = "list";
        keys = [
          {
            kind = "int";
            value = 1;
          }
          {
            kind = "str";
            value = "a";
          }
          {
            kind = "bool";
            value = true;
          }
        ];
      }
      (opaqueOrKey [
        1
        "a"
        true
      ]);
  # Attrsets recurse per attribute (sorted — `==` on the result is stable).
  opaqueAttrs =
    expectEq
      {
        kind = "attrs";
        keys = [
          {
            name = "a";
            key = {
              kind = "int";
              value = 1;
            };
          }
          {
            name = "b";
            key = {
              kind = "str";
              value = "x";
            };
          }
        ];
      }
      (opaqueOrKey {
        a = 1;
        b = "x";
      });
  opaqueNested =
    expectEq
      {
        kind = "attrs";
        keys = [
          {
            name = "a";
            key = {
              kind = "list";
              keys = [
                {
                  kind = "attrs";
                  keys = [
                    {
                      name = "b";
                      key = {
                        kind = "str";
                        value = "y";
                      };
                    }
                  ];
                }
              ];
            };
          }
        ];
      }
      (opaqueOrKey {
        a = [ { b = "y"; } ];
      });
  # Opaque-ness bubbles up: any function anywhere makes the whole key null.
  opaqueFnInList = expectEq null (opaqueOrKey [
    1
    (x: x)
  ]);
  opaqueFnInAttrs = expectEq null (opaqueOrKey {
    config = { pkgs, ... }: { };
  });
  # The `kind` tag keeps different shapes apart: `{ }` vs `[ ]`, a path vs its
  # store string, `42` vs `42.0` (Nix treats int == float as equal).
  opaqueKindListVsAttrs = expectOk (opaqueOrKey [ ] != opaqueOrKey { });
  opaqueKindPathVsString = expectOk (
    opaqueOrKey ./fixtures/tests-fixture-module.nix
    != opaqueOrKey (toString ./fixtures/tests-fixture-module.nix)
  );
  opaqueKindIntVsFloat = expectOk (opaqueOrKey 42 != opaqueOrKey 42.0);
  # Two structurally-identical (differently-ordered) values get equal keys.
  opaqueEqOrder = expectOk (
    opaqueOrKey {
      a = 1;
      b = {
        c = "x";
      };
    } == opaqueOrKey {
      b = {
        c = "x";
      };
      a = 1;
    }
  );

  # --- _dedupeNixosModules (icedos.nix) ------------------------------------

  # Two shims wrapping the same function-free value dedup to the first (its
  # `_file` survives for provenance).
  dedupeKeepsFirst =
    expectEq
      [
        (lib.setDefaultModuleLocation "locA" shared)
      ]
      (dedupe [
        (lib.setDefaultModuleLocation "locA" shared)
        (lib.setDefaultModuleLocation "locB" shared)
      ]);
  dedupeFirstFile = expectOk (
    (builtins.head (dedupe [
      (lib.setDefaultModuleLocation "locA" shared)
      (lib.setDefaultModuleLocation "locB" shared)
    ]))._file == "locA"
  );
  # A bare value and its shim-wrapped twin still dedup (unwrap happens first).
  dedupeBareAndShim = expectEq [ shared ] (dedupe [
    shared
    (lib.setDefaultModuleLocation "loc" shared)
  ]);
  dedupeDistinct = expectEq 2 (
    builtins.length (dedupe [
      (lib.setDefaultModuleLocation "l1" { config.entries = [ "A" ]; })
      (lib.setDefaultModuleLocation "l2" { config.entries = [ "B" ]; })
    ])
  );
  # Functions are opaque — even syntactically-identical ones are never merged.
  dedupeFnsKept = expectEq 2 (
    builtins.length (dedupe [
      (lib.setDefaultModuleLocation "l1" (_: {
        config.entries = [ "F" ];
      }))
      (lib.setDefaultModuleLocation "l2" (_: {
        config.entries = [ "F" ];
      }))
    ])
  );
  # A shim-wrapped path (the jovian shape) dedups to one.
  dedupePath =
    expectEq
      [
        (lib.setDefaultModuleLocation "locA" ./fixtures/tests-fixture-module.nix)
      ]
      (dedupe [
        (lib.setDefaultModuleLocation "locA" ./fixtures/tests-fixture-module.nix)
        (lib.setDefaultModuleLocation "locB" ./fixtures/tests-fixture-module.nix)
      ]);
  # Dedup preserves the relative order of kept modules (order affects
  # merge/priority precedence), each distinct value kept once.
  dedupeOrder = expectEq [ "l1" "l2" "l3" ] (
    map (m: m._file) (dedupe [
      (lib.setDefaultModuleLocation "l1" { config.entries = [ "A" ]; })
      (lib.setDefaultModuleLocation "l2" { config.entries = [ "B" ]; })
      (lib.setDefaultModuleLocation "l3" { config.entries = [ "C" ]; })
    ])
  );
  # Order is also preserved when a duplicate is dropped in the middle: the
  # kept (first) occurrence's position wins, later ones are skipped in place.
  dedupeDropKeepsOrder = expectEq [ "l1" "l3" ] (
    map (m: m._file) (dedupe [
      (lib.setDefaultModuleLocation "l1" { config.entries = [ "A" ]; })
      (lib.setDefaultModuleLocation "l2" { config.entries = [ "A" ]; })
      (lib.setDefaultModuleLocation "l3" { config.entries = [ "B" ]; })
    ])
  );

  # --- end-to-end: identical module values through evalModules -------------
  # Raw emission loads the identical value twice (the gap this closes).
  e2eRawDouble = expectEq [ "S" "S" ] (e2eEntries [
    (lib.setDefaultModuleLocation "locA" shared)
    (lib.setDefaultModuleLocation "locB" shared)
  ]);
  e2eDeduped = expectEq [ "S" ] (
    e2eEntries (dedupe [
      (lib.setDefaultModuleLocation "locA" shared)
      (lib.setDefaultModuleLocation "locB" shared)
    ])
  );
  # Distinct values both survive dedup (nixpkgs merge order is unspecified,
  # so compare as a set).
  e2eDistinct = expectOk (
    let
      result = e2eEntries (dedupe [
        (lib.setDefaultModuleLocation "l1" { config.entries = [ "A" ]; })
        (lib.setDefaultModuleLocation "l2" { config.entries = [ "B" ]; })
      ]);
    in
    builtins.length result == 2 && builtins.elem "A" result && builtins.elem "B" result
  );
  # Function module values are never merged, even when identical.
  e2eFns = expectEq [ "F" "F" ] (
    e2eEntries (dedupe [
      (lib.setDefaultModuleLocation "l1" (_: {
        config.entries = [ "F" ];
      }))
      (lib.setDefaultModuleLocation "l2" (_: {
        config.entries = [ "F" ];
      }))
    ])
  );
  # Shim-wrapped identical paths (the jovian case) dedup to one.
  e2ePath = expectEq [ "S" ] (
    e2eEntries (dedupe [
      (lib.setDefaultModuleLocation "locA" ./fixtures/tests-fixture-module.nix)
      (lib.setDefaultModuleLocation "locB" ./fixtures/tests-fixture-module.nix)
    ])
  );

  # ── cross-source: repo (external) + config-root (extra) modules ────────────
  # Mirrors `modulesFromConfig.nixosModules`: each source dedups, then the combine does.
  crossSourceDedup =
    let
      emit =
        url: name:
        (mod url name null)
        // {
          outputs.nixosModules = _: [ shared ];
        };
      extract = src: fullIcedos.getExternalModuleOutputs src;
    in
    expectEq [ "S" ] (
      e2eEntries (
        dedupe (
          (extract [ (emit "path:src" "dup-a") ]).nixosModules { inputs = { }; }
          ++ (extract [ (emit "config" "duptest-extra") ]).nixosModules { inputs = { }; }
        )
      )
    );

  # Two config-root extra modules emitting the same value, flattened as one
  # source (the `extraModulesP2` list), load it once.
  extraOnlyDedup =
    let
      emit =
        name:
        (mod "config" name null)
        // {
          outputs.nixosModules = _: [ shared ];
        };
    in
    expectEq [ "S" ] (
      e2eEntries (
        (fullIcedos.getExternalModuleOutputs [
          (emit "x-a")
          (emit "x-b")
        ]).nixosModules
          { inputs = { }; }
      )
    );

  crossSourceDistinct = expectOk (
    let
      emit =
        url: name: value:
        (mod url name null)
        // {
          outputs.nixosModules = _: [ value ];
        };
      extract = src: fullIcedos.getExternalModuleOutputs src;
      result = e2eEntries (
        dedupe (
          (extract [ (emit "path:src" "dup-a" { config.entries = [ "A" ]; }) ]).nixosModules { inputs = { }; }
          ++ (extract [ (emit "config" "duptest-extra" { config.entries = [ "B" ]; }) ]).nixosModules {
            inputs = { };
          }
        )
      );
    in
    builtins.length result == 2 && builtins.elem "A" result && builtins.elem "B" result
  );

  # ── icedos.system.extraFlakes ─────────────────────────────────────────────
  # Driven on `mkIcedos` directly; `modulesFromConfig` would need a config root.

  # Flake-input emission: `{ url; inputs; }` value (modulesToLoad stripped),
  # so `inputs.<x>.follows` passthrough survives into the generated flake.
  efInputs = expectEq [
    {
      name = "jovian";
      value = {
        url = "github:jovian-experiments/jovian-nixos";
        inputs = {
          nixpkgs = {
            follows = "nixpkgs";
          };
        };
      };
    }
  ] ((mkIcedos { }).extraFlakeInputs (efIcedos.extraFlakes));
  efInputsBare =
    expectEq
      [
        {
          name = "x";
          value = {
            url = "y";
          };
        }
      ]
      (
        (mkIcedos { }).extraFlakeInputs [
          {
            name = "x";
            url = "y";
          }
        ]
      );
  # Masked-input entries carry the bare name in both fields (the
  # `_createMaskedInputs` contract).
  efMasked = expectEq [
    {
      _originalName = "jovian";
      name = "jovian";
    }
  ] ((mkIcedos { }).extraFlakeMaskedInputs efIcedos.extraFlakes);
  efValid = expectOk ((mkIcedos { })._validateExtraFlakes [ ]);
  efValidEntry = expectOk ((mkIcedos { })._validateExtraFlakes efIcedos.extraFlakes);
  # Validation rejects: reserved name, duplicate names, bad name regex, empty
  # url, unknown key, empty modulesToLoad path.
  efReserved = expectThrow (
    (mkIcedos { })._validateExtraFlakes [
      {
        name = "nixpkgs";
        url = "x";
      }
    ]
  );
  efDuplicate = expectThrow (
    (mkIcedos { })._validateExtraFlakes [
      {
        name = "a";
        url = "x";
      }
      {
        name = "a";
        url = "y";
      }
    ]
  );
  efBadRegex = expectThrow (
    (mkIcedos { })._validateExtraFlakes [
      {
        name = "1bad";
        url = "x";
      }
    ]
  );
  efEmptyUrl = expectThrow (
    (mkIcedos { })._validateExtraFlakes [
      {
        name = "ok";
        url = "";
      }
    ]
  );
  efUnknownKey = expectThrow (
    (mkIcedos { })._validateExtraFlakes [
      {
        name = "ok";
        url = "x";
        bogus = 1;
      }
    ]
  );
  efEmptyPath = expectThrow (
    (mkIcedos { })._validateExtraFlakes [
      {
        name = "ok";
        url = "x";
        modulesToLoad = [ "" ];
      }
    ]
  );

  # modulesToLoad selection: dotted-path walk, single provenance shim.
  efLoad =
    expectEq
      [
        (lib.setDefaultModuleLocation "icedos.system.extraFlakes[0].modulesToLoad[0]" shared)
      ]
      (
        efIcedos.extraFlakeModules {
          inputs = {
            jovian = {
              nixosModules = {
                default = shared;
              };
            };
          };
        }
      );
  efLoadMulti =
    expectEq
      [
        (lib.setDefaultModuleLocation "icedos.system.extraFlakes[0].modulesToLoad[0]" {
          config.entries = [ "A" ];
        })
        (lib.setDefaultModuleLocation "icedos.system.extraFlakes[0].modulesToLoad[1]" {
          config.entries = [ "B" ];
        })
        (lib.setDefaultModuleLocation "icedos.system.extraFlakes[1].modulesToLoad[0]" {
          config.entries = [ "C" ];
        })
      ]
      (
        (mkIcedos {
          system.extraFlakes = [
            {
              name = "a";
              url = "u";
              modulesToLoad = [
                "out.a"
                "out.b"
              ];
            }
            {
              name = "b";
              url = "v";
              modulesToLoad = [ "out.c" ];
            }
          ];
        }).extraFlakeModules
          {
            inputs = {
              a = {
                out = {
                  a = {
                    config.entries = [ "A" ];
                  };
                  b = {
                    config.entries = [ "B" ];
                  };
                };
              };
              b = {
                out = {
                  c = {
                    config.entries = [ "C" ];
                  };
                };
              };
            };
          }
      );
  # Selections are lazy inside the provenance shim, so `deepSeq` lands the throw
  # inside `expectThrow`'s tryEval.
  efMissingInput = expectThrow (
    builtins.deepSeq (efIcedos.extraFlakeModules {
      inputs = { };
    }) true
  );
  efMissingSegment = expectThrow (
    builtins.deepSeq (efIcedos.extraFlakeModules {
      inputs = {
        jovian = { };
      };
    }) true
  );
  efNullOutput = expectThrow (
    builtins.deepSeq (efIcedos.extraFlakeModules {
      inputs = {
        jovian = {
          nixosModules = {
            default = null;
          };
        };
      };
    }) true
  );

  # A module referencing `inputs.jovian` resolves against the registered extra
  # flake; forcing it runs `_extractNixosModules`' validation and guards.
  efMaskedExposure = expectEq [ "S" ] (
    e2eEntries (
      (efBare.getExternalModuleOutputs [
        (
          (mod "path:src" "uses-jovian" null)
          // {
            outputs.nixosModules = { inputs, ... }: [ { imports = [ inputs.jovian.nixosModules.default ]; } ];
          }
        )
      ]).nixosModules
        {
          inputs = {
            jovian = {
              nixosModules = {
                default = shared;
              };
            };
          };
        }
    )
  );

  # A module input whose bare name matches an extraFlake aborts; `deepSeq` lands
  # the lazily-emitted throw inside tryEval.
  efCollision = expectThrow (
    builtins.deepSeq (
      (efBare.getExternalModuleOutputs [
        (
          (mod "path:src" "collide" null)
          // {
            inputs = {
              jovian = {
                url = "v";
              };
            };
            outputs.nixosModules = { inputs, ... }: [
              { imports = [ (inputs.jovian.nixosModules or { }).default ]; }
            ];
          }
        )
      ]).nixosModules
      {
        inputs = { };
      }
    ) true
  );

  # `_extraFlakeNameCollisions` backs both the masked-input and repo-input
  # guards, so driving it directly covers the latter too.
  efNameCollisionsHelper = expectEq [ "jovian" ] (
    (mkIcedos {
      system.extraFlakes = [
        {
          name = "jovian";
          url = "path:/dev/null";
        }
      ];
    })._extraFlakeNameCollisions
      [
        "nur"
        "jovian"
        "home-manager"
      ]
  );

  # An extraFlake named exactly like a module's generated input name would
  # otherwise silently overwrite it in `listToAttrs`.
  efCollisionNamespaced =
    let
      collisionIcedos = mkIcedos {
        system.extraFlakes = [
          {
            name = helpers.moduleInputName {
              repo = "path:src";
              module = "cmod";
              input = "jovian";
            };
            url = "path:/dev/null";
          }
        ];
      };
    in
    expectThrow (
      builtins.deepSeq (
        (collisionIcedos.getExternalModuleOutputs [
          (
            (mod "path:src" "cmod" null)
            // {
              inputs = {
                jovian = {
                  url = "v";
                };
              };
              outputs.nixosModules = { inputs, ... }: [
                { imports = [ (inputs.jovian.nixosModules or { }).default ]; }
              ];
            }
          )
        ]).nixosModules
        {
          inputs = { };
        }
      ) true
    );

  # One value emitted by a module and by a `modulesToLoad` selection loads once.
  efCrossSourceDedup = expectEq [ "S" ] (
    e2eEntries (
      dedupe (
        (efIcedos.getExternalModuleOutputs [
          (
            (mod "path:src" "dup-a" null)
            // {
              outputs.nixosModules = _: [ shared ];
            }
          )
        ]).nixosModules
          {
            inputs = { };
          }
        ++ efIcedos.extraFlakeModules {
          inputs = {
            jovian = {
              nixosModules = {
                default = shared;
              };
            };
          };
        }
      )
    )
  );

  # --- end-to-end hardening (review regressions) ---------------------------
  # Derivation-bearing values key as opaque and never crash on the cycle.
  opaqueDerivationKeepsOpaque = expectOk (
    let
      a = opaqueOrKey {
        config.entries = [ "S" ];
        p = fakeDrv;
      };
      b = opaqueOrKey {
        config.entries = [ "S" ];
        p = fakeDrv;
      };
    in
    a == null && b == null
  );
  # A value that throws when forced never dedups and never aborts eval; only the
  # `throw` makes these payloads opaque.
  e2eThrowsKeepsBoth = expectEq [ "S" "S" ] (
    e2eEntriesWith
      [
        {
          options.boom = lib.mkOption { type = lib.types.unspecified; };
        }
      ]
      (dedupe [
        (lib.setDefaultModuleLocation "l1" {
          config.entries = [ "S" ];
          config.boom = throw "never";
        })
        (lib.setDefaultModuleLocation "l2" {
          config.entries = [ "S" ];
          config.boom = throw "never";
        })
      ])
  );
  # Without the `path` tag both would key to the same store string and dedup.
  e2ePathVsStringKeepsBoth = expectEq [ "S" "S" ] (
    e2eEntriesWith
      [
        {
          options.src = lib.mkOption { type = lib.types.unspecified; };
        }
      ]
      (dedupe [
        (lib.setDefaultModuleLocation "p" {
          config.entries = [ "S" ];
          config.src = ./fixtures/tests-fixture-module.nix;
        })
        (lib.setDefaultModuleLocation "s" {
          config.entries = [ "S" ];
          config.src = toString ./fixtures/tests-fixture-module.nix;
        })
      ])
  );
  # `{ _file; imports; config; }` is a real module, not a shim: a buggy unwrap
  # would key on its imports alone and drop the body.
  e2eRealModuleKeepsBoth = expectOk (
    let
      result = e2eEntries (dedupe [
        (lib.setDefaultModuleLocation "l1" {
          _file = "inner-1";
          imports = [ { config.entries = [ "I" ]; } ];
          config.entries = [ "S" ];
        })
        (lib.setDefaultModuleLocation "l2" {
          _file = "inner-2";
          imports = [ { config.entries = [ "I" ]; } ];
          config.entries = [ "S" ];
        })
      ]);
    in
    # Both kept (4 entries) — a buggy unwrap would collapse to one module (2).
    builtins.length result == 4 && builtins.elem "S" result && builtins.elem "I" result
  );

  # --- extraOptions (lib/config/extra-options.nix) -----------------------
  # Defaults from the schema materialise without any injected value.
  extraDefault = expectEq 8080 (extraEval [ (extraOptions.declare extraSchema) ]).services.myapp.port;

  # `inject` re-applies user-set values per-path (the build-stage raw passthrough
  # analog at genflake stage).
  extraInjectValue = expectEq 9000 (
    (extraEval (
      [
        (extraOptions.declare extraSchema)
      ]
      ++ (extraOptions.inject extraSchema extraUserConfig)
    )).services.myapp.port
  );

  extraInjectAll = expectOk (
    let
      cfg = extraEval (
        [
          (extraOptions.declare extraSchema)
        ]
        ++ (extraOptions.inject extraSchema extraUserConfig)
      );
    in
    cfg.services.myapp.enable == true
    && cfg.services.myapp.port == 9000
    && cfg.services.myapp.name == "app"
  );

  # A leaf without a schema `default` must not get a synthesised `default = null`,
  # which would fail the type check for every unset typed option.
  extraNoDefaultOmitsDefault = expectOk (
    let
      opt =
        (lib.evalModules {
          modules = [
            (extraOptions.declare {
              x.port = {
                type = "int";
              };
            })
          ];
        }).options.x.port;
    in
    !(opt ? default)
  );

  # No-default leaf + user value (via inject): resolves to the value, not an error.
  extraNoDefaultResolves = expectEq 9000 (
    let
      schema = {
        x.port = {
          type = "int";
        };
      };
    in
    (extraEval ([ (extraOptions.declare schema) ] ++ (extraOptions.inject schema { x.port = 9000; })))
    .x.port
  );

  # A wrong-typed injected value fails EAGERLY at inject time (genflake), not
  # silently until something reads the option: shape check via `leafType.check`.
  extraInjectBadShapeThrows = expectThrowMatch (
    let
      schema = {
        x.plugins = {
          type = "stringList";
        };
      };
    in
    extraEval ([ (extraOptions.declare schema) ] ++ (extraOptions.inject schema { x.plugins = 42; }))
  ) "x.plugins";

  # … and a wrong value for a constrained scalar keeps its rich validator
  # message (constraint violation, not the generic shape fallback).
  extraInjectBadScalarThrows = expectThrowMatch (
    let
      schema = {
        x.port = {
          type = "int";
          min = 1;
          max = 65535;
        };
      };
    in
    extraEval ([ (extraOptions.declare schema) ] ++ (extraOptions.inject schema { x.port = 999999; }))
  ) "x.port";

  # An unset no-default leaf is "was accessed but has no value defined" (a throw), not a silent null.
  extraNoDefaultUnsetThrows = expectThrow (
    (extraEval [
      (extraOptions.declare {
        x.port = {
          type = "int";
        };
      })
    ]).x.port
  );

  # … but unset `list`/`attrs` leaves resolve via nixpkgs' `type.emptyValue`.
  # Needs a 2026-era nixpkgs; older `mergeDefinitions` lacks that branch.
  extraEmptyValueList = expectEq [ ] (
    (extraEval [
      (extraOptions.declare {
        x.vals = {
          type = "stringList";
        };
      })
    ]).x.vals
  );
  extraEmptyValueAttrs = expectEq { } (
    (extraEval [
      (extraOptions.declare {
        x.byName = {
          type = "attrs";
          item = "string";
        };
      })
    ]).x.byName
  );

  # enum leaf: schema default applies, inject overrides it.
  extraEnumEval = expectEq "b" (
    let
      schema = {
        x.mode = {
          type = "enum";
          choices = [
            "a"
            "b"
          ];
          default = "a";
        };
      };
    in
    (extraEval ([ (extraOptions.declare schema) ] ++ (extraOptions.inject schema { x.mode = "b"; })))
    .x.mode
  );

  extraAttrsEval = expectEq { foo = "bar"; } (
    let
      schema = {
        x.byName = {
          type = "attrs";
          item = "string";
        };
      };
    in
    (extraEval (
      [
        (extraOptions.declare schema)
      ]
      ++ (extraOptions.inject schema {
        x.byName = {
          foo = "bar";
        };
      })
    )).x.byName
  );

  extraListDescriptorEval = expectEq [ 1 2 ] (
    let
      schema = {
        x.nums = {
          type = "list";
          item = {
            type = "int";
            min = 1;
          };
        };
      };
    in
    (extraEval (
      [
        (extraOptions.declare schema)
      ]
      ++ (extraOptions.inject schema {
        x.nums = [
          1
          2
        ];
      })
    )).x.nums
  );

  # floatList accepts ints — TOML parses whole numbers as ints, so the list
  # variant must mirror the scalar `float` type (types.number, not types.float).
  extraFloatListAcceptsInts = expectEq [ 1 2 3 ] (
    let
      schema = {
        x.vals = {
          type = "floatList";
          default = [ ];
        };
      };
    in
    (extraEval (
      [
        (extraOptions.declare schema)
      ]
      ++ (extraOptions.inject schema {
        x.vals = [
          1
          2
          3
        ];
      })
    )).x.vals
  );

  # The validate.* checks attached to constrained types fire on bad user values.
  extraValidationFires = expectThrow (
    (extraEval [
      (extraOptions.declare {
        x.y = {
          type = "int";
          min = 0;
          max = 10;
        };
      })
      {
        config.x.y = 99;
      }
    ]).x.y
  );

  # The declaring module is wrapped in the marker, so it lands in the option's
  # `declarations` (this is what genflake's optionsDoc keep-filter matches).
  extraMarkerInDeclarations = expectOk (
    lib.elem extraOptions.marker (
      (lib.evalModules {
        modules = [ (extraOptions.declare extraSchema) ];
      }).options.services.myapp.port.declarations or [ ]
    )
  );

  # icedos.* paths are the per-file `config.icedos` imports' job, not inject's.
  extraInjectSkipsIcedos = expectEq [ ] (
    extraOptions.inject
      {
        icedos.applications.x.enable = {
          type = "bool";
        };
      }
      {
        icedos.applications.x.enable = true;
      }
  );

  # A `record` leaf: field defaults apply under a submodule type.
  extraRecordDefault = expectOk (
    let
      cfg = extraEval [
        (extraOptions.declare {
          services.srv = {
            type = "record";
            fields = {
              host = {
                type = "string";
                default = "localhost";
              };
              port = {
                type = "int";
                default = 8080;
              };
            };
          };
        })
        {
          config.services.srv = {
            host = "0.0.0.0";
          };
        }
      ];
    in
    cfg.services.srv.port == 8080 && cfg.services.srv.host == "0.0.0.0"
  );

  # A constrained `list` item type rejects non-conforming elements (deepSeq
  # forces the lazily-checked elements so the throw lands in tryEval).
  extraListBadItem = expectThrow (
    builtins.deepSeq ((extraEval [
      (extraOptions.declare {
        x.nums = {
          type = "list";
          item = "int";
        };
      })
      {
        config.x.nums = [
          1
          "a"
        ];
      }
    ]).x.nums
    ) true
  );

  # Schema validation aborts loudly at `declare` time.
  extraRootNotTable = expectThrow (extraOptions.declare 5);
  extraRootTyped = expectThrow (extraOptions.declare { type = "bool"; });
  extraUnknownType = expectThrow (
    extraOptions.declare {
      x.y = {
        type = "bogus";
      };
    }
  );
  extraScalarNamespace = expectThrow (extraOptions.declare { x.y = 5; });
  extraUnexpectedKey = expectThrow (
    extraOptions.declare {
      x.y = {
        type = "bool";
        bogus = 1;
      };
    }
  );
  extraEnumNoChoices = expectThrow (
    extraOptions.declare {
      x.y = {
        type = "enum";
      };
    }
  );
  extraEnumBadDefault = expectThrow (
    extraOptions.declare {
      x.y = {
        type = "enum";
        choices = [ "a" ];
        default = "b";
      };
    }
  );
  # A constraint-violating default aborts when the option is evaluated; deepSeq
  # lands the throw in tryEval.
  extraBadStringDefault = expectThrow (
    builtins.deepSeq (extraOptions.declare {
      x.y = {
        type = "string";
        minLength = 5;
        default = "ab";
      };
    }) true
  );

  # Empty schema: declare is a no-op module, inject produces nothing.
  extraEmptyInject = expectEq [ ] (extraOptions.inject { } { });
  extraEmptyDeclare = expectOk (
    (lib.evalModules {
      modules = [ (extraOptions.declare { }) ];
    }).options.services or { } == { }
  );

  # Deep composite validation at inject time (genflake): a bad list element,
  # a bad attrs value, and a bad/undeclared record field all throw eagerly.
  extraListBadElemInject = expectThrow (
    let
      schema = {
        x.nums = {
          type = "list";
          item = "int";
        };
      };
    in
    (extraEval (
      [
        (extraOptions.declare schema)
      ]
      ++ (extraOptions.inject schema {
        x.nums = [
          1
          "two"
        ];
      })
    )).x.nums
  );
  extraAttrsBadValueInject = expectThrow (
    let
      schema = {
        x.byName = {
          type = "attrs";
          item = "int";
        };
      };
    in
    (extraEval (
      [
        (extraOptions.declare schema)
      ]
      ++ (extraOptions.inject schema {
        x.byName = {
          a = 1;
          b = "no";
        };
      })
    )).x.byName
  );
  extraRecordBadFieldInject = expectThrow (
    let
      schema = {
        x.service = {
          type = "record";
          fields = {
            name = {
              type = "string";
            };
            port = {
              type = "int";
            };
          };
        };
      };
    in
    (extraEval (
      [
        (extraOptions.declare schema)
      ]
      ++ (extraOptions.inject schema {
        x.service = {
          name = "log";
          port = "nope";
        };
      })
    )).x.service
  );
  extraRecordUndeclaredFieldInject = expectThrow (
    let
      schema = {
        x.service = {
          type = "record";
          fields = {
            name = {
              type = "string";
            };
          };
        };
      };
    in
    (extraEval (
      [
        (extraOptions.declare schema)
      ]
      ++ (extraOptions.inject schema {
        x.service = {
          name = "log";
          bogus = 1;
        };
      })
    )).x.service
  );
  extraRecordGoodInject =
    expectEq
      {
        name = "log";
        port = 8080;
      }
      (
        let
          schema = {
            x.service = {
              type = "record";
              fields = {
                name = {
                  type = "string";
                };
                port = {
                  type = "int";
                };
              };
            };
          };
        in
        (extraEval (
          [
            (extraOptions.declare schema)
          ]
          ++ (extraOptions.inject schema {
            x.service = {
              name = "log";
              port = 8080;
            };
          })
        )).x.service
      );
}
