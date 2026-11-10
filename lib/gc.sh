# shellcheck shell=bash
# Shared gc output formatting matching nh clean 4.4.2 style.

_GC_HEADER=""
_GC_NOUN="path"
_GC_ACTIVE=0
_GC_EXTRA_FREED_KB=0
_GC_ENTRY_COUNT=0
declare -a _GC_ITEM_TYPES=()
declare -a _GC_ITEM_TEXTS=()
declare -a _GC_ITEM_EXTRAS=()
declare -a _GC_DEL_PATHS=()
declare -a _GC_NOTES=()

gc_section() {
  gc_commit
  _GC_HEADER="$1"
  _GC_NOUN="${2:-path}"
  _GC_ACTIVE=1
  _GC_EXTRA_FREED_KB=0
  _GC_ENTRY_COUNT=0
  _GC_ITEM_TYPES=()
  _GC_ITEM_TEXTS=()
  _GC_ITEM_EXTRAS=()
  _GC_DEL_PATHS=()
  _GC_NOTES=()
}

gc_note() {
  _GC_NOTES+=("$*")
}

gc_ok() {
  local p="$1"
  _GC_ITEM_TYPES+=("OK")
  _GC_ITEM_TEXTS+=("$p")
  _GC_ITEM_EXTRAS+=("")
}

gc_skip() {
  local p="$1"
  local reason="$2"
  _GC_ITEM_TYPES+=("SKIP")
  _GC_ITEM_TEXTS+=("$p")
  _GC_ITEM_EXTRAS+=("$reason")
}

gc_del() {
  local p="$1"
  [ -e "$p" ] || [ -L "$p" ] || return 0
  _GC_ITEM_TYPES+=("DEL")
  _GC_ITEM_TEXTS+=("$p")
  _GC_ITEM_EXTRAS+=("")
  _GC_DEL_PATHS+=("$p")
}

gc_del_entry() {
  local label="$1"
  _GC_ITEM_TYPES+=("ENTRY")
  _GC_ITEM_TEXTS+=("$label")
  _GC_ITEM_EXTRAS+=("")
  _GC_ENTRY_COUNT=$(( _GC_ENTRY_COUNT + 1 ))
}

# Lists `find ARGS...` matches newest first: DEL when older than DAYS (0 = all), else OK.
# The age test matches find's `-mtime +DAYS` rounding.
gc_by_age() {
  local days="$1" now entry
  shift
  now=$(date +%s)
  while IFS= read -r -d '' entry; do
    if [ "$days" -eq 0 ] || [ $(( now - ${entry%%.*} )) -ge $(( (days + 1) * 86400 )) ]; then
      gc_del "${entry#* }"
    else
      gc_ok "${entry#* }"
    fi
  done < <(find "$@" -printf '%T@ %p\0' 2>/dev/null | sort -z -rn)
}

gc_freed_kb() {
  local n="${1:-0}"
  _GC_EXTRA_FREED_KB=$(( _GC_EXTRA_FREED_KB + n ))
}

gc_human_kb() {
  local k="${1:-0}"
  local div unit t
  if (( k >= 1073741824 )); then
    div=1073741824
    unit="TiB"
  elif (( k >= 1048576 )); then
    div=1048576
    unit="GiB"
  elif (( k >= 1024 )); then
    div=1024
    unit="MiB"
  else
    div=1
    unit="KiB"
  fi
  t=$(( (k * 10 + div / 2) / div ))
  printf '%d.%d %s\n' "$(( t / 10 ))" "$(( t % 10 ))" "$unit"
}

