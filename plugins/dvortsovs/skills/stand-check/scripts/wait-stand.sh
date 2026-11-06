#!/usr/bin/env bash
# Wait until the dev stand answers through nginx (anything but 502/503/504 or no connection).
#
#   wait-stand.sh <stand-url> [timeout-seconds=900] [container]
#
#   container   the stand's application container (CONTAINER from stand-config.sh): when docker
#               reports it stopped while waiting, the start has failed — print the tail of its log and
#               give up at once; an empty or failed `docker inspect` (docker hiccup) is polled again
#
# Exit code 0 when the stand is up, 1 on timeout or a stopped container.
set -u

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
    -h | --help | '')
        usage
        [ -z "${1:-}" ] && exit 1
        exit 0
        ;;
esac

URL=$1
TIMEOUT=${2:-900}
CONTAINER=${3:-}
POLL_INTERVAL=10
LOG_TAIL=40

start=$(date +%s)
while :; do
    code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "$URL")
    elapsed=$(($(date +%s) - start))
    case "$code" in
        000 | 502 | 503 | 504) ;;
        *)
            echo "stand is up: HTTP $code after ${elapsed}s"
            exit 0
            ;;
    esac
    if [ -n "$CONTAINER" ] && [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = false ]; then
        echo "container $CONTAINER is not running after ${elapsed}s, the start failed; last log lines:"
        docker logs --tail "$LOG_TAIL" "$CONTAINER" 2>&1
        exit 1
    fi
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo "stand did not come up in ${TIMEOUT}s, last answer HTTP $code"
        exit 1
    fi
    sleep "$POLL_INTERVAL"
done
