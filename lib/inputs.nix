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
    }:
    let
      hasRev = hasAttrByPath [ "nodes" repoName "locked" "rev" ] lock;
      hasNarHash = hasAttrByPath [ "nodes" repoName "locked" "narHash" ] lock;
      updateAll = builtins.getEnv "ICEDOS_UPDATE" == "1";
      updateSelected = _repoSelected selectedRepos repoName;
    in
    if ((skipUpdateEnvCheck != true) && (updateAll || updateSelected)) || (!hasRev && !hasNarHash) then
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

  # Rev cache-server last built for a leaf input, "" when untracked/unmatched.
  # Pure: `revs` is cache-server's published tracked-inputs.json (name -> rev |
  # { rev; repo; }). Key match mirrors its tracked-revs.py: exact node key, else a
  # "-<name>" suffixed one. The optional `repo` guard ("scheme:owner/repo") only
  # exists in the newer { rev; repo; } format and must equal the url's host repo;
  # older string entries pin on the name alone.
  # `{ rev; repo; }` view of a tracked-inputs.json entry (string or attrset).
  _cacheEntryOf =
    value:
    if builtins.isString value then
      {
        rev = value;
        repo = "";
      }
    else
      {
        rev = value.rev or "";
        repo = value.repo or "";
      };

  # The tracked key this input matches: exact, else a lone "-<name>" suffix
  # guarded by the url's repo; "" when none or ambiguous. _cacheRevLookup and
  # the declared-ref export (_cachePin's tracked-ref map) share this matching.
  _cacheTrackedKey =
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

      keys = filter (k: k == name || lib.hasSuffix "-${name}" k) (attrNames revs);

      # "scheme:owner/repo" of `url`, "" when it is not a github/gitlab/sourcehut url.
      urlRepo =
        let
          m = match "(github|gitlab|sourcehut):([^/?]+)/([^/?]+)(.*)" url;
        in
        if m == null then "" else "${elemAt m 0}:${elemAt m 1}/${elemAt m 2}";

      # `{ rev; repo; }` entries name their own repo, so one naming this url is
      # unambiguous even when several keys share the "-<name>" suffix.
      repoMatched = filter (k: urlRepo != "" && (_cacheEntryOf revs.${k}).repo == urlRepo) keys;

      # Several entries may claim the same repo (a publish-side mistake). That is
      # only unambiguous while they agree on the rev.
      repoMatchedRevs = lib.unique (map (k: (_cacheEntryOf revs.${k}).rev) repoMatched);

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
    in
    if key == null then "" else key;

  # A remembered custom pin wins while the cache still tracks the input and
  # its rev differs; otherwise the cache rev (or no pin) applies.
  _cachePinRev =
    { rev, savedRev }:
    if rev != "" && savedRev != "" && savedRev != rev then savedRev else rev;

  _cacheRevLookup =
    {
      name,
      url,
      revs,
    }:
    let
      inherit (builtins) elemAt match;

      urlRepo =
        let
          m = match "(github|gitlab|sourcehut):([^/?]+)/([^/?]+)(.*)" url;
        in
        if m == null then "" else "${elemAt m 0}:${elemAt m 1}/${elemAt m 2}";

      key = _cacheTrackedKey {
        inherit name url revs;
      };

      entry =
        if key == "" then
          {
            rev = "";
            repo = "";
          }
        else
          _cacheEntryOf revs.${key};
    in
    if entry.rev == "" || (entry.repo != "" && entry.repo != urlRepo) then "" else entry.rev;

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
      # `?ref=` spelling, possibly among other query params. Folding it into
      # `ref` (and out of the query) means a later baked rev REPLACES the branch
      # instead of stacking with it — nix rejects both at once.
      qref = builtins.match "(github|gitlab|sourcehut):([^/?]+)/([^/?]+)[?]([^#]*)" url;
    in
    if match != null then
      {
        baseUrl = "${builtins.elemAt match 0}:${builtins.elemAt match 1}/${builtins.elemAt match 2}${builtins.elemAt match 4}";
        ref = builtins.elemAt match 3;
      }
    else if qref != null then
      let
        params = builtins.filter builtins.isString (builtins.split "&" (builtins.elemAt qref 3));
        refParams = builtins.filter (p: builtins.match "ref=.+" p != null) params;
        rest = builtins.filter (p: builtins.match "ref=.+" p == null) params;
        kept = concatStringsSep "&" rest;
      in
      {
        baseUrl = "${builtins.elemAt qref 0}:${builtins.elemAt qref 1}/${builtins.elemAt qref 2}${
          lib.optionalString (kept != "") "?${kept}"
        }";
        ref =
          if refParams == [ ] then
            null
          else
            builtins.head (builtins.match "ref=(.*)" (builtins.head refParams));
      }
    else
      {
        baseUrl = url;
        ref = null;
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
