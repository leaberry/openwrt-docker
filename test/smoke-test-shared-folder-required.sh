#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly COMPOSE_FILE="${1:-docker-compose.test.yml}"
readonly SERVICE="openwrt-missing-shared-test"
readonly CONTAINER="openwrt-shared-folder-required-test"

cd "$REPO_ROOT"
docker compose -f "$COMPOSE_FILE" --profile fail-closed down >/dev/null 2>&1 || true
rm -rf test-runtime/missing-shared-storage
mkdir -p test-runtime/missing-shared-storage

docker compose -f "$COMPOSE_FILE" config --quiet
docker compose -f "$COMPOSE_FILE" --profile fail-closed up -d --no-build "$SERVICE"

cleanup() {
    docker compose -f "$COMPOSE_FILE" --profile fail-closed down >/dev/null 2>&1 || true
}
trap cleanup EXIT

deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
    logs="$(docker logs "$CONTAINER" 2>&1 || true)"
    if printf '%s\n' "$logs" | grep -q 'required /shared virtfs mount is unavailable; powering off'; then
        if ! docker exec "$CONTAINER" /run/qemu_qmp.sh -V >/dev/null 2>&1; then
            echo "PASS: a missing /shared mount powers the guest off before it can run as a router."
            exit 0
        fi
    fi
    sleep 3
done

echo "Timed out waiting for the missing-/shared fail-closed behavior." >&2
docker logs "$CONTAINER" >&2 || true
exit 1
