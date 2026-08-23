{
  icedosLib,
  lib,
  self,
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

  # Revision suffix from the lock: /{rev}, ?rev={rev} (git schemes), ?narHash={h},
  # or "". `skipUpdateEnvCheck` leaves the nested bake intact during --update-repos.
  _getRevisionFromLock =
    {
      repoName,
      lock,
      url,
      skipUpdateEnvCheck ? false,
    }:
    let
      hasRev = hasAttrByPath [ "nodes" repoName "locked" "rev" ] lock;
      hasNarHash = hasAttrByPath [ "nodes" repoName "locked" "narHash" ] lock;
    in
    if
      ((skipUpdateEnvCheck != true) && (builtins.getEnv "ICEDOS_UPDATE" == "1"))
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
        inherit lock url skipUpdateEnvCheck;
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
    # --update-repos never unpins module inputs).
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

  # `scheme:owner/repo/<ref>` -> { baseUrl; ref; } for github/gitlab/sourcehut;
  # any other shape passes through with `ref = null`.
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
