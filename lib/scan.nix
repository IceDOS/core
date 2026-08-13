{
  icedosLib,
  lib,
  self,
  ...
}:

let
  inherit (builtins)
    attrNames
    pathExists
    seq
    ;

  inherit (lib)
    filterAttrs
    flatten
    hasSuffix
    optional
    ;

  inherit (icedosLib)
    abortIf
    stringStartsWith
    ;
in
rec {
  # Module entry points under `path` (dirs with a default.nix, plus loose *.nix).
  # Preserves the input type, so the result drops straight into `imports`.
  getModules =
    path:
    let
      entries = builtins.readDir path;
      isDir = _: v: v == "directory";
      isNixFile = n: v: v == "regular" && hasSuffix ".nix" n && n != "default.nix";
      dirs = attrNames (filterAttrs isDir entries);
      files = attrNames (filterAttrs isNixFile entries);
      dirHasDefault = dir: pathExists (path + "/${dir}/default.nix");
    in
    map (dir: path + "/${dir}") (builtins.filter dirHasDefault dirs)
    ++ map (file: path + "/${file}") files;

  # Whether a module is loaded: against `url`, else `repoUrl` (the caller's own
  # repo), else every repo. Pass `name` or a NON-EMPTY `modules` list.
  hasModule =
    {
      config,
      name ? null,
      url ? null,
      repoUrl ? null,
      modules ? null,
    }:
    let
      inherit (config.icedos.system) loadedModules;
      # `modules = []` would be vacuously true, so it aborts; `seq` fires that even
      # when an empty `loadedModules` would short-circuit the scan.
      names =
        seq
          (abortIf (
            modules == [ ] || (name == null && modules == null)
          ) "hasModule: pass a module name or a non-empty modules list")
          (if modules != null then modules else [ name ]);
      inUrl = u: lib.all (n: lib.elem n (loadedModules.${u} or [ ])) names;
    in
    seq names (
      if url != null then
        inUrl url
      else if repoUrl != null then
        inUrl repoUrl
      else
        lib.any inUrl (builtins.attrNames loadedModules)
    );

  scanModules =
    {
      path,
      filename,
      maxDepth ? -1,
    }:
    let
      inherit (builtins) readDir;

      getContentsByType = fileType: filterAttrs (name: type: type == fileType) contents;

      targetPath = if (stringStartsWith "/nix/store" "${path}") then "${path}" else "${self}/${path}";
      contents = readDir targetPath;

      directories = getContentsByType "directory";
      files = getContentsByType "regular";

      directoriesPaths = map (n: "${path}/${n}") (attrNames directories);

      icedosFiles = filterAttrs (n: v: n == filename) files;
      icedosFilesPaths = map (n: "${targetPath}/${n}") (attrNames icedosFiles);
    in
    icedosFilesPaths
    ++ optional (maxDepth != 0) (
      flatten (
        map (
          dp:
          scanModules {
            inherit filename;
            path = dp;
            maxDepth = maxDepth - 1;
          }
        ) directoriesPaths
      )
    );

}
