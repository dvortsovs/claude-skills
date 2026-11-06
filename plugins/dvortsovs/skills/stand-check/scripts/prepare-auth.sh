#!/usr/bin/env bash
# Make sure the checkout under test has its own auth file, at the same path in every checkout.
#
#   prepare-auth.sh [--dry-run] [--help]
#
#   --dry-run   change nothing; a file that would be copied is reported as AUTH_STATUS=would-copy
#
# The auth file is projects/yandex/tests/artifacts/auth.txt of the current checkout (the main one or a
# git worktree; STAND_AUTH_FILE overrides it). It is gitignored, so a new worktree has none: then the
# main checkout's file is copied in (mode 600), and the caller asks the user to refresh it — the copy
# may be stale, and the worktree keeps its own file from now on.
#
# Prints shell-style KEY=VALUE lines:
#   AUTH_FILE    absolute path of the auth file to use
#   AUTH_STATUS  present (already there) | copied (copied from COPIED_FROM just now) |
#                would-copy (--dry-run) | missing
#   COPIED_FROM  the main checkout's file, when AUTH_STATUS=copied or would-copy
#
# Never prints the file's contents. Exit code 0 when AUTH_FILE exists (or would be copied), 1 when it
# is missing everywhere (ask the user for one), 2 outside a datalens-ui checkout, 3 when the copy failed.
set -u

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEFAULT_AUTH_FILE="projects/yandex/tests/artifacts/auth.txt"

DRY_RUN=0
case "${1:-}" in
    -h | --help)
        print_usage "${BASH_SOURCE[0]}"
        exit 0
        ;;
    --dry-run) DRY_RUN=1 ;;
    '') ;;
    *)
        echo "unknown argument: $1" >&2
        exit 2
        ;;
esac

require_checkout

if [ -n "${STAND_AUTH_FILE:-}" ]; then
    case "$STAND_AUTH_FILE" in
        /*) AUTH_FILE=$STAND_AUTH_FILE ;;
        *) AUTH_FILE="${REPO_ROOT}/${STAND_AUTH_FILE}" ;;
    esac
    STATUS=missing
    [ -s "$AUTH_FILE" ] && STATUS=present
    echo "AUTH_FILE=${AUTH_FILE}"
    echo "AUTH_STATUS=${STATUS}"
    [ "$STATUS" = present ]
    exit $?
fi

AUTH_FILE="${REPO_ROOT}/${DEFAULT_AUTH_FILE}"
STATUS=missing
COPIED_FROM=''
if [ -s "$AUTH_FILE" ]; then
    STATUS=present
else
    main=$(main_checkout)
    source_file="${main}/${DEFAULT_AUTH_FILE}"
    if [ -n "$main" ] && [ "$main" != "$REPO_ROOT" ] && [ -s "$source_file" ]; then
        COPIED_FROM=$source_file
        if [ "$DRY_RUN" -eq 1 ]; then
            STATUS=would-copy
        elif mkdir -p "$(dirname "$AUTH_FILE")" && cp -p "$source_file" "$AUTH_FILE" &&
            chmod 600 "$AUTH_FILE" && [ -s "$AUTH_FILE" ]; then
            STATUS=copied
        else
            rm -f "$AUTH_FILE"
            echo "could not copy ${source_file} to ${AUTH_FILE}" >&2
            echo "AUTH_FILE=${AUTH_FILE}"
            echo "AUTH_STATUS=missing"
            exit 3
        fi
    fi
fi

echo "AUTH_FILE=${AUTH_FILE}"
echo "AUTH_STATUS=${STATUS}"
[ -n "$COPIED_FROM" ] && echo "COPIED_FROM=${COPIED_FROM}"
[ "$STATUS" != missing ]
