#!/usr/bin/env bash
#
# cluster_mergerfs — manage mergerfs mounts across a SLURM cluster.
#
# Mounts, inspects, unmounts and un-wedges mergerfs unions that overlay several
# per-node cluster scratch directories onto a single local path.
#
# Run without arguments for the interactive menu, or drive it with flags:
#   cluster_mergerfs.bash status -s projectA-logs -n all -j 8
#   cluster_mergerfs.bash mount  -s all -n current -y
# See --help for the full interface.

set -euo pipefail

readonly VERSION="2.2.2"
readonly PROGNAME="${0##*/}"

# Presentation and internal tunables — not meant to be user-configured.
readonly RULE_WIDTH=63           # width of the ─── separators and headers
readonly PREVIEW_TAG_WIDTH=24    # tag column width in the operation preview
readonly MUX_SOCKET_DIR="/tmp"   # ssh ControlPath home; must fit a sockaddr_un (108 bytes)
readonly MUX_PERSIST=60          # seconds a shared ssh master lingers after its last use
readonly DEFAULT_JOBS=1          # default node parallelism (1 = serial); the single
                                 # switch for serial-vs-parallel everywhere
readonly SUMMARY_COVERAGE_CAP=24 # max width of the summary "coverage" column before
                                 # a long node list is allowed to overflow it

# =============================================================================
# CONFIGURATION
#
# Everything here can be overridden by ~/.config/cluster_mergerfs.conf
# (see load_config below).
# =============================================================================

# Register a merge set. Two equivalent forms:
#
#   Explicit  — the tag, the local mount, then one full branch per node:
#     merge_set <tag> <mount> <branch>...
#
#   Pattern   — the tag, the local mount, a node list and a branch template
#               where {node} expands to each node (nice when branches share a
#               shape and differ only by node):
#     merge_set <tag> <mount> --nodes a,b,c --template '/cluster/{node}/…'
#
# Both compile to the same internal "tag:mount:branch:branch:..." form; a set
# with no branches is reported by validate_config. Add or drop a node by adding
# or deleting a branch line (explicit) or editing --nodes (pattern).
merge_set() {
  local tag="$1" mount="$2"; shift 2
  local branches=()

  if [[ "${1:-}" == --* ]]; then
    local nodes_csv="" template="" nodes=() node
    while (( $# )); do
      case "$1" in
        --nodes)    nodes_csv="${2:-}"; shift 2 ;;
        --template) template="${2:-}"; shift 2 ;;
        *) printf '❌ merge_set %s: unknown option %s\n' "$tag" "$1" >&2; return 1 ;;
      esac
    done
    IFS=',' read -r -a nodes <<< "$nodes_csv"
    for node in "${nodes[@]}"; do
      [[ -n "$node" ]] && branches+=("${template//\{node\}/$node}")
    done
  else
    branches=("$@")
  fi

  local joined="$tag:$mount" branch
  for branch in "${branches[@]}"; do joined+=":$branch"; done
  MERGE_SETS+=("$joined")
}

MERGE_SETS=()

# Pattern form: one branch per node sharing a common template, where {node}
# expands to each entry in --nodes.
merge_set projectA-logs /home/<user>/projects/projectA/logs \
  --nodes node1,node2,node3,node4 \
  --template '/cluster/{node}/<user>/projectA_logs'

# Explicit form: list each branch directly (just as short for single-node sets).
merge_set projectB-scenes /home/<user>/projects/projectB/scenes \
  /cluster/node1/<user>/projectB/scenes

merge_set projectB-outputs /home/<user>/projects/projectB/outputs \
  /cluster/node1/<user>/projectB/outputs

MERGERFS_OPTS="cache.files=off,use_ino,func.getattr=newest,category.create=mfs,moveonenospc=true,minfreespace=300G,allow_other"

HEAD_NODE="head"                         # always offered, even if sinfo omits it
CONSOLIDATE_DIR="$HOME/consolidated"     # destination suggested by the rsync command
SSH_TIMEOUT=5                            # ssh ConnectTimeout, seconds
OP_TIMEOUT=5                             # timeout for remote filesystem probes, seconds
MAX_JOBS="$DEFAULT_JOBS"                 # current node parallelism (see --jobs / DEFAULT_JOBS)

# Stray data under an unmounted mount point lands on the (quota'd) home
# filesystem instead of the union. Above this many bytes it is an error, not a
# warning.
STRAY_FAIL_BYTES=$((1024 * 1024 * 1024))

# Slow probes, off by default. Also settable with --counts / --sizes.
SHOW_FILE_COUNTS="${SHOW_FILE_COUNTS:-false}"
SHOW_DIRECTORY_SIZES="${SHOW_DIRECTORY_SIZES:-false}"

# =============================================================================
# RUNTIME STATE
# =============================================================================

COMMAND=""                # resolved subcommand
SET_ARG=""                # raw --set value
NODE_ARG=""               # raw --node value
ASSUME_YES=false
DRY_RUN=false
CREATE_SOURCES=true
TABLE_MODE=false          # status: one compact row per node instead of a block
USE_COLOR="auto"          # auto|always|never — resolved by setup_colors
COLOR_ON=false            # resolved boolean; also passed down to remote scripts

# ANSI palette. Empty until setup_colors runs and only non-empty when colour is
# actually on, so "${C_RED}x${C_RESET}" collapses to "x" everywhere colour is off.
C_RESET="" C_BOLD="" C_DIM=""
C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""

ALL_NODES=()              # every node we could operate on
CURRENT_NODE=""
SELECTED_SETS=()          # merge set specs chosen for this run
SELECTED_NODES=()

SET_TAG=""                # populated by parse_merge_set
SET_MOUNT=""
SET_SOURCES=()

MIN_FREE_HUMAN=""         # minfreespace as written in MERGERFS_OPTS, e.g. 300G
MIN_FREE_BYTES=0          # same value in bytes, 0 if unset/unparseable

RUN_TMPDIR=""             # per-run scratch for job output
MUX_DIR=""                # ssh ControlPath directory, empty when not multiplexing
MUX_OPTS=()
CHILD_PIDS=()

SUMMARY_ROWS=()           # "level<TAB>code<TAB>tag<TAB>node<TAB>message"
OPS_TOTAL=0
OPS_FAILED=0
OPS_WARNED=0
OPS_UNMOUNTED=0

SHOW_BODY=true            # false in --table mode: suppress the per-node blocks
declare -A CELL=()        # "tag<TAB>node" -> "level<TAB>code", for the status table
declare -A SUMMARY_NODES=() # distinct-fact key -> space-separated node list

readonly TAB=$'\t'
readonly US=$'\x1f'       # unit separator: joins fields in a distinct-fact key

# =============================================================================
# OUTPUT HELPERS
# =============================================================================

# Decide whether colour is on, then fill (or clear) the palette. Based on
# stdout: piping to a file or grep is not a TTY, so output comes out plain and
# stays greppable. Honours the NO_COLOR convention and TERM=dumb.
setup_colors() {
  case "$USE_COLOR" in
    always) COLOR_ON=true ;;
    never)  COLOR_ON=false ;;
    *)      if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]
            then COLOR_ON=true; else COLOR_ON=false; fi ;;
  esac

  if [[ "$COLOR_ON" == true ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
  fi
}

# paint <style> <text...> — wrap text in one semantic style. The whole codebase
# names intent (ok/warn/fail/info/head/bold) and this is the only place that
# maps intent to an ANSI colour.
paint() {
  local style="$1"; shift
  local code=""
  case "$style" in
    ok)   code="$C_GREEN"  ;;
    warn) code="$C_YELLOW" ;;
    fail) code="$C_RED"    ;;
    info) code="$C_DIM"    ;;
    head) code="$C_BOLD$C_CYAN" ;;
    bold) code="$C_BOLD"   ;;
  esac
  printf '%s%s%s' "$code" "$*" "$C_RESET"
}

# Print one styled line — the local mirror of the remote cok/cwarn/cfail helpers.
# cecho <style> <text...>
cecho() { printf '%s\n' "$(paint "$1" "${*:2}")"; }

die()  { cecho fail "❌ $*" >&2; exit 2; }
warn() { cecho warn "⚠️  $*" >&2; }

hr() {
  local char="${1:--}" line="" i
  for ((i = 0; i < RULE_WIDTH; i++)); do line+="$char"; done
  printf '%s\n' "$line"
}

header() {
  local title="$1" char="${2:-═}" rule
  rule="$(hr "$char")"
  printf '%s\n%s\n%s\n' \
    "$(paint head "$rule")" "$(paint head "$title")" "$(paint head "$rule")"
}

pause() {
  [[ -t 0 ]] || return 0
  printf '%s' "${1:-Press Enter to continue...}"
  read -r || true
}

