#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly COMPOSE_FILE="${1:-docker-compose.test.yml}"
readonly SERVICE="openwrt-test"
readonly CONTAINER="openwrt-shared-folder-test"
readonly SHARED_DIR="test-runtime/shared"
readonly MARKER="codex-shared-folder-smoke-test.txt"
readonly SETUP_RESULT="shared-setup-result.txt"

cd "$REPO_ROOT"
docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1 || true
rm -rf test-runtime/storage
mkdir -p test-runtime/storage "$SHARED_DIR"
printf 'host-to-guest\n' > "$SHARED_DIR/$MARKER"
printf 'test DHCP payload\n' > "$SHARED_DIR/dhcphosts"
printf 'copied-during-first-boot\n' > "$SHARED_DIR/setup-payload.txt"
cat > "$SHARED_DIR/upgrade_setup.sh" <<'EOF'
#!/bin/sh -ex
count="$(cat /shared/setup-run-count.txt 2>/dev/null || printf 0)"
printf '%s\n' "$((count + 1))" > /shared/setup-run-count.txt
cp /shared/setup-payload.txt /etc/shared-setup-result.txt
reboot
EOF
chmod +x "$SHARED_DIR/upgrade_setup.sh"
rm -rf "$SHARED_DIR/.openwrt-docker"
rm -f "$SHARED_DIR/setup-run-count.txt" "$SHARED_DIR/guest-result.txt"

docker compose -f "$COMPOSE_FILE" config --quiet
docker compose -f "$COMPOSE_FILE" up -d --no-build "$SERVICE"

cleanup() {
    docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
    status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
    if [ "$status" != "running" ]; then
        echo "Test container is not running (status: ${status:-missing})." >&2
        docker logs "$CONTAINER" >&2 || true
        exit 1
    fi

    guest_command="grep -qx host-to-guest /shared/$MARKER && grep -qx copied-during-first-boot /etc/$SETUP_RESULT && test -f /shared/.openwrt-docker/upgrade-setup-\$(cat /etc/openwrt_version).complete && printf guest-to-host > /shared/guest-result.txt"
    if docker exec "$CONTAINER" /run/qemu_qmp.sh -c "$guest_command" >/dev/null 2>&1 && \
       [ "$(cat "$SHARED_DIR/guest-result.txt" 2>/dev/null || true)" = "guest-to-host" ] && \
       [ "$(cat "$SHARED_DIR/setup-run-count.txt" 2>/dev/null || true)" = "1" ]; then
        break
    fi
    sleep 5
done

if (( SECONDS >= deadline )); then
    echo "Timed out waiting for the OpenWrt guest/shared folder smoke test." >&2
    docker logs "$CONTAINER" >&2 || true
    exit 1
fi

# Reboot once more and prove the per-version completion marker prevents a
# second setup run.
docker exec "$CONTAINER" /run/qemu_qmp.sh -R >/dev/null
sleep 5
deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
    if docker exec "$CONTAINER" /run/qemu_qmp.sh -V >/dev/null 2>&1 && \
       [ "$(cat "$SHARED_DIR/setup-run-count.txt" 2>/dev/null || true)" = "1" ]; then
        echo "PASS: OpenWrt booted, first-boot setup ran exactly once, and /shared works in both directions."
        exit 0
    fi
    sleep 5
done

echo "Timed out verifying that setup is not repeated after reboot." >&2
docker logs "$CONTAINER" >&2 || true
exit 1
