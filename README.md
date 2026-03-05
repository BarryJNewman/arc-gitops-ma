# arc-gitops-ma — Mission Assurance GitOps

Kubernetes manifests for mission assurance workloads, managed via Flux v2 (Azure Arc GitOps).

## Apps

| App | Namespace | Description |
|-----|-----------|-------------|
| TAK Server | `tak-server` | Team Awareness Kit server (messaging, CoT) |
| Traefik | `traefik` | Cloud-native ingress/reverse proxy with dashboard |
| Authentik | `authentik` | Identity provider (SSO, LDAP, SAML, OIDC) |
| Windows DC | `windows-dc` | Windows Server Domain Controller (KubeVirt VM) |

## Structure

```
infrastructure/       Shared cluster infrastructure (StorageClass)
apps/
  base/               Apps deployed on all MA nodes
  tak-server/         TAK Server (DB + application server)
  traefik/            Traefik reverse proxy
  authentik/          Authentik identity provider
  windows-dc/         Windows Server DC (KubeVirt VM)
  overlays/
    base/             Minimal overlay (base apps only)
    full/             All MA apps including VMs
```

## Usage

Flux kustomization paths:
- `path=./infrastructure` — cluster infra
- `path=./apps/overlays/base` — core MA apps
- `path=./apps/overlays/full` — all MA apps including VMs
