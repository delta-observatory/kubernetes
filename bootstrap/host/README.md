# Initial host baseline

This document defines the host baseline before k3s installation.
The baseline covers the administrator account, hostname, SSH authentication, and host firewall.
[HOSTING.md](../../HOSTING.md) defines the remaining host preparation and deployment work.
Ansible automation and private administrative access remain planned.

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

## Host firewall

UFW starts at boot and filters IPv4 and IPv6 traffic.
`/etc/default/ufw` has `IPV6=yes`.

| Item | Policy |
|---|---|
| Incoming traffic | Deny by default. Standard UFW rules retain established traffic and required network control traffic. |
| Outgoing traffic | Allow by default. |
| Forwarded traffic | Deny. Kubernetes requires a separate review of this policy. |
| Explicit inbound service | TCP port 22 for SSH, for both address families. |
| Logging | UFW level `low`. |

The SSH allowance has the comment `SSH bootstrap access`.
Public SSH remains available until a private administrative route passes its access and recovery checks.
This baseline does not require a fixed administrator address or a connection to the home LAN.

## Verification

Run these checks on the host:

```bash
sudo /usr/sbin/sshd -t
sudo /usr/sbin/sshd -T | grep -E '^(pubkeyauthentication|authenticationmethods|passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
sudo ufw status verbose
sudo iptables -S INPUT
sudo ip6tables -S INPUT
grep '^ENABLED=' /etc/ufw/ufw.conf
```

Both INPUT chains must have policy `DROP`.
UFW must report `active`, and its boot configuration must have `ENABLED=yes`.
The explicit inbound rules must allow only TCP port 22 for IPv4 and IPv6.

Test a new SSH connection from the administrator's computer with connection sharing disabled.
Check that the server permits only public-key authentication.
Test a temporary TCP listener on another port through the public IPv4 address.
Check local access to the listener before testing external access.
Check that UFW records the blocked external connection in the kernel log.
Remove the listener after the test.

External IPv6 verification requires a public IPv6 address and an external IPv6 test client.
Configured IPv6 rules alone do not establish external IPv6 test coverage.

## Recovery and further configuration

Keep an authenticated session and the OVH KVM console available during firewall changes.
Save the existing firewall configuration before changing it.
The host stores these backups under `/root/delta-bootstrap-backups/`, with access restricted to root.

For activation from an inactive firewall, schedule a timed `ufw disable` command before enabling UFW.
Cancel the timer only after a new SSH connection and the external firewall test pass.
An existing active firewall requires a rollback that restores its previous policy.

Do not apply this initial firewall policy to a running Kubernetes node.
The [k3s requirements](https://docs.k3s.io/installation/requirements) define additional network requirements.
Pod traffic, service traffic, forwarding, NodePorts, and Kubernetes firewall chains need separate rules and tests before k3s deployment.
Host INPUT rules alone do not establish Kubernetes network isolation.
