#!/usr/bin/env bash
set -euo pipefail
#set -x

# ========= USER SETTINGS =========
FILTER_DS="${1:-}"

PARENT="tank/openebszfs"
DATASET_GLOB="pvc-.*"



REMOTE="crypt-storage-box-1"


# Add --raw for encrypted datasets (preserves encryption);
ZFS_FLAGS="--compressed"
RCLONE_FLAGS="--checkers=7 --ftp-concurrency=10"

# mbuffer tuning
MBUF_SIZE="256M"
MBUF_WATERMARK="128M"

# Snapshot naming
TS="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_PREFIX="auto"
BOOKMARK_PREFIX="bk-auto"


# Force a new FULL after N incrementals per dataset (0 = never force)
ROTATE_FULL_AFTER=20



# ========= INTERNALS =========
log() { printf '[%(%F %T)T] %s\n' -1 "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }


list_children() {
  # Lists immediate children that match the GLOB
  zfs list -H -o name -t filesystem -r "$PARENT" | grep -E "^$PARENT/$DATASET_GLOB$" || true
}

# Get the last bookmark name (if any)
last_bookmark(){
  # retrieve last bookmark
  local ds="$1"
  zfs list -t bookmark -o name -r "$ds" 2>/dev/null \
	  | awk -F# -v pfx="${BOOKMARK_PREFIX}" '$2 ~ "^" pfx { print $2 }' \
	  | sort | tail -n1 || true

}

last_snapshot() {
  # retrieve last snapshot
  local ds="$1"
  zfs list -t snapshot -o name -r "$ds" 2>/dev/null \
	  | awk -F@ -v pfx="${SNAPSHOT_PREFIX}" '$2 ~ "^" pfx { print $0 }' \
	  | sort | tail -n1 || true
}

# count incrementals since last full backup
get_increment_count() {
  local ds="$1"
  # get custom property backup:increment-count
  zfs get -H -o value backup:increment-count "$ds" 2>/dev/null |grep -E '^[0-9]+$' || echo 0

}

# set incrementals since last full backup
set_increment_count() {
  local ds="$1" cnt="$2"
  zfs set backup:increment-count="$cnt" "$ds"
}

# reset incrementals counter to initial value
reset_increment_count() {
  local ds="$1"
  set_increment_count "$ds" 0
}

send_full() {
  local ds="$1" snap="$2"
  #<modified_dataset_name>__<snapshot_name>__FULL.zfs
  local stream_name="${ds//\//_}__${snap#*@}__FULL.zfs"
  local rpath="${REMOTE}:${stream_name}"
  log "FULL send: $snap  →  $rpath"

  # create a bookmark tied to this snap so future incrementals can e based on it
  zfs bookmark "$snap" "${ds}#bk-${snap#*@}" || true
  # zfs send

  zfs send $ZFS_FLAGS "$snap" \
	  | mbuffer -q -s 128k -m "$MBUF_SIZE" -W "$MBUF_WATERMARK" \
	  | rclone rcat $RCLONE_FLAGS --progress "$rpath"
  # Advance bookmark so we can prune old snapshots

  # reset incremental counter
  reset_increment_count $ds
}

send_incremental() {
  local ds="$1" from_bk="$2" to_snap="$3"

  local base="${from_bk#*#}"
  local ts="${to_snap#*@}"
  local stream_name="${ds//\//_}__${base}__to__${ts}__INC.zfs"
  local rpath="${REMOTE}:${stream_name}"

  log "INCR send: $from_bk → $to_snap  →  $rpath"
  zfs send $ZFS_FLAGS -i "$from_bk" "$to_snap" \
	  | mbuffer -q -s 128k -m "$MBUF_SIZE" -W "$MBUF_WATERMARK" \
	  | rclone rcat $RCLONE_FLAGS --progress "$rpath"
  # Advance bookmark so we can prune old snapshots
  zfs bookmark "$to_snap" "${ds}#bk-${ts}" || true

  # prune older auto snapshots
  prune_local_snaps "$ds" 7

  # increase counter
  local cnt
  cnt=$(($(get_increment_count "$ds") + 1))
  set_increment_count "$ds" "$cnt"
}

prune_local_snaps() {
  local ds="$1" keep="${2:-7}"
  # Delete old auto snapshots beyond 'keep' (safe because bookmark anchors incrementals)
  local snaps
  snaps=$(zfs list -t snapshot -o name -r "$ds" 2>/dev/null \
	  | awk -F@ -v pfx="${SNAPSHOT_PREFIX}" '$2 ~ "^" pfx { print $0 }' \
	  | sort)

  local total count
  total=$(echo "$snaps" | wc -l | awk '{print $1}')
  if (( total > keep )); then
    count=$(( total - keep ))
    echo "$snaps" | head -n "$count" | while read -r s; do
      log "Prune local snapshot: $s"
      zfs destroy "$s" || true
    done
  fi
}

# prune, keep latest
prune_local_bookmarks() {
  local ds="$1"
  zfs list -H -t bookmark -o name -r "$ds" \
        | grep -E "^${ds}#bk-" | sort | head -n -1 \
        | xargs -r -n1 zfs destroy || true
}

require_cmds() {
  for c in zfs zpool mbuffer rclone awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || die "Missing command: $c"
  done
}


do_snapshot_all() {
  local ds
  for ds in $(list_children); do
    local snap="${ds}@${SNAPSHOT_PREFIX}-${TS}"
    log "Create snapshot: $snap"
    zfs snapshot -r "$snap"
  done
}

main() {
	require_cmds
	do_snapshot_all
	
	local ds
	for ds in $(list_children); do
	 
	  # check if processing is limited to a specific dataset	
	  if [[ -n "$FILTER_DS" ]]; then
	    if [[ $ds != $FILTER_DS ]]; then
	      log "Skip DS:${ds}"
              continue
	    fi

	  fi
	  log "Process DS: ${ds}"
	  # determine newest snapshot we just made
	  local last_snap
	  last_snap=$(last_snapshot "$ds")
	  [[ -n "$last_snap" ]] || { log "No snapshot found for $ds"; continue; }

          local last_bk incr_count
	  last_bk=$(last_bookmark "$ds")
	  incr_count=$(get_increment_count "$ds")
	  if [[ -z "$last_bk" ]]; then
            # No baseline yet => FULL backup
	    send_full "$ds" "$last_snap"
	    continue
	  fi

	  # rotation policy: force new full after N increments
	  if (( ROTATE_FULL_AFTER > 0 && incr_count >= ROTATE_FULL_AFTER )); then
            log "Rotate policy reached for $ds (incrementals=$incr_count) → new FULL"
	    send_full "$ds" "$last_snap"
	    # prune older bookmarks, keep the last one
	    prune_local_bookmarks "$ds"
            continue
	  fi
	  
	  # send incremental snapshot
	  send_incremental "$ds" "${ds}#${last_bk}" "$last_snap"
	  # prune older bookmarks, keep the last one
	  prune_local_bookmarks "$ds"

	  #

	done
}



main
