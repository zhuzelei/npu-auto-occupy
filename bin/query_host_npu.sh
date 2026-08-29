#!/usr/bin/env bash

set -o pipefail

HOST_SSH_TARGET=${HOST_SSH_TARGET:-root@127.0.0.1}
HOST_SSH_PORT=${HOST_SSH_PORT:-22}
SSH_ATTEMPTS=${SSH_ATTEMPTS:-3}

tmp_output=$(mktemp)
trap 'rm -f "$tmp_output"' EXIT

for ((ssh_attempt = 1; ssh_attempt <= SSH_ATTEMPTS; ssh_attempt++)); do
if ssh -T \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o LogLevel=ERROR \
    -o ConnectTimeout=5 \
    -p "$HOST_SSH_PORT" \
    "$HOST_SSH_TARGET" 'bash -s' >"$tmp_output" <<'REMOTE'
set -o pipefail

source /usr/local/Ascend/cann/set_env.sh 2>/dev/null || true
source /usr/local/Ascend/cann/opp/vendors/custom_transformer/bin/set_env.bash 2>/dev/null || true
DOCKER_ROOT=${DOCKER_ROOT:-/data/z00894965/docker-daemon}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
pids=()
query_card() {
    local npu_id=$1
    local output_file=$2
    local attempt
    for attempt in 1 2 3; do
        if timeout 10 npu-smi info -t proc-mem -i "$npu_id" >"$output_file" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

for npu_id in {0..7}; do
    query_card "$npu_id" "$tmp_dir/$npu_id" 2>/dev/null &
    pids+=("$!")
done
status=0
for child_pid in "${pids[@]}"; do
    wait "$child_pid" || status=1
done
[[ $status -eq 0 ]] || exit "$status"

declare -A pid_cards
declare -A pid_card_seen
declare -A pid_die_count
declare -A pid_die_seen
declare -A pid_dies
for npu_id in {0..7}; do
    current_pids=()
    while IFS= read -r line; do
        if [[ "$line" =~ Process[[:space:]]id:[[:space:]]*([0-9]+) ]]; then
            current_pid=${BASH_REMATCH[1]}
            current_pids+=("$current_pid")
            [[ -n "${pid_card_seen["$current_pid:$npu_id"]:-}" ]] || {
                pid_card_seen["$current_pid:$npu_id"]=1
                pid_cards["$current_pid"]+="${npu_id},"
            }
            continue
        fi
        if [[ "$line" =~ Chip[[:space:]]ID[[:space:]]*:[[:space:]]*([0-9]+) ]] && (( ${#current_pids[@]} > 0 )); then
            chip_id=${BASH_REMATCH[1]}
            die_id=$((npu_id * 2 + chip_id))
            for current_pid in "${current_pids[@]}"; do
                [[ -n "${pid_die_seen["$current_pid:$die_id"]:-}" ]] && continue
                pid_die_seen["$current_pid:$die_id"]=1
                pid_die_count["$current_pid"]=$(( ${pid_die_count["$current_pid"]:-0} + 1 ))
                pid_dies["$current_pid"]+="${die_id},"
            done
            current_pids=()
        fi
    done < "$tmp_dir/$npu_id"
done

for pid in "${!pid_cards[@]}"; do
    card_list=${pid_cards[$pid]%,}
    card_count=$(awk -F, '{print NF}' <<< "$card_list")
    [[ -d "/proc/$pid" ]] || continue
    name=$(cat "/proc/$pid/comm" 2>/dev/null || true)
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
    container_id=$(awk -F/ '$2 == "docker" {print $3; exit}' "/proc/$pid/cgroup" 2>/dev/null)
    docker_name=
    if [[ -n "$container_id" ]]; then
        docker_name=$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || true)
        if [[ -z "$docker_name" && -f "$DOCKER_ROOT/data/containers/$container_id/config.v2.json" ]]; then
            docker_name=$(jq -r '.Name // empty' "$DOCKER_ROOT/data/containers/$container_id/config.v2.json" 2>/dev/null || true)
        fi
    fi
    die_list=${pid_dies[$pid]%,}
    printf 'PROC\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$card_list" "$card_count" "${pid_die_count[$pid]:-0}" "$die_list" "$name" "$cwd" "$docker_name"
done
REMOTE
then
    cat "$tmp_output"
    exit 0
fi
[[ "$ssh_attempt" -lt "$SSH_ATTEMPTS" ]] && sleep 1
done

printf 'query_failed after %s SSH attempts\n' "$SSH_ATTEMPTS" >&2
exit 1
