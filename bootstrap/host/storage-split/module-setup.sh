#!/bin/bash
# dracut module for the one-time root filesystem split.
# dracut includes it only through add_dracutmodules.

check() {
    return 255
}

depends() {
    echo lvm
    return 0
}

install() {
    inst_multiple sfdisk blockdev blkid wipefs e2fsck resize2fs mke2fs dumpe2fs \
        lvm tar find sort md5sum xargs du cut ls tr cmp sed cat date mount umount \
        mkdir rm cp sync udevadm
    inst_simple /etc/mke2fs.conf
    inst_simple "$moddir/delta-storage-migrate.sh" /usr/sbin/delta-storage-migrate
    inst_simple /etc/delta-storage/storage.conf
    inst_simple /etc/delta-storage/before.sfdisk
    inst_simple /etc/delta-storage/after.sfdisk
    inst_hook pre-mount 05 "$moddir/delta-storage-hook.sh"
}