# Ask a yes/no question. End of input counts as "no", never as the default, so
# running unattended without --yes cancels instead of confirming.
confirm() {
  local prompt="$1" default="${2:-y}" reply
  [[ "$ASSUME_YES" == true ]] && return 0

  printf '%s' "$prompt"
  if ! read -r reply; then
    printf '\n'
    warn "no answer available on stdin; treating as \"no\" (pass --yes to skip this prompt)"
    return 1
  fi
  reply="${reply:-$default}"
  [[ "${reply,,}" == y || "${reply,,}" == yes ]]
}

# =============================================================================
# CLEANUP
# =============================================================================

cleanup() {
  local pid
  for pid in "${CHILD_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  mux_shutdown
  [[ -n "$RUN_TMPDIR" && -d "$RUN_TMPDIR" ]] && rm -rf "$RUN_TMPDIR"
  return 0
}

on_interrupt() {
  printf '\n'
  warn "interrupted — stopping remaining work"
  exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# =============================================================================
# CONFIGURATION LOADING AND VALIDATION
# =============================================================================

load_config() {
  local config="${CLUSTER_MERGERFS_CONFIG:-$HOME/.config/cluster_mergerfs.conf}"
  [[ -r "$config" ]] || return 0
  # shellcheck source=/dev/null
  source "$config" || die "failed to load config: $config"
}

# Split "tag:mount:src1:src2:..." into SET_TAG / SET_MOUNT / SET_SOURCES.
# Returns 1 if the spec does not have a tag, a mount point and >=1 source.
parse_merge_set() {
  local spec="$1" rest
  SET_TAG=""; SET_MOUNT=""; SET_SOURCES=()

  [[ "$spec" == *:*:* ]] || return 1
  SET_TAG="${spec%%:*}"
  rest="${spec#*:}"
  SET_MOUNT="${rest%%:*}"
  IFS=':' read -r -a SET_SOURCES <<< "${rest#*:}"

  [[ -n "$SET_TAG" && -n "$SET_MOUNT" && ${#SET_SOURCES[@]} -gt 0 ]]
}

# Echo the full merge-set spec for a tag, or return 1 if there is no such tag.
# Unlike a parse_merge_set scan, this does not clobber the SET_* globals.
spec_for_tag() {
  local tag="$1" spec
  for spec in "${MERGE_SETS[@]}"; do
    [[ "${spec%%:*}" == "$tag" ]] && { printf '%s' "$spec"; return 0; }
  done
  return 1
}

# Fail with <message> unless <value> is a whole number >= <min>.
require_uint() {
  local value="$1" min="$2" message="$3"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min )) || die "$message"
}

validate_config() {
  local spec src seen_tags=" "

  (( ${#MERGE_SETS[@]} > 0 )) || die "no merge sets configured"

  for spec in "${MERGE_SETS[@]}"; do
    parse_merge_set "$spec" \
      || die "malformed merge set (need tag:mount:source[:source...]): $spec"

    [[ "$seen_tags" == *" $SET_TAG "* ]] && die "duplicate merge set tag: $SET_TAG"
    seen_tags+="$SET_TAG "

    for src in "${SET_SOURCES[@]}"; do
      [[ "$src" != "$SET_MOUNT" ]] \
        || die "merge set '$SET_TAG' lists its own mount point as a source: $src"
    done
  done

  require_uint "$SSH_TIMEOUT" 0 "--ssh-timeout must be a whole number of seconds"
  require_uint "$OP_TIMEOUT"  0 "--op-timeout must be a whole number of seconds"
  require_uint "$MAX_JOBS"    1 "--jobs must be a positive whole number"
  [[ "$USE_COLOR" =~ ^(auto|always|never)$ ]] || die "--color must be auto, always or never"
}

# mergerfs excludes a branch from new file creation once it drops below
# minfreespace, so pull the threshold out of the options to warn about it.
parse_min_free_space() {
  MIN_FREE_HUMAN="$(grep -oE 'minfreespace=[^,]+' <<< "$MERGERFS_OPTS" | cut -d= -f2)" || MIN_FREE_HUMAN=""
  if [[ -n "$MIN_FREE_HUMAN" ]]; then
    MIN_FREE_BYTES="$(numfmt --from=iec "$MIN_FREE_HUMAN" 2>/dev/null)" || MIN_FREE_BYTES=0
  else
    MIN_FREE_BYTES=0
  fi
}

# =============================================================================
# NODE DISCOVERY
# =============================================================================

discover_nodes() {
  local expanded=""

  # sinfo prints compressed ranges (node[01-04]) per partition; scontrol expands
  # them. A node in several partitions shows up more than once, so de-duplicate.
  expanded="$(sinfo -h -o '%N' 2>/dev/null \
      | tr ',' '\n' \
      | xargs -r -I{} scontrol show hostnames {} 2>/dev/null)" || expanded=""

  [[ -n "$expanded" ]] || warn "could not get the node list from sinfo; only $HEAD_NODE is available"

  mapfile -t ALL_NODES < <(printf '%s\n%s\n' "$HEAD_NODE" "$expanded" | awk 'NF && !seen[$0]++')
  CURRENT_NODE="$(hostname -s)"
}

# =============================================================================
# REMOTE EXECUTION
#
# Remote scripts are shipped over stdin as literal text and their parameters are
# passed as positional arguments. Nothing is interpolated into the script body,
# which keeps paths with odd characters from breaking (or rewriting) it.
#
# Remote stdout is the human-readable report. Remote stderr carries tagged
# events (see emit() in the prelude) that feed the end-of-run summary.
# =============================================================================

# POSIX-safe single-quoting for a value passed through the remote login shell.
shquote() {
  local s="${1//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# Reuse one SSH connection per node across merge sets. Worth ~1.2s per extra
# connection, so only set up when more than one set is in play.
mux_start() {
  (( ${#SELECTED_SETS[@]} > 1 )) || return 0
  # The ControlPath must fit in a sockaddr_un (108 bytes), so keep it in
  # MUX_SOCKET_DIR rather than under a possibly-deep $TMPDIR. %C is a short hash.
  MUX_DIR="$(mktemp -d "$MUX_SOCKET_DIR/cmfs.XXXXXX" 2>/dev/null)" || { MUX_DIR=""; return 0; }
  MUX_OPTS=(-o ControlMaster=auto -o "ControlPath=$MUX_DIR/%C" -o ControlPersist="$MUX_PERSIST")
}

mux_shutdown() {
  [[ -n "$MUX_DIR" ]] || return 0
  local node
  for node in "${SELECTED_NODES[@]}"; do
    ssh "${MUX_OPTS[@]}" -O exit "$node" 2>/dev/null || true
  done
  rm -rf "$MUX_DIR"
  MUX_DIR=""
  MUX_OPTS=()
}

# run_remote <node> <script> [args...]
run_remote() {
  local node="$1" script="$2"
  shift 2

  local cmd="bash -s --" arg
  for arg in "$@"; do
    cmd+=" $(shquote "$arg")"
  done

  local opts=(-o ConnectTimeout="$SSH_TIMEOUT")
  (( ${#MUX_OPTS[@]} > 0 )) && opts+=("${MUX_OPTS[@]}")
  # Parallel jobs have their output redirected to files, so an interactive ssh
  # prompt (host key, passphrase) would be invisible and would hang well past
  # ConnectTimeout. BatchMode turns that into a fast, visible error instead.
  (( MAX_JOBS > 1 )) && opts+=(-o BatchMode=yes)

  # The colour decision is made locally (from the local stdout TTY) and shipped
  # down as the first line, since the remote side cannot see our terminal. The
  # tagged EVENT lines stay uncoloured regardless, so the summary parser is safe.
  ssh "${opts[@]}" "$node" "$cmd" <<< "_CMFS_COLOR=$COLOR_ON
$script"
}

# Prepended to every remote script.
#
# is_mounted/mountinfo_field read /proc/self/mountinfo instead of calling
# mountpoint(1) or findmnt(1). Both of those stat() the mount path, which blocks
# indefinitely on a wedged FUSE mount — precisely the case the kill command has
# to handle. Reading mountinfo never touches the filesystem.
remote_prelude() {
  cat <<'PRELUDE'
emit() { printf 'EVENT\t%s\t%s\t%s\n' "$1" "$2" "$3" >&2; }

# Colour helpers, mirrored from the local side. _CMFS_COLOR is set as the first
# line the local caller ships, so the remote output matches the local terminal.
if [[ "${_CMFS_COLOR:-false}" == true ]]; then
  _R=$'\e[0m'; _B=$'\e[1m'; _D=$'\e[2m'; _RED=$'\e[31m'; _GRN=$'\e[32m'; _YLW=$'\e[33m'
else
  _R=''; _B=''; _D=''; _RED=''; _GRN=''; _YLW=''
fi
cok()   { printf '%s%s%s' "$_GRN" "$*" "$_R"; }
cwarn() { printf '%s%s%s' "$_YLW" "$*" "$_R"; }
cfail() { printf '%s%s%s' "$_RED" "$*" "$_R"; }
cdim()  { printf '%s%s%s' "$_D"   "$*" "$_R"; }

# Indent piped input under a detail line (matches the 5-space report body).
indent() { sed 's/^/     /'; }

is_mounted() {
  awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo
}

# Field layout: ... mountpoint(5) opts(6) [optional fields] - fstype source superopts
mountinfo_field() {
  awk -v p="$1" -v off="$2" '
    $5 == p {
      for (i = 7; i <= NF; i++)
        if ($i == "-") { print $(i + off); exit }
    }' /proc/self/mountinfo
}
mount_fstype() { mountinfo_field "$1" 1; }

# The mergerfs process owning a mount point, matched on the last cmdline
# argument so a path that appears as a *branch* elsewhere does not collide.
# Sets MFS_PID / MFS_BRANCHES / MFS_OPTS. Reads /proc only, so it never blocks.
find_mergerfs_process() {
  local mount_point="$1" pid line argv n
  MFS_PID=""; MFS_BRANCHES=""; MFS_OPTS=""

  for pid in $(pgrep -u "$(id -u)" -x mergerfs 2>/dev/null || true); do
    argv=()
    while IFS= read -r line; do argv+=("$line"); done \
      < <(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null)
    n=${#argv[@]}
    (( n >= 3 )) || continue
    if [[ "${argv[n-1]}" == "$mount_point" ]]; then
      MFS_PID="$pid"
      MFS_BRANCHES="${argv[n-2]}"
      MFS_OPTS="${argv[n-3]}"
      return 0
    fi
  done
  return 1
}

# Classify the mount point without ever hanging. Sets MOUNT_STATE to one of:
#   unmounted | ok | hung | dead | foreign | error
# and MOUNT_DETAIL to a human-readable note.
probe_mount() {
  local mount_point="$1" op_timeout="$2" fstype out rc
  MOUNT_STATE=""; MOUNT_DETAIL=""; MOUNT_DF=""

  if ! is_mounted "$mount_point"; then
    MOUNT_STATE="unmounted"
    return
  fi

  fstype=$(mount_fstype "$mount_point")
  if [[ "$fstype" != fuse.mergerfs ]]; then
    MOUNT_STATE="foreign"
    MOUNT_DETAIL="$fstype"
    return
  fi

  # statfs goes through FUSE: it times out on a wedged mount and returns
  # ENOTCONN immediately when the mergerfs process has died.
  out=$(timeout "$op_timeout" df -hP "$mount_point" 2>&1); rc=$?
  if (( rc == 124 )); then
    MOUNT_STATE="hung"
  elif [[ "$out" == *"Transport endpoint is not connected"* ]]; then
    MOUNT_STATE="dead"
  elif (( rc != 0 )); then
    MOUNT_STATE="error"
    MOUNT_DETAIL="$out"
  else
    MOUNT_STATE="ok"
    MOUNT_DF="$out"
  fi
}

# Size of whatever sits under an unmounted mount point. Sets STRAY_COUNT and
# STRAY_BYTES (-1 when du timed out, i.e. there is a lot of it).
probe_stray_data() {
  local mount_point="$1" op_timeout="$2" out
  STRAY_COUNT=0; STRAY_BYTES=0

  [[ -d "$mount_point" ]] || return 0
  STRAY_COUNT=$(timeout "$op_timeout" find "$mount_point" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
  (( STRAY_COUNT > 0 )) || return 0

  if out=$(timeout "$op_timeout" du -sb "$mount_point" 2>/dev/null); then
    STRAY_BYTES=${out%%[!0-9]*}
    : "${STRAY_BYTES:=0}"
  else
    STRAY_BYTES=-1
  fi
}

human_bytes() {
  if [[ "$1" == "-1" ]]; then printf 'a lot (du timed out)'
  else numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"
  fi
}

# Probe a source directory, retrying once on timeout. A busy NFS mount can blow
# through the probe timeout transiently, and calling that "inaccessible" is a
# lie that also aborts mounts it should not. Sets PROBE_STATUS to
# ok | timeout | missing.
probe_dir() {
  local dir="$1" op_timeout="$2" rc

  if timeout "$op_timeout" ls -d "$dir" >/dev/null 2>&1; then
    PROBE_STATUS=ok; return 0
  fi
  rc=$?

  if (( rc == 124 )); then
    sleep 1
    if timeout "$op_timeout" ls -d "$dir" >/dev/null 2>&1; then
      PROBE_STATUS=ok; return 0
    fi
    (( $? == 124 )) && { PROBE_STATUS=timeout; return 1; }
  fi

  PROBE_STATUS=missing
  return 1
}

# Print and emit a failed source probe. Call after probe_dir returns non-zero.
# $1 = dir, $2 = leading indent. Reads PROBE_STATUS and the script-global op_timeout.
report_bad_source() {
  if [[ "$PROBE_STATUS" == timeout ]]; then
    echo "$2$(cfail "❌ $1 (no response within ${op_timeout}s, twice)")"
    emit fail source "source did not respond within ${op_timeout}s: $1"
  else
    echo "$2$(cfail "❌ $1 (missing or inaccessible)")"
    emit fail source "source missing or inaccessible: $1"
  fi
}
PRELUDE
}

remote_script_mount() {
  cat <<'SCRIPT'
mount_point="$1"; opts="$2"; op_timeout="$3"; create_sources="$4"; shift 4
sources=("$@")
status=0

echo "  Sources:"
for dir in "${sources[@]}"; do
  if probe_dir "$dir" "$op_timeout"; then
    echo "    $(cok "✅ $dir")"
  elif [[ "$PROBE_STATUS" == missing ]] && [[ "$create_sources" == true ]] \
       && timeout "$op_timeout" mkdir -p "$dir" 2>/dev/null; then
    echo "    $(cok "✅ $dir (created)")"
  else
    report_bad_source "$dir" "    "
    status=1
  fi
done

if (( status != 0 )); then
  echo "  $(cfail "❌ Not mounting: one or more source directories are unusable")"
  emit fail mount-failed "not mounted: source directories unusable"
  exit 1
fi

mkdir -p "$mount_point" 2>/dev/null || true

if is_mounted "$mount_point"; then
  echo "  $(cdim "↻ Replacing existing mount at $mount_point")"
  fusermount -uz "$mount_point" 2>/dev/null || true
else
  # Only meaningful when nothing is mounted: these files sit on local storage
  # and will be hidden (but keep consuming quota) once the union is mounted.
  probe_stray_data "$mount_point" "$op_timeout"
  if (( STRAY_COUNT > 0 )); then
    echo "  $(cwarn "⚠️  Mount point holds $STRAY_COUNT item(s), $(human_bytes "$STRAY_BYTES") — hidden once mounted")"
    emit warn stray "$STRAY_COUNT item(s), $(human_bytes "$STRAY_BYTES") on local storage under the mount point"
  fi
fi

branches=$(IFS=:; printf '%s' "${sources[*]}")
echo "  → mergerfs -o $opts $branches $mount_point"

output=$(mergerfs -o "$opts" "$branches" "$mount_point" 2>&1)
rc=$?

if is_mounted "$mount_point"; then
  echo "  $(cok "✅ Mounted $mount_point")"
  exit 0
fi

echo "  $(cfail "❌ Failed to mount $mount_point (mergerfs exit $rc)")"
[[ -n "$output" ]] && printf '%s\n' "$output" | indent
emit fail mount-failed "mergerfs exited $rc: ${output:-no output}"
exit 1
SCRIPT
}

remote_script_status() {
  cat <<'SCRIPT'
mount_point="$1"; op_timeout="$2"; show_counts="$3"; show_sizes="$4"
min_free_bytes="$5"; min_free_human="$6"; want_branches="$7"; want_opts="$8"
stray_fail_bytes="$9"; shift 9
sources=("$@")

probe_mount "$mount_point" "$op_timeout"

case "$MOUNT_STATE" in
  ok)
    echo "  $(cok "✅ MOUNTED  $mount_point")"
    echo
    echo "  💾 Merged view:"
    printf '%s\n' "$MOUNT_DF" | indent
    if [[ "$show_counts" == true ]]; then
      files=$(timeout "$op_timeout" find "$mount_point" -type f 2>/dev/null | wc -l)
      dirs=$(timeout "$op_timeout"  find "$mount_point" -type d 2>/dev/null | wc -l)
      echo "     files: $files   directories: $dirs"
    fi
    # Compare what is actually running against what the config asks for. The
    # mountinfo fsname is abbreviated by mergerfs, so read the real argv.
    if find_mergerfs_process "$mount_point"; then
      if [[ "$MFS_BRANCHES" != "$want_branches" ]]; then
        echo "  $(cwarn "⚠️  Branch drift — running with a different branch list than configured")"
        echo "     running:    $MFS_BRANCHES"
        echo "     configured: $want_branches"
        emit warn drift "branch list differs from config (remount to apply)"
      fi
      if [[ "$MFS_OPTS" != "$want_opts" ]]; then
        echo "  $(cwarn "⚠️  Option drift — running with different mergerfs options than configured")"
        echo "     running:    $MFS_OPTS"
        echo "     configured: $want_opts"
        emit warn drift "mergerfs options differ from config (remount to apply)"
      fi
    fi
    ;;
  hung)
    echo "  $(cfail "❌ WEDGED  $mount_point")"
    echo "     The mount entry exists but the filesystem does not respond."
    echo "     Fix with the kill command on this node."
    emit fail hung "mount is wedged (probe timed out) — run the kill command"
    ;;
  dead)
    echo "  $(cfail "❌ STALE  $mount_point")"
    echo "     Transport endpoint is not connected: the mergerfs process is gone"
    echo "     but the mount entry remains. Fix with the kill command."
    emit fail dead "stale mount entry, mergerfs process gone — run the kill command"
    ;;
  foreign)
    echo "  $(cfail "❌ UNEXPECTED FILESYSTEM  $mount_point")"
    echo "     Something is mounted here, but it is $MOUNT_DETAIL, not fuse.mergerfs."
    emit fail foreign "unexpected filesystem mounted at the mount point: $MOUNT_DETAIL"
    ;;
  error)
    echo "  $(cfail "❌ ERROR  $mount_point")"
    printf '%s\n' "$MOUNT_DETAIL" | indent
    emit fail error "could not probe the mount: $MOUNT_DETAIL"
    ;;
  unmounted)
    echo "  $(cdim "⭘ NOT MOUNTED  $mount_point")"
    probe_stray_data "$mount_point" "$op_timeout"
    if (( STRAY_COUNT > 0 )); then
      echo "     $(cwarn "⚠️  $STRAY_COUNT item(s), $(human_bytes "$STRAY_BYTES") sitting on local storage here.")"
      echo "        Writes meant for the union are landing on this filesystem instead."
      if [[ "$STRAY_BYTES" == "-1" ]] || (( STRAY_BYTES > stray_fail_bytes )); then
        emit fail stray "not mounted; $STRAY_COUNT item(s), $(human_bytes "$STRAY_BYTES") written to local storage instead of the union"
      else
        emit warn stray "not mounted; $STRAY_COUNT item(s), $(human_bytes "$STRAY_BYTES") on local storage under the mount point"
      fi
    elif [[ -d "$mount_point" ]]; then
      echo "     $(cdim "ℹ️  directory exists and is empty")"
      emit info not-mounted "not mounted (mount point clean)"
    else
      echo "     $(cdim "ℹ️  directory does not exist")"
      emit info not-mounted "not mounted (no directory)"
    fi
    ;;
esac

echo
echo "  📁 Sources (${#sources[@]}):"
for dir in "${sources[@]}"; do
  if ! probe_dir "$dir" "$op_timeout"; then
    report_bad_source "$dir" "     "
    continue
  fi
  echo "     $(cok "✅ $dir")"

  usage=$(timeout "$op_timeout" df -hP "$dir" 2>/dev/null \
            | awk 'NR == 2 { printf "%s free / %s total (%s used)", $4, $2, $5 }')
  [[ -n "$usage" ]] && echo "        $usage"

  avail=$(timeout "$op_timeout" df -P -B1 "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }')
  if [[ -n "$avail" ]] && (( min_free_bytes > 0 && avail < min_free_bytes )); then
    echo "        $(cwarn "⚠️  below minfreespace=$min_free_human — excluded from new file creation")"
    emit warn lowspace "$dir is below minfreespace=$min_free_human — excluded from new writes"
  fi

  if [[ "$show_sizes" == true ]]; then
    echo "        size: $(du -sh "$dir" 2>/dev/null | cut -f1)"
  fi
  if [[ "$show_counts" == true ]]; then
    echo "        files: $(find "$dir" -type f 2>/dev/null | wc -l)"
  fi
done
SCRIPT
}

remote_script_unmount() {
  cat <<'SCRIPT'
mount_point="$1"

if ! is_mounted "$mount_point"; then
  echo "  $(cdim "ℹ️  $mount_point is not mounted")"
  emit info not-mounted "already unmounted"
  exit 0
fi

if output=$(fusermount -uz "$mount_point" 2>&1); then
  echo "  $(cok "✅ Unmounted $mount_point")"
else
  echo "  $(cfail "❌ Failed to unmount $mount_point")"
  [[ -n "$output" ]] && printf '%s\n' "$output" | indent
  echo "     The mount may be wedged; try the kill command."
  emit fail still-mounted "unmount failed: ${output:-no output}"
  exit 1
fi
SCRIPT
}

remote_script_kill() {
  cat <<'SCRIPT'
mount_point="$1"
rc=0
did_something=false

if is_mounted "$mount_point"; then
  echo "  Mount entry present: $mount_point [$(mount_fstype "$mount_point")]"
else
  echo "  $(cdim "ℹ️  No mount entry for $mount_point")"
fi

if find_mergerfs_process "$mount_point"; then
  echo "  Killing PID $MFS_PID (branches: $MFS_BRANCHES)"
  if kill -9 "$MFS_PID" 2>/dev/null; then
    echo "     $(cok "✅ killed")"
    did_something=true
  else
    echo "     $(cfail "❌ could not kill")"
    emit fail kill "could not kill mergerfs PID $MFS_PID"
    rc=1
  fi
  sleep 1
else
  echo "  $(cwarn "⚠️  No mergerfs process owns this mount point (already dead?)")"
fi

# A killed process usually leaves the mount entry behind; clear it either way.
if is_mounted "$mount_point"; then
  if fusermount -uz "$mount_point" 2>/dev/null; then
    echo "  $(cok "✅ Mount entry cleared (fusermount -uz)")"
    did_something=true
  elif umount -l "$mount_point" 2>/dev/null; then
    echo "  $(cok "✅ Mount entry cleared (umount -l)")"
    did_something=true
  else
    echo "  $(cfail "❌ Mount entry still present — needs root or manual cleanup")"
    emit fail still-mounted "mount entry could not be cleared; needs root or manual cleanup"
    rc=1
  fi
else
  echo "  $(cok "✅ No mount entry left behind")"
fi

[[ "$did_something" == false ]] && emit info clean "nothing to clean up"
exit $rc
SCRIPT
}

# =============================================================================
# OPERATIONS
# =============================================================================

# run_on_node <action> <node>; expects SET_* to be populated.
run_on_node() {
  local action="$1" node="$2"
  local branches
  branches="$(IFS=:; printf '%s' "${SET_SOURCES[*]}")"

  case "$action" in
    mount)
      run_remote "$node" "$(remote_prelude; remote_script_mount)" \
        "$SET_MOUNT" "$MERGERFS_OPTS" "$OP_TIMEOUT" "$CREATE_SOURCES" "${SET_SOURCES[@]}"
      ;;
    status)
      run_remote "$node" "$(remote_prelude; remote_script_status)" \
        "$SET_MOUNT" "$OP_TIMEOUT" "$SHOW_FILE_COUNTS" "$SHOW_DIRECTORY_SIZES" \
        "$MIN_FREE_BYTES" "${MIN_FREE_HUMAN:-none}" "$branches" "$MERGERFS_OPTS" \
        "$STRAY_FAIL_BYTES" "${SET_SOURCES[@]}"
      ;;
    unmount)
      run_remote "$node" "$(remote_prelude; remote_script_unmount)" "$SET_MOUNT"
      ;;
    kill)
      run_remote "$node" "$(remote_prelude; remote_script_kill)" "$SET_MOUNT"
      ;;
    *)
      die "internal error: unknown action '$action'"
      ;;
  esac
}

# Fold one operation's exit status and event stream into the summary.
collect_result() {
  local tag="$1" node="$2" rc="$3" errfile="$4"
  local line level code msg
  local had_fail=false had_warn=false had_unmounted=false
  local worst_rank=0 worst_code="" rank   # track the most severe event for the table cell

  (( ++OPS_TOTAL ))

  if [[ -s "$errfile" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if [[ "$line" == "EVENT$TAB"* ]]; then
        IFS="$TAB" read -r _ level code msg <<< "$line"
        rank=0
        case "$level" in
          fail) had_fail=true; rank=3 ;;
          warn) had_warn=true; rank=2 ;;
          info) [[ "$code" == not-mounted ]] && had_unmounted=true; continue ;;
        esac
        (( rank > worst_rank )) && { worst_rank=$rank; worst_code="$code"; }
        SUMMARY_ROWS+=("$level$TAB$code$TAB$tag$TAB$node$TAB$msg")
      else
        # Anything else on stderr is a genuine problem (ssh failure, etc.).
        # Show it inline with the node's block; in --table mode the block is
        # hidden, so rely on the table cell and the summary to carry it.
        [[ "$SHOW_BODY" == true ]] && printf '  %s\n' "$(paint fail "❌ $line")"
        SUMMARY_ROWS+=("fail${TAB}ssh$TAB$tag$TAB$node$TAB$line")
        had_fail=true
        (( worst_rank < 3 )) && { worst_rank=3; worst_code="ssh"; }
      fi
    done < "$errfile"
  fi

  # A non-zero exit that produced no event still has to be visible.
  if (( rc != 0 )) && [[ "$had_fail" == false ]]; then
    SUMMARY_ROWS+=("fail${TAB}exit$TAB$tag$TAB$node${TAB}operation exited with status $rc")
    had_fail=true
    (( worst_rank < 3 )) && { worst_rank=3; worst_code="exit"; }
  fi

  # Record this (set, node) cell's worst state for the status table.
  local cell_level cell_code
  if [[ "$had_fail" == true ]]; then
    cell_level=fail; cell_code="${worst_code:-fail}"; (( ++OPS_FAILED ))
  elif [[ "$had_warn" == true ]]; then
    cell_level=warn; cell_code="${worst_code:-warn}"; (( ++OPS_WARNED ))
  elif [[ "$had_unmounted" == true ]]; then
    cell_level=info; cell_code="not-mounted"; (( ++OPS_UNMOUNTED ))
  else
    cell_level=ok; cell_code="ok"
  fi
  CELL["$tag$TAB$node"]="$cell_level$TAB$cell_code"
  return 0
}

# Run <action> over SELECTED_SETS x SELECTED_NODES.
execute() {
  local action="$1" rc=0

  if [[ "$DRY_RUN" == true ]]; then
    execute_dry_run "$action"
    return 0
  fi

  # The table replaces the per-node blocks, but only for status; for other
  # actions the detail is the point, so --table is ignored (with a note).
  SHOW_BODY=true
  if [[ "$TABLE_MODE" == true ]]; then
    if [[ "$action" == status ]]; then
      SHOW_BODY=false
    else
      warn "--table only applies to status; showing the normal output"
    fi
  fi

  RUN_TMPDIR="$(mktemp -d)" || die "could not create a temporary directory"
  mux_start

  if (( MAX_JOBS == 1 )); then
    execute_serial "$action"
  else
    execute_parallel "$action"
  fi

  mux_shutdown
  [[ "$SHOW_BODY" == false ]] && render_table
  render_summary "$action" || rc=1

  # Release this run's scratch now rather than leaking one dir per menu action;
  # the EXIT trap still covers the case where we die partway through.
  rm -rf "$RUN_TMPDIR"
  RUN_TMPDIR=""
  return "$rc"
}

# Per-merge-set banner. Expects SET_TAG/SET_MOUNT (set by parse_merge_set), so
# the "[tag] mount" format lives in exactly one place.
set_header() {
  echo
  header "[$SET_TAG] $SET_MOUNT"
}

# Per-node banner: a blank line then the highlighted hostname.
node_header() {
  printf '\n%s\n' "$(paint head "🖥️  $1")"
}

execute_dry_run() {
  local action="$1" spec node
  for spec in "${SELECTED_SETS[@]}"; do
    parse_merge_set "$spec"
    set_header
    for node in "${SELECTED_NODES[@]}"; do
      node_header "$node"
      printf '  (dry run) would %s %s\n' "$action" "$SET_MOUNT"
    done
  done
  render_summary "$action"
}

# Serial: run inline so output streams live as it arrives.
execute_serial() {
  local action="$1" spec node rc

  for spec in "${SELECTED_SETS[@]}"; do
    parse_merge_set "$spec"
    [[ "$SHOW_BODY" == true ]] && set_header

    for node in "${SELECTED_NODES[@]}"; do
      [[ "$SHOW_BODY" == true ]] && node_header "$node"
      set +e
      if [[ "$SHOW_BODY" == true ]]; then
        run_on_node "$action" "$node" 2> "$RUN_TMPDIR/err"
      else
        run_on_node "$action" "$node" >/dev/null 2> "$RUN_TMPDIR/err"
      fi
      rc=$?
      set -e
      collect_result "$SET_TAG" "$node" "$rc" "$RUN_TMPDIR/err"
    done
  done
}

# Parallel: one background job per node, each working through every selected set
# in sequence.
#
# Node-major rather than set-major on purpose. Fanning out per set would have
# every node's connection opened at the same moment, and with connection
# multiplexing enabled that means N masters being negotiated concurrently —
# measurably slower and far more erratic than running serially. Giving each node
# one job means it opens a single master and reuses it for the remaining sets,
# so multiplexing and parallelism add up instead of fighting.
#
# Output is still replayed set-major, so the report reads the same at any -j.
execute_parallel() {
  local action="$1" idx i node rc
  local pids=() launched=0 waited=0
  local total=${#SELECTED_NODES[@]}

  CHILD_PIDS=()   # drop finished PIDs from any previous menu action

  for idx in "${!SELECTED_NODES[@]}"; do
    run_node_job "$action" "${SELECTED_NODES[idx]}" "$idx" &
    pids[idx]=$!
    CHILD_PIDS+=("$!")
    (( ++launched ))

    while (( launched - waited >= MAX_JOBS )); do
      wait "${pids[waited]}" 2>/dev/null || true
      (( ++waited ))
      show_progress "$waited" "$total"
    done
  done

  while (( waited < launched )); do
    wait "${pids[waited]}" 2>/dev/null || true
    (( ++waited ))
    show_progress "$waited" "$total"
  done
  clear_progress

  for i in "${!SELECTED_SETS[@]}"; do
    parse_merge_set "${SELECTED_SETS[i]}"
    [[ "$SHOW_BODY" == true ]] && set_header

    for idx in "${!SELECTED_NODES[@]}"; do
      node="${SELECTED_NODES[idx]}"
      if [[ "$SHOW_BODY" == true ]]; then
        node_header "$node"
        [[ -s "$RUN_TMPDIR/$idx.$i.out" ]] && cat "$RUN_TMPDIR/$idx.$i.out"
      fi
      rc="$(cat "$RUN_TMPDIR/$idx.$i.rc" 2>/dev/null)" || rc=1
      collect_result "$SET_TAG" "$node" "${rc:-1}" "$RUN_TMPDIR/$idx.$i.err"
    done
  done
}

# One node, every selected set, in order. Runs as a background job.
run_node_job() {
  local action="$1" node="$2" idx="$3" i

  for i in "${!SELECTED_SETS[@]}"; do
    parse_merge_set "${SELECTED_SETS[i]}"
    set +e
    run_on_node "$action" "$node" \
      > "$RUN_TMPDIR/$idx.$i.out" 2> "$RUN_TMPDIR/$idx.$i.err"
    echo $? > "$RUN_TMPDIR/$idx.$i.rc"
    set -e
  done
}

# Progress goes to stderr so redirecting stdout still yields a clean report.
show_progress() {
  [[ -t 2 ]] || return 0
  printf '\r  … %d/%d nodes done' "$1" "$2" >&2
}

clear_progress() {
  [[ -t 2 ]] || return 0
  printf '\r\033[K' >&2
}

# =============================================================================
# STATUS TABLE  (--table)
# =============================================================================

# Short cell label for an event code.
table_label() {
  case "$1" in
    ok)          printf 'ok' ;;
    ssh)         printf 'unreachable' ;;
    not-mounted) printf 'unmounted' ;;
    lowspace)    printf 'low space' ;;
    hung)        printf 'WEDGED' ;;
    dead)        printf 'STALE' ;;
    foreign)     printf 'foreign fs' ;;
    drift)       printf 'drift' ;;
    stray)       printf 'stray data' ;;
    source)      printf 'source down' ;;
    error)       printf 'probe error' ;;
    exit)        printf 'error' ;;
    *)           printf '%s' "$1" ;;
  esac
}

