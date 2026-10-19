# Hosting plan

This plan targets an independent Delta Observatory installation on the OVH VPS in Hillsboro, Oregon.
The selected host has four virtual CPUs, 8 GB RAM, and 75 GB NVMe storage.
Ubuntu 26.04 is the selected operating system.
The home installation remains the private environment for large scientific workloads.

This document defines planned work. The repository currently deploys the home installation through the commands in [README.md](README.md).
The [host playbook](bootstrap/host/README.md#ansible) prepares the VPS and installs k3s.
No cloud application deployment or Flux configuration exists here yet.

The [initial host baseline](bootstrap/host/README.md) defines configured access, firewall controls, operating-system maintenance, and restart checks.
Administrative SSH normally uses the RB5009 router's dedicated WireGuard connection outside Kubernetes.
The desktop retains a separate WireGuard profile for manual recovery.
The host uses synchronized UTC, daily unattended security updates, and controlled reboots.
The journal has a size limit, and k3s limits container logs.
k3s `v1.36.5+k3s1` runs as one server without Traefik or ServiceLB.
The Kubernetes API is reachable only through the WireGuard management connection.
SSH, firewall, Kubernetes readiness, DNS, and persistent-volume checks pass after a complete host restart.
The [storage layout](bootstrap/host/STORAGE.md) keeps `/`, `/var`, and `/srv` on separate filesystems.

## Deployment decisions

| Item | Decision | Reason |
|---|---|---|
| Kubernetes distribution | One k3s server node | Matches the existing application and limits control-plane overhead. |
| Deployment repository | This `kubernetes` repository | Keeps desired deployment state beside the existing manifests. |
| GitOps controller | Flux | Applies repository changes and reports differences from the desired state. |
| Host preparation | Ansible, with a minimal initial SSH setup | Keeps operating-system configuration repeatable and independent of Kubernetes. |
| Administrative access | Router WireGuard connection, SSH keys, and a manual desktop recovery connection | Keeps public SSH closed and recovery independent of Kubernetes. |
| Database | One CloudNativePG PostgreSQL instance | Preserves the database contracts and PostgreSQL job queue. |
| Application | Existing frontend, API, and worker images | Preserves one maintained application across both installations. |
| Storage | Node-local persistent volumes | Fits one host without a distributed storage service. |
| Root capacity isolation | Separate `/var` and `/srv` filesystems | Keeps logs, containers, and application data from consuming root free space. |
| Application access | Cloudflare Tunnel and Cloudflare Access | Provides an authenticated entry without public application ports on the host. |
| Continuous integration | Standard GitHub-hosted Linux runners | Tests and image builds use public repository runner allowances. |
| Image distribution | GHCR images pinned by digest | Gives the host reproducible images without building source on the VPS. |

GitOps means that the cluster regularly applies its declared state from Git.
A digest identifies the exact image content.
Flux controls Kubernetes resources. Ansible controls the host, SSH, firewall, directories, and k3s installation.
The host must remain recoverable when Kubernetes cannot start.

The VPS is a single failure domain.
Host maintenance and host failure interrupt the application.
One PostgreSQL instance and node-local volumes provide persistence, but they do not provide high availability.

## Repository layout

The proposed layout is:

```text
bootstrap/host/                  # Ansible playbook, templates, example inventory
clusters/ovh-production/         # Flux entry point and deployment dependencies
infrastructure/controllers/     # CloudNativePG and supporting controllers
infrastructure/ovh-production/   # Storage, network policy, tunnel, backup configuration
apps/delta-observatory/base/     # Environment-independent application resources
apps/delta-observatory/overlays/ovh-production/
```

Keep `base/`, `builds/`, and the existing release scripts operational for the home installation during implementation.
Extract shared resources only after rendered comparisons prove that the home deployment remains equivalent.
Do not point the cloud cluster at the existing `base/` directory.
Its NodePorts, host paths, local images, and volume sizes need separate cloud configuration.
A future home Flux entry point requires a separate migration decision.

This repository is public.
Keep credentials, private inventories, scientific records, observations, and backup contents outside Git.
Commit only secret references and example values.
Initially, install secrets through a local operator procedure using a password manager.
Document each secret's owner, destination, rotation procedure, and recovery source without recording its value.
Encrypted Git secrets can be a separate change if secret maintenance becomes difficult.

## Host preparation

Complete these steps before the first application deployment:

1. Record the host identifier, address, selected operating system, and recovery-console procedure in private operator records.
2. Check the installed operating system, CPU architecture, RAM, usable disk capacity, kernel, and cgroup support.
3. Check the selected k3s release against Ubuntu 26.04 and its release notes.
4. Pin the tested k3s version in the host configuration.
5. Create an administrator account with SSH key authentication and sudo access.
6. Test a second SSH session and the OVH recovery console.
7. Disable SSH password authentication and direct root SSH access.
8. Restrict SSH to the approved WireGuard peers after testing private access and recovery.
9. Configure equivalent IPv4 and IPv6 firewall rules.
10. Apply operating-system security updates and configure time synchronization.
11. Retain daily security installation and use a controlled maintenance window for required reboots.
12. Create application data directories with explicit ownership and permissions.
13. Configure bounded system and container logs.
14. Install k3s from the pinned release through the host playbook.
15. Test host restart, SSH recovery, Kubernetes readiness, DNS, and persistent volume access.

Keep provider-console access available while changing SSH or firewall rules.
WireGuard device authentication permits a changing administrator public address.
Permit public UDP port 51820 for WireGuard and keep public TCP port 22 closed.
The implementation must test firewall forwarding rules with Kubernetes networking.
A generic host firewall policy alone does not prove that container ports are private.

Disable bundled Traefik and ServiceLB because the planned entry uses a tunnel.
Retain CoreDNS, local-path storage, and metrics-server.
Use the default SQLite datastore for this single k3s server.
Keep the Kubernetes API private through an SSH tunnel or the administrative VPN.
Protect kubeconfig files and the k3s server token as credentials.

Allow required outbound DNS, time synchronization, package downloads, image downloads, Git access, and Cloudflare Tunnel traffic.
Do not expose PostgreSQL, NodePorts, kubelet, the Kubernetes API, or Flannel ports to the Internet.
The application requires no public inbound HTTP or HTTPS port on the VPS.
Check these restrictions from a separate Internet connection.

The [k3s requirements](https://docs.k3s.io/installation/requirements) describe kernel, resource, and network prerequisites.
Their resource minimums exclude application workloads.

## Application and data preparation

Replace cloud NodePort Services with ClusterIP Services.
Replace `localhost` images and `imagePullPolicy: Never` with registry images and a suitable pull policy.
Pin the frontend, API, worker, database migration image, PostgreSQL image, and controller versions.
Keep the API stateless and retain PostgreSQL as the queue.
Do not add direct API calls to workers.

Use `/srv/delta-observatory/` for controlled host inputs.
Keep observations under `raw/<dataset-id>/` with the exact catalog dataset ID.
Provide separate catalog and cohort directories through explicit read-only mounts.
Keep artifacts on a persistent volume that workers can write and the API can only read.
Use explicit directory creation rather than silently creating missing input directories from pod manifests.

Start with one worker and one concurrent scientific job.
Keep bulk processing on the home installation.
The cloud installation has its own database, credentials, queue, and data inventory.
Do not share the home database or assume that host-local paths exist on the VPS.

Select the initial cloud data before deployment.
Transfer only an approved, bounded collection with its catalog metadata, checksums, provenance, and cohort configuration.
An empty database is acceptable until that collection is ready.
A database import requires matching artifacts and input references.
Do not copy the entire home installation merely to populate the cloud interface.

## Capacity limits

These figures are initial planning budgets, not measured application requirements.
Check actual usable capacity before assigning persistent volumes.
The [storage layout](bootstrap/host/STORAGE.md) defines the host filesystems and application paths.

| RAM allocation | Initial budget |
|---|---:|
| Operating system, k3s, controllers, tunnel, and reserve | 3 GB |
| PostgreSQL | 1 GB |
| API and frontend | 1 GB |
| One worker | 2 GB |
| Unassigned headroom | 1 GB |

Set resource requests and limits from a representative workload test.
Preserve CPU capacity for PostgreSQL, the API, and cluster services during worker execution.
Reduce worker concurrency or job size if memory pressure occurs.
Do not use swap as a substitute for sufficient worker memory.

| Disk allocation | Size |
|---|---:|
| Root filesystem | 16 GiB |
| `/var`, including k3s runtime files, images, and logs | 16 GiB |
| `/srv`, including persistent application data and local backups | All remaining usable capacity, approximately 41.9 GiB |
| Existing boot partitions | Approximately 1.1 GiB |

Within `/srv`, budget 10 GiB for PostgreSQL, including WAL.
Budget 8 GiB each for artifacts and selected inputs with their metadata.
Budget 2 GiB for temporary backup and release files.
The remaining capacity covers filesystem overhead and free space.
These budgets do not enforce directory quotas.
Remote backup storage remains separate.

Persistent volume requests do not enforce filesystem quotas with the default local-path provisioner.
Monitor actual disk use across all directories.
Warn at 70% disk use and stop new scientific submissions at 80% until capacity recovers.
Implement the submission restriction explicitly before treating it as an operating safeguard.
Never delete referenced observations or artifacts automatically to recover space.
Retain bounded logs and delete unused images through a documented maintenance procedure.

## Access and credentials

Route the selected hostname through Cloudflare Access and Tunnel to the frontend Service.
The frontend continues to proxy `/api/` to the API Service.
Require an explicit invitation policy at Cloudflare Access.
Require a separate application credential for each person, with read-only permissions by default.
Cloudflare authentication does not replace application authorization.

Keep administrative credentials separate from browser credentials.
Give automated API or MCP clients separate service identities and the minimum application permissions.
Test service authentication independently from the browser login flow.
Do not create an unauthenticated hostname to bypass automated-client login problems.

Test anonymous denial, invited access, read-only write denial, credential revocation, and direct-origin denial before inviting users.
Check that URLs, browser bundles, logs, and Git contain no credentials.

## GitOps bootstrap and releases

Generate and review Flux manifests locally before bootstrap.
Use `clusters/ovh-production/` as the only cloud reconciliation entry point.
The [Flux GitHub bootstrap procedure](https://fluxcd.io/flux/installation/bootstrap/github/) can write repository commits and install cluster resources.
Run bootstrap only as part of an explicitly requested deployment.
Prefer read-only repository access for the running controller.
Keep image automation disabled initially.

Configure dependency stages for controllers, storage and database, migrations, and application workloads.
Use readiness checks and version-specific migration Jobs.
The [Flux Kustomization reference](https://fluxcd.io/flux/components/kustomize/kustomizations/) describes dependencies, health checks, suspension, and deletion controls.
A release must wait for its own migration Job, not a previous successful Job.
Protect namespaces, database resources, and persistent volumes from automatic deletion when Git resources disappear.
Test those deletion controls in a disposable environment.

Build images from committed component sources through GitHub Actions.
Do not build images from live working trees on the VPS.
Record source commits, image digests, contract versions, and migration requirements for each release.
Update the cloud overlay through one reviewed deployment change.
A merge to the watched branch becomes deployment authorization only after Richard explicitly enables this operating policy.

For each database-changing release:

1. Check compatibility between the current application and the proposed schema.
2. Create a coordinated database and artifact backup.
3. Rehearse migrations against a restored database copy.
4. Stop new writes and drain workers if the migration requires downtime.
5. Run the release-specific migration Job.
6. Deploy compatible API, worker, and frontend images after migration success.
7. Check application health and one bounded job through the PostgreSQL queue.
8. Resume writes after the checks pass.

Prefer schema changes that support both old and new application versions during deployment.
A Git revert changes desired images and configuration. It does not reverse database migrations.
Use an earlier image only when it supports the current schema.
Otherwise, restore the coordinated backup with writers stopped and Flux reconciliation suspended.
Document the records that a restore would delete before executing it.

## GitHub Actions and Flux workflow

This workflow is planned, not implemented.
GitHub Actions performs continuous integration: tests, configuration checks, and image builds.
Flux performs continuous deployment by applying the selected configuration from this repository.
GitHub hosts the build runners. The VPS runs Flux and the application.

1. Run component tests on pull requests and pushes to `main`.
2. Build images only after the required tests pass on trusted `main` commits or release tags.
3. Publish the four component images to GHCR with source commit metadata.
4. Open a deployment pull request in `kubernetes/` with the exact image digests.
5. Check rendered manifests, image availability, contract compatibility, and migration ordering in that pull request.
6. Merge the deployment pull request after its checks and release review pass.
7. Let Flux apply the cloud configuration through the dependency stages described above.
8. Check migration completion, application readiness, and the deployed image digests.

A component image upload does not select that image for deployment.
The deployment pull request selects a compatible release set.
Use commit tags for development images and version tags for releases.
Use digests in deployment manifests because tags can change.
Keep deployment pull requests subject to review initially.
Automatic merges require a separate operating decision.

Give build workflows only the repository and package permissions that they need.
Use the repository's `GITHUB_TOKEN` to publish its images.
Use a narrowly scoped GitHub App token to open deployment pull requests across repositories.
Configure that App only for the required repositories and pull request operations.
Ensure its deployment pull requests start the required checks.
Keep publication credentials unavailable to untrusted pull request code.
Pin third-party Actions to full commit hashes.

GitHub runners need no host SSH keys, kubeconfig, or Kubernetes API access.
Flux reads the deployment repository from inside the cluster.
Do not install a build runner on the production VPS.
Keep scientific records and private research inputs outside public workflow logs, artifacts, caches, and images.

### Free service usage

The plan targets no additional CI/CD service charge under the current free allowances.
The VPS, domain, and remote backup storage remain separate costs.
Flux has no software licence charge.

| Service | Free usage condition |
|---|---|
| GitHub Actions compute | Standard GitHub-hosted runners in public repositories are free. Larger runners incur charges. |
| Private repository workflows | Hosted runner usage must remain within the organization's included allowance. |
| GHCR | Container image storage and bandwidth are currently free. |
| Actions artifacts and caches | Retention and usage must remain within the applicable free storage allowances. |

The [Actions billing documentation](https://docs.github.com/en/billing/concepts/product-billing/github-actions) defines runner and storage allowances.
The [Packages billing documentation](https://docs.github.com/en/billing/concepts/product-billing/github-packages) describes the current GHCR policy.
The [Flux documentation](https://fluxcd.io/flux/) describes the deployment controller.
These service policies can change.

Use standard Linux runners for the public application repositories.
Keep the research repositories private.
Set short retention for test artifacts and bounded cache use.
Configure billing controls to block paid usage where GitHub supports that control.
Check organization billing settings before enabling workflows.
Do not treat free runner compute as unlimited free artifact storage.

## Backup and recovery

The provider's daily backup is supplementary recovery coverage.
It does not replace a tested database and artifact backup.
Store encrypted application backups outside this VPS and outside its local disk.
Select the destination, credentials, and retention before admitting persistent user data.

Start with daily coordinated backups and backups before database migrations.
Retain seven daily copies and four weekly copies, subject to measured storage cost.
The initial recovery objective permits up to 24 hours of data loss between successful backups.
Measure recovery duration through a restore exercise before promising a recovery time.

Stop or drain writers while capturing each coordinated backup.
Include PostgreSQL, artifacts, selected input manifests, required catalog files, cohort configuration, and release identifiers.
Preserve source observations remotely or document a tested checksum-verified reacquisition procedure.
Record file checksums.
Check remote upload completion.
Keep encryption keys and secret recovery material in a separate protected location.

Back up the k3s datastore and server token through a procedure appropriate for SQLite.
Keep these backups separate from application backups.
A Git checkout alone cannot recover database records, persistent files, or secrets.

Test restoration into an isolated namespace or replacement host before opening access.
Check record counts, artifact hashes, input references, authentication, and a bounded worker job.
Prevent the restored environment from accepting production traffic or consuming the production queue.
Repeat the restore exercise after material storage or backup changes.

## Implementation order and completion checks

| Stage | Deliverable | Completion check |
|---|---|---|
| 1. Host | Ansible preparation and private inventory | SSH recovery, firewall checks, restart, and k3s readiness pass. |
| 2. Images | Registry builds and pinned release metadata | A clean host can pull every selected image. |
| 3. Cloud configuration | Cloud overlay and controlled input directories | Rendering shows no home paths, local images, or public NodePorts. |
| 4. GitOps | Flux entry point and protected persistent resources | Reconciliation, dependency ordering, and deletion protection pass. |
| 5. Recovery | Remote encrypted backups and restore procedure | An isolated restore passes the application checks. |
| 6. Access | Tunnel, invitation policy, and individual credentials | Anonymous access and unauthorized writes fail. |
| 7. Operations | Alerts, maintenance procedure, and bounded workload evidence | Host restart and a representative job preserve records and artifacts. |

Monitor host availability, disk capacity, memory pressure, pod restarts, database readiness, Flux failures, and backup age.
Alert when no successful remote backup exists within 26 hours.
Use lightweight checks first. Add a larger metrics stack only when measurements justify its resource cost.
Test upgrades on a disposable environment before changing k3s, PostgreSQL, or CloudNativePG.

Implementation needs the hostname, administrator access details, backup destination, and initial data selection.
Keep private values outside this public document.
This plan does not authorize repository pushes, host changes, or deployment.
