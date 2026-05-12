#!/bin/bash
#
# cluster_mergerfs.sh — interactive helper to mount/unmount/inspect mergerfs
# unions across a SLURM cluster.
#
# MIT License
#
# Copyright (c) 2025 Marc Benedí San Millán
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

set -euo pipefail  # Exit on error, undefined variables, or pipe failures

# ========== CONFIGURATION ==========
# Format: local_mount:path1:path2:path3
MERGE_SETS=(
  # "/home/<user>/merge:/home/<user>/s1:/home/<user>/s2"
  "/home/<user>/projects/projectA/logs:/cluster/node1/<user>/projectA_logs:/cluster/node2/<user>/projectA_logs:/cluster/node3/<user>/projectA_logs:/cluster/node4/<user>/projectA_logs"
  "/home/<user>/projects/projectB/scenes:/cluster/node1/<user>/projectB/scenes"
  "/home/<user>/projects/projectB/outputs:/cluster/node1/<user>/projectB/outputs"
)

MERGERFS_OPTS="cache.files=off,use_ino,func.getattr=newest,category.create=mfs,moveonenospc=true,minfreespace=300G,allow_other"
SSH_TIMEOUT=5

# Extract minfreespace threshold from MERGERFS_OPTS so we can flag branches that
# fall below it (mergerfs excludes such branches from new file creation).
MIN_FREE_SPACE=$(grep -oE 'minfreespace=[^,]+' <<< "$MERGERFS_OPTS" | cut -d= -f2 || true)
MIN_FREE_BYTES=$(numfmt --from=iec "${MIN_FREE_SPACE:-0}" 2>/dev/null || echo 0)