# Emoji for a cell level. The trailing space on the narrower glyphs keeps the
# columns roughly aligned in a monospace terminal (emoji cell width varies).
table_icon() {
  case "$1" in
    ok)   printf '✅' ;;
    warn) printf '⚠️ ' ;;
    fail) printf '❌' ;;
    *)    printf '⭘ ' ;;
  esac
}

# Grid of nodes (rows) x merge sets (columns), one compact coloured cell each,
# read from the CELL map that collect_result populated.
render_table() {
  local i node spec cell level code label
  local tags=() labw=() node_w=4

  for spec in "${SELECTED_SETS[@]}"; do tags+=("${spec%%:*}"); done
  for node in "${SELECTED_NODES[@]}"; do (( ${#node} > node_w )) && node_w=${#node}; done

  # per-column label width = max(tag, widest label in the column)
  for i in "${!tags[@]}"; do
    labw[i]=${#tags[i]}
    for node in "${SELECTED_NODES[@]}"; do
      cell="${CELL["${tags[i]}$TAB$node"]:-}"
      code="${cell##*$TAB}"; [[ -n "$cell" ]] || code="?"
      label="$(table_label "$code")"
      (( ${#label} > labw[i] )) && labw[i]=${#label}
    done
  done

  echo
  header "STATUS TABLE"

  # header row: a 2-space icon placeholder keeps tags above their cell labels
  printf '  %-*s' "$node_w" "NODE"
  for i in "${!tags[@]}"; do printf '  %s %-*s' '  ' "${labw[i]}" "${tags[i]}"; done
  printf '\n'

  for node in "${SELECTED_NODES[@]}"; do
    printf '  %-*s' "$node_w" "$node"
    for i in "${!tags[@]}"; do
      cell="${CELL["${tags[i]}$TAB$node"]:-}"
      level="${cell%%$TAB*}"; code="${cell##*$TAB}"
      [[ -n "$cell" ]] || { level=info; code="?"; }
      printf '  %s %s' \
        "$(paint "$level" "$(table_icon "$level")")" \
        "$(paint "$level" "$(printf '%-*s' "${labw[i]}" "$(table_label "$code")")")"
    done
    printf '\n'
  done
}

# =============================================================================
# SUMMARY
# =============================================================================

# A fact keyed on (level, code, tag, message) but NOT on node. Codes that
# describe a shared source directory rather than a per-node mount collapse to
# "all nodes" when every selected node reports them identically; everything else
# stays per node. Same physical NFS export seen from 25 nodes => one line, not 25.
summary_scope() {
  case "$1" in
    lowspace|source) printf source ;;
    *)               printf node ;;
  esac
}

# Render a fact's node coverage. All selected nodes agreeing -> "all nodes";
# otherwise the node names, spelled out.
summary_coverage() {
  local -a ns=($1)
  local total=${#SELECTED_NODES[@]} out="" n
  if (( ${#ns[@]} >= total && total > 1 )); then
    printf 'all nodes'
    return
  fi
  for n in "${ns[@]}"; do out+="${out:+, }$n"; done
  printf '%s' "$out"
}

# One deduped subgroup (the source or the node half of a severity), or a
# "(none this run)" placeholder so an empty half still reads as checked.
render_summary_subgroup() {
  local style="$1" title="$2"; shift 2
  local keys=("$@") key level code tag msg cov i=0
  local tag_width=0 cov_width=0
  local -a covs=()

  printf '    %s\n' "$(paint bold "$title")"
  if (( ${#keys[@]} == 0 )); then
    printf '      %s\n' "$(paint info "(none this run)")"
    return
  fi

  for key in "${keys[@]}"; do
    IFS="$US" read -r level code tag msg <<< "$key"
    (( ${#tag} > tag_width )) && tag_width=${#tag}
    cov="$(summary_coverage "${SUMMARY_NODES[$key]}")"
    covs[i]="$cov"
    (( ${#cov} > cov_width )) && cov_width=${#cov}
    (( ++i ))
  done
  (( cov_width > SUMMARY_COVERAGE_CAP )) && cov_width=$SUMMARY_COVERAGE_CAP   # keep one long node list from misaligning the rest

  i=0
  for key in "${keys[@]}"; do
    IFS="$US" read -r level code tag msg <<< "$key"
    printf '      %s\n' \
      "$(paint "$style" "$(printf '[%-*s] %-*s  %s' \
         "$tag_width" "$tag" "$cov_width" "${covs[i]}" "$msg")")"
    (( ++i ))
  done
}

# One severity block: a heading plus the source and node subgroups.
render_summary_group() {
  local style="$1" heading="$2"; shift 2
  local keys=("$@") key rest code src_keys=() nod_keys=()

  for key in "${keys[@]}"; do
    rest="${key#*"$US"}"       # strip level -> code<US>tag<US>msg
    code="${rest%%"$US"*}"     # keep the code
    if [[ "$(summary_scope "$code")" == source ]]; then
      src_keys+=("$key")
    else
      nod_keys+=("$key")
    fi
  done

  printf '\n  %s\n' "$(paint "$style" "$heading")"
  render_summary_subgroup "$style" "Source issues (node-independent)" "${src_keys[@]}"
  render_summary_subgroup "$style" "Node issues"                       "${nod_keys[@]}"
}

render_summary() {
  local action="$1" row level code tag node msg key
  local total_fail=0 total_warn=0
  local order=() fail_keys=() warn_keys=() ok

  if [[ "$DRY_RUN" == true ]]; then
    echo
    cecho ok "✅ Dry run complete — nothing was changed"
    return 0
  fi

  # Fold the raw rows into distinct facts, remembering which nodes hit each and
  # the order they first appeared (which is selection order).
  SUMMARY_NODES=()
  for row in "${SUMMARY_ROWS[@]}"; do
    IFS="$TAB" read -r level code tag node msg <<< "$row"
    [[ "$level" == fail ]] && (( ++total_fail ))
    [[ "$level" == warn ]] && (( ++total_warn ))
    key="$level$US$code$US$tag$US$msg"
    if [[ -z "${SUMMARY_NODES[$key]+x}" ]]; then
      order+=("$key")
      SUMMARY_NODES[$key]="$node"
    elif [[ " ${SUMMARY_NODES[$key]} " != *" $node "* ]]; then
      SUMMARY_NODES[$key]+=" $node"
    fi
  done

  for key in "${order[@]}"; do
    case "$key" in
      fail"$US"*) fail_keys+=("$key") ;;
      warn"$US"*) warn_keys+=("$key") ;;
    esac
  done

  ok=$(( OPS_TOTAL - OPS_FAILED - OPS_WARNED - OPS_UNMOUNTED ))

  echo
  header "SUMMARY — $action"
  printf '  %d operation(s): %s' "$OPS_TOTAL" "$(paint ok "$ok ok")"
  (( OPS_UNMOUNTED > 0 )) && printf ', %s' "$(paint info "$OPS_UNMOUNTED not mounted")"
  (( OPS_WARNED    > 0 )) && printf ', %s' "$(paint warn "$OPS_WARNED with warnings")"
  (( OPS_FAILED    > 0 )) && printf ', %s' "$(paint fail "$OPS_FAILED failed")"
  printf '\n'

  local nnodes=${#SELECTED_NODES[@]}
  if (( ${#fail_keys[@]} > 0 )); then
    render_summary_group fail \
      "$(printf '❌ FAILED — %d distinct (%d total · %d node(s))' \
         "${#fail_keys[@]}" "$total_fail" "$nnodes")" "${fail_keys[@]}"
  fi
  if (( ${#warn_keys[@]} > 0 )); then
    render_summary_group warn \
      "$(printf '⚠️  WARNINGS — %d distinct (%d total · %d node(s))' \
         "${#warn_keys[@]}" "$total_warn" "$nnodes")" "${warn_keys[@]}"
  fi

  echo
  if (( OPS_FAILED > 0 )); then
    cecho fail "❌ Completed with failures"
    return 1
  fi
  cecho ok "✅ Completed"
  return 0
}

# =============================================================================
# PREVIEW AND CONFIRMATION
# =============================================================================

action_description() {
  case "$1" in
    mount)
      echo "  • Create any missing source directories (unless --no-create)"
      echo "  • Replace stale mounts, then mount the union"
      echo "  ⚠️  Existing files under the mount point are hidden while mounted"
      ;;
    status)
      echo "  • Classify each mount: healthy, wedged, stale, foreign or unmounted"
      echo "  • Flag stray data written under an unmounted mount point"
      echo "  • Flag branch/option drift against this config"
      echo "  • Report per-source usage and minfreespace warnings"
      ;;
    unmount)
      echo "  ⚠️  Unmount the union — merged data is inaccessible until remounted"
      ;;
    kill)
      echo "  ⚠️  SIGKILL the mergerfs process owning the mount point"
      echo "  ⚠️  Force-clear the leftover mount entry"
      ;;
  esac
}

is_destructive() {
  [[ "$1" == mount || "$1" == unmount || "$1" == kill ]]
}

show_preview() {
  local action="$1" spec node

  echo
  header "⚠️  OPERATION PREVIEW"
  echo
  echo "Action: $action"
  [[ "$DRY_RUN" == true ]] && echo "Mode:   DRY RUN (nothing will be changed)"
  (( MAX_JOBS > 1 )) && echo "Jobs:   $MAX_JOBS nodes in parallel"
  echo
  echo "Merge sets (${#SELECTED_SETS[@]}):"
  for spec in "${SELECTED_SETS[@]}"; do
    parse_merge_set "$spec"
    printf '  - %-*s %s (%d sources)\n' "$PREVIEW_TAG_WIDTH" "$SET_TAG" "$SET_MOUNT" "${#SET_SOURCES[@]}"
  done
  echo
  echo "Nodes (${#SELECTED_NODES[@]}):"
  for node in "${SELECTED_NODES[@]}"; do
    echo "  - $node"
  done
  echo
  echo "What will happen:"
  action_description "$action"
  echo
  echo "Total operations: $(( ${#SELECTED_SETS[@]} * ${#SELECTED_NODES[@]} ))"
  hr "═"
}

# Preview, then confirm when the action changes something.
confirm_operation() {
  local action="$1"

  show_preview "$action"
  echo

  if [[ "$DRY_RUN" == true ]] || ! is_destructive "$action"; then
    return 0
  fi

  if [[ "$action" == mount ]]; then
    confirm "$(paint bold 'Proceed? [Y/n]: ')" y
  else
    confirm "$(paint warn "⚠️  Proceed with $action? [y/N]: ")" n
  fi
}

# =============================================================================
# SELECTION PROMPTS
# =============================================================================

# Build a "1) item   2) item …" menu line with the numbers highlighted.
menu_string() {
  local i out=""
  for ((i = 1; i <= $#; i++)); do
    out+="$(paint head "$i)") ${!i}   "
  done
  printf '%s' "$out"
}

# prompt_one <title> <default_item> <outvar> <item>...
prompt_one() {
  local title="$1" default="$2"
  local -n _one_out="$3"
  shift 3
  local items=("$@") i choice default_index=1

  for i in "${!items[@]}"; do
    [[ "${items[i]}" == "$default" ]] && default_index=$((i + 1))
  done

  echo
  cecho bold "$title"
  printf '%s\n' "$(menu_string "${items[@]}")"

  while true; do
    printf '%s %s: ' "$(paint bold 'Enter choice')" "$(paint info "[default: $default_index]")"
    read -r choice || die "no input"
    choice="${choice:-$default_index}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
      _one_out="${items[choice - 1]}"
      return 0
    fi
    cecho fail "❌ Invalid selection. Try again."
  done
}

# prompt_many <title> <default> <outvar> <item>...
# <default> is an item name, the literal "all", or "" for no default.
prompt_many() {
  local title="$1" default="$2"
  local -n _many_out="$3"
  shift 3
  local items=("$@") i input index selected

  # A default that is not on offer (e.g. the current node is not in sinfo) must
  # not silently widen the selection, so drop it and require an explicit choice.
  if [[ -n "$default" && "$default" != all ]]; then
    local found=false
    for i in "${items[@]}"; do [[ "$i" == "$default" ]] && found=true; done
    [[ "$found" == true ]] || default=""
  fi

  echo
  cecho bold "$title"
  printf '%s\n' "$(menu_string "${items[@]}")"

  while true; do
    if [[ -n "$default" ]]; then
      printf '%s %s: ' "$(paint bold "Enter choices (space-separated) or 'all'")" \
                       "$(paint info "[default: $default]")"
    else
      printf '%s: ' "$(paint bold "Enter choices (space-separated) or 'all'")"
    fi
    read -r input || die "no input"

    if [[ -z "$input" ]]; then
      [[ -n "$default" ]] || { cecho fail "❌ A selection is required."; continue; }
      input="$default"
    fi

    if [[ "$input" == all ]]; then
      _many_out=("${items[@]}")
      return 0
    fi

    selected=()
    for index in $input; do
      if [[ "$index" =~ ^[0-9]+$ ]] && (( index >= 1 && index <= ${#items[@]} )); then
        selected+=("${items[index - 1]}")
      else
        # Also accept the item name itself, which makes the default work.
        for i in "${items[@]}"; do [[ "$i" == "$index" ]] && selected+=("$i"); done
      fi
    done

    if (( ${#selected[@]} > 0 )); then
      _many_out=("${selected[@]}")
      return 0
    fi
    cecho fail "❌ Invalid selection. Try again."
  done
}

prompt_for_sets() {
  local tags=() chosen=() spec tag
  for spec in "${MERGE_SETS[@]}"; do
    tags+=("${spec%%:*}")
  done

  prompt_many "Select merge set(s):" all chosen "${tags[@]}"

  SELECTED_SETS=()
  for tag in "${chosen[@]}"; do
    spec="$(spec_for_tag "$tag")" && SELECTED_SETS+=("$spec")
  done
}

prompt_for_nodes() {
  prompt_many "Select node(s):" "$CURRENT_NODE" SELECTED_NODES "${ALL_NODES[@]}"
}

# Ask a y/N question, printing the label in bold and the hint dimmed.
ask_yes_no() {
  local label="$1" hint="$2" reply
  printf '%s %s ' "$(paint bold "$label")" "$(paint info "$hint")"
  read -r reply || reply=n
  [[ "${reply,,}" == y* ]]
}

prompt_for_slow_options() {
  ask_yes_no 'Show file counts?'     '(slow) [y/N]:' && SHOW_FILE_COUNTS=true      || SHOW_FILE_COUNTS=false
  ask_yes_no 'Show directory sizes?' '(slow) [y/N]:' && SHOW_DIRECTORY_SIZES=true  || SHOW_DIRECTORY_SIZES=false
  ask_yes_no 'Compact table?'        '(one row per node) [y/N]:' && TABLE_MODE=true || TABLE_MODE=false
}

# Ask how many nodes to work on at once. Only meaningful with more than one node
# selected, so skip the question otherwise. The default is the current MAX_JOBS,
# so a value chosen here carries over as the default for the next action.
prompt_for_jobs() {
  local reply
  (( ${#SELECTED_NODES[@]} > 1 )) || return 0

  while true; do
    printf '%s %s: ' \
      "$(paint bold "Parallel jobs across ${#SELECTED_NODES[@]} nodes")" \
      "$(paint info "[1 = serial, default: $MAX_JOBS]")"
    read -r reply || reply="$MAX_JOBS"
    reply="${reply:-$MAX_JOBS}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 )); then
      MAX_JOBS="$reply"
      return 0
    fi
    cecho fail "❌ Enter a positive whole number."
  done
}

# =============================================================================
# ARGUMENT RESOLUTION
# =============================================================================

# Resolve --set. Returns 1 when the flag was not given.
resolve_sets() {
  local wanted=() tag spec

  [[ -n "$SET_ARG" ]] || return 1
  SELECTED_SETS=()

  if [[ "$SET_ARG" == all ]]; then
    SELECTED_SETS=("${MERGE_SETS[@]}")
    return 0
  fi

  IFS=',' read -r -a wanted <<< "$SET_ARG"
  for tag in "${wanted[@]}"; do
    spec="$(spec_for_tag "$tag")" \
      || die "unknown merge set tag: $tag (run '$PROGNAME list')"
    SELECTED_SETS+=("$spec")
  done

  (( ${#SELECTED_SETS[@]} > 0 )) || die "--set matched no merge sets"
}

# Resolve --node. Returns 1 when the flag was not given.
resolve_nodes() {
  local wanted=() node known n

  [[ -n "$NODE_ARG" ]] || return 1
  SELECTED_NODES=()

  case "$NODE_ARG" in
    all)     SELECTED_NODES=("${ALL_NODES[@]}"); return 0 ;;
    current) SELECTED_NODES=("$CURRENT_NODE");   return 0 ;;
  esac

  IFS=',' read -r -a wanted <<< "$NODE_ARG"
  for node in "${wanted[@]}"; do
    [[ -n "$node" ]] || continue
    # "current" is also accepted inside a comma-separated list.
    [[ "$node" == current ]] && node="$CURRENT_NODE"
    known=false
    for n in "${ALL_NODES[@]}"; do [[ "$n" == "$node" ]] && known=true; done
    [[ "$known" == true ]] || warn "'$node' is not in the discovered node list; using it anyway"
    SELECTED_NODES+=("$node")
  done

  (( ${#SELECTED_NODES[@]} > 0 )) || die "--node matched no nodes"
}

# =============================================================================
# COMMANDS
# =============================================================================

cmd_list() {
  local spec src

  header "Merge sets (${#MERGE_SETS[@]})"
  for spec in "${MERGE_SETS[@]}"; do
    parse_merge_set "$spec"
    printf '\n📦 %s\n   mount:   %s\n   sources: %d\n' "$SET_TAG" "$SET_MOUNT" "${#SET_SOURCES[@]}"
    for src in "${SET_SOURCES[@]}"; do
      printf '     - %s\n' "$src"
    done
  done

  echo
  header "Nodes (${#ALL_NODES[@]})"
  printf '%s\n' "${ALL_NODES[*]}"
  printf '\ncurrent node: %s\n' "$CURRENT_NODE"

  echo
  header "mergerfs options"
  printf '%s\n' "$MERGERFS_OPTS"
}

cmd_rsync() {
  local spec src

  header "💡 Rsync commands to consolidate merge sets"

  for spec in "${SELECTED_SETS[@]}"; do
    parse_merge_set "$spec"
    local dest="$CONSOLIDATE_DIR/${SET_MOUNT##*/}"

    printf '\n📦 [%s] %s\n' "$SET_TAG" "$SET_MOUNT"
    echo "   mkdir -p $dest"
    echo "   rsync -avh --progress \\"
    for src in "${SET_SOURCES[@]}"; do
      echo "     $src/ \\"
    done
    echo "     $dest/"
    echo
    hr "-"
  done

  cat <<EOF

💡 Tips:
   - Add --dry-run first to see what would be transferred.
   - Later sources overwrite earlier ones where paths collide; put the source
     you trust most last.
   - Do NOT add --delete: with several sources rsync would delete files that
     came from the other sources.
EOF
}

# =============================================================================
# INTERACTIVE MENU
# =============================================================================

# Interactive menu: "label|action" in display order — the single source of
# truth for both the on-screen labels and the label→action mapping.
readonly MENU_ITEMS=(
  "Mount|mount"
  "Check mounts|status"
  "Unmount|unmount"
  "Kill mergerfs process|kill"
  "Show rsync commands|rsync"
  "Exit|exit"
)

menu_labels() {
  local item
  for item in "${MENU_ITEMS[@]}"; do printf '%s\n' "${item%%|*}"; done
}

menu_action_for_label() {
  local item
  for item in "${MENU_ITEMS[@]}"; do
    [[ "${item%%|*}" == "$1" ]] && { printf '%s' "${item##*|}"; return 0; }
  done
  return 1
}

menu_label_for_action() {
  local item
  for item in "${MENU_ITEMS[@]}"; do
    [[ "${item##*|}" == "$1" ]] && { printf '%s' "${item%%|*}"; return 0; }
  done
  return 1
}

reset_run_state() {
  SUMMARY_ROWS=()
  CELL=()
  OPS_TOTAL=0
  OPS_FAILED=0
  OPS_WARNED=0
  OPS_UNMOUNTED=0
}

interactive_menu() {
  local label action rc=0 labels=()
  mapfile -t labels < <(menu_labels)

  while true; do
    prompt_one "Select an action:" "$(menu_label_for_action status)" label "${labels[@]}"
    action="$(menu_action_for_label "$label")"

    case "$action" in
      exit)
        echo
        cecho head "Goodbye!"
        return "$rc"
        ;;
      rsync)
        SELECTED_SETS=("${MERGE_SETS[@]}")
        cmd_rsync
        pause
        continue
        ;;
      status)
        prompt_for_slow_options
        ;;
    esac

    prompt_for_sets
    prompt_for_nodes
    prompt_for_jobs

    if confirm_operation "$action"; then
      reset_run_state
      execute "$action" || rc=1
    else
      cecho fail "❌ Operation cancelled"
    fi
    pause
  done
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

usage() {
  cat <<EOF
$PROGNAME $VERSION — manage mergerfs mounts across the cluster

USAGE
  $PROGNAME [COMMAND] [OPTIONS]

  With no COMMAND the interactive menu is shown.

COMMANDS
  mount        Mount the merged filesystem
  status       Report mount state, usage and source health  (alias: check)
  unmount      Unmount the merged filesystem
  kill         Kill a wedged mergerfs process and clear its mount entry
  rsync        Print rsync commands to consolidate a merge set
  list         List configured merge sets and discovered nodes
  menu         Interactive menu (default)

OPTIONS
  -s, --set TAGS       Merge set tag(s), comma separated, or "all"
  -n, --node NODES     Node(s), comma separated, "all", or "current"
  -j, --jobs N         Nodes to work on in parallel (default $MAX_JOBS = serial)
  -y, --yes            Do not ask for confirmation
  -N, --dry-run        Show what would happen without doing it
      --counts         status: count files and directories (slow)
      --sizes          status: compute source sizes with du (slow)
      --table          status: compact one-row-per-node table instead of blocks
      --no-create      mount: do not create missing source directories
      --ssh-timeout S  ssh connect timeout in seconds (default $SSH_TIMEOUT)
      --op-timeout S   Timeout for remote filesystem probes (default $OP_TIMEOUT)
      --color WHEN     Colourise output: auto (default), always or never
      --no-color       Alias for --color never
  -h, --help           Show this help
  -V, --version        Show the version

  Omitting --set or --node for an operation falls back to the interactive
  picker for that choice, so the flags can be mixed with prompting.

  With -j > 1 each node's output is buffered and replayed in selection order,
  and ssh runs in BatchMode so a stalled auth prompt fails fast instead of
  hanging invisibly. Selecting several merge sets reuses one ssh connection
  per node automatically.

EXAMPLES
  $PROGNAME                                            # interactive menu
  $PROGNAME status -s all -n all -j 8                  # fast full sweep
  $PROGNAME mount  -s all -n current -y
  $PROGNAME kill   -s projectA-logs -n node1,node2 -y
  $PROGNAME unmount -s projectB-scenes -n node1 --dry-run
  $PROGNAME list

SUMMARY
  Every run ends with a tally and, when relevant, FAILED and WARNINGS blocks
  so a problem on one node cannot get lost in the scrollback. Identical findings
  are deduplicated: a fact seen on every node collapses to one line reading
  "all nodes", while an outlier node is spelled out by name. Each block is split
  into "Source issues (node-independent)" — facts about a shared source such as
  low free space or an inaccessible source — and "Node issues" — facts about a
  node's own mount, such as a wedged or stale mount, drift or stray data.
  Reported as failures: unreachable nodes, wedged mounts, stale mount entries, a
  foreign filesystem at the mount point, inaccessible sources, and more than 1G
  of stray data written under an unmounted mount point. Reported as warnings:
  smaller amounts of stray data, sources below minfreespace, and branch or
  option drift between a running mount and this config.

CONFIGURATION
  Defaults sit at the top of this script and can be overridden by
  \$CLUSTER_MERGERFS_CONFIG or ~/.config/cluster_mergerfs.conf, sourced as bash.
  It may set MERGERFS_OPTS, HEAD_NODE, CONSOLIDATE_DIR, SSH_TIMEOUT,
  OP_TIMEOUT, MAX_JOBS and STRAY_FAIL_BYTES.

  Merge sets are declared with the merge_set builder, in either form:
      merge_set <tag> <local-mount> <branch>...                  # explicit
      merge_set <tag> <local-mount> --nodes a,b,c --template T   # pattern
  In the pattern form {node} in the template T expands to each node in --nodes.
  A config file can add more sets with further merge_set calls; to replace the
  built-in sets entirely, reset with MERGE_SETS=() before your own calls.

EXIT STATUS
  0  success
  1  one or more operations failed
  2  usage or configuration error
EOF
}

need_arg() {
  (( $# >= 2 )) || die "option $1 requires an argument"
}

parse_args() {
  while (( $# )); do
    # Normalise --opt=value into --opt value.
    if [[ "$1" == --*=* ]]; then
      set -- "${1%%=*}" "${1#*=}" "${@:2}"
    fi

    case "$1" in
      mount|unmount|kill|rsync|list|menu) COMMAND="$1" ;;
      status|check)                       COMMAND="status" ;;
      -s|--set)        need_arg "$@"; SET_ARG="$2";      shift ;;
      -n|--node)       need_arg "$@"; NODE_ARG="$2";     shift ;;
      -j|--jobs)       need_arg "$@"; MAX_JOBS="$2";     shift ;;
      --ssh-timeout)   need_arg "$@"; SSH_TIMEOUT="$2";  shift ;;
      --op-timeout)    need_arg "$@"; OP_TIMEOUT="$2";   shift ;;
      -y|--yes)        ASSUME_YES=true ;;
      -N|--dry-run)    DRY_RUN=true ;;
      --counts)        SHOW_FILE_COUNTS=true ;;
      --sizes)         SHOW_DIRECTORY_SIZES=true ;;
      --table)         TABLE_MODE=true ;;
      --no-create)     CREATE_SOURCES=false ;;
      --color)         need_arg "$@"; USE_COLOR="$2"; shift ;;
      --no-color)      USE_COLOR="never" ;;
      -h|--help)       usage; exit 0 ;;
      -V|--version)    printf '%s %s\n' "$PROGNAME" "$VERSION"; exit 0 ;;
      -*)              die "unknown option: $1 (try --help)" ;;
      *)               die "unknown command: $1 (try --help)" ;;
    esac
    shift
  done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  load_config
  parse_args "$@"
  setup_colors
  validate_config
  parse_min_free_space
  discover_nodes

  case "${COMMAND:-menu}" in
    menu)
      interactive_menu
      ;;
    list)
      cmd_list
      ;;
    rsync)
      resolve_sets || SELECTED_SETS=("${MERGE_SETS[@]}")
      cmd_rsync
      ;;
    mount|status|unmount|kill)
      resolve_sets  || prompt_for_sets
      resolve_nodes || prompt_for_nodes
      confirm_operation "$COMMAND" || { cecho fail "❌ Operation cancelled"; exit 1; }
      execute "$COMMAND"
      ;;
    *)
      die "internal error: unhandled command '$COMMAND'"
      ;;
  esac
}

main "$@"