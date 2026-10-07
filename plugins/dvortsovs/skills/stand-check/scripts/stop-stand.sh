#!/usr/bin/env bash
# Stop every DataLens dev stand of the current user, whoever started it: native processes and the
# docker-mode containers (compose project datalens-ui-yandex).
#
#   stop-stand.sh [--list|--dry-run] [--pattern <ere>] [stand-url]
#
#   --list, --dry-run  only print what would be stopped
#   --pattern <ere>    extra `pgrep -f` pattern, for a non-standard start command
#   stand-url          after stopping, print the HTTP code the stand answers with
#
# Processes are killed by pid (TERM, then KILL), never with `pkill -f`: a `pkill -f` pattern
# matches the shell that runs it. The shell chain running this script is always spared.
# Containers are stopped with `docker stop` (through `sudo -n` when the socket needs it).
# Exit code 0 means no stand process, no container and no dist/run socket listener is left.
set -u

PATTERN='(yc|yt|public|ent):dev|app-builder/dist/cli\.js|dist/yandex/src/server/index\.js|ts-checker'
LIST_ONLY=0
URL=''
TERM_WAIT_STEPS=20
MAX_ROUNDS=3
COMPOSE_PROJECT='datalens-ui-yandex'

usage() {
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --list | --dry-run) LIST_ONLY=1 ;;
        --pattern)
            shift
            PATTERN="$PATTERN|$1"
            ;;
        *) URL="$1" ;;
    esac
    shift
done

# The shell chain running this script must survive even if its command line mentions a dev script.
ancestors() {
    local pid=$$
    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
        echo "$pid"
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
}

descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        echo "$child"
        descendants "$child"
    done
}

find_pids() {
    local skip pid
    skip=" $(ancestors | tr '\n' ' ')"
    for pid in $(pgrep -u "$(id -u)" -af "$PATTERN" 2>/dev/null | grep -v 'stop-stand\.sh' | awk '{print $1}'); do
        case "$skip" in *" $pid "*) continue ;; esac
        echo "$pid"
        descendants "$pid"
    done | sort -un
}

alive() {
    local pid
    for pid in "$@"; do
        kill -0 "$pid" 2>/dev/null && echo "$pid"
    done
}

show() {
    # shellcheck disable=SC2086
    ps -o pid=,etime=,args= -p $(echo "$@" | tr ' ' ',') 2>/dev/null | cut -c1-220
}

# `docker` itself, or through sudo when the socket is root-only; empty when docker is unusable here
DOCKER=''
if command -v docker >/dev/null 2>&1; then
    if docker ps -q >/dev/null 2>&1; then
        DOCKER='docker'
    elif sudo -n docker ps -q >/dev/null 2>&1; then
        DOCKER='sudo -n docker'
    fi
fi

find_containers() {
    [ -n "$DOCKER" ] || return 0
    $DOCKER ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null | tr '\n' ' '
}

show_containers() {
    # shellcheck disable=SC2086
    $DOCKER ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" --format '  {{.Names}}  {{.Status}}' 2>/dev/null
}

pids=$(find_pids | tr '\n' ' ')

if [ -z "${pids// /}" ]; then
    echo "no stand processes running"
elif [ "$LIST_ONLY" -eq 1 ]; then
    echo "stand processes (not stopped, dry run):"
    show $pids
fi

containers=$(find_containers)
if [ -z "$DOCKER" ]; then
    echo "containers: docker unavailable here, skipped"
elif [ -z "${containers// /}" ]; then
    echo "no stand containers running"
elif [ "$LIST_ONLY" -eq 1 ]; then
    echo "stand containers (not stopped, dry run):"
    show_containers
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    exit 0
fi

if [ -n "${pids// /}" ]; then
    round=0
    while [ -n "${pids// /}" ] && [ "$round" -lt "$MAX_ROUNDS" ]; do
        round=$((round + 1))
        echo "stopping (round $round):"
        show $pids
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null
        left="$pids"
        for _ in $(seq 1 "$TERM_WAIT_STEPS"); do
            sleep 0.5
            left=$(alive $pids | tr '\n' ' ')
            [ -z "${left// /}" ] && break
        done
        # shellcheck disable=SC2086
        [ -n "${left// /}" ] && kill -KILL $left 2>/dev/null
        sleep 0.5
        # `docker` itself, or through sudo when the socket is root-only; empty when docker is unusable here
DOCKER=''
if command -v docker >/dev/null 2>&1; then
    if docker ps -q >/dev/null 2>&1; then
        DOCKER='docker'
    elif sudo -n docker ps -q >/dev/null 2>&1; then
        DOCKER='sudo -n docker'
    fi
fi

find_containers() {
    [ -n "$DOCKER" ] || return 0
    $DOCKER ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null | tr '\n' ' '
}

show_containers() {
    # shellcheck disable=SC2086
    $DOCKER ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" --format '  {{.Names}}  {{.Status}}' 2>/dev/null
}

pids=$(find_pids | tr '\n' ' ')
    done
fi

status=0

leftover=$(find_pids | tr '\n' ' ')
if [ -n "${leftover// /}" ]; then
    echo "STILL RUNNING:"
    show $leftover
    status=1
else
    echo "processes: none left"
fi

listeners=$(ss -lxp 2>/dev/null | grep 'dist/run')
if [ -n "$listeners" ]; then
    echo "STILL LISTENING on dist/run sockets:"
    echo "$listeners" | cut -c1-220
    status=1
else
    echo "dist/run sockets: no listeners"
fi

if [ -n "$DOCKER" ]; then
    leftover_containers=$(find_containers)
    if [ -n "${leftover_containers// /}" ]; then
        echo "STILL RUNNING containers:"
        show_containers
        status=1
    else
        echo "containers: none left"
    fi
fi

if [ -n "$URL" ]; then
    code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "$URL")
    echo "stand answers HTTP $code (502, or 000 with the docker nginx gone, is expected for a stopped stand)"
fi

exit $status
