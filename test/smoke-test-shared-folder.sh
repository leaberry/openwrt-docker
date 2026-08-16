#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly COMPOSE_FILE="${1:-docker-compose.test.yml}"
readonly SERVICE="openwrt-test"
readonly CONTAINER="openwrt-shared-folder-test"
readonly SHARED_DIR="test-runtime/shared"
readonly MARKER="codex-shared-folder-smoke-test.txt"

cd "$REPO_ROOT"
mkdir -p test-runtime/storage "$SHARED_DIR"
printf 'host-to-guest\n' > "$SHARED_DIR/$MARKER"

docker compose -f "$COMPOSE_FILE" config --quiet
docker compose -f "$COMPOSE_FILE" up -d --no-build "$SERVICE"

deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
    status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
    if [ "$status" != "running" ]; then
        echo "Test container is not running (status: ${status:-missing})." >&2
        docker logs "$CONTAINER" >&2 || true
        exit 1
    fi

    guest_command="grep -qx host-to-guest /shared/$MARKER && printf guest-to-host > /shared/guest-result.txt"
    if docker exec "$CONTAINER" /run/qemu_qmp.sh -c "$guest_command" >/dev/null 2>&1 && \
       [ "$(cat "$SHARED_DIR/guest-result.txt" 2>/dev/null || true)" = "guest-to-host" ]; then
        echo "PASS: OpenWrt booted and the shared folder works in both directions."
        exit 0
    fi
    sleep 5
done

echo "Timed out waiting for the OpenWrt guest/shared folder smoke test." >&2
docker logs "$CONTAINER" >&2 || true
exit 1
