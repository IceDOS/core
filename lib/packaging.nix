{
  lib,
  ...
}:

let
  inherit (lib) optionalString;
in
{
  # Shell-snippet builders for `installPhase`/`postFixup` bodies, passed to a
  # `package.nix` explicitly via `callPackage ./package.nix { inherit ... }`.
  packaging = {
    # Unpacks an AppImage into $out. `extractedDir` is the scratch dir the image
    # is unpacked to, which `preMove`/`moveSubdir` are then relative to.
    extractAppImage =
      {
        appimageTools,
        src,
        extractedDir ? "AppDir",
        moveSubdir ? null,
        preMove ? "",
      }:
      ''
        ${appimageTools.appimage-exec}/bin/appimage-exec.sh -x ${extractedDir} ${src}
        mkdir -p $out
        ${preMove}
        mv ${extractedDir}/${optionalString (moveSubdir != null) "${moveSubdir}/"}* $out
      '';

    # Desktop-entry install with `@out@` substitution: `desktopItem`'s exec/icon
    # carry the marker so the file can be rewritten to the real $out.
    installDesktopEntry =
      {
        desktopItem,
        desktopFile,
        icon ? null,
        replaceMarker ? "/@out@",
      }:
      ''
        install -Dm644 ${desktopItem}/share/applications/${desktopFile} \
          $out/share/applications/${desktopFile}
        substituteInPlace $out/share/applications/${desktopFile} \
          --replace-fail "${replaceMarker}" "$out"
      ''
      + optionalString (icon != null) ''
        ln -s $out/${icon} $out/share/applications/${icon}
      '';
  };

}
