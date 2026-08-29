#!/usr/bin/env bash

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR=${STATE_DIR:-$SCRIPT_DIR/.state}
LOG_FILE=${LOG_FILE:-$STATE_DIR/auto-occupy.tsv}
ACTIVE_FILE="$STATE_DIR/auto.active"
WORKER_PID_FILE="$STATE_DIR/worker.pid"
WORKER_LOG="$STATE_DIR/worker.log"
RELEASE_FILE="$STATE_DIR/worker.release"
MEMORY_GIB_PER_DEVICE=${MEMORY_GIB_PER_DEVICE:-50}
HOST_SSH_TARGET=${HOST_SSH_TARGET:-root@127.0.0.1}
HOST_SSH_PORT=${HOST_SSH_PORT:-22}
CANN_ENV_FILE=${CANN_ENV_FILE:-/usr/local/Ascend/cann/set_env.sh}
CUSTOM_TRANSFORMER_ENV_FILE=${CUSTOM_TRANSFORMER_ENV_FILE:-/usr/local/Ascend/cann/opp/vendors/custom_transformer/bin/set_env.bash}
PYTHON_BIN=${PYTHON_BIN:-/usr/local/python3.11.15/bin/python}

mkdir -p "$STATE_DIR"

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log_event() {
    printf '%s\t%s\t%s\n' "$(now)" "$1" "${2:-}" >> "$LOG_FILE"
}

query_output() {
    HOST_SSH_TARGET="$HOST_SSH_TARGET" HOST_SSH_PORT="$HOST_SSH_PORT" \
        "$SCRIPT_DIR/query_host_npu.sh"
}

has_user_process() {
    awk -F '\t' '$1 == "PROC" && $7 != "auto-occupy" { found=1 }
        END { exit(found ? 0 : 1) }' <<< "$1"
}

worker_alive() {
    pgrep -x auto-occupy >/dev/null 2>&1
}

start_worker() {
    mkdir -p "$STATE_DIR"
    rm -f "$RELEASE_FILE"
    if worker_alive; then
        touch "$ACTIVE_FILE"
        return 0
    fi

    nohup env \
        CANN_ENV_FILE="$CANN_ENV_FILE" \
        CUSTOM_TRANSFORMER_ENV_FILE="$CUSTOM_TRANSFORMER_ENV_FILE" \
        PYTHON_BIN="$PYTHON_BIN" \
        setsid bash -c '
        set -e
        [[ -z "$CANN_ENV_FILE" ]] || source "$CANN_ENV_FILE"
        [[ -z "$CUSTOM_TRANSFORMER_ENV_FILE" ]] || source "$CUSTOM_TRANSFORMER_ENV_FILE"
        exec env MEMORY_GIB_PER_DEVICE="$1" WORKER_RELEASE_FILE="$2" \
            "$PYTHON_BIN" "$3"
    ' _ "$MEMORY_GIB_PER_DEVICE" "$RELEASE_FILE" \
        "$SCRIPT_DIR/auto_occupy_worker.py" >>"$WORKER_LOG" 2>&1 </dev/null &
    printf '%s\n' "$!" > "$WORKER_PID_FILE"

    for _ in {1..10}; do
        if worker_alive; then
            touch "$ACTIVE_FILE"
            log_event AUTO_START "memory_gib_per_device=$MEMORY_GIB_PER_DEVICE"
            return 0
        fi
        sleep 1
    done
    rm -f "$WORKER_PID_FILE" "$ACTIVE_FILE"
    log_event AUTO_START_ERROR "worker did not become ready"
    return 1
}

stop_worker() {
    rm -f "$ACTIVE_FILE" "$RELEASE_FILE"
    local worker_pids
    worker_pids=$(pgrep -x auto-occupy || true)
    if [[ -n "$worker_pids" ]]; then
        kill $worker_pids 2>/dev/null || true
        for _ in {1..10}; do
            pgrep -x auto-occupy >/dev/null 2>&1 || break
            sleep 1
        done
        worker_pids=$(pgrep -x auto-occupy || true)
        [[ -z "$worker_pids" ]] || kill -KILL $worker_pids 2>/dev/null || true
    fi
    rm -f "$WORKER_PID_FILE"
    log_event AUTO_RELEASE "worker released; host watchdog owns idle timer"
}

manual_once() {
    local output
    if ! output=$(query_output 2>&1); then
        printf 'once refused: query failed: %s\n' "${output//$'\n'/ }" >&2
        return 1
    fi
    if has_user_process "$output"; then
        printf 'once refused: state=USER_IN_USE\n' >&2
        return 1
    fi
    start_worker || return 1
    if printf '%s\n' '[NPU Auto-Occupy] 手动占用；释放：pkill -f auto-occupy' | ssh -T \
        -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$HOST_SSH_PORT" "$HOST_SSH_TARGET" wall >/dev/null 2>&1; then
        log_event BROADCAST_OK '手动占用；释放：pkill -f auto-occupy'
    else
        log_event BROADCAST_ERROR '手动占用；释放：pkill -f auto-occupy'
    fi
    log_event AUTO_START_MANUAL "memory_gib_per_device=$MEMORY_GIB_PER_DEVICE"
}

status() {
    local output state=IDLE
    if ! output=$(query_output 2>&1); then
        state=QUERY_ERROR
    elif awk -F '\t' '$1 == "PROC" && $7 != "auto-occupy" { user=1 }
                      $1 == "PROC" && $7 == "auto-occupy" { auto=1 }
                      END { exit !(user && auto) }' <<< "$output"; then
        state=USER_IN_USE_AND_AUTO_OCCUPIED
    elif has_user_process "$output"; then
        state=USER_IN_USE
    elif awk -F '\t' '$1 == "PROC" && $7 == "auto-occupy" { found=1 }
                      END { exit(found ? 0 : 1) }' <<< "$output"; then
        state=AUTO_OCCUPIED
    fi
    printf 'state=%s\n' "$state"
    printf 'auto_active=%s\n' "$([[ -f "$ACTIVE_FILE" ]] && echo yes || echo no)"
    if worker_alive; then
        printf 'worker=running\n'
    else
        printf 'worker=stopped\n'
    fi
}

case "${1:-status}" in
    once|start|start-worker) manual_once ;;
    kill|stop) stop_worker ;;
    check) query_output ;;
    status) status ;;
    run|supervise)
        printf '%s\n' 'container monitor removed; use host auto-occupy-docker.service' >&2
        exit 2
        ;;
    *)
        printf 'usage: %s {once|kill|status|check}\n' "$0" >&2
        exit 2
        ;;
esac
