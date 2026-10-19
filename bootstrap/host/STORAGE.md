# Root capacity isolation

The host keeps `/`, `/var`, and `/srv` on separate filesystems.
Growth in `/var` or `/srv` cannot consume root free space.
The boot partitions keep their original sizes and contents.

## Layout

One GiB equals 1,073,741,824 bytes.

| Mount | Device | Size | Contents |
|---|---|---:|---|
| `/` | Partition 1, ext4 | 16 GiB | Operating-system files, configuration, and administrator homes. |
| `/var` | LVM volume `delta/var`, ext4 | 16 GiB | Package state, logs, container images, container writable layers, and temporary Kubernetes data. |
| `/srv` | LVM volume `delta/srv`, ext4 | All remaining capacity, approximately 41.9 GiB | Database volumes, artifacts, observations, catalog files, and protected operator backups. |
| `/boot`, `/boot/efi`, BIOS boot | Partitions 13, 15, and 14 | Unchanged | Bootloader, kernel images, initramfs files, and EFI files. |

The root partition keeps its original start sector, partition identity, and filesystem identity.
Partition 2 fills the space after the root partition. It is the only physical volume in the LVM volume group `delta`.
LVM divides a storage device into logical volumes.
The volume group has no free capacity reserve.
No filesystem uses automatic volume growth.

`/tmp` uses memory-backed storage.
`/var/tmp` belongs to the `/var` filesystem.
Administrator homes must not contain observations, container images, application caches, or unattended backups.
Capacity isolation does not prevent an administrator or privileged software from writing directly to `/`.

## Mounts

`/etc/fstab` mounts `/var` and `/srv` by filesystem UUID.
`/var` uses `defaults,discard`.
`/srv` uses `defaults,discard,nodev,nosuid`.
Normal boot requires both mounts. Do not use `nofail` for these mounts.
Require the mounts explicitly in the k3s service before k3s starts application processes.
Do not allow a missing mount to redirect application writes into the underlying root directories.

`/etc/cloud/cloud.cfg.d/99-delta-storage.cfg` stops cloud-init from growing the root partition or filesystem:

```yaml
growpart:
  mode: "off"
resize_rootfs: false
```

## Application paths

K3s runtime data stays under `/var/lib/rancher/k3s/`.
Kubelet data and container logs stay under `/var`.
The local persistent-volume provisioner must use `/srv/delta-observatory/volumes/`.
Controlled observations, catalog files, and cohort files stay under `/srv/delta-observatory/`.
These paths separate persistent application data from container images and logs.

Operator backups are in `/srv/delta-observatory/operator-backups/`, with access restricted to root.
`/root/delta-bootstrap-backups` is a symbolic link to that directory.
Local backups on the same disk do not provide disk-failure protection.

A full `/var` can still stop system services and container workloads.
A full `/srv` can still stop database and artifact writes.
Configure bounded logs, filesystem alerts, and submission restrictions in addition to these boundaries.
Persistent-volume requests alone do not enforce capacity quotas with the local-path provisioner.

## Split procedure

Linux cannot shrink a mounted ext4 filesystem.
The [storage-split](storage-split/) dracut module does the split during a normal restart, before the initramfs mounts `/`.
The initramfs is the temporary system that starts before the root filesystem.
This procedure does not use provider rescue mode, so the installed firewall and WireGuard access stay in effect.

The module acts only when `/boot/delta-storage/mode` contains `check` or `apply`.
It deletes that file before any other step, so each request runs one time.
It writes its log to `/boot/delta-storage/last-run.log` and to the kernel log with the prefix `delta-storage:`.

Both modes make these checks without writing to the disk:

1. The partition table equals the expected table.
2. The root filesystem UUID equals the expected UUID.
3. Partition 2 and the volume group do not exist.
4. The fstab does not mount `/var` or `/srv`, and `/srv` is empty.
5. No LVM devices file exists.
6. A read-only `e2fsck` is clean, and the minimum root size is at least 1 GiB below the target.

The `apply` mode then makes these changes:

1. Shrink the root filesystem to 16 GiB with `resize2fs`.
2. Reduce the end sector of partition 1, and create partition 2 in the released space.
3. Create the `delta` volume group and the `var` and `srv` logical volumes.
4. Create ext4 filesystems with the UUIDs from the host configuration.
5. Copy `/var` with numeric ownership, permissions, hard links, extended attributes, and access-control lists.
6. Compare names, types, modes, owners, link targets, and file contents of both copies.
7. Add the two fstab entries after the comparison passes.

A failure before step 7 leaves the original fstab, so the host starts with `/var` on the root filesystem.
A failure during step 1 or step 2 can stop the restart. Use the OVH KVM console and the off-host backup for recovery.

To run the procedure:

1. Copy the root filesystem, the boot area, and the partition table to protected storage outside the VPS.
2. Rehearse `apply` on a loop device with changed identifiers.
3. Delete all rehearsal devices. Make sure that no LVM devices file exists.
4. Install the host configuration in `/etc/delta-storage/`, based on [storage.conf.example](storage-split/storage.conf.example).
5. Install the expected partition tables as `before.sfdisk` and `after.sfdisk` in the same directory.
6. Install the module in `/usr/lib/dracut/modules.d/95delta-storage/`.
7. Add `add_dracutmodules+=" delta-storage "` to `/etc/dracut.conf.d/90-delta-storage.conf`, and rebuild the initramfs.
8. Write `check` to the mode file, restart, and read the log.
9. Write `apply` to the mode file, restart, and read the log.
10. Check the acceptance items.
11. Delete the old `/var` files under the root filesystem through a bind mount of `/`.
12. Delete the module, the dracut configuration, and `/etc/delta-storage/`. Then rebuild the initramfs.

Keep the host configuration, partition tables, backup images, and checksums outside Git.

## Acceptance

1. `/`, `/var`, and `/srv` have separate filesystem identities and the sizes in the layout table.
2. `/tmp` keeps its memory-backed mount.
3. Operator backups resolve to `/srv` and are accessible only to root.
4. Private SSH, WireGuard, firewall rules, time synchronization, and system services pass their checks.
5. Public TCP ports 22, 80, and 443 do not accept connections.
6. The initramfs does not contain the storage-split module.
7. The mounts and access checks pass again after another controlled restart.

K3s acceptance must check reported filesystem capacities and disk-pressure behavior against the selected release.
Separate mounts alone do not prove correct Kubernetes storage accounting.
The [Kubernetes storage guide](https://kubernetes.io/docs/concepts/storage/ephemeral-storage/) defines supported temporary-storage layouts and their limits.
Check local persistent-volume placement before permitting application writes.

## Provider rescue mode

Do not use provider rescue mode for maintenance that a restart procedure can do.
The installed host firewall does not protect a separate rescue system.
If rescue mode becomes necessary, keep the original SSH service available until its replacement passes a new private connection test.
The [provider's regular restart action](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/understand-vps-control-panel#rebootvps) `Reboot my VPS` returns the host to normal boot.
A restart inside the rescue operating system can keep rescue mode.
Check the provider boot mode after the restart.
