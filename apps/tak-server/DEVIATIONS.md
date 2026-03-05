# TAKServer on Kubernetes — Deviations & Workarounds

The upstream TAKServer distribution (`takserver-docker-hardened-5.5-RELEASE-45`) was
designed for Docker Compose on a single host. This document captures every deviation
from the upstream deployment that was required to make it work on Kubernetes (RKE2).

---

## 1. Custom Dockerfiles — Iron Bank Bypass

**Problem:** The hardened Dockerfiles use Iron Bank base images from `registry1.dso.mil`
(`ironbank/redhat/openjdk/openjdk17`, `ironbank/opensource/postgres/postgresql`) which
require DoD PKI credentials to pull.

**Fix:** Created replacement Dockerfiles in `azlinux-custom-images-2/docker/`:

| File | Base Image | Upstream Base |
|------|-----------|---------------|
| `Dockerfile.takserver` | `eclipse-temurin:17-jammy` | `ironbank/redhat/openjdk/openjdk17:1.17` |
| `Dockerfile.takserver-db` | `postgres:15-bookworm` | `ironbank/opensource/postgres/postgresql` |

**Gotcha:** Must pin `postgres:15-bookworm` specifically. The unqualified `postgres:15`
tag now resolves to Debian Trixie, which has removed `openjdk-17-jdk-headless` from
its repositories, causing the build to fail.

---

## 2. DB Entrypoint — Replace `configureInDocker.sh`

**Problem:** The upstream `configureInDocker.sh` entrypoint was written for the Iron Bank
postgres image and assumes it runs as root. The official `postgres:15` image uses `gosu`
for user switching, and the script breaks in three ways:

1. `psql` defaults to the OS user (root), which has no PostgreSQL role →
   `FATAL: role "root" does not exist`
2. `pg_ctl reload` refuses to run as root →
   `pg_ctl: cannot be run as root`
3. The script backgrounds `docker-entrypoint.sh postgres &`, conflicting with
   how the official image expects to own PID 1

**Fix:** Replaced the custom entrypoint entirely. The Dockerfile now uses the standard
postgres `docker-entrypoint.sh` (image default) plus a custom init script at
`/docker-entrypoint-initdb.d/01-takserver-init.sh` that executes during first-boot:

```
1. CREATE ROLE martiuser LOGIN
2. CREATE DATABASE cot OWNER martiuser
3. CREATE EXTENSION IF NOT EXISTS postgis  (in cot DB)
4. sed CoreConfig.example.xml: tak-database → localhost  (for SchemaManager)
5. java -jar SchemaManager.jar upgrade     (applies 92 schema migrations)
6. sed CoreConfig.example.xml: localhost → tak-database  (restore for runtime)
```

---

## 3. Do NOT Copy pg_hba.conf

**Problem:** The upstream `configureInDocker.sh` copies `/opt/tak/db-utils/pg_hba.conf`
over the PostgreSQL data directory's `pg_hba.conf`. The TAK version enables `peer`
authentication, which immediately breaks all subsequent `psql` commands — the postgres
container user identity doesn't match what peer auth expects.

**Fix:** Removed the `pg_hba.conf` copy step entirely. Instead, the deployment uses:
```yaml
env:
  - name: POSTGRES_HOST_AUTH_METHOD
    value: "trust"
```
This tells the official postgres image to configure `trust` authentication in its own
generated `pg_hba.conf`, which is appropriate for an in-cluster database not exposed
externally.

---

## 4. SchemaManager Connects to Wrong Host

**Problem:** `SchemaManager.jar` reads its JDBC URL from `CoreConfig.example.xml`, which
contains `jdbc:postgresql://tak-database:5432/cot`. During the DB init script, postgres
is running on `localhost`, not reachable via the Kubernetes service name `tak-database`
(the Service won't route to a pod that isn't Ready yet).

**Fix:** The init script temporarily patches the XML before running SchemaManager:
```bash
sed -i "s|tak-database|localhost|g" /opt/tak/CoreConfig.example.xml
java -jar SchemaManager.jar upgrade
sed -i "s|localhost|tak-database|g" /opt/tak/CoreConfig.example.xml
```

---

## 5. Schema Migration on Every Server Start

**Problem:** The `01-takserver-init.sh` script only runs during the first PostgreSQL
initialization (when the data directory is empty). If the DB pod restarts with an existing
persistent volume, PostgreSQL skips initialization entirely — meaning SchemaManager never
runs. This leaves the database with only the `spatial_ref_sys` table (from PostGIS), causing
TAKServer to fail with `relation "data_feed" does not exist` errors and a broken WebTAK UI.

**Fix:** Added a `schema-upgrade` initContainer to the **server** deployment
(`server-deployment.yaml`) that runs `SchemaManager.jar upgrade` before TAKServer starts.
It runs after the `wait-for-db` initContainer confirms the database is reachable:

```yaml
- name: schema-upgrade
  image: arconboardacr.azurecr.io/takserver-db:5.5-RELEASE-45
  command: ["bash", "-c", "cd /opt/tak/db-utils && java -jar SchemaManager.jar upgrade"]
```

SchemaManager is idempotent — on a fresh DB it applies all 92 migrations; on an existing
DB it detects the current version and applies only what's needed (usually zero updates).

---

## 6. Volume Mounts — Do NOT Mount Over `/opt/tak`

**Problem:** The Docker Compose setup bind-mounts the entire host `tak/` directory to
`/opt/tak` in both containers. Translating this to a Kubernetes `hostPath` volume at
`/opt/tak` **overwrites all container binaries** because the host directory is empty on
first deploy. The container's baked-in files (jars, scripts, configs) become invisible.

