#!/usr/bin/env bash
# Make sure the local tvmtool is healthy before a YT stand starts, refreshing its config only when needed.
#
#   ensure-tvm.sh [--dry-run] [--force] [--help]
#
#   --dry-run   report the state and what would be done, change nothing
#   --force     refresh the config and restart tvmtool even when everything looks healthy
#   ENV=production in the environment selects the prod TVM config, as for `ENV=production pnpm yt:dev`
#
# A refresh runs projects/yandex/scripts/dev/setup-tvm-env.sh (yav → /etc/tvmtool, /var/lib/tvmtool,
# service restart) and happens when the daemon is not running, does not answer `OK` on /tvm/ping,
# or its config / daemon token differ from the current version in Secretnica. Otherwise nothing is
# touched, so the stand can be started as often as needed without a restart of tvmtool every time.
#
# Exit codes: 0 healthy (unchanged or refreshed), 1 still broken after a refresh, 2 tvmtool is not
# installed or a prerequisite (sudo, yav) is unavailable — the message says what to tell the user.
# Source of the procedure: https://wiki.yandex-team.ru/ct/lib/rabota-s-tvm-pri-razrabotke/
set -u

# The script lives in the plugin cache, so the DataLens checkout is the working directory (or STAND_REPO_ROOT)
REPO_ROOT=${STAND_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}
if [ -z "$REPO_ROOT" ] || [ ! -d "${REPO_ROOT}/projects/yandex" ]; then
    echo "not inside a datalens-ui checkout: run from the repo root or set STAND_REPO_ROOT" >&2
    exit 2
fi
SETUP_SCRIPT="${REPO_ROOT}/projects/yandex/scripts/dev/setup-tvm-env.sh"
SERVICE='yandex-passport-tvmtool'
CONF='/etc/tvmtool/tvmtool.conf'
TOKEN='/var/lib/tvmtool/local.auth'
PING_URL='http://127.0.0.1:18080/tvm/ping'
SECRET='sec-01k2heaz4fswf2pg682edkfpzz'
READY_WAIT_STEPS=30

DRY_RUN=0
FORCE=0

usage() {
    sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ "${ENV:-development}" = "production" ]; then
    CONF_KEY='ui_prod_conf'
else
    CONF_KEY='ui_us_conf'
fi

ping_body() {
    curl -s -m 5 "$PING_URL" 2>/dev/null || true
}

service_active() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$SERVICE"
    else
        sudo -n service "$SERVICE" status >/dev/null 2>&1
    fi
}

# --- prerequisites ------------------------------------------------------------------------

if [ ! -d /etc/tvmtool ] || ! { command -v tvmtool >/dev/null 2>&1 || [ -x /usr/bin/tvmtool ] || [ -f "/etc/init.d/$SERVICE" ] || systemctl list-unit-files 2>/dev/null | grep -q "^$SERVICE"; }; then
    echo "TVM: tvmtool is not installed. Ask the user to install it (needs the yandex apt repo, see the wiki page):" >&2
    echo "  sudo apt install yandex-passport-tvmtool yandex-passport-tvmknife" >&2
    exit 2
fi
if ! sudo -n true 2>/dev/null; then
    echo "TVM: passwordless sudo is unavailable, so the config can't be refreshed from here. Ask the user to run:" >&2
    echo "  cd projects/yandex && ./scripts/dev/setup-tvm-env.sh" >&2
    exit 2
fi

# --- state --------------------------------------------------------------------------------

reasons=()

if service_active; then
    echo "service: active"
else
    echo "service: not running"
    reasons+=('service not running')
fi

ping=$(ping_body)
if [ "$ping" = "OK" ]; then
    echo "ping: OK"
else
    echo "ping: '${ping:-no answer}'"
    reasons+=("ping answered '${ping:-nothing}' instead of OK")
fi

yav_conf=$(yav get version "$SECRET" -o "$CONF_KEY" 2>/dev/null)
yav_token=$(yav get version "$SECRET" -o TVM_DAEMON_TOKEN 2>/dev/null)
if [ -z "$yav_conf" ] || [ -z "$yav_token" ]; then
    echo "secretnica: unreachable (yav failed) — config freshness unknown"
    yav_ok=0
else
    yav_ok=1
    if [ "$(sudo -n cat "$CONF" 2>/dev/null)" = "$yav_conf" ]; then
        echo "config ($CONF_KEY): matches secretnica"
    else
        echo "config ($CONF_KEY): differs from secretnica"
        reasons+=("$CONF differs from $CONF_KEY in secretnica")
    fi
    if [ "$(sudo -n cat "$TOKEN" 2>/dev/null)" = "$yav_token" ]; then
        echo "daemon token: matches secretnica"
    else
        echo "daemon token: differs from secretnica"
        reasons+=("$TOKEN differs from TVM_DAEMON_TOKEN in secretnica")
    fi
fi

# --- decide -------------------------------------------------------------------------------

if [ "$FORCE" -eq 0 ] && [ ${#reasons[@]} -eq 0 ]; then
    echo "TVM: ok, nothing to refresh"
    exit 0
fi

if [ "$FORCE" -eq 1 ] && [ ${#reasons[@]} -eq 0 ]; then
    reasons+=('--force')
fi

if [ "$yav_ok" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    echo "TVM: needs a refresh ($(IFS='; '; echo "${reasons[*]}")), but yav is unavailable, so setup-tvm-env.sh would fail too." >&2
    echo "Ask the user to log in to yav (yav oauth) or to run: cd projects/yandex && ./scripts/dev/setup-tvm-env.sh" >&2
    exit 2
fi

echo "TVM: refresh needed — $(IFS='; '; echo "${reasons[*]}")"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry run: would run ENV=${ENV:-development} ${SETUP_SCRIPT#"$REPO_ROOT"/}"
    exit 0
fi

# --- refresh ------------------------------------------------------------------------------

(cd "${REPO_ROOT}/projects/yandex" && ENV="${ENV:-development}" bash "$SETUP_SCRIPT")
setup_status=$?
if [ "$setup_status" -ne 0 ]; then
    echo "TVM: setup-tvm-env.sh failed with exit code $setup_status" >&2
    exit 1
fi

for _ in $(seq 1 "$READY_WAIT_STEPS"); do
    if [ "$(ping_body)" = "OK" ]; then
        echo "TVM: refreshed, ping OK"
        exit 0
    fi
    sleep 1
done

echo "TVM: refreshed, but tvmtool still answers '$(ping_body)' after ${READY_WAIT_STEPS}s — check: sudo service $SERVICE status; journalctl -u $SERVICE -n 50" >&2
exit 1
