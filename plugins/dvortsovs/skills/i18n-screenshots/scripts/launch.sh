#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: launch.sh <session> <url> <auth-file> <cookie-domain>

(Re)starts an agent-browser session for screenshots on a stand that dvortsovs:stand-check has
brought up, and opens <url>:
  - restarts the session, because --ignore-https-errors and init scripts apply only at launch;
  - registers stub.js (XHR/fetch mocks and window.DL overrides, driven by localStorage);
  - imports the cookies of <auth-file> (stand-check's AUTH_FILE: "Copy as cURL", a Cookie header
    or a storageState JSON) for <cookie-domain> (stand-check's COOKIE_DOMAIN), never printing them;
  - sets the viewport ($VIEWPORT, default "1600 1000 2" — width, height, scale) and a light
    colour scheme.
Prints the final url, whether the light theme is on and whether the stub is active.
EOF
}

if [[ "${1:-}" == "--help" || $# -lt 4 ]]; then
    usage
    [[ "${1:-}" == "--help" ]] && exit 0 || exit 1
fi

SESSION=$1
URL=$2
AUTH=$3
DOMAIN=$4
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ORIGIN=$(node -e 'console.log(new URL(process.argv[1]).origin)' "$URL")
AB=(agent-browser --session "$SESSION")

if [[ ! -f "$AUTH" ]]; then
    echo "Auth file not found: $AUTH" >&2
    exit 1
fi

"${AB[@]}" close >/dev/null 2>&1 || true
"${AB[@]}" --ignore-https-errors --init-script "$SCRIPT_DIR/stub.js" open "$ORIGIN/" >/dev/null
"${AB[@]}" cookies set --curl "$AUTH" --domain "$DOMAIN" >/dev/null
# shellcheck disable=SC2086
"${AB[@]}" set viewport ${VIEWPORT:-1600 1000 2} >/dev/null
"${AB[@]}" set media light >/dev/null
"${AB[@]}" open "$URL" >/dev/null
"${AB[@]}" wait --load networkidle >/dev/null
"${AB[@]}" eval 'JSON.stringify({url: location.href, light: document.body.classList.contains("g-root_theme_light"), stub: XMLHttpRequest.prototype.send.toString().includes("findMock")})'
