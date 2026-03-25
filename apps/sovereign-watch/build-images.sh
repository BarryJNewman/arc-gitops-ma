#!/usr/bin/env bash
# build-images.sh — Build Sovereign Watch Docker images on remote build server and push to ACR
#
# Usage:
#   ./build-images.sh [--host user@host] [--acr-name NAME] [--force] [--no-js8call]
#
# Defaults:
#   REMOTE_HOST  from BUILD_REMOTE_HOST env or 192.168.0.36
#   ACR_NAME     from ACR_NAME env or arconboardacr
#   ACR_CLOUD    azureusgovernment (for .azurecr.us suffix)

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
REMOTE_HOST="${BUILD_REMOTE_HOST:-192.168.0.36}"
ACR_NAME="${ACR_NAME:-arconboardacr}"
ACR_CLOUD="${ACR_CLOUD:-azureusgovernment}"
FORCE=false
BUILD_JS8CALL=true
SW_REPO="https://github.com/d3mocide/Sovereign_Watch.git"
REMOTE_SW_DIR="/home/packet/sovereign-watch"

###############################################################################
# Parse args
###############################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)        REMOTE_HOST="$2"; shift ;;
        --acr-name)    ACR_NAME="$2"; shift ;;
        --force)       FORCE=true ;;
        --no-js8call)  BUILD_JS8CALL=false ;;
        -h|--help)
            echo "Usage: $0 [--host user@host] [--acr-name NAME] [--force] [--no-js8call]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

###############################################################################
# Resolve REMOTE_DEST (support both user@host and plain IP)
###############################################################################
if [[ "$REMOTE_HOST" == *@* ]]; then
    REMOTE_DEST="$REMOTE_HOST"
else
    REMOTE_DEST="packet@${REMOTE_HOST}"
fi

remote_run() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_DEST" "$@"; }

###############################################################################
# Verify SSH
###############################################################################
echo ">>> Connecting to build server ${REMOTE_DEST}..."
remote_run "echo ok" &>/dev/null || {
    echo "ERROR: Cannot SSH to ${REMOTE_DEST}"
    echo "  Run: ssh-copy-id ${REMOTE_DEST}"
    exit 1
}
echo "  ✓ Connected"

###############################################################################
# Get ACR login server + credentials locally
###############################################################################
echo ">>> Resolving ACR credentials..."
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --subscription "${ARC_SUBSCRIPTION:-}" \
    --cloud "$ACR_CLOUD" -o tsv --query loginServer 2>/dev/null || \
    az acr show --name "$ACR_NAME" -o tsv --query loginServer 2>/dev/null)

if [[ -z "$ACR_LOGIN_SERVER" ]]; then
    echo "ERROR: Could not resolve ACR login server for '${ACR_NAME}'"
    echo "  Make sure 'az' is logged in and ACR_NAME is correct."
    exit 1
fi
echo "  ✓ ACR: ${ACR_LOGIN_SERVER}"

ACR_USER=$(az acr credential show --name "$ACR_NAME" --cloud "$ACR_CLOUD" \
    -o tsv --query username 2>/dev/null || \
    az acr credential show --name "$ACR_NAME" \
    -o tsv --query username 2>/dev/null)

ACR_PASS=$(az acr credential show --name "$ACR_NAME" --cloud "$ACR_CLOUD" \
    -o tsv --query "passwords[0].value" 2>/dev/null || \
    az acr credential show --name "$ACR_NAME" \
    -o tsv --query "passwords[0].value" 2>/dev/null)

if [[ -z "$ACR_USER" || -z "$ACR_PASS" ]]; then
    echo "ERROR: Could not retrieve ACR credentials for '${ACR_NAME}'"
    exit 1
fi
echo "  ✓ ACR credentials retrieved"

###############################################################################
# Check if images already exist (skip unless --force)
###############################################################################
check_tag_exists() {
    local repo="$1"
    az acr repository show-tags --name "$ACR_NAME" --repository "$repo" \
        --cloud "$ACR_CLOUD" -o tsv 2>/dev/null | grep -qx "latest" || \
    az acr repository show-tags --name "$ACR_NAME" --repository "$repo" \
        -o tsv 2>/dev/null | grep -qx "latest"
}

