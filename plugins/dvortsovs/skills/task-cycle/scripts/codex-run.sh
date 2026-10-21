#!/usr/bin/env bash
# Run one Codex role (critic or reviewer) non-interactively, read-only, in the target repo.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: codex-run.sh [--dry-run] <prompt-file> <output-file>

Runs `codex exec` in a read-only sandbox from the repository that contains the
current working directory (or TASK_CYCLE_REPO_ROOT), feeding it <prompt-file>
on stdin. Codex's final message is written to <output-file>; its full log goes
to <output-file>.log.

Environment:
  TASK_CYCLE_CODEX_MODEL   model slug     (default: gpt-6-astra, the frontier model)
  TASK_CYCLE_CODEX_EFFORT  reasoning effort (default: xhigh)
  TASK_CYCLE_REPO_ROOT     repository to run in (default: git toplevel of $PWD)

Exit codes: 0 - output written; 1 - codex failed or produced no output (see the log);
2 - bad arguments or codex is not installed.
USAGE
}

dry_run=0
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
if [[ "${1:-}" == "--dry-run" ]]; then dry_run=1; shift; fi
if [[ $# -ne 2 ]]; then usage >&2; exit 2; fi

prompt_file=$1
output_file=$2
model=${TASK_CYCLE_CODEX_MODEL:-gpt-6-astra}
effort=${TASK_CYCLE_CODEX_EFFORT:-xhigh}
repo_root=${TASK_CYCLE_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}

if [[ -z "$repo_root" ]]; then echo "Not inside a git repository; set TASK_CYCLE_REPO_ROOT." >&2; exit 2; fi
if [[ ! -s "$prompt_file" ]]; then echo "Prompt file is missing or empty: $prompt_file" >&2; exit 2; fi
if ! command -v codex >/dev/null 2>&1; then echo "codex is not installed (brew install codex / npm i -g @openai/codex)." >&2; exit 2; fi

cmd=(codex exec -m "$model" -c "model_reasoning_effort=\"$effort\"" -s read-only --ephemeral
    -C "$repo_root" -o "$output_file" -)

if [[ $dry_run -eq 1 ]]; then
    printf '%q ' "${cmd[@]}"; printf '< %q\n' "$prompt_file"
    exit 0
fi

rm -f "$output_file"
started=$(date +%s)
status=0
"${cmd[@]}" < "$prompt_file" > "$output_file.log" 2>&1 || status=$?
elapsed=$(( $(date +%s) - started ))

if [[ $status -ne 0 || ! -s "$output_file" ]]; then
    echo "codex failed (exit $status, ${elapsed}s, model $model). Last log lines:" >&2
    tail -20 "$output_file.log" >&2
    exit 1
fi
echo "codex done in ${elapsed}s (model $model, effort $effort): $output_file"
