{
  icedosLib,
  lib,
  ...
}:

let
  inherit (builtins)
    elemAt
    filter
    fromJSON
    head
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
    # A git-scheme url has no `narHash` query param: nix folds it into the
    # REMOTE url and emits something `git ls-remote` cannot resolve. Unpinned
    # beats unfetchable (mirrors the same guard in `_modulesToInputs`).
    # Deliberately NOT gated on githubViaSsh: a hand-written `git+…` url was
    # always broken this way, and emitting an unfetchable pin is never right.
    else if _urlIsGitScheme url then
      ""
    else
      "?narHash=${lock.nodes.${repoName}.locked.narHash}";

  # Pure tail: given a lock and node key, drop the pin when the node's `original`
  # no longer describes `url` (an overrideUrl toggle), else return its suffix.
  _resolveFlakeRevisionLocked =
    {
      url,
      lock,
      nodeKey,
      # The ref this url will actually be emitted with (`null` for none, and for
      # a 40-hex pin — that becomes a `rev`, never a `ref`). When the lock node
      # recorded a ref of its own it must still agree, or the pinned rev may no
      # longer be reachable from the ref we are about to ask for: editing
      # `github:o/r/dev` to `github:o/r` would otherwise pair rev D (on `dev`)
      # with `HEAD`, and a git-scheme fetch aborts instead of re-resolving.
      ref ? null,
      skipUpdateEnvCheck ? false,
      selectedRepos ? _selectedRepos,
    }:
    let
      orig = lock.nodes.${nodeKey}.original or null;

      lockedOriginalMatches =
        let
          type = orig.type or "";
          # Transport-agnostic identity: githubViaSsh only changes HOW the same
          # repo is fetched. Comparing raw spellings would read a flag flip as a
          # different input, drop the pin, and silently re-resolve the branch tip
          # on a plain rebuild (and again on every flip back).
          canonUrl = _canonicalRepoUrl url;
        in
        orig != null
        && (
          if type == "path" then
            url == "path:${orig.path}"
          else
            let
              canonOrig = _canonicalLockOriginal orig;
            in
            (canonOrig != null && canonOrig == canonUrl)
            # Verbatim git urls still match without going through the canonical
            # form, which only knows the ssh spelling of a forge repo.
            || (type == "git" && (url == orig.url || url == "git+${orig.url}"))
        );
      # `github:` cannot spell a ref and a rev together, so IceDOS' own
      # rev-pinned emission (`github:o/r/<rev>`) is recorded as `{owner; repo;
      # rev;}` with NO ref. Reading that absence as "the ref changed" would
      # unpin, re-resolve the branch tip, re-pin, and unpin again on alternating
      # rebuilds. The git-scheme spelling keeps `?rev=&ref=` together, so an
      # edit is still caught there — which is where a bare `?rev=` would abort.
      refUnknowable = (orig ? rev) && !(orig ? ref);

      refMatches = refUnknowable || (orig.ref or null) == ref;
    in
    if !lockedOriginalMatches || !refMatches then
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
      ref ? null,
    }:
    let
      lock = _readFlakeLock;
    in
    if (lock == null) || ((stringStartsWith "path:" url) && (ICEDOS_STAGE == "genflake")) then
      ""
    else
      _resolveFlakeRevisionLocked {
        inherit url lock ref;
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
      ref ? null,
    }:
    let
      inputKey = _lockNestedNodeKey { inherit lock subFlakeName inputName; };
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
        inherit url lock ref;
        nodeKey = inputKey;
        skipUpdateEnvCheck = true;
      };

  # Does the lock CONFIRM that `ref` is where this node's rev came from? Our own
  # rev-pinned emission (`github:o/r/<rev>`, `original = {owner; repo; rev;}`)
  # cannot say — pairing its rev with the config's CURRENT ref would emit a
  # lookup that aborts rather than re-resolving, since the two need not agree
  # after a config edit. The git-scheme spelling records both, so from the first
  # ssh build onward the answer is yes and the cheap `&ref=` path is used again.
  _lockRefConfirmedLocked =
    {
      lock,
      nodeKey,
      ref ? null,
    }:
    let
      orig = lock.nodes.${nodeKey}.original or null;
    in
    orig != null && ref != null && (orig.ref or null) == ref;

  _lockRefConfirmed =
    {
      repoName,
      ref ? null,
    }:
    let
      lock = _readFlakeLock;
    in
    lock != null
    && _lockRefConfirmedLocked {
      inherit lock ref;
      nodeKey = repoName;
    };

  # root -> sub-flake node key -> input node key. `null` on any missing hop (or
  # a follows-array where a key was expected).
  _lockNestedNodeKey =
    {
      lock,
      subFlakeName,
      inputName,
    }:
    let
      hop =
        attrs: name:
        let
          v = attrs.${name} or null;
        in
        if builtins.isString v then v else null;

      subKey = hop (lock.nodes.root.inputs or { }) subFlakeName;
    in
    if subKey != null then hop (lock.nodes.${subKey}.inputs or { }) inputName else null;

  _lockRefConfirmedNested =
    {
      subFlakeName,
      inputName,
      ref ? null,
    }:
    let
      lock = _readFlakeLock;
      nodeKey =
        if lock == null then null else _lockNestedNodeKey { inherit lock subFlakeName inputName; };
    in
    nodeKey != null
    && _lockRefConfirmedLocked {
      inherit lock ref nodeKey;
    };

  # Revision lookup for a module input, which lives one level down inside its
  # module's sub-flake.
  _resolveFlakeRevisionNested =
    {
      url,
      subFlakeName,
      inputName,
      ref ? null,
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
          ref
          ;
      };

  # Rev cache-server last built for a leaf input, "" when untracked/unmatched.
  # Pure: `revs` is cache-server's published tracked-inputs.json (name -> rev |
  # { rev; repo; }). Key match mirrors its tracked-revs.py: exact node key, else a
  # "-<name>" suffixed one. The optional `repo` guard ("scheme:owner/repo") only
  # exists in the newer { rev; repo; } format and must equal the url's host repo;
  # older string entries pin on the name alone.
  _cacheRevLookup =
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
          }
        else
          {
            rev = value.rev or "";
            repo = value.repo or "";
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
          }
        else
          _entryOf revs.${key};
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

  # The ref a url actually names, whichever way it spells it: `o/r/<ref>` as a
  # path segment or `?ref=<ref>` in the query. `null` when it names none.
  _urlRef =
    url:
    let
      parsed = _parseFlakeUrl url;
      hits = map (lib.removePrefix "ref=") (
        filter (p: lib.hasPrefix "ref=" p) (_urlQueryParams parsed.baseUrl)
      );
    in
    if parsed.ref != null then
      parsed.ref
    else if hits == [ ] then
      null
    else
      head hits;

  # Git-scheme ref spelling: `?rev=` only for a 40-hex rev (any case), else
  # `?ref=` — a bare one is refs/heads/<ref>, so a tag needs refs/tags/<tag>.
  # Both qualified forms also resolve in a `github:` url (verified against the
  # API and `nix flake metadata`), so they are safe to write in config.toml,
  # which is shared by both transports; see `_gitRefSuffix`.
  _revSeparator = ref: if builtins.match "[0-9a-fA-F]{40}" ref != null then "?rev=" else "?ref=";

  # `a=1&b=2` of a url's query, [] when it carries none.
  _urlQueryParams =
    url:
    let
      m = builtins.match "[^?]*[?](.*)" url;
    in
    if m == null then [ ] else lib.splitString "&" (builtins.elemAt m 0);

  _urlHasParam = param: url: lib.any (p: lib.hasPrefix "${param}=" p) (_urlQueryParams url);

  # Nix resolves a git-scheme `?rev=` against `HEAD` ALONE, so a rev living on
  # any other branch aborts with "Cannot find Git revision '<rev>' in ref
  # 'HEAD' ... add allRefs = true". `github:` never had that limit, so a
  # rewritten url must carry a way to reach its rev.
  #
  # `ref` must be a branch the rev is KNOWN to live on — the one it was resolved
  # from. Passing an unrelated ref (say, the author's declared branch next to a
  # rev the cache server published from somewhere else) narrows the lookup to a
  # branch that may not contain it, which aborts the fetch; pass `null` there.
  #
  # `allRefsFallback` says whether a rev with no such branch NEEDS the escape
  # hatch. It is true only where the rev's provenance is unknown — a
  # hand-written 40-hex pin, or a rev the cache server published — because such
  # a rev may live outside the default branch's history. A rev nix itself
  # resolved from this very url is reachable from `HEAD` by construction, and
  # `allRefs=1` there would make every rebuild fetch every branch, tag and
  # `refs/pull/*` of every repo for nothing.
  #
  # No-op for non-git schemes and for urls that already resolve (no rev pin, or
  # an explicit ref/allRefs).
  _withRevReachable =
    {
      url,
      ref ? null,
      allRefsFallback ? false,
      # For a caller re-emitting a url another site already spelled this ref on:
      # the warning is about the config entry, not the emission, so tracing it
      # once per rebuild is the point.
      quiet ? false,
    }:
    if
      !(_urlIsGitScheme url)
      || !(_urlHasParam "rev" url)
      || _urlHasParam "ref" url
      || _urlHasParam "allRefs" url
    then
      url
    # A 40-hex `ref` is a rev, not a branch: it cannot narrow the lookup.
    # Spelled through `_gitRefSuffix` like every other ref, or a tag arriving on
    # the locked-rev path (where the caller never spells one) would be turned
    # into `refs/heads/<tag>` with no warning to explain the failed fetch.
    else if ref != null && ref != "" && _revSeparator ref == "?ref=" then
      _appendRevSuffix url (_gitRefSuffix {
        inherit ref url quiet;
      })
    else if allRefsFallback then
      _appendRevSuffix url "?allRefs=1"
    else
      url;

  # Transport-agnostic repo identity: `git+ssh://git@<host>/o/r` and the
  # `github:` spelling of the same repo collapse to one `repo:<host>/<o>/<r>`
  # key. The host is part of it — `github:` takes `host=` for GitHub Enterprise,
  # and the ssh rewrite honours it, so hardcoding github.com would drop a GHE
  # repo's lock pin on every transport flip. Remaining query params are sorted,
  # since the two spellings need not list them in the same order. Anything else
  # (gitlab:, sourcehut:, a plain git+https url) passes through unchanged.
  _canonicalRepoUrl =
    url:
    let
      ssh = builtins.match "git[+]ssh://git@([^/]+)/([^/?]+)/([^/?]+)([?].*)?" url;
      gh = builtins.match "github:([^/?]+)/([^/?]+)([?].*)?" url;

      params = _urlQueryParams url;
      paramValue =
        name:
        let
          hits = map (lib.removePrefix "${name}=") (filter (p: lib.hasPrefix "${name}=" p) params);
        in
        if hits == [ ] then null else head hits;
    in
    if ssh != null then
      _canonicalRepoKey {
        host = elemAt ssh 0;
        owner = elemAt ssh 1;
        repo = elemAt ssh 2;
        dir = paramValue "dir";
      }
    else if gh != null then
      _canonicalRepoKey {
        host = if paramValue "host" == null then "github.com" else paramValue "host";
        owner = elemAt gh 0;
        repo = elemAt gh 1;
        dir = paramValue "dir";
      }
    else
      url;

  # Identity is WHICH repo (and which subdirectory of it), never which revision
  # of it: nix hoists `ref`, `rev`, `allRefs`, `submodules`, `shallow`, `dir`,
  # `host` out of the url into separate `original` fields, so any of them left
  # in the key would compare against a `original` that no longer spells them and
  # lose the pin on every rebuild.
  _canonicalRepoKey =
    {
      host,
      owner,
      repo,
      dir ? null,
    }:
    "repo:${host}/${owner}/${lib.removeSuffix ".git" repo}"
    + (lib.optionalString (dir != null) "?dir=${dir}");

  # The same identity for a lock node's `original`, so both sides of the
  # comparison are built the same way. `null` = a shape we cannot canonicalise.
  _canonicalLockOriginal =
    orig:
    let
      type = orig.type or "";
    in
    if type == "github" then
      _canonicalRepoKey {
        host = orig.host or "github.com";
        inherit (orig) owner repo;
        dir = orig.dir or null;
      }
    else if type == "gitlab" || type == "sourcehut" then
      "${type}:${orig.owner}/${orig.repo}"
    else if type == "git" then
      # `orig.url` is the bare remote; `dir` was hoisted out of it, so add it
      # back the same way the url side derives it.
      let
        base = _canonicalRepoUrl "git+${lib.removePrefix "git+" orig.url}";
        ssh = builtins.match "git[+]ssh://git@([^/]+)/([^/?]+)/([^/?]+)([?].*)?" (
          "git+${lib.removePrefix "git+" orig.url}"
        );
      in
      if ssh == null then
        base
      else
        _canonicalRepoKey {
          host = elemAt ssh 0;
          owner = elemAt ssh 1;
          repo = elemAt ssh 2;
          dir = orig.dir or null;
        }
    else
      null;

  # Advisory-only: ANY unqualified ref is ambiguous over ssh — nix expands it to
  # refs/heads/<ref>, so a tag or a short rev fails with a confusing "couldn't
  # find remote ref" and nothing points at the transport switch. Guessing which
  # names look tag-shaped misses every tag that is not semver-shaped, so warn on
  # all of them; `refs/...` and a full 40-hex rev are unambiguous and stay quiet.
  # (`github:` accepts both `refs/...` forms too, so qualifying is portable.)
  _ambigRef = ref: builtins.match "[0-9a-fA-F]{40}" ref == null && !(lib.hasPrefix "refs/" ref);

  # THE way to spell a ref onto a git-scheme url: `?rev=<rev>` or `?ref=<ref>`,
  # with the ambiguity warning attached. Several sites rewrite a ref-stripped
  # base and re-attach the ref by hand, so a warning living in one of them
  # (`_githubUrlToGitSsh`) silently misses the others — repositories and module
  # inputs, which are exactly where tags get pinned. `url` is message context.
  _gitRefSuffix =
    {
      ref,
      url ? "",
      # Framework-supplied urls (the default nixpkgs channel) are known-good
      # branches the user never wrote, so they must not nag about them.
      quiet ? false,
    }:
    lib.warnIf (!quiet && _ambigRef ref)
      "githubViaSsh: bare ref '${ref}'${
        lib.optionalString (url != "") " of ${url}"
      } resolves as refs/heads/${ref} over ssh, so a tag of that name would be missed silently. Qualify it — refs/heads/${ref} for a branch, refs/tags/${ref} for a tag — or pin a full 40-hex rev; all three resolve with and without the switch."
      "${_revSeparator ref}${ref}";

  # Opt-in ssh transport: `github:` -> `git+ssh://git@github.com/...`; emission
  # only — names/lock keys keep the original url, non-github urls pass unchanged.
  _githubUrlToGitSshWith =
    {
      url,
      quiet ? false,
    }:
    let
      parsed = _parseFlakeUrl url;
      base = builtins.match "github:([^/?]+)/([^/?]+)(.*)" parsed.baseUrl;

      params = _urlQueryParams parsed.baseUrl;
      valuesOf = name: map (lib.removePrefix "${name}=") (filter (p: lib.hasPrefix "${name}=" p) params);

      # `github:` takes `host=` for GitHub Enterprise. ssh must point at THAT
      # server — keeping github.com would silently fetch from the wrong one —
      # and the param itself must not ride along, since the git scheme just
      # folds an unknown param back into the remote address.
      hosts = valuesOf "host";
      sshHost = if hosts == [ ] then "github.com" else head hosts;

      # A ref reaches us as a path segment (`github:o/r/<ref>`) or as a query
      # param; either way it is spelled exactly once, by `_gitRefSuffix`.
      ref = _urlRef url;

      rest = filter (p: !(lib.hasPrefix "host=" p) && !(lib.hasPrefix "ref=" p)) params;

      sshBase =
        "git+ssh://git@${sshHost}/${builtins.elemAt base 0}/${builtins.elemAt base 1}"
        + (lib.optionalString (rest != [ ]) "?${concatStringsSep "&" rest}");
    in
    if base == null then
      url
    else
      # Any rev pin here was hand-written — a 40-hex ref, or a query-form
      # `rev=` — so it may sit on any branch, and a bare `?rev=` (which nix
      # resolves from HEAD alone) would abort. Reachability is folded in rather
      # than left to callers: genflake's channels/overlays/nixpkgs and
      # `extraFlakeInputs` emit this result verbatim. A no-op when there is no
      # rev pin at all.
      _withRevReachable {
        url =
          if ref == null then
            sshBase
          else
            _appendRevSuffix sshBase (_gitRefSuffix {
              inherit ref quiet;
              url = sshBase;
            });
        allRefsFallback = true;
      };

  _githubUrlToGitSsh = url: _githubUrlToGitSshWith { inherit url; };

  # `f` applied to every `url` in a flake-input declaration: its own, and the
  # nested `inputs.<j>.url` overrides nix allows. Those are real fetches, so the
  # transport switch has to reach them too. A `follows`-only entry carries no
  # url and comes back untouched.
  _mapInputUrls =
    f: decl:
    if !(builtins.isAttrs decl) then
      decl
    else
      decl
      // (lib.optionalAttrs (decl ? url && builtins.isString decl.url) { url = f decl.url; })
      // (lib.optionalAttrs (decl ? inputs && builtins.isAttrs decl.inputs) {
        inputs = lib.mapAttrs (_: _mapInputUrls f) decl.inputs;
      });

  # Same rewrite, no ambiguity warning — for urls IceDOS itself supplies.
  _githubUrlToGitSshQuiet =
    url:
    _githubUrlToGitSshWith {
      inherit url;
      quiet = true;
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
