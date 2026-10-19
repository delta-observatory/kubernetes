#!/bin/sh
# One-time split of the root filesystem into /, /var and /srv.
#
# The dracut pre-mount hook runs this script before the root filesystem is
# mounted. It acts only when the state directory holds a "mode" file with the
# value "check" or "apply", and it removes that file before any other step.
# Every failure before the fstab update leaves a bootable system.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -f
CONF_DIR=${DELTA_STORAGE_CONF_DIR:-/etc/delta-storage}
. "$CONF_DIR/storage.conf" || exit 0

RUN=${RUN_DIR:-/run/delta-storage}
mkdir -p "$RUN" || exit 0
LOG=$RUN/log
: > "$LOG"

log() {
    printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$LOG"
    if [ "${KMSG:-1}" = 1 ] && [ -w /dev/kmsg ]; then
        printf '<5>delta-storage: %s\n' "$*" > /dev/kmsg
    fi
}

# The state directory is on the boot partition in the initramfs, and in a plain
# directory during a rehearsal.
state_open() {
    if [ -n "${BOOT_UUID:-}" ]; then
        mkdir -p "$RUN/boot" &&
            mount -t ext4 "/dev/disk/by-uuid/$BOOT_UUID" "$RUN/boot" || return 1
        STATE=$RUN/boot/delta-storage
    else
        STATE=$STATE_DIR
    fi
    [ -d "$STATE" ]
}

state_close() {
    if [ -n "${BOOT_UUID:-}" ]; then
        umount "$RUN/boot"
    fi
}

finish() {
    log "$1"
    if state_open; then
        cp "$LOG" "$STATE/last-run.log"
        sync
        state_close
    fi
    exit 0
}

# Partition table dump with device names and spacing normalized.
table() {
    sfdisk -d "$DISK" 2>> "$LOG" |
        sed -e "s#^${DISK}${PSEP}\([0-9]\)#P\1#" -e '/^device:/d' |
        tr -s ' '
}

# Digest of a directory tree's names, types, modes, owners, link targets and
# file contents, for copy verification. Directory sizes are not compared.
listing() {
    (
        cd "$1" || exit 1
        find . -path ./lost+found -prune -o -printf '%P %y %m %U %G %l\n' | sort
        find . -path ./lost+found -prune -o -type f -print0 | sort -z | xargs -0 -r md5sum
    ) | md5sum
}

if ! state_open; then
    state_close 2> /dev/null
    exit 0
fi
if [ ! -f "$STATE/mode" ]; then
    state_close
    exit 0
fi
MODE=$(cat "$STATE/mode")
rm -f "$STATE/mode"
sync
state_close
log "start mode=$MODE"
case $MODE in
    check | apply) ;;
    *) finish "abort: unknown mode" ;;
esac

P1=${DISK}${PSEP}1
P2=${DISK}${PSEP}2
LV_VAR=/dev/mapper/${VG}-var
LV_SRV=/dev/mapper/${VG}-srv
export LVM_SUPPRESS_FD_WARNINGS=1

# Checks. None of these steps writes to the disk.
table > "$RUN/before.sfdisk" || finish "abort: cannot read the partition table"
tr -s ' ' < "$CONF_DIR/before.sfdisk" | cmp -s - "$RUN/before.sfdisk" ||
    finish "abort: the partition table differs from the expected table"
[ "$(blkid -p -s UUID -o value "$P1")" = "$ROOT_UUID" ] ||
    finish "abort: the root filesystem UUID differs"
[ ! -e "$P2" ] || finish "abort: partition 2 exists"
[ ! -e "/dev/$VG" ] || finish "abort: volume group $VG exists"

mkdir -p "$RUN/root"
mount -t ext4 -o ro,noload "$P1" "$RUN/root" || finish "abort: read-only root mount failed"
fstab_ok=1
grep -Eq '^[^#]*[[:space:]]/(var|srv)/?[[:space:]]' "$RUN/root/etc/fstab" && fstab_ok=0
srv_empty=1
[ -z "$(ls -A "$RUN/root/srv")" ] || srv_empty=0
devfile=0
[ -e "$RUN/root/etc/lvm/devices/system.devices" ] && devfile=1
var_kib=$(du -sx -k "$RUN/root/var" | cut -f1)
umount "$RUN/root"
[ "$fstab_ok" = 1 ] || finish "abort: fstab already mounts /var or /srv"
[ "$srv_empty" = 1 ] || finish "abort: /srv is not empty"
[ "$devfile" = 0 ] || finish "abort: an LVM devices file exists and would hide the new partition"
[ "$var_kib" -lt $((VAR_SIZE_MIB * 1024 / 2)) ] || finish "abort: /var uses ${var_kib} KiB"

e2fsck -f -n "$P1" >> "$LOG" 2>&1
rc=$?
[ "$rc" = 0 ] || finish "abort: read-only e2fsck rc=$rc"
min=$(resize2fs -P "$P1" 2>> "$LOG" | sed -n 's/^Estimated minimum size of the filesystem: //p')
[ -n "$min" ] && [ "$min" -lt $((ROOT_BLOCKS - 262144)) ] ||
    finish "abort: minimum root size is ${min:-unknown} blocks"