# Performance options
# Set to "true" to enable slow operations (file counting, du -sh)
# Set to "false" to skip them for faster execution
SHOW_FILE_COUNTS="${SHOW_FILE_COUNTS:-false}"
SHOW_DIRECTORY_SIZES="${SHOW_DIRECTORY_SIZES:-false}"
# ===================================

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Custom select function with support for default choice (marked with !)
# Usage: result=$(selectWithDefault "Option1" "!Option2" "Option3")
# Returns the selected option text (without the ! marker)
# For multi-select: result=$(selectWithDefault --multi "Option1" "Option2" "Option3")
# In multi-select, !-prefixed items become the default selection (instead of "all")
selectWithDefault() {
  local multi_select=false
  local item i=0 numItems defaultIndex=1 line=""
  local items=()
  local sep="   "

  # Check if multi-select mode
  if [[ "$1" == "--multi" ]]; then
    multi_select=true
    shift
  fi

  numItems=$#

  # Build the menu and identify default
  for item; do
    ((i++))
    if [[ "$item" == !* ]]; then
      defaultIndex=$i
      item="${item:1}"  # Remove ! prefix
    fi
    items+=("$item")
    line+="$i) $item$sep"
  done

  # Display menu
  echo "$line" >&2

  # Get user input
  if [[ "$multi_select" == true ]]; then
    # Build default list from !-prefixed items (already stripped above into items[])
    # Re-scan original args to find which were !-prefixed
    local default_items=()
    for item in "$@"; do
      [[ "$item" == !* ]] && default_items+=("${item:1}")
    done
    # Fallback: if no defaults marked, default to all
    [[ ${#default_items[@]} -eq 0 ]] && default_items=("${items[@]}")

    # Multi-select mode: allow space-separated numbers, re-prompt on bad input
    while true; do
      printf "Enter choices (space-separated) or 'all' [default: %s]: " "${default_items[*]}" >&2
      read -r input

      if [[ -z "$input" ]]; then
        echo "${default_items[@]}"
        return
      fi

      if [[ "$input" == "all" ]]; then
        echo "${items[@]}"
        return
      fi

      local selected=()
      local valid=true
      for index in $input; do
        if [[ "$index" =~ ^[0-9]+$ ]] && (( index >= 1 && index <= numItems )); then
          selected+=("${items[$((index - 1))]}")
        else
          echo "❌ Invalid selection: $index. Please try again." >&2
          valid=false
          break
        fi
      done

      if [[ "$valid" == true ]]; then
        echo "${selected[@]}"
        return
      fi
    done
  else
    # Single select mode (original behavior)
    while true; do
      printf "Enter choice [default: %d]: " "$defaultIndex" >&2
      read -r index

      # Use default if empty
      if [[ -z "$index" ]]; then
        index=$defaultIndex
        break
      fi

      # Validate numeric input in range
      if [[ "$index" =~ ^[0-9]+$ ]] && (( index >= 1 && index <= numItems )); then
        break
      fi

      echo "❌ Invalid selection. Please try again." >&2
    done

    echo "${items[$((index - 1))]}"
  fi
}

# Parse a merge set string into global variables: mount_point and source_dirs[]
# Input format: "/mount/path:/source1:/source2:/source3"
parse_merge_set() {
  local set="$1"

  # Extract mount point (everything before first colon)
  mount_point="${set%%:*}"

  # Extract sources (everything after first colon)
  local sources="${set#*:}"

  # Split sources into array
  IFS=':' read -r -a source_dirs <<< "$sources"
}

# Get list of all available cluster nodes
get_nodes() {
  local node_list

  # Get nodes from SLURM and expand any bracket notation (e.g. node[01-04])
  # sinfo outputs compressed ranges; scontrol show hostnames expands them
  if ! node_list=$(sinfo -h -o "%N" 2>/dev/null \
      | tr ',' '\n' \
      | xargs -I{} scontrol show hostnames {} 2>/dev/null \
      | tr '\n' ' '); then
    echo "⚠️  Warning: Could not get node list from sinfo" >&2
    node_list=""
  fi

  # Add the head/login node to the list
  read -r -a NODES <<< "headnode $node_list"
}

# Create any missing source directories on a remote node
ensure_sources_exist() {
  local node="$1"
  local -n _ens_dirs="$2"

  for dir in "${_ens_dirs[@]}"; do
    run_ssh_command "$node" "
      if [[ ! -d '$dir' ]]; then
        echo 'Creating missing source directory: $dir'
        if ! mkdir -p '$dir' 2>&1; then
          echo '❌ Failed to create source directory: $dir'
        fi
      fi
    "
  done
}

# Check all source directories are accessible on a node via SSH
# Prints status for each directory. Returns 1 if any are inaccessible.
check_source_dirs_on_node() {
  local node="$1"
  local -n _chk_src_dirs="$2"

  local source_joined
  source_joined=$(IFS=:; echo "${_chk_src_dirs[*]}")

  run_ssh_command "$node" "
    all_ok=true
    IFS=':' read -r -a _src_dirs <<< '$source_joined'
    for dir in \"\${_src_dirs[@]}\"; do
      if timeout 5 ls \"\$dir\" > /dev/null 2>&1; then
        echo \"    ✅ \$dir\"
      else
        echo \"    ❌ \$dir (inaccessible or timed out)\"
        all_ok=false
      fi
    done
    [[ \$all_ok == true ]]
  "
}

# Execute a command on a remote node via SSH
# Usage: run_ssh_command node "command"
run_ssh_command() {
  local node="$1"
  local command="$2"

  ssh -o ConnectTimeout="$SSH_TIMEOUT" "$node" bash <<EOF
$command
EOF
}

# Print a separator line
print_separator() {
  local char="${1:--}"
  printf '%0.s'"$char" {1..63}; echo
}

# Print a header with separator
print_header() {
  local title="$1"
  local char="${2:-═}"
  print_separator "$char"
  echo "$title"
  print_separator "$char"
}

# Pause and wait for user to press Enter
pause() {
  local message="${1:-Press Enter to continue...}"
  printf '%s' "$message"
  read -r
}

# =============================================================================
# NODE OPERATION FUNCTIONS
# =============================================================================

# Mount MergerFS on a specific node
_mount_base() {
  local node="$1"
  local mount_point="$2"
  local -n _source_dirs="$3"

  # Join source directories with colons for MergerFS
  local source_joined
  source_joined=$(IFS=:; echo "${_source_dirs[*]}")

  echo "--- Node: $node ---"

  # Ensure all source directories exist on the remote node
  ensure_sources_exist "$node" "$3"

  # Verify all source directories are accessible before mounting
  echo "  Sources:"
  if ! check_source_dirs_on_node "$node" "$3"; then
    echo "  ❌ Skipping mount: one or more source directories are inaccessible"
    echo
    return 1
  fi

  # Execute mount operation on remote node
  run_ssh_command "$node" "
    echo 'Mounting $mount_point on $node...'

    # Create mount point if needed
    mkdir -p '$mount_point'

    # Check if mount point is not empty and not currently mounted
    if [[ -d '$mount_point' ]] && ! mountpoint -q '$mount_point'; then
      FILE_COUNT=\$(find '$mount_point' -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
      if [[ \$FILE_COUNT -gt 0 ]]; then
        echo '⚠️  WARNING: Mount point is not empty (\$FILE_COUNT items found)'
        echo '⚠️  Mounting will hide existing files until unmounted!'
      fi
    fi

    # Unmount if already mounted (stale mount)
    if mountpoint -q '$mount_point'; then
      echo 'Unmounting stale mount at $mount_point...'
      fusermount -uz '$mount_point' || true
    fi

    # Attempt to mount
    echo \"Running: mergerfs -o $MERGERFS_OPTS '$source_joined' '$mount_point'\"
    OUTPUT=\$(mergerfs -o $MERGERFS_OPTS '$source_joined' '$mount_point' 2>&1)
    STATUS=\$?

    # Verify mount succeeded
    if mountpoint -q '$mount_point'; then
      echo '✅ Mounted $mount_point successfully on $node'
    else
      echo '❌ Failed to mount $mount_point on $node'
      echo \"MergerFS output: \$OUTPUT\"
      echo \"Exit status: \$STATUS\"
    fi
  "
}

mount_on_node() {
  _mount_base "$1" "$2" "$3"
}

# Show mount status, merged-view usage, mounted options, and per-source disk usage on a node.
# File counts and directory sizes are gated by SHOW_FILE_COUNTS / SHOW_DIRECTORY_SIZES (slow).
check_mounts_on_node() {
  local node="$1"
  local mount_point="$2"
  local -n _chk_source_dirs="$3"

  print_separator "-"
  echo "🖥️  Node: $node"
  print_separator "-"

  run_ssh_command "$node" "
    if mountpoint -q '$mount_point' 2>/dev/null; then
      echo '✅ Mount Status: ACTIVE'
      echo
      echo '📍 Mount Point: $mount_point'
      if [[ -d '$mount_point' ]]; then
        echo \"   Created:       \$(stat -c %w '$mount_point' 2>/dev/null || echo 'unknown')\"
        echo \"   Last accessed: \$(stat -c %x '$mount_point' 2>/dev/null || echo 'unknown')\"
        if [[ '$SHOW_FILE_COUNTS' == 'true' ]]; then
          FILE_COUNT=\$(find '$mount_point' -type f 2>/dev/null | wc -l)
          DIR_COUNT=\$(find '$mount_point' -type d 2>/dev/null | wc -l)
          echo \"   Files:         \$FILE_COUNT\"
          echo \"   Directories:   \$DIR_COUNT\"
        fi
      fi
      echo
      echo '💾 Merged View Usage:'
      df -h '$mount_point' | awk 'NR==1 {print \"   \" \$0} NR==2 {print \"   \" \$0}'
      echo
      echo '⚙️  Mounted Options:'
      mount | grep \" on $mount_point \" | sed 's/^/   /' || echo '   (no mount entry found)'
    else
      echo '❌ Mount Status: NOT MOUNTED'
      if [[ -d '$mount_point' ]]; then
        FILE_COUNT=\$(find '$mount_point' -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
        if [[ \$FILE_COUNT -gt 0 ]]; then
          echo \"   ⚠️  Directory exists with \$FILE_COUNT items (will be hidden if mounted over)\"
        else
          echo '   ℹ️  Directory exists and is empty'
        fi
      else
        echo '   ℹ️  Directory does not exist'
      fi
    fi
  "
  echo

  echo "📁 Source Directories (${#_chk_source_dirs[@]}):"
  for dir in "${_chk_source_dirs[@]}"; do
    run_ssh_command "$node" "
      if timeout 5 ls '$dir' > /dev/null 2>&1; then
        DF_INFO=\$(df -h '$dir' 2>/dev/null | awk 'NR==2 {printf \"%s free / %s total (%s used)\", \$4, \$2, \$5}')
        echo '   ✅ $dir'
        echo \"      \$DF_INFO\"
        AVAIL_BYTES=\$(df -B1 '$dir' 2>/dev/null | awk 'NR==2 {print \$4}')
        if [[ -n \"\$AVAIL_BYTES\" && $MIN_FREE_BYTES -gt 0 && \$AVAIL_BYTES -lt $MIN_FREE_BYTES ]]; then
          echo '      ⚠️  Below minfreespace=$MIN_FREE_SPACE — excluded from new file creation'
        fi
        if [[ '$SHOW_DIRECTORY_SIZES' == 'true' ]]; then
          SIZE=\$(du -sh '$dir' 2>/dev/null | cut -f1)
          echo \"      Size: \$SIZE\"
        fi
        if [[ '$SHOW_FILE_COUNTS' == 'true' ]]; then
          FILE_COUNT=\$(find '$dir' -type f 2>/dev/null | wc -l)
          echo \"      Files: \$FILE_COUNT\"
        fi
      else
        echo '   ❌ $dir (inaccessible or timed out)'
      fi
    "
  done
  echo
}

# Unmount MergerFS on a node
unmount_on_node() {
  local node="$1"
  local mount_point="$2"

  echo "--- Node: $node ---"
  run_ssh_command "$node" "
    if mountpoint -q '$mount_point'; then
      echo '  Unmounting $mount_point...'
      fusermount -uz '$mount_point'
      echo '  ✅ Unmounted successfully'
    else
      echo '  ℹ️  $mount_point is not mounted'
    fi
  "
  echo
}

# Kill a hung mergerfs process for a specific mount point on a node
kill_mergerfs_on_node() {
  local node="$1"
  local mount_point="$2"

  echo "--- Node: $node ---"
  run_ssh_command "$node" "
    echo '  Mount: $mount_point'

    # Step 1: Check if the mount is present via findmnt
    if ! findmnt --types fuse.mergerfs --target '$mount_point' > /dev/null 2>&1; then
      echo 'ℹ️  No mergerfs mount found at $mount_point on $node (findmnt found nothing)'
      exit 0
    fi
    echo '✅ findmnt: mergerfs mount found at $mount_point'

    # Step 2: Find the mergerfs PID owning this mount point
    # Match mergerfs processes where the mount point is the LAST argument of
    # /proc/<pid>/cmdline, to avoid false matches when the mount point string
    # appears in a *source* path of a different mergerfs instance.
    PIDS=\$(
      for pid in \$(pgrep -u \"\$(id -u)\" mergerfs 2>/dev/null || true); do
        last_arg=\$(tr '\0' '\n' < /proc/\$pid/cmdline 2>/dev/null | tail -1)
        if [[ \"\$last_arg\" == '$mount_point' ]]; then
          echo \$pid
        fi
      done
    )

    if [[ -z \"\$PIDS\" ]]; then
      echo '⚠️  No mergerfs process found — process may have already died, proceeding to cleanup...'
    else
      echo \"✅ Found mergerfs PID(s): \$PIDS\"
      for PID in \$PIDS; do
        CMDLINE=\$(tr '\0' ' ' < /proc/\$PID/cmdline 2>/dev/null || echo '(unknown)')
        echo \"   Killing PID \$PID: \$CMDLINE\"
        kill -9 \$PID && echo \"   ✅ Killed PID \$PID\" || echo \"   ❌ Failed to kill PID \$PID\"
      done
    fi

    # Always run fusermount -uz to clean up after the kill,
    # fall back to umount -l if the mount entry is stuck in the kernel
    sleep 1
    echo '   Running fusermount -uz to clean up mount entry...'
    if fusermount -uz '$mount_point' 2>/dev/null; then
      echo '✅ fusermount -uz succeeded'
    else
      echo '   ⚠️  fusermount -uz failed, trying umount -l (lazy unmount)...'
      umount -l '$mount_point' 2>/dev/null \
        && echo '✅ umount -l succeeded' \
        || echo '❌ umount -l also failed — mount entry may need manual cleanup or root'
    fi
  "
  echo
}

# Display preview of what operation will do and get confirmation
# Returns 0 if user confirms, 1 if user cancels
show_operation_preview() {
  local action="$1"
  local merge_sets=("${!2}")
  local nodes=("${!3}")

  echo
  print_header "⚠️  OPERATION PREVIEW"
  echo
  echo "Action: $action"
  echo

  echo "Targets:"
  echo "  📦 Merge Sets: ${#merge_sets[@]}"
  for set in "${merge_sets[@]}"; do
    parse_merge_set "$set"
    echo "     - $mount_point"
  done
  echo

  echo "  🖥️  Nodes: ${#nodes[@]}"
  for node in "${nodes[@]}"; do
    echo "     - $node"
  done
  echo

  echo "What will happen:"
  case "$action" in
    Mount)
      echo "  • Create mount points if needed"
      echo "  • Unmount any stale mounts"
      echo "  • Mount MergerFS with configured sources"
      echo "  • Verify mounts succeeded"
      ;;
    "Check mounts")
      echo "  • Check if mount points are active"
      echo "  • Show merged-view disk usage and mounted options"
      echo "  • Show per-source disk usage and minfreespace warnings"
      ;;
    Unmount)
      echo "  ⚠️  Unmount MergerFS filesystems"
      echo "  ⚠️  This will make merged data inaccessible until remounted"
      ;;
    "Kill mergerfs process")
      echo "  ⚠️  Check for mergerfs mount via findmnt"
      echo "  ⚠️  Find the mergerfs process owning the mount point"
      echo "  ⚠️  Kill it with SIGKILL (-9)"
      echo "  ⚠️  Attempt to clean up any stale mount entry"
      ;;
  esac
  echo

  local total_ops=$((${#merge_sets[@]} * ${#nodes[@]}))
  echo "Total operations: $total_ops"
  print_separator "═"
  echo

  local default_response="y"
  local prompt="Proceed? [Y/n]: "

  # For destructive operations, require explicit yes
  if [[ "$action" == "Unmount" ]] || [[ "$action" == "Kill mergerfs process" ]]; then
    default_response="n"
    prompt="⚠️  Proceed with $action? [y/N]: "
  fi

  printf '%s' "$prompt"
  read -r response
  response=${response:-$default_response}

  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo
    return 0
  else
    echo
    echo "❌ Operation cancelled"
    echo
    return 1
  fi
}

# Generate and display rsync commands for consolidating merge sets
show_rsync_commands() {
  echo
  print_header "💡 Rsync Commands to Consolidate Your Merge Sets"
  echo

  if [[ ${#MERGE_SETS[@]} -eq 0 ]]; then
    echo "No merge sets configured."
    return
  fi

  for set in "${MERGE_SETS[@]}"; do
    parse_merge_set "$set"

    local mount_name="${mount_point##*/}"
    local dest_dir="$HOME/consolidated/$mount_name"

    echo "📦 Merge set: $mount_point"
    echo "   Sources (${#source_dirs[@]} directories):"
    for dir in "${source_dirs[@]}"; do
      echo "     - $dir"
    done
    echo
    echo "   Suggested consolidation command:"
    echo "   rsync -avh --progress \\"
    for ((i=0; i<${#source_dirs[@]}; i++)); do
      echo "     ${source_dirs[$i]}/ \\"
    done
    echo "     $dest_dir/"
    echo
    echo "   This will merge all sources into: $dest_dir/"
    print_separator "-"
    echo
  done

  echo "💡 Tips:"
  echo "   - Add --dry-run to test without copying"
  echo "   - Add --delete to make destination match sources exactly"
  echo "   - Run 'mkdir -p \$HOME/consolidated' first"
  echo

  pause
}

# Prompt the user whether to enable slow performance options for relevant actions
configure_performance_options() {
  case "$ACTION" in
    "Check mounts")
      printf 'Show file counts? (slow) [y/N]: '
      read -r r; [[ "${r:-n}" =~ ^[Yy]$ ]] && SHOW_FILE_COUNTS=true || SHOW_FILE_COUNTS=false
      printf 'Show directory sizes? (slow) [y/N]: '
      read -r r; [[ "${r:-n}" =~ ^[Yy]$ ]] && SHOW_DIRECTORY_SIZES=true || SHOW_DIRECTORY_SIZES=false
      ;;
  esac
}

# =============================================================================
# INTERACTIVE MENU FUNCTIONS
# =============================================================================

select_multiple() {
  local prompt="$1"
  local result_var="$2"
  shift 2
  local items=("$@")

  echo
  echo "$prompt"

  local result
  result=$(selectWithDefault --multi "${items[@]}")

  read -r -a "$result_var" <<< "$result"
}

select_single() {
  local prompt="$1"
  local result_var="$2"
  shift 2
  local items=("$@")

  echo
  echo "$prompt"

  local result
  result=$(selectWithDefault "${items[@]}")

  printf -v "$result_var" '%s' "$result"
}

select_action() {
  select_single "Select an action:" ACTION \
    "Mount" "!Check mounts" "Unmount" \
    "Kill mergerfs process" "Show rsync commands" "Exit"
}

select_merge_set() {
  select_multiple "Select merge set(s):" MERGE_SET_CHOICES "${MERGE_SETS[@]}"
}

select_node() {
  # Tag the current node with ! so it becomes the default selection
  local tagged_nodes=()
  for node in "${NODES[@]}"; do
    if [[ "$node" == "$CURRENT_NODE" ]]; then
      tagged_nodes+=("!$node")
    else
      tagged_nodes+=("$node")
    fi
  done
  select_multiple "Select node(s):" NODE_CHOICES "${tagged_nodes[@]}"
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

get_nodes
CURRENT_NODE=$(hostname -s)

while true; do
  select_action

  if [[ "$ACTION" == "Exit" ]]; then
    echo
    echo "Goodbye!"
    exit 0
  fi

  if [[ "$ACTION" == "Show rsync commands" ]]; then
    show_rsync_commands
    continue
  fi

  configure_performance_options
  select_merge_set
  MERGE_SETS_TO_USE=("${MERGE_SET_CHOICES[@]}")

  select_node
  NODES_TO_USE=("${NODE_CHOICES[@]}")

  if ! show_operation_preview "$ACTION" MERGE_SETS_TO_USE[@] NODES_TO_USE[@]; then
    continue
  fi

  echo "Executing operations..."
  echo

  for set in "${MERGE_SETS_TO_USE[@]}"; do
    parse_merge_set "$set"

    echo "=== $mount_point ==="
    echo

    # || true on each call prevents set -euo pipefail from aborting the loop
    # if one node/mount fails (e.g. SSH error, pgrep finds nothing)
    for node in "${NODES_TO_USE[@]}"; do
      case "$ACTION" in
        Mount)
          mount_on_node "$node" "$mount_point" source_dirs || true
          ;;
        "Check mounts")
          check_mounts_on_node "$node" "$mount_point" source_dirs || true
          ;;
        Unmount)
          unmount_on_node "$node" "$mount_point" || true
          ;;
        "Kill mergerfs process")
          kill_mergerfs_on_node "$node" "$mount_point" || true
          ;;
      esac
    done
  done

  echo
  echo "✅ Operations completed"
  pause
done
