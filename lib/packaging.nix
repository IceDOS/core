{
  icedosLib,
  lib,
  self,
  ...
}:

let
  inherit (lib) optionalString;
in
rec {
  # Shell-snippet builders for `installPhase`/`postFixup` bodies, passed to a
  # `package.nix` explicitly via `callPackage ./package.nix { inherit ... }`.
  packaging = {
    # Extracts an AppImage into $out. `extractedDir` is what it unpacks to
    # ("AppDir", "squashfs-root"); `steamRun` wraps it in a glibc envelope.
    extractAppImage =
      {
        src,
        extractedDir ? "AppDir",
        moveSubdir ? null,
        steamRun ? null,
        preMove ? "",
      }:
      ''
        mkdir -p $out
        cp ${src} $TMPDIR/image.AppImage
        chmod +x $TMPDIR/image.AppImage
        ${
          optionalString (steamRun != null) "${steamRun}/bin/steam-run "
        }$TMPDIR/image.AppImage --appimage-extract
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
