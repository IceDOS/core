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
  inherit (pkgs) coreutils gnugrep;
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

            timeout=300
            maxjobs=auto
            exclude_patterns=()
            positional=()

            function printHelp() {
              echo "usage: icedos git rpull [--exclude <patterns>] [-j|--jobs <n|auto>] [--timeout <seconds>] [<path>]"
              echo "fast-forward pull every git repo found under <path> (default: current directory)"
              echo "stops at the first .git directory in each path; submodules are not pulled"
              echo ""
              echo "options:"
              echo -e "  ${yellowString "--exclude <patterns>"}: comma-separated substrings; repos whose path contains any match are skipped"
              echo -e "  ${yellowString "-j|--jobs <n|auto>"}: max concurrent pulls (default auto = 2-8 based on CPU count, capped at 64)"
              echo -e "  ${yellowString "--timeout <seconds>"}: max seconds per pull, 0 = no limit (default 300)"
              echo ""
              echo "pass -j 1 to pull sequentially and allow interactive prompts (ssh passphrases, https login)"
            }

            while [[ $# -gt 0 ]]; do
              case "$1" in
                -h | --help | help)
                  printHelp
                  exit 0
                  ;;
                --exclude)
                  [ $# -ge 2 ] || die "--exclude needs a value"
                  IFS=',' read -ra exclude_patterns <<< "$2"
                  shift 2
                  ;;
                -j | --jobs)
                  [ $# -ge 2 ] || die "--jobs needs a value"
                  maxjobs="$2"
                  shift 2
                  ;;
                --timeout)
                  [ $# -ge 2 ] || die "--timeout needs a value"
                  timeout="$2"
                  shift 2
                  ;;
                *)
                  positional+=("$1")
                  shift
                  ;;
              esac
            done

            if [ "$maxjobs" = auto ]; then
              ncpu=$(${coreutils}/bin/nproc)
              maxjobs=$(( ncpu < 2 ? 2 : ncpu ))
              [ "$maxjobs" -gt 8 ] && maxjobs=8
            fi
            [[ "$maxjobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be 'auto' or a positive integer"
            [ "$maxjobs" -le 64 ] || {
              log_warn "--jobs capped at 64"
              maxjobs=64
            }
            [[ "$timeout" =~ ^[0-9]+$ ]] || die "--timeout must be a non-negative integer"
            [ "$timeout" -le 86400 ] || die "--timeout must be <= 86400"

            root="''${positional[0]:-.}"
            [ -d "$root" ] || die "not a directory: $root"

            repos=()
            while IFS= read -r -d "" repo; do
              repos+=("$repo")
            done < <(LC_ALL=C find "$root" -type d -exec test -e "{}/.git" ";" -prune -print0 | LC_ALL=C ${coreutils}/bin/sort -z)

            excluded=0
            count=0
            include=()

            for repo in "''${repos[@]}"; do
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
              include+=("$repo")
            done

            if [ "$count" -eq 0 ]; then
              echo
              if [ "$excluded" -eq 0 ]; then
                log_warn "no git repositories found under $root"
              else
                log_warn "all $excluded repositories excluded, nothing to pull"
              fi
              exit 0
            fi

            if [ -t 1 ] && [ "''${TERM:-}" != dumb ] && [ -z "''${NO_TUI:-}" ] && [ "$maxjobs" -gt 1 ]; then
              tui=1
            else
              tui=0
            fi

            state=()
            detail=()
            start=()
            born=()
            for ((i=1; i<=count; i++)); do
              state[$i]=queued
              detail[$i]=""
              start[$i]=$SECONDS
              born[$i]=$SECONDS
            done

            tmpdir=$(${coreutils}/bin/mktemp -d) || die "could not create temp dir"
            prev_lines=0
            tui_past=0
            spin_i=0
            trap '
              if [ "$tui" -eq 1 ] && [ "$tui_past" -eq 0 ]; then
                printf "\033[?25h\r\n"
              elif [ "$tui" -eq 1 ]; then
                printf "\033[?25h"
              fi
              ${coreutils}/bin/rm -rf "$tmpdir"
            ' EXIT

            function showRepos() {
              mode="$*"
              [ -n "$mode" ] || mode=all
              errors=false
              skips=0
              for m in $mode; do
                [ "$m" = errors ] && errors=true
                [ "$m" = skip-unstarted ] && skips=1
              done
              failed=()
              failed_i=()

              for ((i=1; i<=spawned; i++)); do
                s=""
                [ -e "$tmpdir/$i.status" ] && IFS=/ read -r _ s < "$tmpdir/$i.status"
                [ -n "$s" ] || s=1
                if [ "$s" -ne 0 ]; then
                  failed+=("''${include[$((i - 1))]}")
                  failed_i+=("$i")
                  [ "$skips" -eq 1 ] && log_warn "exit $s: ''${include[$((i - 1))]}"
                fi
              done

              if $errors; then
                for j in "''${failed_i[@]}"; do
                  [ -s "$tmpdir/$j.err" ] || continue
                  log_step "''${include[$((j - 1))]}"
                  ${coreutils}/bin/cat "$tmpdir/$j.err" >&2 2>/dev/null
                done
              else
                for ((j=1; j<=spawned; j++)); do
                  [ -e "$tmpdir/$j.out" ] && ${coreutils}/bin/cat "$tmpdir/$j.out" || true
                  [ -e "$tmpdir/$j.err" ] && ${coreutils}/bin/cat "$tmpdir/$j.err" >&2 2>/dev/null || true
                done
              fi

              [ "$skips" -eq 1 ] && return 0

              echo
              if [ ''${#failed[@]} -eq 0 ]; then
                msg="all $count repositories pulled successfully"
                [ "$excluded" -gt 0 ] && msg="$msg ($excluded excluded)"
                log_ok "$msg"
              else
                log_fail "failed pulls:"
                for d in "''${failed[@]}"; do
                  printf '  - %s\n' "$d"
                done
                if ${gnugrep}/bin/grep -q -E 'ssh:|Connection (refused|closed|reset)|Too many|max sessions|rate limit|kex_exchange_identification|timed out' "$tmpdir"/*.err 2>/dev/null; then
                  log_warn "pulls may have hit an ssh/rate limit; retry failed repos one at a time with: icedos git rpull -j 1"
                fi
                if ${gnugrep}/bin/grep -q -E 'Permission denied \(publickey\)|Host key verification failed|terminal prompts disabled' "$tmpdir"/*.err 2>/dev/null; then
                  log_warn "some pulls failed because parallel mode disables interactive prompts; retry them one at a time with: icedos git rpull -j 1"
                fi
                exit 1
              fi
            }

            function cachedetail() {
              local i="$1" out="$tmpdir/$i.out" line="" upd="" stat=""
              if ${gnugrep}/bin/grep -q 'Already up to date' "$out" 2>/dev/null; then
                echo "up to date"
                return
              fi
              line=$(${gnugrep}/bin/grep -m1 '^Updating ' "$out" 2>/dev/null || true)
              [ -n "$line" ] && upd="''${line#Updating }"
              line=$(${gnugrep}/bin/grep -m1 -E '[0-9]+ files? changed' "$out" 2>/dev/null || true)
              if [ -n "$upd" ]; then
                if [[ "$line" =~ ([0-9]+)\ files?\ changed,\ ([0-9]+)\ insertions?\(\+\),\ ([0-9]+)\ deletions?\(-\) ]]; then
                  echo "''${upd}  ''${BASH_REMATCH[1]} files +''${BASH_REMATCH[2]} −''${BASH_REMATCH[3]}"
                else
                  echo "$upd"
                fi
              elif [ -n "$line" ]; then
                echo "$line"
              else
                echo "exit 0"
              fi
            }

            function faildetail() {
              local i="$1" s="$2" line=""
              case "$s" in
                124) echo "timed out after ''${timeout}s"; return ;;
                137) echo "timed out (killed)"; return ;;
                143) echo "interrupted"; return ;;
              esac
              line=$(${gnugrep}/bin/grep -m1 -E '^fatal:|^error:' "$tmpdir/$i.err" 2>/dev/null || true)
              if [ -n "$line" ]; then
                line="''${line#fatal: }"
                line="''${line#error: }"
                echo "$line"
                return
              fi
              line=$(${gnugrep}/bin/grep -E '.+' "$tmpdir/$i.err" 2>/dev/null | ${coreutils}/bin/tail -n 1 || true)
              if [ -n "$line" ]; then
                echo "$line"
              else
                echo "exit $s"
              fi
            }

            if [ "''${TERM:-}" = linux ]; then
              spin=('|' '/' '-' '\')
            else
              spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
            fi

            function render() {
              local full=0
              [ "''${1:-}" = full ] && full=1
              local cols=80 rows=24 size
              if size=$(${coreutils}/bin/stty size </dev/tty 2>/dev/null); then
                read -r rows cols <<< "$size"
                [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
                [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
                [ "$rows" -gt 0 ] || rows=24
                [ "$cols" -gt 0 ] || cols=80
              fi

              local -a sel=()
              local -a disp=()
              local i st
              local failn=0 runn=0 donen=0 qn=0
              for ((i=1; i<=count; i++)); do
                st="''${state[$i]}"
                case "$st" in
                  failed | interrupted) failn=$((failn + 1)) ;;
                  running) runn=$((runn + 1)) ;;
                  done) donen=$((donen + 1)) ;;
                  queued) qn=$((qn + 1)) ;;
                esac
              done

              if [ "$full" -eq 1 ]; then
                for ((i=1; i<=count; i++)); do
                  sel+=("$i")
                done
              else
                local k=$(( rows - 4 ))
                [ "$k" -lt 1 ] && k=1
                [ "$k" -gt "$count" ] && k=$count

                for ((i=1; i<=count; i++)); do
                  st="''${state[$i]}"
                  if [ "$st" = failed ] || [ "$st" = interrupted ]; then
                    sel+=("$i")
                    [ "''${#sel[@]}" -ge "$k" ] && break
                  fi
                done
                for ((i=1; i<=count; i++)); do
                  [ "''${state[$i]}" = running ] || continue
                  sel+=("$i")
                  [ "''${#sel[@]}" -ge "$k" ] && break
                done
                for ((i=1; i<=count; i++)); do
                  [ "''${state[$i]}" = queued ] || continue
                  sel+=("$i")
                  [ "''${#sel[@]}" -ge "$k" ] && break
                done
                for ((i=1; i<=count; i++)); do
                  [ "''${state[$i]}" = done ] || continue
                  sel+=("$i")
                  [ "''${#sel[@]}" -ge "$k" ] && break
                done
              fi

              local nsel="''${#sel[@]}" done_selected=0 hidden=0 collapse=""
              if [ "$full" -eq 0 ]; then
                for i in "''${sel[@]}"; do
                  [ "''${state[$i]}" = done ] && done_selected=$((done_selected + 1))
                done
                hidden=$(( donen - done_selected ))
                if [ "$hidden" -gt 0 ] && [ "$nsel" -gt 0 ]; then
                  local last_idx="''${sel[$((nsel - 1))]}"
                  local last_st="''${state[$last_idx]}"
                  if [ "$last_st" = failed ] || [ "$last_st" = interrupted ]; then
                    collapse=""
                  else
                    collapse="… +''${hidden} done"
                    sel=("''${sel[@]:0:$((nsel - 1))}")
                  fi
                fi
              fi

              local line="" name="" detail_str="" icon="" col="" budget=0 detail_max=0 name_max=0 keep=0
              for i in "''${sel[@]}"; do
                st="''${state[$i]}"
                icon="·"; col=""; detail_str=""
                case "$st" in
                  running)
                    icon="''${spin[$spin_i]}"
                    col="$DIM_BLUE"
                    detail_str="$(( SECONDS - start[$i] ))s"
                    ;;
                  done)
                    icon="✓"
                    col="$GREEN"
                    detail_str="''${detail[$i]}"
                    ;;
                  failed)
                    icon="✗"
                    col="$RED"
                    detail_str="''${detail[$i]}"
                    ;;
                  interrupted)
                    icon="⚠"
                    col="$YELLOW"
                    detail_str="''${detail[$i]}"
                    ;;
                esac
                name="''${include[$((i - 1))]}"
                [[ "$name" == "$root/"* ]] && name="''${name#"$root/"}"
                budget=$(( cols - 6 ))
                [ "$budget" -lt 1 ] && budget=1
                detail_max=$(( budget / 2 ))
                [ "$detail_max" -gt 40 ] && detail_max=40
                if [ "''${#detail_str}" -gt "$detail_max" ]; then
                  detail_str="''${detail_str:0:$((detail_max - 1))}…"
                fi
                name_max=$(( budget - ''${#detail_str} ))
                [ "$name_max" -lt 0 ] && name_max=0
                if [ "''${#name}" -gt "$name_max" ]; then
                  if [ "$name_max" -le 1 ]; then
                    name="…"
                  else
                    keep=$(( name_max - 1 ))
                    name="…''${name: -$keep}"
                  fi
                fi
                if [ -n "$col" ]; then
                  disp+=("''${col}''${icon}''${NC} ''${name}  ''${detail_str}")
                else
                  disp+=("''${icon} ''${name}  ''${detail_str}")
                fi
              done

              local footer="''${donen}/''${count} done"
              [ "$failn" -gt 0 ] && footer="''${footer} · ''${failn} failed"
              [ "$runn" -gt 0 ] && footer="''${footer} · ''${runn} running"
              [ "$full" -eq 1 ] && [ "$qn" -gt 0 ] && footer="''${footer} · ''${qn} queued"
              footer="''${footer} · j=''${maxjobs}"
              [ "$excluded" -gt 0 ] && footer="''${footer} (''${excluded} excluded)"

              local -a frame=()
              if [ "$rows" -le 3 ] && [ "$full" -eq 0 ]; then
                frame=("$footer")
              else
                for i in "''${disp[@]}"; do
                  frame+=("$i")
                done
                [ -n "$collapse" ] && frame+=("$collapse")
                frame+=("$footer")
              fi

              local out="" n="''${#frame[@]}" idx2=0
              if [ "$prev_lines" -gt 1 ]; then
                out="\r\033[$((prev_lines - 1))A"
              elif [ "$prev_lines" -eq 1 ]; then
                out="\r"
              fi
              for i in "''${frame[@]}"; do
                idx2=$((idx2 + 1))
                out="''${out}\033[2K''${i}"
                [ "$idx2" -lt "$n" ] && out="''${out}\n"
              done
              out="''${out}\033[J"
              printf '%b' "$out"
              prev_lines=$n
              spin_i=$(( (spin_i + 1) % ''${#spin[@]} ))
            }

            function move_past() {
              printf '\033[?25h\r\n'
              tui_past=1
            }

            spawned=0
            running=0
            next=1

            trap 'trap "" INT; for pass in 1 2; do for f in "$tmpdir"/*.gpid; do [ -e "$f" ] || continue; pid=$(${coreutils}/bin/cat "$f"); kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; done; [ "$pass" -eq 1 ] && ${coreutils}/bin/sleep 0.2; done; trap "exit 130" INT; wait 2>/dev/null; if [ "$tui" -eq 1 ]; then for ((i=1; i<=spawned; i++)); do case "''${state[$i]}" in running|queued) state[$i]=interrupted; detail[$i]="interrupted" ;; esac; done; render full; move_past; showRepos errors skip-unstarted; echo; log_warn "interrupted by Ctrl-C; pulls stopped (exit 130)"; else showRepos skip-unstarted; echo; log_warn "interrupted by Ctrl-C; pulls stopped (exit 130)"; fi; exit 130' INT

            while [ "$spawned" -lt "$count" ] || [ "$running" -gt 0 ]; do
              for ((i=1; i<=spawned; i++)); do
                st="''${state[$i]}"
                if [ "$st" = done ] || [ "$st" = failed ]; then
                  continue
                fi
                if [ -e "$tmpdir/$i.status" ]; then
                  IFS=/ read -r _ s < "$tmpdir/$i.status"
                  if [ "$s" -eq 0 ]; then
                    state[$i]=done
                    detail[$i]=$(cachedetail "$i")
                  else
                    state[$i]=failed
                    detail[$i]=$(faildetail "$i" "$s")
                  fi
                  running=$((running - 1))
                elif [ "$((SECONDS - born[$i]))" -ge 2 ] && [ ! -e "$tmpdir/$i.gpid" ]; then
                  state[$i]=failed
                  detail[$i]="exit 1"
                  running=$((running - 1))
                fi
              done

              while [ "$running" -lt "$maxjobs" ] && [ "$next" -le "$count" ]; do
                i=$next
                next=$((next + 1))
                running=$((running + 1))
                state[$i]=running
                born[$i]=$SECONDS
                start[$i]=$SECONDS
                [ "$tui" -eq 0 ] && log_step "''${include[$((i - 1))]}"
                env_args=("${coreutils}/bin/env")
                if [ "$maxjobs" -gt 1 ]; then
                  env_args+=(
                    "GIT_SSH_COMMAND=''${GIT_SSH_COMMAND:-$(git -C "''${include[$((i - 1))]}" config --get core.sshCommand 2>/dev/null || echo ssh)} -o BatchMode=yes"
                    "GIT_TERMINAL_PROMPT=0"
                    "GIT_ASKPASS="
                    "SSH_ASKPASS_REQUIRE=never"
                  )
                fi
                (
                  trap '
                    if [ ! -e "$tmpdir/$i.status" ]; then
                      echo ok/1 > "$tmpdir/$i.status.part" 2>/dev/null
                      ${coreutils}/bin/mv "$tmpdir/$i.status.part" "$tmpdir/$i.status" 2>/dev/null
                      ${coreutils}/bin/rm -f "$tmpdir/$i.gpid"
                    fi
                  ' EXIT
                  "''${env_args[@]}" ${coreutils}/bin/timeout -k 10 $timeout git -C "''${include[$((i - 1))]}" pull --ff-only </dev/null &
                  gp=$!
                  echo "$gp" > "$tmpdir/$i.gpid"
                  wait "$gp"
                  s=$?
                  echo ok/"$s" > "$tmpdir/$i.status.part"
                  ${coreutils}/bin/mv "$tmpdir/$i.status.part" "$tmpdir/$i.status"
                  ${coreutils}/bin/rm -f "$tmpdir/$i.gpid"
                ) > "$tmpdir/$i.out" 2> "$tmpdir/$i.err" &
                spawned=$i
              done

              if [ "$tui" -eq 1 ]; then
                render
              fi
              ${coreutils}/bin/sleep 0.1
            done

            wait

            trap 'exit 130' INT

            if [ "$tui" -eq 1 ]; then
              render full
              move_past
              showRepos errors
            else
              showRepos
            fi
          '';

          help = "[--exclude <patterns>] [-j|--jobs <n|auto>] [--timeout <seconds>] <path> - fast-forward pull every git repo found recursively under path (default: current directory)";

          completion.files = true;
        }
      ];
    }
  ];
}