log "checks passed: min_blocks=$min var_kib=$var_kib"
[ "$MODE" = apply ] || finish "check complete: no change"

# Changes.
e2fsck -f -p "$P1" >> "$LOG" 2>&1
rc=$?
[ "$rc" -le 1 ] || finish "abort: e2fsck -p rc=$rc"
log "resize2fs start"
resize2fs "$P1" "$ROOT_BLOCKS" >> "$LOG" 2>&1 ||
    finish "FAILED: resize2fs. Check the root filesystem from the console."
blocks=$(dumpe2fs -h "$P1" 2> /dev/null | sed -n 's/^Block count: *//p')
[ "$blocks" = "$ROOT_BLOCKS" ] || finish "FAILED: root block count is $blocks after resize2fs"
e2fsck -f -n "$P1" >> "$LOG" 2>&1 || finish "FAILED: e2fsck after resize2fs"
log "resize2fs done"

sed -e "s#^P\([0-9]\)#${DISK}${PSEP}\1#" "$CONF_DIR/after.sfdisk" > "$RUN/after.input"
sfdisk --no-reread --no-tell-kernel --wipe never --wipe-partitions never "$DISK" < "$RUN/after.input" >> "$LOG" 2>&1 ||
    finish "FAILED: sfdisk. Check the partition table from the console."
blockdev --rereadpt "$DISK" >> "$LOG" 2>&1 ||
    finish "FAILED: partition table re-read. The new table applies at the next restart."
udevadm settle --timeout=60
table > "$RUN/after.sfdisk"
tr -s ' ' < "$CONF_DIR/after.sfdisk" | cmp -s - "$RUN/after.sfdisk" ||
    finish "FAILED: the written partition table differs from the expected table"
[ "$(blockdev --getsz "$P1")" = "$ROOT_SECTORS" ] || finish "FAILED: root partition size"
[ -b "$P2" ] || finish "FAILED: partition 2 is missing"
e2fsck -f -n "$P1" >> "$LOG" 2>&1 || finish "FAILED: e2fsck after the partition change"
log "partition table written"

wipefs -a "$P2" >> "$LOG" 2>&1 || finish "FAILED: wipefs"
lvm pvcreate --yes "$P2" >> "$LOG" 2>&1 || finish "FAILED: pvcreate"
lvm vgcreate "$VG" "$P2" >> "$LOG" 2>&1 || finish "FAILED: vgcreate"
# LVM creates its own device nodes, so these steps do not wait for udev.
LVM_NODES="activation { udev_sync = 0 udev_rules = 0 }"
lvm lvcreate --config "$LVM_NODES" --yes -W y -n var -L "${VAR_SIZE_MIB}m" "$VG" >> "$LOG" 2>&1 ||
    finish "FAILED: lvcreate var"
lvm lvcreate --config "$LVM_NODES" --yes -W y -n srv -l 100%FREE "$VG" >> "$LOG" 2>&1 ||
    finish "FAILED: lvcreate srv"
udevadm settle --timeout=60
[ -b "$LV_VAR" ] && [ -b "$LV_SRV" ] || finish "FAILED: logical volume nodes are missing"
mke2fs -q -F -t ext4 -U "$VAR_UUID" -L delta-var "$LV_VAR" >> "$LOG" 2>&1 || finish "FAILED: mke2fs var"
mke2fs -q -F -t ext4 -U "$SRV_UUID" -L delta-srv "$LV_SRV" >> "$LOG" 2>&1 || finish "FAILED: mke2fs srv"
log "volumes created"

mkdir -p "$RUN/var"
mount -t ext4 "$P1" "$RUN/root" || finish "FAILED: root mount"
mount -t ext4 "$LV_VAR" "$RUN/var" || {
    umount "$RUN/root"
    finish "FAILED: var mount"
}
TAR_OPTS="--xattrs --xattrs-include=* --acls --numeric-owner"
(
    cd "$RUN/root/var" && tar $TAR_OPTS --sparse -cpf - .
    echo $? > "$RUN/tar-create.rc"
) | (
    cd "$RUN/var" && tar $TAR_OPTS -xpf -
    echo $? > "$RUN/tar-extract.rc"
)
src=$(listing "$RUN/root/var")
dst=$(listing "$RUN/var")
copy_ok=0
if [ "$(cat "$RUN/tar-create.rc")" = 0 ] && [ "$(cat "$RUN/tar-extract.rc")" = 0 ] && [ "$src" = "$dst" ]; then
    copy_ok=1
    cp -p "$RUN/root/etc/fstab" "$RUN/root/etc/fstab.pre-delta-storage"
    printf 'UUID=%s\t/var\text4\tdefaults,discard\t0 2\nUUID=%s\t/srv\text4\tdefaults,discard,nodev,nosuid\t0 2\n' \
        "$VAR_UUID" "$SRV_UUID" >> "$RUN/root/etc/fstab"
fi
sync
umount "$RUN/var"
umount "$RUN/root"
[ "$copy_ok" = 1 ] || finish "FAILED: /var copy check. fstab is unchanged."
log "var copied: $src"
finish "apply complete"
