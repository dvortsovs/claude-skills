#!/usr/bin/env bash
# Wait until the dev stand answers through nginx (anything but 502/503/504 or no connection).
#
#   wait-stand.sh <stand-url> [timeout-seconds=900]
#
# Exit code 0 when the stand is up, 1 on timeout.
set -u

usage() {
    sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
POLL_INTERVAL=10

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
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo "stand did not come up in ${TIMEOUT}s, last answer HTTP $code"
        exit 1
    fi
    sleep "$POLL_INTERVAL"
done
