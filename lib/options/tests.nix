# Eval-only smoke tests for core/lib/options/validate.nix, core/lib/helpers.nix
# (hasModule, moduleInputName) and core/lib/icedos.nix (_mergeModuleLibs).
# Usage (canonical): `nix flake check` in the core repo — the `checks.<system>.lib-tests`
# derivation fails if any result value is not "ok".
# Manual: nix-instantiate --eval --strict --expr '(import ./lib/options/tests.nix) { }'
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

  validate = (import ./validate.nix { inherit icedosLib lib; }).validate;

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
}
