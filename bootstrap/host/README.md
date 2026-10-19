# Initial host baseline

This document defines the host baseline before k3s installation.
The baseline covers the administrator account, hostname, private SSH access, and host firewall.
[HOSTING.md](../../HOSTING.md) defines the remaining host preparation and deployment work.
Ansible automation remains planned.

## Access and hostname

The administrator account is `delta`, with a home directory and membership in the `sudo` group.
SSH requires the administrator's key. Sudo requires the account password.
Keep the host address, hostname, and key location in a private inventory outside Git.
The OVH KVM console provides a separate recovery path.

`/etc/cloud/cloud.cfg.d/99-delta-hostname.cfg` preserves the selected hostname:

```yaml
preserve_hostname: true
```

The static hostname and the `127.0.1.1` entry in `/etc/hosts` use the same name.

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

A dedicated WireGuard connection links the administrator's computer directly to the VPS.
The interface name is `wg-delta` on both hosts.
The firewall permits SSH only through this connection.
SSH continues to require the administrator's key.
This connection does not change the home router, LAN routes, default route, or DNS settings.

Each peer has one management address.
Each peer's `AllowedIPs` contains only the other peer's management address, with a `/32` prefix.
The host connection requires no forwarding or masquerading.
Keep peer addresses, public keys, and the VPS endpoint in the private inventory.
Keep private keys outside Git and public logs.

The VPS stores its configuration in `/etc/wireguard/wg-delta.conf`, owned by root with mode `0600`.
The parent directory has mode `0700`.
The `wg-quick@wg-delta.service` unit starts at boot, independently of Kubernetes.
The VPS listens on UDP port 51820.

NetworkManager stores and activates the desktop's `wg-delta` profile.
The profile starts automatically and uses `PersistentKeepalive = 25` for the connection through the home router.
The profile has `ipv4.never-default=yes`, no DNS entries, and IPv6 disabled on this dedicated interface.
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
| Private inbound service | TCP port 22 on `wg-delta`, from the approved peer address to the VPS management address. |
| Public SSH | No allowance for TCP port 22, for either address family. |
| Logging | UFW level `low`. |

The WireGuard allowance has the comment `WireGuard management`.
The private SSH allowance has the comment `Private SSH`.
WireGuard authenticates the administrator's device without a fixed home public address.

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
ip -4 route show dev wg-delta
ssh -S none -o BatchMode=yes -o StrictHostKeyChecking=yes delta
```

The profile must show automatic connection, no default route, no DNS entries, and IPv6 disabled.
Only the VPS management address must use the WireGuard route.
Check that the public VPS endpoint and home LAN retain their normal routes.

Test a new SSH connection from the administrator's computer with connection sharing disabled.
Check that the server permits only public-key authentication.
Test a new TCP connection to port 22 through the public IPv4 address.
Check that the connection fails and UFW records the blocked packets.
Test a temporary TCP listener on another port through the public IPv4 address.
Check local access to the listener before testing external access.
Check that UFW records the blocked external connection in the kernel log.
Remove the listener after the test.

Test a WireGuard service restart and a desktop profile reconnection before removing bootstrap SSH access.
Check a new private SSH connection after both restarts.
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

If WireGuard fails, use the OVH KVM console to inspect its service, configuration, and firewall allowance.
Keep recovery credentials outside the VPS.
Do not expose SSH publicly as the permanent recovery procedure.

Do not apply this initial firewall policy to a running Kubernetes node.
The [k3s requirements](https://docs.k3s.io/installation/requirements) define additional network requirements.
Pod traffic, service traffic, forwarding, NodePorts, and Kubernetes firewall chains need separate rules and tests before k3s deployment.
Host INPUT rules alone do not establish Kubernetes network isolation.
