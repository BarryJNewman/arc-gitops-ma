# Sovereign Watch — Image Build & Deploy Guide

## Overview

All custom service images must be built from source and pushed to ACR before the
GitOps manifests will run. Infrastructure images (TimescaleDB, Redis, Redpanda)
use public registries and require no build step.

## Prerequisites

```bash
git clone https://github.com/d3mocide/Sovereign_Watch.git ~/sovereign-watch
az acr login --name arconboardacr
```

## ACR Login Server

| Cloud          | Login Server              |
|----------------|---------------------------|
| AzureUSGov     | arconboardacr.azurecr.us  |
| AzurePublic    | arconboardacr.azurecr.io  |

Set `ACR` to match your cloud:
```bash
ACR=arconboardacr.azurecr.us   # USGov
```

## Build & Push

```bash
cd ~/sovereign-watch

# Backend API (FastAPI)
docker build -t $ACR/sovereign-watch-backend:latest ./backend/api
docker push $ACR/sovereign-watch-backend:latest

# Frontend (React/Vite → Nginx)
# Build arg sets the API URL to the cluster ingress hostname
docker build \
  --build-arg VITE_API_URL=https://sovereign.darkoverlay.com \
  --build-arg VITE_CENTER_LAT=45.5152 \
  --build-arg VITE_CENTER_LON=-122.6784 \
  --build-arg VITE_COVERAGE_RADIUS_NM=150 \
  --build-arg VITE_ENABLE_MAPBOX=false \
  --build-arg VITE_ENABLE_3D_TERRAIN=false \
  -t $ACR/sovereign-watch-frontend:latest ./frontend
docker push $ACR/sovereign-watch-frontend:latest

# Pollers
docker build -t $ACR/sovereign-watch-ais-poller:latest    ./backend/ingestion/maritime_poller
docker push $ACR/sovereign-watch-ais-poller:latest

docker build -t $ACR/sovereign-watch-adsb-poller:latest   ./backend/ingestion/aviation_poller
docker push $ACR/sovereign-watch-adsb-poller:latest

docker build -t $ACR/sovereign-watch-space-pulse:latest   ./backend/ingestion/space_pulse
docker push $ACR/sovereign-watch-space-pulse:latest

docker build -t $ACR/sovereign-watch-infra-poller:latest  ./backend/ingestion/infra_poller
docker push $ACR/sovereign-watch-infra-poller:latest

docker build -t $ACR/sovereign-watch-gdelt-pulse:latest   ./backend/ingestion/gdelt_pulse
docker push $ACR/sovereign-watch-gdelt-pulse:latest

docker build -t $ACR/sovereign-watch-rf-pulse:latest      ./backend/ingestion/rf_pulse
docker push $ACR/sovereign-watch-rf-pulse:latest

# JS8Call radio terminal (optional — skip if KiwiSDR not available)
docker build -t $ACR/sovereign-watch-js8call:latest       ./js8call
docker push $ACR/sovereign-watch-js8call:latest
```

## Entra App Registration

Already created — `Sovereign Watch` app in your tenant.

| Setting         | Value                                                    |
|-----------------|----------------------------------------------------------|
| App ID          | `766a99ab-7d2b-40b5-803c-8ceea4a83893`                   |
| Redirect URI    | `https://sovereign.darkoverlay.com/oauth2/callback`      |
| Credentials     | Stored in KV as `sovereign-watch-entra-client-*`         |

To restrict access to specific users/groups, configure **User Assignment Required**
on the Enterprise Application and assign users in the Azure portal.

## KV Secrets (auto-seeded)

| KV Secret                         | Usage                         |
|-----------------------------------|-------------------------------|
| `sovereign-watch-pg-password`     | TimescaleDB root password     |
| `sovereign-watch-cookie-secret`   | oauth2-proxy cookie signing   |
| `sovereign-watch-entra-client-id` | Entra App client ID           |
| `sovereign-watch-entra-client-secret` | Entra App client secret   |

## Optional Poller Config

Set these KV secrets to enable additional data sources:

```bash
# AIS Maritime data (free at aisstream.io)
az keyvault secret set --vault-name arc-onboard-kv \
  --name sovereign-watch-aisstream-key --value "<your-key>"

# Mapbox 3D terrain (mapbox.com)
az keyvault secret set --vault-name arc-onboard-kv \
  --name sovereign-watch-mapbox-token --value "<your-token>"
```

Then add these to the `secret-provider.yaml` `objects` array and reference them
in `pollers.yaml` via `sovereign-watch-poller-secrets`.

## Access

Once images are pushed and Flux reconciles:
**https://sovereign.darkoverlay.com** — Entra login required
