#!/usr/bin/env bash
# Resolve the dev stand parameters of the current developer for a Yandex installation.
#
#   stand-config.sh <yc|yt|yc-docker|yt-docker|detect> [--help]
#
#   yc, yt               native stand on a dev VM: host nginx + host tvmtool, address from
#                        projects/yandex/dev-nginx/nginx.conf
#   yc-docker, yt-docker docker mode (local machine): app, nginx and tvmtool run as containers of the
#                        compose project datalens-ui-yandex, address from the compose nginx template
#   detect               print only DEFAULT=<mode>: native when the host nginx config exists, docker otherwise
#
# Prints shell-style KEY=VALUE lines:
#   MODE           native | docker
#   COMMAND        the pnpm script that starts the stand (run from the repo root)
#   URL            the stand address
#   HOST_SOURCE    where URL came from: nginx.conf, compose-template, env (STAND_URL) or user-fallback
#   RESOLVES_TO    what the stand host resolves to on this machine (empty when it does not resolve)
#   COOKIE_DOMAIN  the domain to set the auth cookies for in agent-browser
#   AUTH_FILE      the auth file to pass to `agent-browser cookies set --curl`
#   NEEDS_TVM      1 when the host tvmtool must be checked before the start (native YT only; in docker
#                  mode tvmtool is a container fed from .env, nothing to refresh on the host)
#   WARNING        a problem the caller should confirm with the user (docker host not pointing here, …)
#
# Overrides (environment): STAND_URL, STAND_AUTH_FILE, STAND_REPO_ROOT, PROJECT_NAME (docker nginx name)
#
# Exit code 1 when the address can't be resolved: the caller must ask the user for it.
set -u

# The script lives in the plugin cache, so the DataLens checkout is the working directory (or STAND_REPO_ROOT)
REPO_ROOT=${STAND_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}
if [ -z "$REPO_ROOT" ] || [ ! -d "${REPO_ROOT}/projects/yandex" ]; then
    echo "not inside a datalens-ui checkout: run from the repo root or set STAND_REPO_ROOT" >&2
    exit 2
fi
NGINX_CONF="${REPO_ROOT}/projects/yandex/dev-nginx/nginx.conf"
DOTENV="${REPO_ROOT}/projects/yandex/.env"
DEFAULT_AUTH_FILE="projects/yandex/tests/artifacts/auth.txt"
DEFAULT_PROJECT_NAME="datalens-ui-yandex"

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# PROJECT_NAME of the compose nginx: environment wins, then projects/yandex/.env, then the compose default
docker_project_name() {
    if [ -n "${PROJECT_NAME:-}" ]; then
        echo "$PROJECT_NAME"
    elif [ -r "$DOTENV" ] && grep -qE '^PROJECT_NAME=' "$DOTENV"; then
        grep -E '^PROJECT_NAME=' "$DOTENV" | tail -1 | cut -d= -f2- | tr -d '"'"'"
    else
        echo "$DEFAULT_PROJECT_NAME"
    fi
}

ENV_NAME=${1:-}
case "$ENV_NAME" in
    -h | --help | '')
        usage
        [ -z "$ENV_NAME" ] && exit 1
        exit 0
        ;;
    detect)
        if [ -r "$NGINX_CONF" ]; then
            echo "DEFAULT=yc"
        else
            echo "DEFAULT=yc-docker"
        fi
        exit 0
        ;;
    yc)
        MODE=native
        COMMAND='pnpm run yc:dev'
        HOST_PATTERN='\.dev\.preprod\.datalens\.ru$'
        COOKIE_DOMAIN='.preprod.datalens.ru'
        FALLBACK_HOST="${USER:-}.dev.preprod.datalens.ru"
        NEEDS_TVM=0
        ;;
    yt)
        MODE=native
        COMMAND='pnpm run yt:dev'
        HOST_PATTERN='\.ui\.yandex-team\.ru$'
        COOKIE_DOMAIN='.yandex-team.ru'
        # The YT host starts with CONFIG_NAME, which only nginx.conf knows
        FALLBACK_HOST=''
        NEEDS_TVM=1
        ;;
    yc-docker)
        MODE=docker
        COMMAND='pnpm run yc:dev:docker:no-typecheck'
        COOKIE_DOMAIN='.preprod.datalens.ru'
        DOCKER_HOST_SUFFIX='dev.preprod.datalens.ru'
        NEEDS_TVM=0
        ;;
    yt-docker)
        MODE=docker
        COMMAND='pnpm run yt:dev:docker:no-typecheck'
        COOKIE_DOMAIN='.yandex-team.ru'
        DOCKER_HOST_SUFFIX='ui.yandex-team.ru'
        NEEDS_TVM=0
        ;;
    *)
        echo "unknown environment '$ENV_NAME': expected yc, yt, yc-docker, yt-docker or detect" >&2
        usage >&2
        exit 1
        ;;
esac

URL=''
HOST_SOURCE=''
WARNING=''
if [ -n "${STAND_URL:-}" ]; then
    URL="$STAND_URL"
    HOST_SOURCE='env'
elif [ "$MODE" = docker ]; then
    # Mirrors server_name in projects/yandex/dev/docker/nginx.conf: ${PROJECT_NAME}.${USERNAME}.<suffix>
    if [ -n "${USER:-}" ]; then
        URL="https://$(docker_project_name).${USER}.${DOCKER_HOST_SUFFIX}"
        HOST_SOURCE='compose-template'
    fi
else
    if [ -r "$NGINX_CONF" ]; then
        host=$(grep -E '^\s*server_name\b' "$NGINX_CONF" | tr -s ' ;' '\n' | grep -E "$HOST_PATTERN" | head -1)
        if [ -n "$host" ]; then
            URL="https://${host}"
            HOST_SOURCE='nginx.conf'
        fi
    fi
    if [ -z "$URL" ] && [ -n "$FALLBACK_HOST" ] && [ -n "${USER:-}" ]; then
        URL="https://${FALLBACK_HOST}"
        HOST_SOURCE='user-fallback'
    fi
fi

RESOLVES_TO=''
if [ -n "$URL" ]; then
    stand_host=${URL#https://}
    stand_host=${stand_host%%/*}
    RESOLVES_TO=$(resolve_host "$stand_host" | sed 's/ *$//')
    if [ "$MODE" = docker ]; then
        if [ -z "$RESOLVES_TO" ]; then
            WARNING="the docker stand host ${stand_host} does not resolve on this machine; it must point at 127.0.0.1 (e.g. in /etc/hosts) — confirm the address with the user"
        elif ! is_loopback "$RESOLVES_TO"; then
            WARNING="the docker stand host ${stand_host} resolves to ${RESOLVES_TO}, not to this machine; the browser would hit another host — confirm the address with the user"
        fi
    fi
fi

echo "MODE=${MODE}"
echo "COMMAND=${COMMAND}"
echo "URL=${URL}"
echo "HOST_SOURCE=${HOST_SOURCE}"
echo "RESOLVES_TO=${RESOLVES_TO}"
echo "COOKIE_DOMAIN=${COOKIE_DOMAIN}"
echo "AUTH_FILE=${STAND_AUTH_FILE:-$DEFAULT_AUTH_FILE}"
echo "NEEDS_TVM=${NEEDS_TVM}"
echo "WARNING=${WARNING}"

if [ -z "$URL" ]; then
    echo "stand address not found: no ${NGINX_CONF#"$REPO_ROOT"/} and no STAND_URL — ask the user" >&2
    exit 1
fi
