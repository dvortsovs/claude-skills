# claude-skills

A personal library of reusable [Claude Code](https://code.claude.com/docs)
skills for DataLens development, packaged as a plugin marketplace. Skills are
installed into any checkout with `/plugin install` — they live here, not in the
repos that use them.

Skills are grouped under `dvortsovs`, a personal namespace plugin, and invoked
as `dvortsovs:<skill>`.

## Install

```text
/plugin marketplace add dvortsovs/claude-skills
/plugin install dvortsovs@claude-skills
```

## Update

```text
/plugin marketplace update claude-skills
/plugin update dvortsovs@claude-skills
/reload-plugins
```

From a shell: `claude plugin marketplace update claude-skills`, then
`claude plugin update dvortsovs@claude-skills`, then restart Claude Code.
`claude plugin list` shows the installed version.

---

## `dvortsovs:stand-check`

Verifies the change you are working on in a real browser against your own
DataLens dev stand, end to end: asks which installation (YC / YT / other) and
which auth file to use, checks that the auth session is alive before spending
minutes on a build, makes sure TVM is healthy for YT (refreshing it only when
the config in `/etc/tvmtool` has drifted from Secretnica or the daemon is
down), stops every running dev stand — including ones started elsewhere —
starts a fresh one, drives the UI with
[agent-browser](https://www.npmjs.com/package/agent-browser) against the real
backend, stops the stand, and reports each check with the evidence that
decided it.

The workflow is in [SKILL.md](plugins/dvortsovs/skills/stand-check/SKILL.md);
the traps of driving the DataLens UI with agent-browser (HTTPS flag, mocks that
silently don't work, Gravity widgets, selectors that held up) are in
[references/agent-browser-notes.md](plugins/dvortsovs/skills/stand-check/references/agent-browser-notes.md).

### Usage

Claude triggers it on its own when you ask to «проверить на стенде» /
"check this on the stand"; it can also be invoked directly:

```text
/dvortsovs:stand-check
/dvortsovs:stand-check на YT
```

Run it from the DataLens checkout (`datalens-ui-private`): the scripts find
the repo from the working directory.

### What it needs on the machine

| What | Why |
|---|---|
| A dev VM set up per `docs/dev/setup.md` of the DataLens repo | nginx config (`projects/yandex/dev-nginx/nginx.conf`) is where the stand address comes from |
| `npm i -g agent-browser` | the browser |
| `projects/yandex/tests/artifacts/auth.txt` | a curl command copied from the browser devtools with a live session (gitignored); a Playwright `storageState` JSON works too |
| YT only: `tvmtool`, passwordless `sudo`, `yav` logged in | for the automatic TVM refresh |

Overrides: `STAND_URL`, `STAND_AUTH_FILE`, `STAND_REPO_ROOT` in the environment.

### Scripts

All under `plugins/dvortsovs/skills/stand-check/scripts/`, each with `--help`:

| Script | Does |
|---|---|
| `stand-config.sh <yc\|yt>` | prints the start command, stand URL, cookie domain, auth file and whether TVM is needed |
| `ensure-tvm.sh [--dry-run] [--force]` | checks `tvmtool`, refreshes its config from Secretnica only when needed |
| `stop-stand.sh [--dry-run] [--pattern <ere>] [url]` | stops every dev stand process by pid, confirms no socket listener is left |
| `wait-stand.sh <url> [timeout]` | polls until the stand answers through nginx |
