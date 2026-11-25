{
  icedosLib,
  lib,
  ...
}:

let
  inherit (builtins)
    fromJSON
    pathExists
    readFile
    replaceStrings
    ;

  inherit (lib)
    concatStringsSep
    hasAttrByPath
    ;

  inherit (icedosLib)
    ICEDOS_STAGE
    ICEDOS_STATE_DIR
    INPUTS_PREFIX
    stringStartsWith
    ;
in
rec {
  # ─── flake / input helpers ────────────────────────────────────────────────
  # Consumed by lib/genflake.nix and lib/icedos.nix.

  # Flake-input name from identifying parts: joined with `-`, prefixed, and
  # URL-unsafe chars (`: / . ? = +`) mapped to `_`.
  mkInputName =
    { parts }:
    replaceStrings [ ":" "/" "." "?" "=" "+" ] [ "_" "_" "_" "_" "_" "_" ] (
      concatStringsSep "-" ([ INPUTS_PREFIX ] ++ parts)
    );

  # The root input name of a module's input-namespace sub-flake. Mirrors
  # `_getModuleInputs` in lib/icedos.nix (single source of truth).
  moduleSubFlakeName =
    {
      repo,
      module,
    }:
    mkInputName {
      parts = [
        repo
        module
      ];
    };

  # `<sub-flake>/<input>` — the spelling `nix flake update` takes. A `follows`
  # built from it no longer resolves and aborts at genflake (see AGENTS.md §5).
  moduleInputName =
    {
      repo,
      module,
      input,
    }:
    "${moduleSubFlakeName { inherit repo module; }}/${input}";

  # Detect git-transport flake URLs (git+ssh://, git+https://, git+file://, git://, …).
  # These encode rev as a query parameter (?rev=<hash>), not a path segment.
  _urlIsGitScheme = url: stringStartsWith "git+" url || stringStartsWith "git://" url;

  # The state lock (the only one holding the generated inputs); null on a first
  # build, which callers read as "no pin available".
  _readFlakeLock =
    let
      lockPath = "${ICEDOS_STATE_DIR}/flake.lock";
    in
    if pathExists lockPath then fromJSON (readFile lockPath) else null;

  # `locked` of the node reached from `lock`'s root through the `chain` input names;
  # null on a missing lock, a missing hop, or a follows (array) hop.
  _lockChainLocked =
    { lock, chain }:
    let
      hop =
        key: name:
        let
          v = (lock.nodes.${key}.inputs or { }).${name} or null;
        in
        if builtins.isString v then v else null;
      key = builtins.foldl' (k: name: if k == null then null else hop k name) "root" chain;
    in
    if lock == null || key == null then null else (lock.nodes.${key} or { }).locked or null;

  # Locked rev of a root input, "" when absent, a follows, or unrevisioned.
  _lockRootRev =
    { lock, name }:
    let
      locked = _lockChainLocked {
        inherit lock;
        chain = [ name ];
      };
    in
    if locked == null then "" else locked.rev or "";

  # Locked `lastModified` of a root input, null when absent or unrevisioned (a
  # synthetic channel lock carries revs only).
  _lockRootLastModified =
    { lock, name }:
    let
      locked = _lockChainLocked {
        inherit lock;
        chain = [ name ];
      };
    in
    if locked == null then null else locked.lastModified or null;

  # Input names Python asked genflake to keep at their locked rev; empty when unset.
  _frozenInputs =
    let
      raw = builtins.getEnv "ICEDOS_FREEZE_INPUTS";
    in
    if raw == "" then [ ] else lib.filter (s: s != "") (lib.splitString " " raw);

  # Locked rev of a frozen root input, "" when not frozen or not locked yet.
  _frozenRev =
    {
      name,
      frozen ? _frozenInputs,
      lock ? _readFlakeLock,
    }:
    if lib.elem name frozen then
      _lockRootRev {
        inherit lock name;
      }
    else
      "";

  # Root inputs whose URL rev comes from the cache-server pin; empty when pins are off.
  _cachePinnedInputs =
    {
      nixpkgsCacheRev ? "",
      homeManagerCacheRev ? "",
    }:
    lib.optional (nixpkgsCacheRev != "") "nixpkgs"
    ++ lib.optional (homeManagerCacheRev != "") "home-manager";

  # `cache-unpin.json` value as `{ rev; lastModified; }`: a bare string is the
  # rev-only spelling, a malformed value pins nothing.
  _cacheUnpinEntry =
    value:
    if builtins.isString value then
      {
        rev = value;
        lastModified = null;
      }
    else if builtins.isAttrs value then
      {
        rev = if builtins.isString (value.rev or null) then value.rev else "";
        lastModified = if builtins.isInt (value.lastModified or null) then value.lastModified else null;
      }
    else
      {
        rev = "";
        lastModified = null;
      };

  # Bare rev a live unpin entry pins `name` to, "" when there is none.
  _cacheUnpinRev =
    { name, unpins }:
    (_cacheUnpinEntry (unpins.${name} or null)).rev;

  # Url whose tip is "latest upstream" for an unpin: the author's declared ref,
  # minus anything that pins a revision (`/rev`, `?rev=`). A ref that is itself
  # a commit hash is dropped too (only the default branch is left to ask); every
  # other query parameter (`ref=`, `dir=`, ...) survives. The cache-pin url keeps
  # the rev-less base instead, since Python appends /<cacheRev> to it.
  _unpinLatestUrl =
    url:
    let
      inherit (builtins)
        filter
        head
        length
        match
        ;
      # lib.splitString splits on a literal, unlike builtins.split's regex.
      parts = lib.splitString "?" url;
      parsed = _parseFlakeUrl (head parts);
      # `?rev=<hash>` pins exactly like the path form, so it must go; `?` with no
      # parameters left is dropped rather than trailing.
      params = filter (part: part != "" && !(lib.hasPrefix "rev=" part)) (
        lib.splitString "&" (if length parts > 1 then builtins.elemAt parts 1 else "")
      );
      pathRef = parsed.ref;
      base =
        if pathRef != null && match "[0-9a-f]{40}|[0-9a-f]{64}" pathRef == null then
          "${parsed.baseUrl}/${pathRef}"
        else
          parsed.baseUrl;
    in
    if params == [ ] then base else "${base}?${lib.concatStringsSep "&" params}";

  # `--update-except` freezes a module leaf by either spelling: `<sub>/<input>`,
  # or `<sub>/<input>_source` for the upstream node of a patched input.
  _leafFrozen =
    { name, frozen }:
    lib.elem name frozen || lib.elem "${name}_source" frozen;

  # Where a cache-controlled input's rev comes from, in precedence order:
  # frozen (--update-except) > live unpin entry > cache rev > locked rev > the
  # author's ref. `source` keeps the url shape right: "lock"/"ref" may already
  # be a pre-formed suffix, "unpin"/"cache" are bare revs.
  #
  # An unpin only applies to an input the cache still pins (`cacheRev != ""`,
  # i.e. the name is in genflake's `cacheUnpinInfo`); the orchestrator prunes
  # everything else from the file, so a stale entry pins nothing here.
  _cacheRevChoice =
    {
      name,
      unpins,
      frozen,
      lockRev ? "",
      cacheRev ? "",
      inlineRef ? "",
    }:
    let
      unpinRev = _cacheUnpinRev { inherit name unpins; };
    in
    if frozen && lockRev != "" then
      {
        source = "lock";
        rev = lockRev;
      }
    else if unpinRev != "" && cacheRev != "" then
      {
        source = "unpin";
        rev = unpinRev;
      }
    else if cacheRev != "" then
      {
        source = "cache";
        rev = cacheRev;
      }
    else if lockRev != "" then
      {
        source = "lock";
        rev = lockRev;
      }
    else
      {
        source = "ref";
        rev = inlineRef;
      };

  # Repo urls from --update-repos-select; empty when unset.
  _selectedRepos =
    let
      raw = builtins.getEnv "ICEDOS_UPDATE_REPOS_SELECT";
    in
    if raw == "" then [ ] else lib.filter (s: s != "") (lib.splitString " " raw);

  # Match `repoName` against generated input names or config.toml urls.
  _repoSelected =
    selectedRepos: repoName:
    lib.any (
      selected:
      selected == repoName || (mkInputName { parts = [ (_parseFlakeUrl selected).baseUrl ]; }) == repoName
    ) selectedRepos;

  # Revision suffix from the lock: /{rev}, ?rev={rev} (git schemes), ?narHash={h},
  # or "". `skipUpdateEnvCheck` leaves the nested bake intact during --update-repos-only.
  _getRevisionFromLock =
    {
      repoName,
      lock,
      url,
      skipUpdateEnvCheck ? false,
      selectedRepos ? _selectedRepos,
      frozenInputs ? _frozenInputs,
    }:
    let
      hasRev = hasAttrByPath [ "nodes" repoName "locked" "rev" ] lock;
      hasNarHash = hasAttrByPath [ "nodes" repoName "locked" "narHash" ] lock;
      updateAll = builtins.getEnv "ICEDOS_UPDATE" == "1";
      updateSelected = _repoSelected selectedRepos repoName;
      frozen = lib.elem repoName frozenInputs;
    in
    if
      ((skipUpdateEnvCheck != true) && !frozen && (updateAll || updateSelected))
      || (!hasRev && !hasNarHash)
    then
      ""
    else if hasRev && _urlIsGitScheme url then
      "?rev=${lock.nodes.${repoName}.locked.rev}"
    else if hasRev then
      "/${lock.nodes.${repoName}.locked.rev}"
    else
      "?narHash=${lock.nodes.${repoName}.locked.narHash}";

  # Pure tail: given a lock and node key, drop the pin when the node's `original`
  # no longer describes `url` (an overrideUrl toggle), else return its suffix.
  _resolveFlakeRevisionLocked =
    {
      url,
      lock,
      nodeKey,
      skipUpdateEnvCheck ? false,
      selectedRepos ? _selectedRepos,
    }:
    let
      lockedOriginalMatches =
        let
          orig = lock.nodes.${nodeKey}.original or null;
          type = orig.type or "";
        in
        orig != null
        && (
          if type == "github" || type == "gitlab" || type == "sourcehut" then
            url == "${type}:${orig.owner}/${orig.repo}"
          else if type == "path" then
            url == "path:${orig.path}"
          else if type == "git" then
            url == orig.url || url == "git+${orig.url}"
          else
            false
        );
    in
    if !lockedOriginalMatches then
      ""
    else
      _getRevisionFromLock {
        repoName = nodeKey;
        inherit
          lock
          url
          skipUpdateEnvCheck
          selectedRepos
          ;
      };

  # A repo input's locked revision suffix, "" when it must re-resolve.
  _resolveFlakeRevision =
    {
      url,
      repoName,
    }:
    let
      lock = _readFlakeLock;
    in
    if (lock == null) || ((stringStartsWith "path:" url) && (ICEDOS_STAGE == "genflake")) then
      ""
    else
      _resolveFlakeRevisionLocked {
        inherit url lock;
        nodeKey = repoName;
      };

  # Pure tail: root -> sub-flake node key -> input node key, then the shared tail.
  # Any missing hop (or a follows-array where a key was expected) returns "".
  _resolveFlakeRevisionNestedLocked =
    {
      url,
      lock,
      subFlakeName,
      inputName,
    }:
    let
      # A lock `inputs` value is either a node key (string) or a follows path
      # (array); only the string form resolves a hop.
      hop =
        attrs: name:
        let
          v = attrs.${name} or null;
        in
        if builtins.isString v then v else null;

      subKey = hop (lock.nodes.root.inputs or { }) subFlakeName;

      inputKey = if subKey != null then hop (lock.nodes.${subKey}.inputs or { }) inputName else null;
    in
    # Its own flag, so clearing the sub-flake bake never unpins repo urls (and
    # --update-repos-only never unpins module inputs).
    if
      (inputKey == null)
      || ((stringStartsWith "path:" url) && (ICEDOS_STAGE == "genflake"))
      || (builtins.getEnv "ICEDOS_UPDATE_MODULE_INPUTS" == "1")
    then
      ""
    else
      _resolveFlakeRevisionLocked {
        inherit url lock;
        nodeKey = inputKey;
        skipUpdateEnvCheck = true;
      };

  # Revision lookup for a module input, which lives one level down inside its
  # module's sub-flake.
  _resolveFlakeRevisionNested =
    {
      url,
      subFlakeName,
      inputName,
    }:
    let
      lock = _readFlakeLock;
    in
    if lock == null then
      ""
    else
      _resolveFlakeRevisionNestedLocked {
        inherit
          url
          lock
          subFlakeName
          inputName
          ;
      };

  # Resolved tracked-inputs.json entry for a leaf input: `{ rev; repo; lastModified; }`,
  # rev "" when untracked or ambiguous. Key match mirrors tracked-revs.py:
  # exact node key or a "-<name>" suffix; the optional repo guard must equal the
  # url's host repo, older string entries pin on the name alone.
  _cacheRevEntry =
    {
      name,
      url,
      revs,
    }:
    let
      inherit (builtins)
        attrNames
        elemAt
        head
        filter
        length
        match
        ;

      _entryOf =
        value:
        if builtins.isString value then
          {
            rev = value;
            repo = "";
            lastModified = null;
          }
        else
          {
            rev = value.rev or "";
            repo = value.repo or "";
            # Not published today (tracked-revs.py emits key/rev/repo only); read
            # when it is, so the unpin expiry needs no fetch.
            lastModified = if builtins.isInt (value.lastModified or null) then value.lastModified else null;
          };

      keys = filter (k: k == name || lib.hasSuffix "-${name}" k) (attrNames revs);

      # "scheme:owner/repo" of `url`, "" when it is not a github/gitlab/sourcehut url.
      urlRepo =
        let
          m = match "(github|gitlab|sourcehut):([^/?]+)/([^/?]+)(.*)" url;
        in
        if m == null then "" else "${elemAt m 0}:${elemAt m 1}/${elemAt m 2}";

      # `{ rev; repo; }` entries name their own repo, so one naming this url is
      # unambiguous even when several keys share the "-<name>" suffix.
      repoMatched = filter (k: urlRepo != "" && (_entryOf revs.${k}).repo == urlRepo) keys;

      # Several entries may claim the same repo (a publish-side mistake). That is
      # only unambiguous while they agree on the rev.
      repoMatchedRevs = lib.unique (map (k: (_entryOf revs.${k}).rev) repoMatched);

      # Exact key wins, then a repo-guarded match, then a lone string suffix;
      # the rest is ambiguous (same leaf in different repos), so refuse.
      key =
        if builtins.elem name keys then
          name
        else if length repoMatchedRevs == 1 then
          head repoMatched
        else if repoMatched != [ ] then
          null
        else if length keys == 1 then
          head keys
        else
          null;

      entry =
        if key == null then
          {
            rev = "";
            repo = "";
            lastModified = null;
          }
        else
          _entryOf revs.${key};
    in
    if entry.rev == "" || (entry.repo != "" && entry.repo != urlRepo) then
      {
        rev = "";
        repo = "";
        lastModified = null;
      }
    else
      entry;

  # Rev cache-server last built for this leaf input, "" when untracked.
  _cacheRevLookup =
    {
      name,
      url,
      revs,
    }:
    (_cacheRevEntry { inherit name url revs; }).rev;

  # Splice a PRE-FORMED revision suffix onto a url that may already carry a query:
  # a path segment goes before the query, a query param joins it with `&`.
  _appendRevSuffix =
    baseUrl: suffix:
    if suffix == "" then
      baseUrl
    else
      let
        m = builtins.match "([^?]*)[?](.*)" baseUrl;
        stem = if m == null then baseUrl else builtins.elemAt m 0;
        # A bare trailing `?` is an empty query: drop it rather than emit `?&`.
        rawQuery = if m == null then "" else builtins.elemAt m 1;
        hasQuery = rawQuery != "";
        query = if hasQuery then "?${rawQuery}" else "";
      in
      if !(lib.hasPrefix "?" suffix) then
        "${stem}${suffix}${query}"
      else if hasQuery then
        "${stem}${query}&${lib.removePrefix "?" suffix}"
      else
        "${stem}${suffix}";

  # Same, for a BARE rev: `separator` is "/" for github/gitlab/sourcehut and
  # "?rev=" for git schemes, which spell revs as a query parameter.
  _appendRev =
    {
      baseUrl,
      rev,
      separator ? "/",
    }:
    _appendRevSuffix baseUrl (if rev == "" then "" else "${separator}${rev}");

  # `scheme:owner/repo/<ref>` -> { baseUrl; ref; } for github/gitlab/sourcehut;
  # anything else has `ref = null`. baseUrl keeps its query — compose with `_appendRev`.
  _parseFlakeUrl =
    url:
    let
      match = builtins.match "(github|gitlab|sourcehut):([^/?]+)/([^/?]+)/([^?]+)(.*)" url;
    in
    if match == null then
      {
        baseUrl = url;
        ref = null;
      }
    else
      {
        baseUrl = "${builtins.elemAt match 0}:${builtins.elemAt match 1}/${builtins.elemAt match 2}${builtins.elemAt match 4}";
        ref = builtins.elemAt match 3;
      };

  # Generate a unique key for a module (url/name combination).
  _getModuleKey = url: name: "${url}/${name}";

  # The inputs that actually age the system. `lastModified` is known at eval time,
  # so status.nix only computes the age at runtime.
  freshInputs = inputs: [
    {
      name = "nixpkgs";
      lm = inputs.nixpkgs.sourceInfo.lastModified;
    }
    {
      name = "home-manager";
      lm = inputs.home-manager.sourceInfo.lastModified;
    }
  ];
}
