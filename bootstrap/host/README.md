# Initial host baseline

This document defines the host baseline before k3s installation.
The baseline covers administrator access, the hostname, the host firewall, operating-system maintenance, and recovery checks.
[HOSTING.md](../../HOSTING.md) defines the remaining host preparation and deployment work.
Ansible automation remains planned.
The [storage plan](STORAGE.md) requires separate `/var` and `/srv` filesystems before k3s installation.
Partition migration remains pending.

## Access and hostname

The administrator account is `delta`, with a home directory and membership in the `sudo` group.
SSH requires the administrator's key. Sudo requires the account password.
Keep the host address, hostname, and key location in a private inventory outside Git.
The OVH KVM console provides a separate recovery path.

`/etc/cloud/cloud.cfg.d/99-delta-hostname.cfg` preserves the selected hostname:

```yaml
preserve_hostname: true
```

The selected static hostname resolves to `127.0.1.1` through `/etc/hosts`.
The file can also retain provider hostname aliases.

`/etc/ssh/sshd_config.d/00-delta-access.conf` defines SSH authentication:

```text
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

Ubuntu reads this file before the cloud image's SSH configuration files.
An SSH reload requires a successful syntax check and inspection of the effective settings.

## Private management connection

A dedicated WireGuard connection links the home RB5009 router to the VPS.
The router interface is `wg-delta-ovh`. The VPS interface is `wg-delta`.
The approved home LAN can reach only TCP port 22 on the VPS management address through this connection.
SSH continues to require an authorized key on each administrator device.
The existing home VPN, DNS settings, default routes, and network isolation rules retain their configuration.

Each WireGuard peer has one management address.
Each peer's allowed address contains only the other peer's management address, with a `/32` prefix.
The VPS has separate router and desktop peers.
Keep peer addresses, public keys, the approved LAN range, and the VPS endpoint in the private inventory.
Keep private keys outside Git and public logs.

The VPS stores its configuration in `/etc/wireguard/wg-delta.conf`, owned by root with mode `0600`.
The parent directory has mode `0700`.
The `wg-quick@wg-delta.service` unit starts at boot, independently of Kubernetes.
The VPS listens on UDP port 51820.

### Router policy

The router starts the connection to the public VPS endpoint.
Its UDP listen port is 51823, and its keepalive interval is 25 seconds.
The interface MTU is 1420 bytes.
The existing firewall permits replies to the router's outbound connection without an additional public inbound allowance.
The management interface remains outside the router's `LAN` interface list.

Only the VPS management address has a host route through the management interface.
Both `main` and `wan2` contain this `/32` route, which preserves management access for devices with existing WAN routing policies.
The public VPS endpoint follows the current main Internet route.
Automatic failover between Internet connections is outside this configuration.

The router's `delta-ovh` firewall chain permits LAN SSH requests and their replies.
It blocks other forwarded tunnel traffic, including new connections from the VPS to the LAN.
Its forward-chain entry rules follow the existing network isolation checks and precede FastTrack.
The router translates permitted LAN SSH connections to its own management address.
The VPS requires no route to the home LAN.
Existing remote VPN clients are outside the approved source range.

Router objects use the comment prefix `delta-ovh:`.
The [RouterOS WireGuard documentation](https://manual.mikrotik.com/docs/virtual-private-networks/wireguard/) describes peer, route, and firewall configuration.

### Desktop recovery connection

NetworkManager retains the desktop's `wg-delta` profile for manual recovery.
The profile has `connection.autoconnect=no` and remains inactive during normal router access.
It uses `PersistentKeepalive = 25` when active.
The profile has `ipv4.never-default=yes`, no DNS entries, and IPv6 disabled on this dedicated interface.
Activating this profile routes only the VPS management address directly from the desktop through WireGuard.
Deactivating it returns management traffic to the router.

The [WireGuard quick start](https://www.wireguard.com/quickstart/) explains peer keys and keepalive behavior.
The [NetworkManager guide](https://blogs.gnome.org/thaller/2019/03/15/wireguard-in-networkmanager/) explains profile import and automatic connections.

The desktop's `delta` SSH alias selects the VPS management address.
Its `HostKeyAlias` selects the existing verified server identity from `known_hosts`.
Changing the destination does not require accepting an unverified host key.

## Host firewall

UFW starts at boot and filters IPv4 and IPv6 traffic.
`/etc/default/ufw` has `IPV6=yes`.

| Item | Policy |
|---|---|
| Incoming traffic | Deny by default. Standard UFW rules retain established traffic and required network control traffic. |
| Outgoing traffic | Allow by default. |
| Forwarded traffic | Deny. Kubernetes requires a separate review of this policy. |
| Public inbound service | UDP port 51820 for WireGuard, for both address families. |
| Private inbound service | TCP port 22 on `wg-delta`, from either approved peer address to the VPS management address. |
| Public SSH | No allowance for TCP port 22, for either address family. |
| Logging | UFW level `low`. |

The WireGuard allowance has the comment `WireGuard management`.
The desktop SSH allowance has the comment `Private SSH`.
The router SSH allowance has the comment `Router private SSH`.
WireGuard authenticates each peer without a fixed home public address.

## Operating-system maintenance

The host uses UTC and synchronized network time.
Ubuntu's `apt-daily.timer` and `apt-daily-upgrade.timer` units remain enabled.
The package configuration enables daily index updates and unattended security installation.
The allowed package origins retain Ubuntu's vendor defaults.
Automatic reboots remain disabled.
Required reboots use an operator-controlled maintenance window.

Keep Ubuntu package phasing enabled.
Phasing delays selected updates while Ubuntu checks their effect across installations.
Deferred non-security packages alone do not indicate a failed security upgrade.
Record installed versions, pending packages, and reboot evidence in private operator records.

### Package maintenance procedure

1. Check recovery-console access before package maintenance.
2. Save root-only configuration backups under `/root/delta-bootstrap-backups/`.
3. Include SSH, WireGuard, firewall, network, package, hostname, and boot configuration in those backups.
4. Protect backup contents as credentials.
5. Refresh package indexes.
6. Review an upgrade simulation, including package additions, removals, and deferred updates.
7. Apply eligible upgrades with package removals prohibited.
8. Preserve local configuration files unless a reviewed change requires replacement.
9. Run the upgrade through a system service that survives SSH interruption.
10. Save its package log and final service result in the private backup directory.
11. Check the service result if its client disconnects.
12. Check `dpkg --audit` and `apt-get check` after the upgrade.
13. Check an unattended-upgrade dry run.
14. Check pending security updates and reboot requirements.

The upgrade service's exit status and package log determine whether the transaction succeeded.
A disconnected client alone does not establish an upgrade failure.
Package updates can interrupt the SSH listener while an existing session remains connected.

Before ending the existing session:

1. Check SSH configuration with `sshd -t`.
2. Check that `ssh.socket` is active.
3. Test a new private SSH connection with connection sharing disabled.

### Controlled host restart

Before rebooting:

1. Check that package operations completed successfully.
2. Check bootloader configuration syntax with `grub-script-check`.
3. Check the selected kernel image and its initramfs, which contains the files needed during early startup.
4. Retain the previous working kernel.
5. Record the current boot identifier and kernel version.
6. Check recovery-console availability.

After rebooting:

1. Test a new private SSH connection through the router with the desktop recovery profile inactive.
2. Check that the boot identifier changed and the selected kernel runs.
3. Check SSH authentication, both WireGuard peers, management routes, and the firewall policy.
4. Check the hostname, hostname resolution, DNS, and network time synchronization.
5. Check package health, pending security updates, reboot requirements, and failed system services.
6. Test that public TCP ports 22, 80, and 443 remain blocked.
7. Save the results in private operator records.

Kubernetes readiness and persistent-volume checks require separate acceptance after k3s installation.
The [Ubuntu package guide](https://ubuntu.com/server/docs/how-to/software/package-management/) describes package maintenance.
The [automatic update guide](https://ubuntu.com/server/docs/how-to/software/automatic-updates/) describes unattended security updates and reboot controls.
The [phased update guide](https://ubuntu.com/server/docs/explanation/software/about-apt-upgrade-and-phased-updates/) explains deferred updates.

## Verification

Run these checks on the host:

```bash
sudo /usr/sbin/sshd -t
sudo /usr/sbin/sshd -T | grep -E '^(pubkeyauthentication|authenticationmethods|passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
systemctl is-active wg-quick@wg-delta.service
systemctl is-enabled wg-quick@wg-delta.service
sudo wg show wg-delta latest-handshakes
sudo ufw status verbose
sudo iptables -S INPUT
sudo ip6tables -S INPUT
grep '^ENABLED=' /etc/ufw/ufw.conf
```

Both INPUT chains must have policy `DROP`.
UFW must report `active`, and its boot configuration must have `ENABLED=yes`.
The explicit inbound rules must match the table above.
The WireGuard unit must report `active` and `enabled`.

Run these checks on the administrator's computer:

```bash
nmcli -g connection.autoconnect,ipv4.never-default,ipv4.dns,ipv6.method connection show wg-delta
ssh -S none -o BatchMode=yes -o StrictHostKeyChecking=yes delta 'printf "%s\n" "$SSH_CONNECTION"'
```

The desktop profile must show automatic connection disabled, no default route, no DNS entries, and IPv6 disabled.
Normal SSH connections must reach the VPS with the router's management address as their source.
The desktop recovery profile must remain inactive during this check.

Check the router's peer handshake, both management routes, firewall counters, and source translation counters.
Check that the management forwarding rules follow existing isolation rules and precede FastTrack.
Compare private configuration exports before and after changes, excluding only the tagged additions.
Check that the public VPS endpoint and other LAN destinations retain their normal routes.

Test a new SSH connection from the administrator's computer with connection sharing disabled.
Check that the server permits only public-key authentication.
Test a new TCP connection to port 22 through the public IPv4 address.
Check that the connection fails and UFW records the blocked packets.
Test another TCP port through the management address from the LAN.
Check that the router's tunnel drop counter increases.
Check that the VPS cannot start an SSH connection to the router's management address.
Test a temporary TCP listener on another port through the public IPv4 address.
Check local access to the listener before testing external access.
Check that UFW records the blocked external connection in the kernel log.
Remove the listener after the test.

Test the desktop recovery profile before changing the primary management route.
Use automatic desktop profile restoration while testing the router with the desktop profile inactive.
Cancel restoration only after a new router-mediated SSH connection and the blocking checks pass.
Test service and profile reconnection before relying on them for recovery.
Enabled services alone do not establish recovery after a complete host restart.

External IPv6 verification requires a public IPv6 address and an external IPv6 test client.
Configured IPv6 rules alone do not establish external IPv6 test coverage.

## Recovery and further configuration

Keep an authenticated session and the OVH KVM console available during firewall changes.
Save the existing firewall configuration before changing it.
The host stores these backups under `/root/delta-bootstrap-backups/`, with access restricted to root.

For activation from an inactive firewall, schedule a timed `ufw disable` command before enabling UFW.
Cancel the timer only after a new SSH connection and the external firewall test pass.
An existing active firewall requires a rollback that restores its previous policy.

Before removing bootstrap SSH access, schedule a five-minute rollback that restores its public TCP port 22 allowance.
Remove the allowance only after a new private SSH connection succeeds.
Cancel the rollback only after another private SSH connection succeeds and the public SSH test fails.
Check that both rollback units remain inactive.

Router changes require a five-minute rollback that removes only their tagged additions.
Check its complete script source and scheduled execution before applying router changes.
Cancel the rollback only after router-mediated SSH and traffic restriction checks pass.
Remove temporary rollback objects after cancellation.
RouterOS Safe Mode also covers changes from other login sessions, as the [configuration manual](https://manual.mikrotik.com/docs/getting-started/configuration-management/) explains.
A targeted rollback protects other operators' work.

Upload multiline RouterOS configuration as an inert `.rsc` file.
Check it with `/import file-name=<file> verbose=yes dry-run` before application.
The `dry-run` parameter is a flag without `=yes`.
Do not submit multiline blocks directly through SSH command mode.
Remove temporary imports after verification.

Private router configuration exports and approved scripts reside under `~/.local/state/delta-observatory/operator/router/` on the administrator's computer.
These exports omit private keys and do not replace a complete credential recovery procedure.

For desktop recovery, activate the retained profile:

```bash
nmcli connection up wg-delta
```

After router recovery, deactivate the desktop profile:

```bash
nmcli connection down wg-delta
```

If WireGuard fails, use the OVH KVM console to inspect its service, configuration, and firewall allowance.
Keep recovery credentials outside the VPS.
Do not expose SSH publicly as the permanent recovery procedure.

Do not apply this initial firewall policy to a running Kubernetes node.
The [k3s requirements](https://docs.k3s.io/installation/requirements) define additional network requirements.
Pod traffic, service traffic, forwarding, NodePorts, and Kubernetes firewall chains need separate rules and tests before k3s deployment.
Host INPUT rules alone do not establish Kubernetes network isolation.
