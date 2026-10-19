# Root capacity isolation

The host requires root capacity isolation before k3s installation.
The host currently uses one ext4 root filesystem for `/`, `/var`, and `/srv`.
The target layout and migration remain pending.
The existing boot partitions retain their sizes and contents.

## Target layout

These sizes describe filesystem containers before filesystem metadata and reserved space.
One GiB equals 1,073,741,824 bytes.

| Mount or allocation | Proposed size | Contents |
|---|---:|---|
| `/` | 16 GiB | Operating-system files, configuration, and administrator homes. |
| `/var` | 20 GiB | Package state, logs, container images, container writable layers, and temporary Kubernetes data. |
| `/srv` | 32 GiB | Database volumes, artifacts, observations, catalog files, and protected operator backups. |
| Unallocated logical-volume capacity | Approximately 5.9 GiB | Capacity for later filesystem growth after review. |
| Existing boot partitions | Unchanged | Bootloader, kernel images, initramfs files, and EFI files. |

The root filesystem retains its existing partition, filesystem identity, and start sector.
Its reduced partition size releases space for one new partition.
The new partition contains an LVM volume group with separate logical volumes for `/var` and `/srv`.
LVM divides a storage device into volumes that can grow using unallocated capacity.
Only `/var` and `/srv` use this volume group.
No filesystem uses automatic volume growth.

The existing `/tmp` mount uses memory-backed storage.
`/var/tmp` belongs to the `/var` filesystem.
Administrator homes must not contain observations, container images, application caches, or unattended backups.
Capacity isolation does not prevent an administrator or privileged software from writing directly to `/`.

## Application paths and mount requirements

K3s runtime data remains under `/var/lib/rancher/k3s/`.
Kubelet data and container logs remain under `/var`.
The local persistent-volume provisioner must use `/srv/delta-observatory/volumes/`.
Controlled observations, catalog files, and cohort files remain under `/srv/delta-observatory/`.
These paths separate persistent application data from container images and logs.

Operator backups belong under `/srv/delta-observatory/operator-backups/`, with access restricted to root.
The existing `/root/delta-bootstrap-backups/` path can reference that protected directory after migration.
Keep a verified backup outside the VPS before changing its partition table.
Local backups on the same disk do not provide disk-failure protection.

Mount both filesystems by filesystem UUID.
Require both mounts during normal boot.
Do not use `nofail` for these mounts.
Require the mounts explicitly in the k3s service before its installation starts application processes.
Do not allow a missing mount to redirect application writes into the underlying root directories.
Disable automatic cloud-image root growth after establishing the custom partition layout.

A full `/var` can still stop system services and container workloads.
A full `/srv` can still stop database and artifact writes.
Their capacity boundaries preserve root free space against growth on those filesystems.
Configure bounded logs, filesystem alerts, and submission restrictions in addition to these boundaries.
Persistent-volume requests alone do not enforce capacity quotas with the local-path provisioner.

## Offline migration requirements

The ext4 root filesystem must be unmounted before shrinking it.
The [resize2fs manual](https://www.man7.org/linux/man-pages/man8/resize2fs.8.html) defines filesystem and partition resize ordering.
The [OVH rescue guide](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/rescue) describes booting a separate maintenance system.
Device names can change in rescue mode.
Identify the installed disk from its geometry, filesystem UUIDs, and partition identities before each write.

Before the rescue reboot:

1. Obtain approval for downtime and changes to the root partition.
2. Check recovery-console access and the rescue procedure.
3. Check how public SSH remains blocked while the separate rescue system runs.
4. Prepare private access to the rescue system through the console and the approved WireGuard connection.
5. Record disk geometry, partition identities, filesystem UUIDs, mount options, package versions, and access configuration in private operator records.
6. Prepare protected storage outside the VPS for its recovery image and checksums.
7. Check that no other operator has an active task on the host.

The installed host firewall does not protect a separate rescue system.
Check provider firewall coverage before relying on it during rescue boot.
Do not start migration without a working private rescue path and external recovery storage.

In rescue mode:

1. Check that the installed root filesystem remains unmounted.
2. Create a recoverable disk image outside the VPS before writing to the installed disk.
3. Check the saved image's checksum and its partition and filesystem metadata.
4. Check a read-only restoration of the required configuration and administrator files.
5. Run an offline filesystem check.
6. Shrink the filesystem below the proposed root partition size.
7. Reduce only the root partition's end sector.
8. Preserve its start sector, partition identity, and filesystem identity.
9. Grow the reduced filesystem to fill its 16 GiB partition.
10. Create the new LVM partition only within the released space.
11. Create the proposed logical volumes and ext4 filesystems.
12. Copy `/var` and `/srv` with numeric ownership, permissions, hard links, extended attributes, and access-control lists preserved.
13. Check file contents and metadata before removing the original copies from the underlying root filesystem.
14. Relocate protected operator backups to the `/srv` filesystem.
15. Configure required UUID mounts and the cloud-image growth policy.
16. Check the mount configuration, filesystem consistency, bootloader configuration, and recovery files.
17. Unmount the installed filesystems cleanly before returning to normal boot.

Do not restore only the old partition table after creating filesystems in the released space.
An incomplete rollback can expose overlapping filesystems.
Use the verified disk image for recovery when partition ownership becomes uncertain.

## Acceptance

1. Check separate filesystem identities for `/`, `/var`, and `/srv` after normal boot.
2. Check the proposed sizes and the remaining unallocated LVM capacity.
3. Check that `/tmp` retains its memory-backed mount.
4. Check that operator backups resolve to `/srv` and remain accessible only to root.
5. Check ownership and contents against the migration records.
6. Check private SSH, WireGuard, firewall rules, package health, time synchronization, and failed system services.
7. Check that the cloud-image growth policy preserves the partition layout.
8. Repeat the mount and access checks after another controlled host restart.

K3s acceptance must check reported filesystem capacities and disk-pressure behavior against the selected release.
Separate mounts alone do not prove correct Kubernetes storage accounting.
The [Kubernetes storage guide](https://kubernetes.io/docs/concepts/storage/ephemeral-storage/) defines supported temporary-storage layouts and their limits.
Check local persistent-volume placement before permitting application writes.
Keep all private images, inventories, checksums, and backup contents outside Git.
