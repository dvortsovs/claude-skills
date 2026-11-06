# Shared helpers of the stand-check scripts; sourced, not run.
#
# The scripts live in the plugin cache, so the DataLens checkout is the working directory (or
# STAND_REPO_ROOT); the checkout's own launcher projects/yandex/scripts/dev/docker-stand.js names its stand.

DEFAULT_CLIENT_PORT=8010
DEFAULT_SERVER_PORT=8020

# Sets REPO_ROOT (physical path) and LAUNCHER, or exits 2
require_checkout() {
    REPO_ROOT=${STAND_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}
    if [ -z "$REPO_ROOT" ] || [ ! -d "${REPO_ROOT}/projects/yandex" ]; then
        echo "not inside a datalens-ui checkout: run from the checkout root or set STAND_REPO_ROOT" >&2
        exit 2
    fi
    REPO_ROOT=$(cd "$REPO_ROOT" && pwd -P)
    LAUNCHER="${REPO_ROOT}/projects/yandex/scripts/dev/docker-stand.js"
    if [ ! -f "$LAUNCHER" ]; then
        echo "${LAUNCHER#"$REPO_ROOT"/} is missing: this checkout predates per-worktree docker stands — rebase it on main" >&2
        exit 2
    fi
}

# Sets LAUNCHER_INFO (`docker-stand.js info` output), INSTANCE, PROJECT and CONTAINER, or exits 2:
# without them nothing can be said about this checkout's stand
require_stand_info() {
    if ! LAUNCHER_INFO=$(cd "$REPO_ROOT" && node "$LAUNCHER" info 2>&1); then
        echo "the launcher could not name this checkout's stand:" >&2
        echo "$LAUNCHER_INFO" >&2
        exit 2
    fi
    INSTANCE=$(info_field 'Instance')
    PROJECT=$(info_field 'Compose project')
    CONTAINER=$(info_field 'Application container')
    if [ -z "$INSTANCE" ] || [ -z "$PROJECT" ] || [ -z "$CONTAINER" ]; then
        echo "unexpected output of docker-stand.js info (no instance, compose project or container):" >&2
        echo "$LAUNCHER_INFO" >&2
        exit 2
    fi
}

# The value of a `<label>: <value>` line of the launcher's info output
info_field() {
    echo "$LAUNCHER_INFO" | sed -n "s/^[[:space:]]*$1: //p" | head -1
}

# The launcher itself runs plain `docker`, so a docker that needs sudo is as good as none here
docker_ok() {
    docker info >/dev/null 2>&1
}

# running | stopped | absent | unknown (docker did not answer)
container_state() {
    local out
    if ! out=$(docker inspect -f '{{.State.Running}}' "$1" 2>&1); then
        case "$out" in
            *'No such'*) echo absent ;;
            *) echo unknown ;;
        esac
        return
    fi
    case "$out" in
        true) echo running ;;
        false) echo stopped ;;
        *) echo unknown ;;
    esac
}

# Host ports of the stand: the container keeps its pair even when stopped; the default stand
# without a container yet still owns 8010/8020
stand_ports() {
    local ports
    ports=$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}' "$CONTAINER" 2>/dev/null)
    if [ -z "${ports// /}" ] && [ "$INSTANCE" = default ]; then
        ports="$DEFAULT_CLIENT_PORT $DEFAULT_SERVER_PORT"
    fi
    echo "$ports"
}

# The comment block at the top of a script, after the shebang
print_usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
}

# The main checkout of this repository (the checkout itself when it is not a linked worktree)
main_checkout() {
    local common
    common=$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    (cd "$(dirname "$common")" && pwd -P)
}
