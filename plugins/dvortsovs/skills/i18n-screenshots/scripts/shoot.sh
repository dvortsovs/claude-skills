#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: shoot.sh <session> <screens.json> <screen> <out-dir>

Draws the annotation overlay for <screen> on the page currently open in <session>, saves the
whole viewport — never a cropped part of it — to <out-dir>/NN-<screen>.png (NN = the screen's
position in screens.json) and removes the overlay.
Prints the overlay result {"missing": [...], "offscreen": [...], "covered": [...], "found": n}
and the file. Exits 1 when an item is missing, outside the viewport or covered by a label.
The page must already be in the state the screen describes.
EOF
}

if [[ "${1:-}" == "--help" || $# -lt 4 ]]; then
    usage
    [[ "${1:-}" == "--help" ]] && exit 0 || exit 1
fi

SESSION=$1
SPEC=$2
SCREEN=$3
OUT=$4
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AB=(agent-browser --session "$SESSION")

INDEX=$(node -e '
    const spec = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log(String(Object.keys(spec.screens).indexOf(process.argv[2]) + 1).padStart(2, "0"));
' "$SPEC" "$SCREEN")
mkdir -p "$OUT"
FILE="$OUT/$INDEX-$SCREEN.png"

RESULT=$(node "$SCRIPT_DIR/render.mjs" "$SPEC" "$SCREEN" | "${AB[@]}" eval --stdin)
echo "$RESULT"
if [[ "$RESULT" == *error* ]]; then
    exit 1
fi
"${AB[@]}" screenshot "$FILE" >/dev/null
"${AB[@]}" eval 'window.__annotateCleanup()' >/dev/null
echo "$FILE"
CLEAN=$(printf '%s' "$RESULT" | tr -d '\\ ')
for field in missing offscreen covered; do
    if [[ "$CLEAN" != *"\"$field\":[]"* ]]; then
        exit 1
    fi
done
