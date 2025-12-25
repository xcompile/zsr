
# Example restore of one PVC
REMOTE="backupremote:zfs-backups/openebs"
TMP="/var/tmp/restore"

mkdir -p "$TMP"
rclone copy "$REMOTE" "$TMP" --include "tank_openebszfs_pvc-5d5dec35__auto-20251205-1645__FULL.zfs"
rclone copy "$REMOTE" "$TMP" --include "tank_openebszfs_pvc-5d5dec35__bk-auto-20251205-1645__to__auto-20251205-1745__INCR.zfs"

# Receive into a restore tree (use -u to avoid rolling back if resume)
zfs receive -u -F tank/restore/openebszfs/pvc-5d5dec35 < "$TMP/tank_openebszfs_pvc-5d5dec35__auto-20251205-1645__FULL.zfs"

# Apply the incremental in order
zfs receive -u -F tank/restore/openebszfs/pvc-5d5dec35 < "$TMP/tank_openebszfs_pvc-5d5dec35__bk-auto-20251205-1645__to__auto-20251205-1745__INCR.zfs"
``

