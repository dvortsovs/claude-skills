#!/usr/bin/env bash
# Resolve the dev stand parameters of the current developer for a Yandex installation.
#
#   stand-config.sh <yc|yt> [--help]
#
# Prints shell-style KEY=VALUE lines:
#   COMMAND        the pnpm script that starts the stand (run from the repo root)
#   URL            the stand address, taken from `server_name` in projects/yandex/dev-nginx/nginx.conf
#   HOST_SOURCE    where URL came from: nginx.conf, env (STAND_URL) or user-fallback ($USER pattern)
#   COOKIE_DOMAIN  the domain to set the auth cookies for in agent-browser
#   AUTH_FILE      the auth file to pass to `agent-browser cookies set --curl`
#   NEEDS_TVM      1 when the installation talks to internal services through tvmtool (YT):
#                  run ensure-tvm.sh before starting the stand
#
# Overrides (environment):
#   STAND_URL        use this address instead of the one from nginx.conf
#   STAND_AUTH_FILE  use this auth file instead of projects/yandex/tests/artifacts/auth.txt
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
DEFAULT_AUTH_FILE="projects/yandex/tests/artifacts/auth.txt"

usage() {
    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ENV_NAME=${1:-}
case "$ENV_NAME" in
    -h | --help | '')
        usage
        [ -z "$ENV_NAME" ] && exit 1
        exit 0
        ;;
    yc)
        COMMAND='pnpm run yc:dev'
        HOST_PATTERN='\.dev\.preprod\.datalens\.ru$'
        COOKIE_DOMAIN='.preprod.datalens.ru'
        FALLBACK_HOST="${USER:-}.dev.preprod.datalens.ru"
        NEEDS_TVM=0
        ;;
    yt)
        COMMAND='pnpm run yt:dev'
        HOST_PATTERN='\.ui\.yandex-team\.ru$'
        COOKIE_DOMAIN='.yandex-team.ru'
        # The YT host starts with CONFIG_NAME, which only nginx.conf knows
        FALLBACK_HOST=''
        NEEDS_TVM=1
        ;;
    *)
        echo "unknown environment '$ENV_NAME': expected yc or yt" >&2
        usage >&2
        exit 1
        ;;
esac

URL=''
HOST_SOURCE=''
if [ -n "${STAND_URL:-}" ]; then
    URL="$STAND_URL"
    HOST_SOURCE='env'
elif [ -r "$NGINX_CONF" ]; then
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

echo "COMMAND=${COMMAND}"
echo "URL=${URL}"
echo "HOST_SOURCE=${HOST_SOURCE}"
echo "COOKIE_DOMAIN=${COOKIE_DOMAIN}"
echo "AUTH_FILE=${STAND_AUTH_FILE:-$DEFAULT_AUTH_FILE}"
echo "NEEDS_TVM=${NEEDS_TVM}"

if [ -z "$URL" ]; then
    echo "stand address not found: no ${NGINX_CONF#"$REPO_ROOT"/} and no STAND_URL — ask the user" >&2
    exit 1
fi