if [[ "$FORCE" != "true" ]]; then
    echo ">>> Checking existing ACR images..."
    all_exist=true
    for img in backend frontend ais-poller adsb-poller space-pulse infra-poller gdelt-pulse rf-pulse; do
        if ! check_tag_exists "sovereign-watch-${img}" 2>/dev/null; then
            all_exist=false
            echo "  ✗ sovereign-watch-${img}:latest — not found"
        else
            echo "  ✓ sovereign-watch-${img}:latest — exists"
        fi
    done
    if [[ "$all_exist" == "true" ]]; then
        echo ""
        echo "All images already in ACR. Use --force to rebuild."
        exit 0
    fi
fi

###############################################################################
# Clone / update Sovereign Watch repo on build server
###############################################################################
echo ""
echo ">>> Syncing Sovereign Watch repo on build server..."
remote_run "
    set -e
    if [[ -d '${REMOTE_SW_DIR}/.git' ]]; then
        echo '  Pulling latest...'
        git -C '${REMOTE_SW_DIR}' pull --ff-only
    else
        echo '  Cloning...'
        git clone '${SW_REPO}' '${REMOTE_SW_DIR}'
    fi
    echo '  ✓ Repo ready'
"

###############################################################################
# Build and push all images on build server
###############################################################################
echo ""
echo ">>> Building and pushing images on ${REMOTE_DEST}..."

BUILD_JS8CALL_FLAG="$BUILD_JS8CALL"

# Pass credentials and config via heredoc to avoid shell quoting issues
remote_run bash << REMOTE_SCRIPT
set -e
ACR='${ACR_LOGIN_SERVER}'
ACR_USER='${ACR_USER}'
SW_DIR='${REMOTE_SW_DIR}'
BUILD_JS8CALL='${BUILD_JS8CALL_FLAG}'

echo "  Logging in to ACR..."
echo "\${ACR_USER}" | docker login "\${ACR}" -u "\${ACR_USER}" --password '${ACR_PASS}' 2>/dev/null
echo "  ✓ Docker login successful"

build_and_push() {
    local name="\$1"
    local ctx="\$2"
    local image="\${ACR}/\${name}:latest"
    shift 2
    echo ""
    echo "  --- \${name} ---"
    echo "  Building \${image}..."
    docker build "\$@" -t "\${image}" "\${SW_DIR}/\${ctx}" 2>&1 | tail -3
    echo "  ✓ Built"
    echo "  Pushing..."
    docker push "\${image}" 2>&1 | tail -3
    echo "  ✓ Pushed: \${image}"
}

build_and_push sovereign-watch-backend        backend/api
build_and_push sovereign-watch-frontend       frontend \
    --build-arg VITE_API_URL=https://sovereign.darkoverlay.com \
    --build-arg VITE_CENTER_LAT=45.5152 \
    --build-arg VITE_CENTER_LON=-122.6784 \
    --build-arg VITE_COVERAGE_RADIUS_NM=150 \
    --build-arg VITE_ENABLE_MAPBOX=false \
    --build-arg VITE_ENABLE_3D_TERRAIN=false
build_and_push sovereign-watch-ais-poller     backend/ingestion/maritime_poller
build_and_push sovereign-watch-adsb-poller    backend/ingestion/aviation_poller
build_and_push sovereign-watch-space-pulse    backend/ingestion/space_pulse
build_and_push sovereign-watch-infra-poller   backend/ingestion/infra_poller
build_and_push sovereign-watch-gdelt-pulse    backend/ingestion/gdelt_pulse
build_and_push sovereign-watch-rf-pulse       backend/ingestion/rf_pulse

if [[ "\${BUILD_JS8CALL}" == "true" ]]; then
    if [[ -d "\${SW_DIR}/js8call" ]]; then
        build_and_push sovereign-watch-js8call js8call
    else
        echo "  (js8call dir not found — skipping)"
    fi
fi

docker logout "\${ACR}" 2>/dev/null || true
echo ""
echo "=== All images pushed to \${ACR} ==="
REMOTE_SCRIPT

###############################################################################
# Done
###############################################################################
echo ""
echo ">>> Done. All Sovereign Watch images are in ACR: ${ACR_LOGIN_SERVER}"
echo ""
echo "    Next: delete ImagePullBackOff pods so Kubernetes pulls the new images:"
echo "    ssh packet@192.168.0.43 \\"
echo "      '/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \\"
echo "       delete pods -n sovereign-watch -l app=sovereign-watch'"