**Fix:** All application binaries live inside the container image. Only mutable data is
persisted via hostPath volumes:

| Container | Mount | Host Path | Purpose |
|-----------|-------|-----------|---------|
| takserver-db | `/var/lib/postgresql/data` (subPath: pgdata) | `/var/lib/tak-server/db` | PostgreSQL data files |
| takserver | `/opt/tak/certs/files` | `/var/lib/tak-server/certs` | Generated TLS certificates |
| takserver | `/opt/tak/logs` | `/var/lib/tak-server/logs` | Server log files |
| tak-cert-init | `/opt/tak/certs/files` | `/var/lib/tak-server/certs` | Write certs for server to read |

---

## 7. Health Probes — Replace `health_check.sh`

**Problem:** The upstream DB deployment references `/opt/tak/health/takserver-db/health_check.sh`
for startup/liveness/readiness probes. This script is designed for the `configureInDocker.sh`
entrypoint and returns non-zero exit codes when used with the standard postgres entrypoint,
even when postgres is fully ready. This causes the pod to never become Ready, which means
the `tak-database` Service never routes traffic, which means the server init container
`wait-for-db` loops forever.

**Fix:** Replaced all DB probes with `pg_isready`:
```yaml
startupProbe:
  exec:
    command: ["pg_isready", "-U", "postgres"]
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 30
```

---

## 8. Certificate Chicken-and-Egg

**Problem:** TAKServer requires TLS certificates (`takserver.jks`, `truststore-root.jks`)
to start its HTTPS connectors on ports 8443/8444/8446. Without certs, the server starts
but only listens on internal Ignite ports (47100–47500, 10800–10804) — none of the TAK
client/admin ports open. Meanwhile, the original cert-init Job had an init container
that waited for port 8443 to become available before generating certs → deadlock.

**Fix:** The cert-init Job runs **without** any init container waiting for the server.
Certificate generation (openssl/keytool) doesn't need a running server. The deployment
sequence is:

```
1. cert-init Job runs → generates certs to /var/lib/tak-server/certs/
2. takserver Deployment starts → picks up certs via hostPath mount at /opt/tak/certs/files
3. If server started before certs: kubectl rollout restart deployment/takserver -n tak-server
```

The cert-init Job is idempotent — if `takserver.jks` and `truststore-root.jks` already
exist, it exits immediately.

---

## 9. Admin Cert Registration Requires Running Server

**Problem:** The upstream `cert_generate.py` runs `UserManager.jar certmod -A user.pem`
inside the running TAKServer container to register the admin certificate. This requires
the server to be running with a connected database. It cannot be done in the cert-init
Job because the server isn't up yet.

**Fix:** Admin cert registration is a manual post-deploy step (automated in `build.sh`
post-install):
```bash
kubectl exec -n tak-server deployment/takserver -c takserver -- \
  java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/user.pem
```

---

## 10. imagePullPolicy: Always

**Problem:** During iterative image fixes, pushing updated images with the same tag
(`5.5-RELEASE-45`) caused Kubernetes to use the cached (stale) version. Containerd
won't re-pull an image if the tag already exists locally, even when the digest has
changed in the registry.

**Fix:** Both deployments and the cert-init Job set `imagePullPolicy: Always`.
To force an immediate pull when debugging, delete the cached image on the node:
```bash
crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock \
  rmi arconboardacr.azurecr.io/takserver-db:5.5-RELEASE-45
```

---

## 11. No StorageClass on RKE2 — Use hostPath

**Problem:** The initial manifests used PersistentVolumeClaims, but RKE2 ships without
a default StorageClass or dynamic provisioner. PVCs stayed in `Pending` forever, blocking
pod scheduling.

**Fix:** Replaced all PVCs with `hostPath` volumes (see section 6). This is appropriate
for a single-node deployment. For multi-node, a CSI driver (e.g., Longhorn, local-path-provisioner)
would be needed.

---

## 12. Flux Kustomization Health Check Stalls

**Problem:** Flux's `cluster-config-apps` Kustomization performs health checks after
applying manifests. When TAKServer pods were stuck (due to PVC, volume, or probe issues),
the health check timed out and the Kustomization entered a `Failed` state. Subsequent
`reconcile.fluxcd.io/requestedAt` annotations couldn't unstick it because Flux was still
waiting on the old health check.

**Fix:** When the Kustomization is stuck:
1. Delete the broken resources manually (`kubectl delete deployment ...`)
2. Re-apply manifests directly (`kubectl apply -f`)
3. Force reconcile both the GitRepository and Kustomization:
```bash
kubectl annotate gitrepository cluster-config -n cluster-config \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate kustomization cluster-config-apps -n cluster-config \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

---

## Summary of Files Changed vs Upstream

| What | Upstream | This Deployment |
|------|----------|-----------------|
| DB base image | Iron Bank postgres | `postgres:15-bookworm` |
| Server base image | Iron Bank openjdk17 | `eclipse-temurin:17-jammy` |
| DB entrypoint | `configureInDocker.sh` | Standard postgres + init script |
| pg_hba.conf | Copied from TAK distribution | Not copied; `POSTGRES_HOST_AUTH_METHOD=trust` |
| Volumes | Bind-mount entire `/opt/tak` | hostPath only for DB data, certs, logs |
| DB probes | `health_check.sh` | `pg_isready -U postgres` |
| Cert generation | `cert_generate.py` via Docker exec | Kubernetes Job (standalone) |
| Admin cert registration | Part of cert_generate.py | Separate `kubectl exec` step |
| Storage | Docker volumes | hostPath (no StorageClass) |
| Image registry | Iron Bank / local | Azure Container Registry |
| Schema migration | Only during first DB init | initContainer runs SchemaManager on every server start |
