# TAKServer Kubernetes Deployment

TAK (Team Awareness Kit) Server deployed via GitOps on RKE2 with Azure Arc.

## Architecture

- **takserver-db** — PostgreSQL 15 + PostGIS (persistent storage)
- **takserver** — TAK Server 5.5-RELEASE-45 (Java/Tomcat)
- **cert-init** — One-time Job to generate TLS certificates

Images are pulled from Azure Container Registry (ACR) with Defender for Containers.

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8089 | TLS/TCP  | TAK client connections (SSL) |
| 8088 | TCP      | TAK streaming TCP |
| 8443 | HTTPS    | Web dashboard / admin |
| 8444 | HTTPS    | Federation HTTPS |
| 8446 | HTTPS    | Certificate enrollment |
| 9000 | TCP      | Federation |
| 9001 | TCP      | Federation v2 |

## Setup

TAKServer is deployed automatically when `--tak-server` is passed to `build.sh`:

```bash
./build.sh --remote --proxmox --unattended --tak-server rocm-rke2-arc-unattended-iso
```

This will:
1. Create ACR with Defender for Containers (if not exists)
2. Build and push TAKServer Docker images to ACR
3. Build the OS image, deploy to Proxmox
4. Configure ACR pull secret on the cluster
5. GitOps (Flux) deploys TAKServer from these manifests

## Certificate Management

The `cert-init-job.yaml` runs once after TAKServer starts to:
- Generate Root CA
- Generate server certificate (`takserver.jks`)
- Generate client certificate (`user.p12`)
- Register admin cert for dashboard access

Certificates are stored in the `tak-data` PVC at `/opt/tak/certs/files/`.

## Accessing the Dashboard

After deployment (allow 5-10 minutes for full startup):

```
https://<NODE_IP>:<NODE_PORT>/Marti/metrics/index.html#!/
```

Install the `user.p12` certificate in your browser to authenticate.
