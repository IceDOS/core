{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.users) genDefaults;

  inherit (icedosLib.bash)
    dimGreenString
    dimYellowString
    purpleString
    redString
    yellowString
    ;

  inherit (config.icedos.system.git) users;
in
{
  icedos.system.git.users = genDefaults {
    inherit (config.icedos) users;
  };

  home-manager.sharedModules = [
    (
      { config, ... }:
      let
        gitUser = users.${config.home.username};
      in
      {
        home.packages = [ pkgs.lazygit ];

        programs.git = {
          enable = true;

          settings =
            let
              inherit (lib) mkIf;
            in
            {
              user.email = mkIf (gitUser.email != "") gitUser.email;
              user.name = mkIf (gitUser.username != "") gitUser.username;
            };

          signing.format = null; # Fallback for system version lower than 25.05
        };
      }
    )
  ];

  icedos.system.toolset.commands = [
    {
      command = "git";
      help = "git related commands";
      commands = [
        {
          command = "extract-commit";

          script = ''
            ERROR="${redString "error"}"

            function printHelp() {
              echo "Available arguments:"
              echo -e "> ${yellowString "-c, --commit"}: commit hash from which a file list will be generated"
              echo -e "> ${yellowString "-d, --destination"}: path to copy generated file list to"
              echo -e "> ${purpleString "--fetch-files-from-commit"}: fetch files content from commit, instead of current tree"
              echo -e "\n(${dimGreenString "!"}) Yellow-colored arguments are required"
            }

            if [[ $# -le 1 ]]; then
              printHelp
              exit 0
            fi

            while [[ $# -gt 0 ]]; do
              case "$1" in
                -c|--commit)
                  COMMIT="$2"
                  shift 2
                  ;;
                -d|--destination)
                  DESTINATION="$2"
                  shift 2
                  ;;
                --fetch-files-from-commit)
                  FETCH_COMMIT=1
                  shift
                  ;;
                *)
                  echo -e "$ERROR: unknown arg \"$1\" \n"
                  printHelp
                  exit 1
              esac
            done

            [ "$COMMIT" == "" ] && echo -e "$ERROR: ${dimYellowString "-c|--commit"} required" && exit 1
            [ "$DESTINATION" == "" ] && echo -e "$ERROR: ${dimYellowString "-d|--destination"} required" && exit 1

            FILES_TO_EXTRACT=$(git diff-tree --no-commit-id --name-only -r "$COMMIT" 2>/dev/null)

            [ -z "''${FILES_TO_EXTRACT[@]}" ] && echo -e "$ERROR: no files to extract, make sure the commit hash is correct and not empty" && exit 1

            mkdir -p "$DESTINATION"

            for file in $FILES_TO_EXTRACT; do
              source_dir=$(dirname "$file")
              dest_dir="$DESTINATION/$source_dir"

              mkdir -p "$dest_dir"

              case $FETCH_COMMIT in
                1)
                  git show "''${COMMIT}:''${file}" > "$DESTINATION/$file"
                  ;;
                *)
                  if [[ ! -e "$file" ]]; then
                    echo -e "$ERROR: failed to copy \"$file\", file is not present in current structure"
                    continue
                  fi

                  cp "$file" "$DESTINATION/$file"
                  ;;
              esac
            done
          '';

          help = "-c <commit_hash> -d <destination_directory>";
        }
        {
          command = "rpull";

          script = ''
            set -u

            function printHelp() {
              echo "usage: icedos git rpull [--exclude <patterns>] [<path>]"
              echo "fast-forward pull every git repo found under <path> (default: current directory)"
              echo ""
              echo "options:"
              echo -e "  ${yellowString "--exclude <patterns>"}: comma-separated substrings; repos whose path contains any match are skipped"
            }

            exclude_patterns=()
            positional=()

            while [[ $# -gt 0 ]]; do
              case "$1" in
                -h | --help | help)
                  printHelp
                  exit 0
                  ;;
                --exclude)
                  IFS=',' read -ra exclude_patterns <<< "$2"
                  shift 2
                  ;;
                *)
                  positional+=("$1")
                  shift
                  ;;
              esac
            done

            root="''${positional[0]:-.}"
            [ -d "$root" ] || die "not a directory: $root"

            excluded=0
            failed=()
            count=0

            while IFS= read -r -d "" repo; do
              skip=false
              for pat in "''${exclude_patterns[@]}"; do
                if [[ "$repo" == *"$pat"* ]]; then
                  skip=true
                  break
                fi
              done

              if $skip; then
                excluded=$((excluded + 1))
                continue
              fi

              count=$((count + 1))
              log_step "$repo"
              if ! git -C "$repo" pull --ff-only; then
                failed+=("$repo")
              fi
            done < <(find "$root" -type d -exec test -e "{}/.git" ";" -prune -print0)

            echo
            if [ "$count" -eq 0 ] && [ "$excluded" -eq 0 ]; then
              log_warn "no git repositories found under $root"
              exit 0
            fi

            if [ "$count" -eq 0 ] && [ "$excluded" -gt 0 ]; then
              log_warn "all $excluded repositories excluded, nothing to pull"
              exit 0
            fi

            if [ ''${#failed[@]} -eq 0 ]; then
              msg="all $count repositories pulled successfully"
              [ "$excluded" -gt 0 ] && msg="$msg ($excluded excluded)"
              log_ok "$msg"
            else
              log_fail "failed pulls:"
              for d in "''${failed[@]}"; do
                printf '  - %s\n' "$d"
              done
              exit 1
            fi
          '';

          help = "[--exclude <patterns>] <path> - fast-forward pull every git repo found recursively under path (default: current directory)";
        }
      ];
    }
  ];
}
