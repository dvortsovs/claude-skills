#!/usr/bin/env bash
# Stop the docker dev stand of the current checkout (the main one or a git worktree), and nothing else:
# stands of other worktrees and the shared nginx keep running.
#
#   stop-stand.sh [--list|--dry-run] [--pattern <ere>] [stand-url]
#
#   --list, --dry-run  only print what would be stopped
#   --pattern <ere>    extra `pgrep -f` pattern, for a non-standard start command
#   stand-url          after stopping, print the HTTP code the stand answers with
#
# Stops, in this order:
#   - host processes started from this checkout — a foreground `pnpm *:dev:docker*` (launcher,
#     dev-proxy, attached `docker compose up`) or native YC (`yc:dev:native`); a process belongs to the
#     checkout when its working directory is inside it. Killed by pid (TERM, then KILL), never with
#     `pkill -f`, which would match the shell that runs it; the shell chain running this script is spared;
#   - the containers of this checkout's compose project, with the repo's `docker-stand.js stop`
#     (containers and volumes are kept, the next start skips the dependency install).
# Then checks that nothing listens on the stand's host ports (8010/8020 for the main checkout, the
# worktree's own pair otherwise) — a server the filter missed would block the next start.
# Exit code 0 means no such process, no running container of this checkout's stand and no listener
# is left; 1 means something is left or docker did not answer, so that can't be confirmed; 2 means
# the checkout or its stand could not be resolved and nothing was stopped.
set -u

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PATTERN='docker-stand\.js|dev-proxy|(yc|yt|public|ent):dev|app-builder/dist/cli\.js|dist/yandex/src/server/index\.js|ts-checker'
LIST_ONLY=0
URL=''
TERM_WAIT_STEPS=20
MAX_ROUNDS=3
PORT_WAIT_STEPS=5

usage() {
    print_usage "${BASH_SOURCE[0]}"
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

require_checkout
require_stand_info

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

process_cwd() {
    if [ -e "/proc/$1/cwd" ]; then
        readlink "/proc/$1/cwd" 2>/dev/null
    else
        lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
    fi
}

# A stand of another worktree runs the same commands; only the working directory tells them apart.
in_checkout() {
    local cwd
    cwd=$(process_cwd "$1")
    case "$cwd" in
        "$REPO_ROOT" | "$REPO_ROOT"/*) return 0 ;;
    esac
    return 1
}

find_pids() {
    local skip pid
    skip=" $(ancestors | tr '\n' ' ')"
    for pid in $(pgrep -u "$(id -u)" -f "$PATTERN" 2>/dev/null); do
        case "$skip" in *" $pid "*) continue ;; esac
        ps -o args= -p "$pid" 2>/dev/null | grep -q 'stop-stand\.sh' && continue
        in_checkout "$pid" || continue
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

DOCKER_OK=0
docker_ok && DOCKER_OK=1

find_containers() {
    [ "$DOCKER_OK" -eq 1 ] || return 0
    docker ps -q --filter "label=com.docker.compose.project=${PROJECT}" 2>/dev/null | tr '\n' ' '
}

show_containers() {
    docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '  {{.Names}}  {{.Status}}' 2>/dev/null
}

echo "checkout: ${REPO_ROOT} (stand ${INSTANCE}, compose project ${PROJECT})"

pids=$(find_pids | tr '\n' ' ')
if [ -z "${pids// /}" ]; then
    echo "no stand processes of this checkout running"
elif [ "$LIST_ONLY" -eq 1 ]; then
    echo "stand processes (not stopped, dry run):"
    show $pids
fi

containers=$(find_containers)
if [ "$DOCKER_OK" -eq 0 ]; then
    echo "containers: docker unreachable, can't be checked or stopped (colima start; a docker that needs sudo does not work with the launcher)" >&2
elif [ -z "${containers// /}" ]; then
    echo "no containers of this checkout's stand running"
elif [ "$LIST_ONLY" -eq 1 ]; then
    echo "stand containers (not stopped, dry run):"
    show_containers
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    exit 0
fi

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
    pids=$(find_pids | tr '\n' ' ')
done

# A foreground compose stops its containers on TERM itself; the launcher's stop covers the rest
if [ -n "$(find_containers | tr -d ' ')" ]; then
    echo "stopping containers:"
    show_containers
    (cd "$REPO_ROOT" && node "$LAUNCHER" stop)
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

if [ "$DOCKER_OK" -eq 1 ]; then
    if [ -n "$(find_containers | tr -d ' ')" ]; then
        echo "STILL RUNNING containers:"
        show_containers
        status=1
    else
        echo "containers: none left (other worktrees' stands and the shared nginx are untouched)"
    fi
else
    echo "containers: UNKNOWN, docker unreachable"
    status=1
fi

ports=$(stand_ports)
if [ -z "${ports// /}" ]; then
    echo "host ports: none recorded for this stand"
else
    # The docker VM's port forwarding may close a moment after the container stops
    for _ in $(seq 1 "$PORT_WAIT_STEPS"); do
        listeners=''
        for port in $ports; do
            listeners="${listeners}$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2)"
        done
        [ -z "$listeners" ] && break
        sleep 1
    done
    if [ -n "$listeners" ]; then
        echo "STILL LISTENING on the stand's host ports (${ports% }):"
        echo "$listeners" | cut -c1-220
        status=1
    else
        echo "host ports ${ports% }: no listeners"
    fi
fi

if [ -n "$URL" ]; then
    code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "$URL")
    echo "stand answers HTTP $code (502 is expected for a stopped stand: the shared nginx stays up)"
fi

exit $status
