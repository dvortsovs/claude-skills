#!/usr/bin/env bash
# Resolve the docker dev stand of the current checkout (the main one or a git worktree).
#
#   stand-config.sh <yt|yc|yc-preprod> [--help]
#
#   yt           YT, ENV=development (STAND_ENV in the environment overrides the ENV of any mode)
#   yc           YC with the production backend, ENV=production
#   yc-preprod   YC with the preprod backend, ENV=development
#
# Every checkout runs its own stand (compose project, containers, host ports, subdomain) behind one
# shared nginx; the repo's launcher projects/yandex/scripts/dev/docker-stand.js names it. This script
# asks that launcher (`info`) for the stand of the checkout it runs in, so call it from that checkout.
#
# Prints shell-style KEY=VALUE lines:
#   INSTANCE       default (main checkout) or the worktree's instance name
#   CONTAINER      the application container of this stand
#   STATE          running | stopped | absent | unknown (docker did not answer) — the container right now
#   RUNNING_ENV    RUN_DEV and ENV of the running container (empty unless STATE=running)
#   COMMAND        starts this checkout's stand in the background (run from the checkout root)
#   URL            the stand address
#   RESOLVES_TO    what the stand host resolves to on this machine (empty when it does not resolve)
#   COOKIE_DOMAIN  the domain to set the auth cookies for in agent-browser
#   AUTH_FILE      the auth file to pass to `agent-browser cookies set --curl`
#   WARNING        a problem the caller should confirm with the user (host not pointing here, docker down)
#
# Overrides (environment): STAND_URL, STAND_AUTH_FILE, STAND_REPO_ROOT, STAND_ENV (the app's ENV — a
# separate name, since a shell or a sourced .env often exports ENV for its own purposes); DEV_INSTANCE
# and PROJECT_NAME are read by the launcher itself.
#
# Exit code 1 when the address can't be resolved, 2 outside a checkout with the per-worktree launcher
# or when the launcher does not name the stand.
set -u

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEFAULT_AUTH_FILE="projects/yandex/tests/artifacts/auth.txt"

usage() {
    print_usage "${BASH_SOURCE[0]}"
}

resolve_host() {
    # Linux and macOS differ here; python is the common denominator when both tools are missing
    if command -v getent >/dev/null 2>&1; then
        getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' '
    elif command -v dscacheutil >/dev/null 2>&1; then
        dscacheutil -q host -a name "$1" 2>/dev/null | awk '/address/ {print $2}' | tr '\n' ' '
    else
        python3 -c "import socket,sys; print(' '.join(sorted({a[4][0] for a in socket.getaddrinfo(sys.argv[1], None)})))" "$1" 2>/dev/null
    fi
}

is_loopback() {
    case " $1 " in
        *" 127."* | *" ::1 "* | *" 0.0.0.0 "*) return 0 ;;
    esac
    return 1
}

case "${1:-}" in
    -h | --help | '')
        usage
        [ -z "${1:-}" ] && exit 1
        exit 0
        ;;
    yt)
        APP_ENV=${STAND_ENV:-development}
        SCRIPT='yt:dev:docker:no-typecheck'
        COOKIE_DOMAIN='.yandex-team.ru'
        ;;
    yc)
        APP_ENV=${STAND_ENV:-production}
        SCRIPT='yc:dev:docker:no-typecheck'
        COOKIE_DOMAIN='.datalens.ru'
        ;;
    yc-preprod)
        APP_ENV=${STAND_ENV:-development}
        SCRIPT='yc:dev:docker:no-typecheck'
        COOKIE_DOMAIN='.preprod.datalens.ru'
        ;;
    *)
        echo "unknown environment '$1': expected yt, yc or yc-preprod" >&2
        usage >&2
        exit 1
        ;;
esac

# The line of `docker-stand.js info` with the address; for YC it follows ENV, as the launcher's getUrls
if [ "$1" = yt ]; then
    INFO_KEY='YT'
else
    case "$APP_ENV" in
        production | staging) INFO_KEY='YC with ENV=production or staging' ;;
        *) INFO_KEY='YC with another ENV' ;;
    esac
fi

require_checkout
require_stand_info
LAUNCHER_URL=$(info_field "$INFO_KEY")

WARNING=''
RUNNING_ENV=''
if ! docker_ok; then
    WARNING='docker is not reachable — the user has to start it (colima start); a docker that needs sudo does not work with the launcher either'
    STATE=unknown
else
    STATE=$(container_state "$CONTAINER")
    case "$STATE" in
        running)
            RUNNING_ENV=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null |
                grep -E '^(RUN_DEV|ENV)=' | tr '\n' ' ' | sed 's/ *$//')
            ;;
        unknown) WARNING="docker inspect ${CONTAINER} failed — the stand's state is unknown, check it with the user (pnpm docker:dev:list)" ;;
    esac
fi

URL=${STAND_URL:-$LAUNCHER_URL}

RESOLVES_TO=''
if [ -n "$URL" ]; then
    stand_host=${URL#https://}
    stand_host=${stand_host%%/*}
    RESOLVES_TO=$(resolve_host "$stand_host" | sed 's/ *$//')
    if [ -z "$RESOLVES_TO" ]; then
        WARNING="${WARNING:+$WARNING; }${stand_host} does not resolve on this machine; it must point at 127.0.0.1 — once for all worktree stands: pnpm docker:dev:dns (asks for sudo, the user runs it), or a line in /etc/hosts"
    elif ! is_loopback "$RESOLVES_TO"; then
        WARNING="${WARNING:+$WARNING; }${stand_host} resolves to ${RESOLVES_TO}, not to this machine; the browser would hit another host — pnpm docker:dev:dns or /etc/hosts"
    fi
fi

echo "INSTANCE=${INSTANCE}"
echo "CONTAINER=${CONTAINER}"
echo "STATE=${STATE}"
echo "RUNNING_ENV=${RUNNING_ENV}"
echo "COMMAND=ENV=${APP_ENV} pnpm run ${SCRIPT} --detach"
echo "URL=${URL}"
echo "RESOLVES_TO=${RESOLVES_TO}"
echo "COOKIE_DOMAIN=${COOKIE_DOMAIN}"
echo "AUTH_FILE=${STAND_AUTH_FILE:-$DEFAULT_AUTH_FILE}"
echo "WARNING=${WARNING}"

if [ -z "$URL" ]; then
    echo "stand address not found in the launcher's info output — ask the user" >&2
    exit 1
fi
