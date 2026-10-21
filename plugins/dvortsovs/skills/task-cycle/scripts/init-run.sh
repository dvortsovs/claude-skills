#!/usr/bin/env bash
# Create the artifact directory for one task-cycle run and print its path.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: init-run.sh <slug>

Creates <git-common-dir>/task-cycle/<slug>-<YYYYmmdd-HHMMSS>/ with plan/, review/,
prompts/ and test/ subdirectories, and prints the absolute path. Living inside the
.git directory keeps the artifacts next to the repo, readable by every agent
(Codex included), and never committed. <slug> is usually the ticket key or the branch.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
if [[ $# -ne 1 ]]; then usage >&2; exit 2; fi

slug=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')
common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
run_dir="$common_dir/task-cycle/$slug-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run_dir"/{plan,review,prompts,test}
echo "$run_dir"