gc_commit() {
  [ "$_GC_ACTIVE" -eq 1 ] || return 0
  _GC_ACTIVE=0

  local total_items="${#_GC_ITEM_TYPES[@]}"
  [ "$total_items" -gt 0 ] || return 0

  local phase="${ICEDOS_GC_PHASE:-both}"
  local dry="${ICEDOS_GC_DRY:-0}"
  local summary_file="${ICEDOS_GC_SUMMARY_FILE:-}"
  local i note p
  # Blocks open with a blank line (as nh does) so separate processes never run together.
  local sep_done=0

  if [ "$phase" = "preview" ] || [ "$phase" = "both" ]; then
    printf '\n%b%s%b\n' "$BLUE" "$_GC_HEADER" "$NC"
    if [ "${#_GC_NOTES[@]}" -gt 0 ]; then
      for note in "${_GC_NOTES[@]}"; do
        printf '%b\n' "$note"
      done
      printf '\n'
    fi
    for i in "${!_GC_ITEM_TYPES[@]}"; do
      case "${_GC_ITEM_TYPES[$i]}" in
        OK)
          printf -- '- %bOK %b %s\n' "$DIM_GREEN" "$NC" "${_GC_ITEM_TEXTS[$i]}"
          ;;
        DEL|ENTRY)
          printf -- '- %bDEL%b %s\n' "$DIM_RED" "$NC" "${_GC_ITEM_TEXTS[$i]}"
          ;;
        SKIP)
          printf -- '- %bSKIP%b %s (%s)\n' "$DIM_YELLOW" "$NC" "${_GC_ITEM_TEXTS[$i]}" "${_GC_ITEM_EXTRAS[$i]}"
          ;;
      esac
    done
  fi

  _gc_sep() {
    [ "$sep_done" -eq 1 ] && return 0
    printf '\n'
    sep_done=1
  }

  if [ "$phase" = "remove" ] || [ "$phase" = "both" ]; then
    local deleted_count=0
    local freed_kb=0

    if [ "$dry" = "1" ]; then
      for p in "${_GC_DEL_PATHS[@]}"; do
        if [ -e "$p" ] || [ -L "$p" ]; then
          local skb
          skb=$(du -sk -- "$p" 2>/dev/null | cut -f1) || skb=0
          freed_kb=$(( freed_kb + ${skb:-0} ))
          deleted_count=$(( deleted_count + 1 ))
        fi
      done
    else
      for p in "${_GC_DEL_PATHS[@]}"; do
        if [ -e "$p" ] || [ -L "$p" ]; then
          local skb
          skb=$(du -sk -- "$p" 2>/dev/null | cut -f1) || skb=0
          _gc_sep
          log_step "Removing $p"
          if rm -rf -- "$p" 2>/dev/null; then
            deleted_count=$(( deleted_count + 1 ))
            freed_kb=$(( freed_kb + ${skb:-0} ))
          else
            log_warn "failed to remove $p"
          fi
        fi
      done
    fi

    deleted_count=$(( deleted_count + _GC_ENTRY_COUNT ))
    freed_kb=$(( freed_kb + _GC_EXTRA_FREED_KB ))

    # `icedos gc` sums these files into its final total line.
    if [ "$dry" != "1" ] && [ "$freed_kb" -gt 0 ] && [ -n "${ICEDOS_GC_TOTAL_FILE:-}" ] && [ -w "$ICEDOS_GC_TOTAL_FILE" ]; then
      printf '%s\n' "$freed_kb" >> "$ICEDOS_GC_TOTAL_FILE"
    fi

    if [ "$deleted_count" -gt 0 ]; then
      local noun_phrase
      if [ "$deleted_count" -eq 1 ]; then
        noun_phrase="$deleted_count $_GC_NOUN"
      else
        noun_phrase="$deleted_count ${_GC_NOUN}s"
      fi

      local human_freed
      human_freed=$(gc_human_kb "$freed_kb")

      local summary_line
      if [ "$dry" = "1" ]; then
        summary_line="$noun_phrase would be deleted, $human_freed would be freed"
      else
        summary_line="$noun_phrase deleted, $human_freed freed"
      fi

      if [ -n "$summary_file" ]; then
        printf '%s\n' "$summary_line" >> "$summary_file"
      else
        _gc_sep
        printf '%s\n' "$summary_line"
      fi
    fi
  fi
}

# KiB from the last "... 23.8 GiB freed" line in FILE (nix store gc output), else 0.
gc_parse_freed_kb() {
  local file="$1" line kib=0 int dec mult
  local re='([0-9]+)(\.([0-9]))?[0-9]* (B|KiB|MiB|GiB|TiB) freed'
  [ -r "$file" ] || { echo 0; return 0; }
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    int="${BASH_REMATCH[1]}"
    dec="${BASH_REMATCH[3]:-0}"
    case "${BASH_REMATCH[4]}" in
      B) mult=0 ;;
      KiB) mult=1 ;;
      MiB) mult=1024 ;;
      GiB) mult=1048576 ;;
      TiB) mult=1073741824 ;;
    esac
    if [ "$mult" -eq 0 ]; then
      kib=$(( int / 1024 ))
    else
      kib=$(( (int * 10 + dec) * mult / 10 ))
    fi
  done < "$file"
  echo "$kib"
}

# Prints the grand total: EXTRA_KIB plus every number in the files under DIR.
gc_print_total() {
  local dir="$1" total="${2:-0}" f n
  for f in "$dir"/*; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    case "$f" in *.log) continue ;; esac
    while IFS= read -r n; do
      [[ "$n" =~ ^[0-9]+$ ]] && total=$(( total + n ))
    done < "$f"
  done
  printf '\nTotal: %b%s%b freed\n' "$DIM_GREEN" "$(gc_human_kb "$total")" "$NC"
}

trap gc_commit EXIT
