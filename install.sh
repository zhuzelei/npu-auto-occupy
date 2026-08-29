#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

HOST_BASE=${HOST_BASE:-/data/z00894965/code/auto-occupy}
CONTAINER_BASE=${CONTAINER_BASE:-}
CONTAINER_NAME=${CONTAINER_NAME:-cann_900_torchtitan_master_zdp}
DOCKER_HOST_SOCKET=${DOCKER_HOST_SOCKET:-unix:///data/z00894965/docker-daemon/docker.sock}
DOCKER_SERVICE_NAME=${DOCKER_SERVICE_NAME:-docker-z00894965.service}
HOST_SSH_TARGET=${HOST_SSH_TARGET:-root@127.0.0.1}
HOST_SSH_PORT=${HOST_SSH_PORT:-22}
MEMORY_GIB_PER_DEVICE=${MEMORY_GIB_PER_DEVICE:-50}
IDLE_THRESHOLD_SECONDS=${IDLE_THRESHOLD_SECONDS:-1200}
CHECK_INTERVAL_SECONDS=${CHECK_INTERVAL_SECONDS:-30}
STATE_RECORD_INTERVAL_SECONDS=${STATE_RECORD_INTERVAL_SECONDS:-300}
CANN_ENV_FILE=${CANN_ENV_FILE:-/usr/local/Ascend/cann/set_env.sh}
CUSTOM_TRANSFORMER_ENV_FILE=${CUSTOM_TRANSFORMER_ENV_FILE:-/usr/local/Ascend/cann/opp/vendors/custom_transformer/bin/set_env.bash}
PYTHON_BIN=${PYTHON_BIN:-/usr/local/python3.11.15/bin/python}
CONFIG_FILE=${AUTO_OCCUPY_CONFIG:-/etc/default/auto-occupy-docker}
START_SERVICE=1

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Install the host watchdog and synchronize the one-shot command layer into the
target container. The default values match the existing A3 deployment.

Options:
  --container NAME             Container name
  --docker-socket URI|PATH     Docker socket (default: unix:///data/z00894965/docker-daemon/docker.sock)
  --docker-service NAME|none   Docker systemd unit dependency (default: docker-z00894965.service)
  --host-base PATH             Host code/state directory
  --container-base PATH        Code directory visible inside the container
  --host-ssh-target TARGET      Host SSH target used by npu-smi probe
  --host-ssh-port PORT         Host SSH port used by npu-smi probe
  --memory-gib-per-device N    Worker allocation per device (default: 50)
  --idle-threshold SEC         Idle time before auto-start (default: 1200)
  --check-interval SEC         Watchdog poll interval (default: 30)
  --state-record-interval SEC  Repeated TSV record interval (default: 300)
  --cann-env PATH               CANN environment script inside the container
  --custom-transformer-env PATH Custom transformer environment script
  --python PATH                 Python executable inside the container
  --config PATH                 Watchdog configuration file
  --no-start                    Install and reload, but do not start the service
  -h, --help                    Show this help

Release NPU occupancy with:
  pkill -f auto-occupy
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_value() {
    (($# >= 2)) || die "$1 requires a value"
    [[ -n "$2" ]] || die "$1 requires a non-empty value"
}

while (($#)); do
    case "$1" in
        --container) need_value "$1" "${2-}"; CONTAINER_NAME=$2; shift 2 ;;
        --docker-socket) need_value "$1" "${2-}"; DOCKER_HOST_SOCKET=$2; shift 2 ;;
        --docker-service) (($# >= 2)) || die "$1 requires a value"; DOCKER_SERVICE_NAME=$2; shift 2 ;;
        --host-base) need_value "$1" "${2-}"; HOST_BASE=$2; shift 2 ;;
        --container-base) need_value "$1" "${2-}"; CONTAINER_BASE=$2; shift 2 ;;
        --host-ssh-target) need_value "$1" "${2-}"; HOST_SSH_TARGET=$2; shift 2 ;;
        --host-ssh-port) need_value "$1" "${2-}"; HOST_SSH_PORT=$2; shift 2 ;;
        --memory-gib-per-device) need_value "$1" "${2-}"; MEMORY_GIB_PER_DEVICE=$2; shift 2 ;;
        --idle-threshold) need_value "$1" "${2-}"; IDLE_THRESHOLD_SECONDS=$2; shift 2 ;;
        --check-interval) need_value "$1" "${2-}"; CHECK_INTERVAL_SECONDS=$2; shift 2 ;;
        --state-record-interval) need_value "$1" "${2-}"; STATE_RECORD_INTERVAL_SECONDS=$2; shift 2 ;;
        --cann-env) need_value "$1" "${2-}"; CANN_ENV_FILE=$2; shift 2 ;;
        --custom-transformer-env) need_value "$1" "${2-}"; CUSTOM_TRANSFORMER_ENV_FILE=$2; shift 2 ;;
        --python) need_value "$1" "${2-}"; PYTHON_BIN=$2; shift 2 ;;
        --config) need_value "$1" "${2-}"; CONFIG_FILE=$2; shift 2 ;;
        --no-start) START_SERVICE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (use --help)" ;;
    esac
