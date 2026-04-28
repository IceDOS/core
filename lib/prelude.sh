# shellcheck shell=bash
# Bash prelude shared by Nix-embedded scripts (via icedosLib.bash.prelude
# in core/lib/helpers.nix) and standalone .sh files (via `source`).
#
# Bold + color (1;3N) for severity-style prefixes that end with `:` —
# `error:`, `warning:`, etc. (matches nh's look). Dim variants (0;3N)
# for inline highlights that aren't level prefixes (status arrows, arg
# names in help text, file paths). Pick the *String helper (Nix side)
# or the matching colour var (shell side) based on whether the colored
# fragment is followed by a `:` in the surrounding sentence.
NC='\033[0m'
BLUE='\033[1;34m'
GREEN='\033[1;32m'
PURPLE='\033[1;35m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
DIM_BLUE='\033[0;34m'
DIM_GREEN='\033[0;32m'
DIM_PURPLE='\033[0;35m'
DIM_RED='\033[0;31m'
DIM_YELLOW='\033[0;33m'

# Strip escape codes when stdout isn't a terminal so piped/redirected
# output stays clean (e.g. `icedos download | cat`).
if [ ! -t 1 ]; then
  NC='' BLUE='' GREEN='' PURPLE='' RED='' YELLOW=''
  DIM_BLUE='' DIM_GREEN='' DIM_PURPLE='' DIM_RED='' DIM_YELLOW=''
fi

log_info()  { printf '%b>%b %s\n' "$DIM_BLUE"  "$NC" "$*"; }
log_step()  { printf '%b>%b %s\n' "$DIM_GREEN" "$NC" "$*"; }
log_ok()    { printf '%b✓%b %s\n' "$GREEN"     "$NC" "$*"; }
log_warn()  { printf '%b⚠%b %s\n' "$YELLOW"    "$NC" "$*" >&2; }
log_fail()  { printf '%b✗%b %s\n' "$RED"       "$NC" "$*" >&2; }
log_error() { log_fail "$@"; }
die()       { log_fail "$@"; exit 1; }

is_help_flag() {
  [[ "${1-}" == "" || "${1-}" == "--help" || "${1-}" == "-h" \
     || "${1-}" == "help" || "${1-}" == "h" ]]
}
