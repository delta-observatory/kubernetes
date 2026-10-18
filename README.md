# Delta Observatory deployment

This repository holds the k3s manifests for the Delta Observatory components on a single k3s node.
Manifests are applied with `kubectl`. No GitOps controller and no image registry are involved.

```text
LAN ──► NodePort 30871 ──► Service delta-frontend ──► Deployment delta-frontend (nginx, static files)
                                                          │ /api/
                                                          ▼
LAN ──► NodePort 30870 ──► Service delta-api ──► Deployment delta-api (stateless)
                                                     │ reads rows, and experiments/cohorts.json (host path, read-only)
                                                     ▼
              Cluster delta-db (CloudNativePG) ◄── rows ──► Deployment delta-worker
                                                     ▲            │ reads raw/, datasets/ (host paths, read-only)
                                                     │            ▼ writes
                                   PVC delta-artifacts ◄──────────┘
```

- Namespace: `delta-observatory`
- Frontend: `http://<node>:30871/`, where `<node>` is the node address on the LAN. nginx sends `/api/` to the `delta-api` Service.
- API: `http://<node>:30870/api/docs` on the LAN. The API needs a bearer token. No ingress or TLS.
- Database: CNPG cluster `delta-db`, database and owner `delta`. CNPG creates the Secret `delta-db-app`.
- Images: `localhost/delta-<component>:<tag>`, built in the cluster by kaniko, `imagePullPolicy: Never`.

## Files

| File | Content |
|---|---|
| `base/namespace.yaml` | Namespace. |
| `base/database.yaml` | CNPG `Cluster` with one instance on `local-path` storage. |
| `base/storage.yaml` | `delta-artifacts` PVC for artifact files. |
| `base/worker.yaml` | Worker Deployment. Mounts `raw/` and `datasets/` read-only and the artifact PVC read-write. |
| `base/api.yaml` | API Deployment and NodePort Service. Mounts the artifact PVC and `experiments/` read-only. The cohort guard reads `experiments/cohorts.json`. |
| `base/frontend.yaml` | Frontend Deployment and NodePort Service 30871. No volumes except temporary nginx directories. |
| `base/kustomization.yaml` | Resources, environment ConfigMaps, and the selected image tags. |
| `builds/build-image.template.yaml` | kaniko build Job template. Not in the kustomization. |
| `builds/migrate.template.yaml` | Migration Job template. Not in the kustomization. |
| `builds/rehearse.template.yaml` | Migration rehearsal Job template for a copy of the database. Not in the kustomization. |
| `scripts/build.sh` | Builds one component image and prints its tag. |
| `scripts/migrate.sh` | Applies migrations from one database image. |
| `scripts/backup.sh` | Writes a logical dump of the database and its SHA-256 to `~/backups/delta-observatory/`. |
| `scripts/rehearse.sh` | Applies the migrations of one database image to a copy of the newest dump, then drops the copy. |
| `scripts/set-tag.sh` | Selects one component tag in `base/kustomization.yaml`. |

The worker and the API mount `local-path` volumes and host paths on one node.
A second node needs a different storage arrangement.

## Release

```bash
cd kubernetes
DB=$(scripts/build.sh database)
WORKERS=$(scripts/build.sh workers)
BACKEND=$(scripts/build.sh backend)
FRONTEND=$(scripts/build.sh frontend)
scripts/set-tag.sh database "$DB"
scripts/set-tag.sh workers "$WORKERS"
scripts/set-tag.sh backend "$BACKEND"
scripts/set-tag.sh frontend "$FRONTEND"
kubectl apply -k base
kubectl -n delta-observatory wait cluster/delta-db --for=condition=Ready --timeout=10m
scripts/backup.sh
scripts/migrate.sh "$DB"
kubectl -n delta-observatory rollout status deploy/delta-worker deploy/delta-api deploy/delta-frontend --timeout=5m
```

The worker reads its version from the `delta-versions` ConfigMap at startup. The ConfigMap has a fixed name, so a frontend or backend release does not restart the worker.
A worker release restarts the worker, and a restart returns a running job to the queue. Check `GET /api/runs` for running jobs before a worker release.
The build context is the live working tree of each component repository, including uncommitted edits.
Commit each component before a release that you want to reproduce.

## Backup and migration

The CNPG cluster has no scheduled backup. `scripts/backup.sh` writes a logical dump of the `delta` database before each migration.
The dump goes to `~/backups/delta-observatory/` on the node, outside every repository, with its SHA-256.
`migrate.sh` in the database image applies each migration in its own transaction under an advisory lock. A failed migration leaves no change.

Rehearse a new migration on a copy of the live records before the release:

1. Restore the newest dump into a separate database: `scripts/rehearse.sh <database-image-tag>`.
2. The script runs the migration image against the copy, prints the migration list and row counts, and drops the copy.

Restore a dump after a failed release only after the API and the worker are stopped:

```bash
kubectl -n delta-observatory scale deploy/delta-api deploy/delta-worker --replicas=0
kubectl -n delta-observatory exec -i delta-db-1 -c postgres -- pg_restore -U postgres -d delta --clean --if-exists --no-owner --role=delta < ~/backups/delta-observatory/<dump>
```

Then select the earlier image tags and apply the manifests again.
A restore removes records that clients wrote after the dump. Artifact files on the PVC stay.

## Checks

```bash
kubectl -n delta-observatory get cluster,pods,pvc
curl -s http://localhost:30870/api/health
curl -s http://localhost:30871/healthz
kubectl -n delta-observatory logs deploy/delta-worker --tail=50
```