done

[[ -n "$CONTAINER_BASE" ]] || CONTAINER_BASE=$HOST_BASE

[[ $EUID -eq 0 ]] || die 'run as root (for example: sudo ./install.sh)'
command -v docker >/dev/null 2>&1 || die 'docker command not found'
command -v systemctl >/dev/null 2>&1 || die 'systemctl command not found'
[[ -f "$REPO_ROOT/bin/auto_occupy.sh" ]] || die 'repository is incomplete: bin/auto_occupy.sh missing'

[[ "$HOST_BASE" = /* ]] || die '--host-base must be an absolute path'
[[ "$CONTAINER_BASE" = /* ]] || die '--container-base must be an absolute path'
[[ "$HOST_SSH_PORT" =~ ^[0-9]+$ ]] || die '--host-ssh-port must be numeric'
[[ "$MEMORY_GIB_PER_DEVICE" =~ ^[0-9]+$ ]] || die '--memory-gib-per-device must be numeric'
[[ "$IDLE_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]] || die '--idle-threshold must be numeric'
[[ "$CHECK_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || die '--check-interval must be numeric'
[[ "$STATE_RECORD_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || die '--state-record-interval must be numeric'

if [[ "$DOCKER_HOST_SOCKET" = /* ]]; then
    DOCKER_HOST_SOCKET="unix://$DOCKER_HOST_SOCKET"
fi

docker_cmd() {
    docker --host "$DOCKER_HOST_SOCKET" "$@"
}

docker_cmd inspect "$CONTAINER_NAME" >/dev/null 2>&1 \
    || die "container not found through $DOCKER_HOST_SOCKET: $CONTAINER_NAME"
running=$(docker_cmd inspect -f '{{.State.Running}}' "$CONTAINER_NAME")
[[ "$running" == true ]] || die "container is not running: $CONTAINER_NAME"

install -d -m 0755 "$HOST_BASE" "$HOST_BASE/.state"
install -m 0755 "$REPO_ROOT/bin/auto_occupy.sh" "$HOST_BASE/auto_occupy.sh"
install -m 0755 "$REPO_ROOT/bin/query_host_npu.sh" "$HOST_BASE/query_host_npu.sh"
install -m 0755 "$REPO_ROOT/bin/auto_occupy_worker.py" "$HOST_BASE/auto_occupy_worker.py"

# The data directory is normally bind-mounted into the container. Copying the
# files explicitly also supports images where that mount is not present.
docker_cmd exec "$CONTAINER_NAME" /bin/bash -lc 'mkdir -p "$1"' bash "$CONTAINER_BASE"
for name in auto_occupy.sh query_host_npu.sh auto_occupy_worker.py; do
    src="$HOST_BASE/$name"
    dst="$CONTAINER_BASE/$name"
    host_hash=$(sha256sum "$src" | awk '{print $1}')
    container_hash=$(docker_cmd exec "$CONTAINER_NAME" sha256sum "$dst" 2>/dev/null | awk '{print $1}' || true)
    if [[ "$host_hash" != "$container_hash" ]]; then
        docker_cmd cp "$src" "$CONTAINER_NAME:$dst"
    fi
done
docker_cmd exec "$CONTAINER_NAME" chmod 0755 \
    "$CONTAINER_BASE/auto_occupy.sh" \
    "$CONTAINER_BASE/query_host_npu.sh" \
    "$CONTAINER_BASE/auto_occupy_worker.py"
docker_cmd exec "$CONTAINER_NAME" /bin/bash -lc 'mkdir -p "$1"' bash "$CONTAINER_BASE/.state"

config_tmp=$(mktemp)
unit_tmp=$(mktemp)
trap 'rm -f "$config_tmp" "$unit_tmp"' EXIT
{
    printf '# Generated by npu-auto-occupy/install.sh; edit to customize.\n'
    printf 'DOCKER_HOST_SOCKET=%q\n' "$DOCKER_HOST_SOCKET"
    printf 'CONTAINER=%q\n' "$CONTAINER_NAME"
    printf 'HOST_BASE=%q\n' "$HOST_BASE"
    printf 'CONTAINER_BASE=%q\n' "$CONTAINER_BASE"
    printf 'HOST_SSH_TARGET=%q\n' "$HOST_SSH_TARGET"
    printf 'HOST_SSH_PORT=%q\n' "$HOST_SSH_PORT"
    printf 'MEMORY_GIB_PER_DEVICE=%q\n' "$MEMORY_GIB_PER_DEVICE"
    printf 'IDLE_THRESHOLD_SECONDS=%q\n' "$IDLE_THRESHOLD_SECONDS"
    printf 'CHECK_INTERVAL_SECONDS=%q\n' "$CHECK_INTERVAL_SECONDS"
    printf 'STATE_RECORD_INTERVAL_SECONDS=%q\n' "$STATE_RECORD_INTERVAL_SECONDS"
    printf 'CANN_ENV_FILE=%q\n' "$CANN_ENV_FILE"
    printf 'CUSTOM_TRANSFORMER_ENV_FILE=%q\n' "$CUSTOM_TRANSFORMER_ENV_FILE"
    printf 'PYTHON_BIN=%q\n' "$PYTHON_BIN"
} > "$config_tmp"
install -D -m 0644 "$config_tmp" "$CONFIG_FILE"

install -m 0755 "$REPO_ROOT/host/auto-occupy-watchdog" /usr/local/sbin/auto-occupy-watchdog
install -m 0755 "$REPO_ROOT/systemd/auto-occupy-refuse-stop" /usr/local/sbin/auto-occupy-refuse-stop
install -d -m 0755 /etc/systemd/system/auto-occupy-docker.service.d
install -m 0644 "$REPO_ROOT/systemd/guard.conf" \
    /etc/systemd/system/auto-occupy-docker.service.d/guard.conf

if [[ "$DOCKER_SERVICE_NAME" == none ]]; then
    sed -e "s|@AUTO_OCCUPY_CONFIG@|$CONFIG_FILE|g" \
        -e '/^Requires=docker-z00894965.service$/d' \
        -e '/^After=docker-z00894965.service$/d' \
        "$REPO_ROOT/systemd/auto-occupy-docker.service" > "$unit_tmp"
else
    sed -e "s|@AUTO_OCCUPY_CONFIG@|$CONFIG_FILE|g" \
        -e "s/docker-z00894965.service/$DOCKER_SERVICE_NAME/g" \
        "$REPO_ROOT/systemd/auto-occupy-docker.service" > "$unit_tmp"
fi
install -m 0644 "$unit_tmp" /etc/systemd/system/auto-occupy-docker.service

systemctl daemon-reload
if systemctl is-active --quiet auto-occupy-docker.service; then
    # RefuseManualStop blocks systemctl stop/restart. Killing only the main
    # watchdog lets Restart=always reload the new files without touching the
    # container worker.
    systemctl kill --kill-who=main -s SIGTERM auto-occupy-docker.service || true
fi
if (( START_SERVICE )); then
    systemctl enable --now auto-occupy-docker.service
else
    systemctl enable auto-occupy-docker.service >/dev/null
fi

printf 'Installed auto-occupy-docker.service\n'
printf '  host code:      %s\n' "$HOST_BASE"
printf '  container code: %s\n' "$CONTAINER_BASE"
printf '  container:      %s\n' "$CONTAINER_NAME"
printf '  idle threshold: %ss\n' "$IDLE_THRESHOLD_SECONDS"
printf '  release:        pkill -f auto-occupy\n'
if (( START_SERVICE )); then
    systemctl is-active --quiet auto-occupy-docker.service \
        || die 'service did not become active; inspect with journalctl -u auto-occupy-docker.service'
    printf '  service state:  active\n'
else
    printf '  service state:  not started (--no-start)\n'
fi
