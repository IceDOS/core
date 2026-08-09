# Eval-only smoke tests for core/lib/options/validate.nix, core/lib/helpers.nix
# (hasModule, moduleInputName) and core/lib/icedos.nix (_mergeModuleLibs,
# _opaqueOrKey, _dedupeNixosModules).
# Usage (canonical): `nix flake check` in the core repo — the `checks.<system>.lib-tests`
# derivation fails if any result value is not "ok".
# Manual: nix-instantiate --eval --strict --expr '(import ./lib/tests/tests.nix) { }'
# Every key must evaluate to "ok". Any "FAIL:..." string or thrown error equals regression.

{
  lib ? import <nixpkgs/lib>,
}:

let
  icedosLib = {
    abortIf = condition: message: if condition then throw message else true;
    # Track the real prefix so a constants.nix change fails the test instead of
    # silently passing; the rest of icedosLib is lazy, so it never evaluates.
    INPUTS_PREFIX = (import ../constants.nix { }).INPUTS_PREFIX;
    generateAttrPath = throw "helpers.generateAttrPath is not stubbed in tests";
  };

  validate = (import ../options/validate.nix { inherit icedosLib lib; }).validate;

  helpers = import ../helpers.nix {
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

  # --- icedosLib.hasModule (helpers.nix) --------------------------------
  # Import helpers.nix with just the members hasModule actually forces stubbed;
  # the abortIf/stringStartsWith stubs carry the real semantics.
  hasModule =
    (import ../helpers.nix {
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
  # The merge folds module `lib` field contributions onto the base lib. Import
  # icedos.nix with a stubbed base lib and force only `_mergeModuleLibs` — the
  # resolution machinery is a lazy rec member, so the rest never evaluates.
  merge =
    (import ../icedos.nix {
      inherit lib;
      config = { };
      inputs = { };
      pkgs = { };
      icedosLib = {
        foo = "baseFoo";
      };
    })._mergeModuleLibs;

  # --- _opaqueOrKey / _dedupeNixosModules (icedos.nix) ---------------------
  icedos = import ../icedos.nix {
    inherit lib;
    config = { };
    inputs = { };
    pkgs = { };
    icedosLib = {
      foo = "baseFoo";
    };
  };

  # The real, fully-loaded lib (common.nix + helpers + icedos.nix) for the
  # cross-source e2e tests, which drive `getExternalModuleOutputs` →
  # `_extractNixosModules` (masked inputs, provenance shims, per-source dedup).
  # `pkgs`/`inputs`/`config` stay empty — nothing those functions force needs
  # them. Imported through the `in` block so it is lazy unless forced.
  fullIcedos =
    let
      realLib = import ../default.nix {
        inherit lib;
        config = { };
        inputs = { };
        pkgs = { };
        enableLogging = false;
        self = "tests";
      };
    in
    realLib;

  opaqueOrKey = icedos._opaqueOrKey;
  dedupe = icedos._dedupeNixosModules;

  # End-to-end module-system observable: `entries` collects whatever module
  # values were actually loaded (identical values would load twice without
  # dedup). The options module is separate from the emitted values so the
  # emitted module stays function-free and structurally comparable.
  e2eEntries =
    emitted:
    (lib.evalModules {
      modules = [ e2eBase ] ++ emitted;
    }).config.entries;

  # `e2eEntries` with extra *base* modules declaring options the emitted
  # payloads use. Keeping declarations out of the emitted values matters:
  # a `lib.types.*` value contains a `merge` function, which would make a
  # payload opaque in `_opaqueOrKey` for the wrong reason (never keyed, so a
  # test asserting dedup/keep behaviour by key could not observe it).
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

  # moduleInputName — mirrors _getModuleInputs in lib/icedos.nix (single source of truth).
  moduleInputNameJovian = expectEq "icedos-github_icedos_providers-jovian-jovian" (
    helpers.moduleInputName {
      repo = "github:icedos/providers";
      module = "jovian";
      input = "jovian";
    }
  );

  moduleInputNameNur = expectEq "icedos-github_icedos_providers-nur-nur" (
    helpers.moduleInputName {
      repo = "github:icedos/providers";
      module = "nur";
      input = "nur";
    }
  );

  # repo/module pass through mkInputName's URL-char sanitization; `input` is a Nix
  # attr identifier in production and is appended verbatim.
  moduleInputNameSanitizesUrlChars =
    expectEq "icedos-https___example_com_blog_from_1-the_post-nixpkgs"
      (
        helpers.moduleInputName {
          repo = "https://example.com/blog?from=1";
          module = "the.post";
          input = "nixpkgs";
        }
      );

  # A patched module's inputs split into an unpatched node (named `<input>_source`)
  # and a patched node — the `_source` variant mirrors _getModuleInputs' normalInput.
  moduleInputNamePatchedSource = expectEq "icedos-github_icedos_providers-jovian-jovian_source" (
    helpers.moduleInputName {
      repo = "github:icedos/providers";
      module = "jovian";
      input = "jovian_source";
    }
  );
  # --- hasModule (helpers.nix) & _mergeModuleLibs (icedos.nix) test cases ---
  # --- hasModule test cases ---------------------------------------------

  # name present in any repo -> true
  hasModuleNamePresent = expectOk (hasModule {
    config = fakeConfig loaded;
    name = "steam";
  });
  # name absent everywhere -> false (NOT an abort)
  hasModuleNameAbsent = expectOk (
    !(hasModule {
      config = fakeConfig loaded;
      name = "ghost";
    })
  );
  # url branch: matching repo + present name -> true
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
  # url branch: unknown repo -> false
  hasModuleUrlNoSuchRepo = expectOk (
    !(hasModule {
      config = fakeConfig loaded;
      url = "github:icedos/ghost";
      name = "btop";
    })
  );
  # repoUrl branch -> true
  hasModuleRepoUrlMatch = expectOk (hasModule {
    config = fakeConfig loaded;
    repoUrl = "github:icedos/desktop";
    modules = [ "default" ];
  });
  # modules branch: all present -> true
  hasModuleModulesAll = expectOk (hasModule {
    config = fakeConfig loaded;
    modules = [
      "btop"
      "steam"
    ];
  });
  # modules branch: one missing -> false
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
  # neither name nor modules -> abort
  hasModuleNeitherAbort = expectThrow (hasModule {
    config = fakeConfig loaded;
  });
  # empty loadedModules + malformed call -> still aborts (seq forces the guard)
  hasModuleEmptyLoadedMalformed = expectThrow (hasModule {
    config = fakeConfig { };
  });

  # disjoint contributions fold in cleanly
  mergeHappy = expectOk (
    (merge [
      (mod "github:icedos/a" "m1" { alpha = 1; })
      (mod "github:icedos/b" "m2" { beta = 2; })
    ]).beta == 2
  );
  # a contribution name colliding with the base lib -> named throw
  mergeCollidesBase = expectThrowMatch (merge [
    (mod "github:icedos/a" "m1" { foo = "shadow"; })
  ]) "Duplicate icedosLib name 'foo'";
  # a name colliding across two contributions -> named throw
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
    value = toString ./tests-fixture-module.nix;
  } (opaqueOrKey ./tests-fixture-module.nix);
  # `null` keys as its own kind (a module value carrying `null` can dedup).
  opaqueNull = expectEq { kind = "null"; } (opaqueOrKey null);
  # A derivation is opaque: keying inspects `type` alone and never forces the
  # value (a derivation is a cyclic attrset; forcing `drvPath` could
  # instantiate). It degrades to `null`, so derivation-bearing values are
  # never deduplicated.
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
  # A property wrapper (`_type` attr: mkIf/mkMerge/mkForce/option types, …) is
  # opaque — keying must never descend into branches the module system may
  # drop unforced. `abort` is NOT caught by `tryEval`, so this only passes
  # because of the `_type` guard, not the safety net.
  opaquePropertyWrapper = expectEq null (opaqueOrKey (lib.mkIf false (abort "unforced")));
  # A payload that DECLARES options is opaque too: `lib.mkOption` produces
  # `{ _type = "option"; … }`, so duplicate option declarations are never
  # silently merged by dedup — they still fail loudly, which is correct.
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
  # Lists recurse elementwise.
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
  # Structurally different shapes never compare equal (the `kind` tag): an
  # empty list vs an empty attrset, a path vs a plain string of its store
  # text, and `42` vs `42.0` (Nix treats int == float as equal untagged).
  opaqueKindListVsAttrs = expectOk (opaqueOrKey [ ] != opaqueOrKey { });
  opaqueKindPathVsString = expectOk (
    opaqueOrKey ./tests-fixture-module.nix != opaqueOrKey (toString ./tests-fixture-module.nix)
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
  # Keep-first preserves the surviving shim's `_file`.
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
  # Distinct function-free values are both kept.
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
        (lib.setDefaultModuleLocation "locA" ./tests-fixture-module.nix)
      ]
      (dedupe [
        (lib.setDefaultModuleLocation "locA" ./tests-fixture-module.nix)
        (lib.setDefaultModuleLocation "locB" ./tests-fixture-module.nix)
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
  # Deduped emission loads it once.
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
      (lib.setDefaultModuleLocation "locA" ./tests-fixture-module.nix)
      (lib.setDefaultModuleLocation "locB" ./tests-fixture-module.nix)
    ])
  );

  # ── cross-source: repo (external) + config-root (extra) modules ────────────
  # Mirrors modulesFromConfig.nixosModules exactly: each source flattens and
  # dedups internally (`getExternalModuleOutputs` → `_extractNixosModules`),
  # then the two sources are combined and deduped again
  # (`_dedupeNixosModules (external ++ extra)`), so an identical value emitted
  # by a config-root `icedos.nix` module (`_repoInfo.url = "config"`) and a
  # repo module loads only once.
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

  # Cross-source distinct values both survive the combine (order unspecified).
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

  # --- end-to-end hardening (review regressions) ---------------------------
  # Identical derivation-bearing values are opaque — both `null`, so never
  # deduplicated, and keying never crashes on the cyclic derivation. A full e2e
  # is not possible: carrying `p` under `config` needs an option declaration,
  # and any `lib.types.*` type contains a `merge` function, which makes the
  # whole payload opaque (correctly: never deduped).
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
  # A value that throws when forced never dedups and never aborts eval. The
  # option declaration lives in the base module so the emitted payloads stay
  # function-free — only the `throw` makes them opaque.
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
  # A path and an equal-looking plain string never collide (without the
  # `path:` tag both would key to the same store string and dedup to one).
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
          config.src = ./tests-fixture-module.nix;
        })
        (lib.setDefaultModuleLocation "s" {
          config.entries = [ "S" ];
          config.src = toString ./tests-fixture-module.nix;
        })
      ])
  );
  # A real module shaped `{ _file; imports; config; }` is NOT a shim: its body
  # is part of the key, so two distinct locations stay distinct (a buggy
  # unwrap would key on the single imports payload alone and drop one's body).
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
}
