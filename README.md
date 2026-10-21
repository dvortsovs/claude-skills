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
/plugin install dvortsovs@dvortsovs-skills
```

The marketplace registers under the name `dvortsovs-skills` (the repository is
`claude-skills`), so it does not clash with other personal marketplaces that
use the repository name.

## Update

```text
/plugin marketplace update dvortsovs-skills
/plugin update dvortsovs@dvortsovs-skills
/reload-plugins
```

From a shell: `claude plugin marketplace update dvortsovs-skills`, then
`claude plugin update dvortsovs@dvortsovs-skills`, then restart Claude Code.
`claude plugin list` shows the installed version.

---

## `dvortsovs:stand-check`

Verifies the change you are working on in a real browser against your own
DataLens dev stand, end to end: asks which installation (YC / YT, native on a
dev VM or docker on a local machine / other) and which auth file to use, checks that the auth session is alive before spending
minutes on a build, makes sure TVM is healthy for YT (refreshing it only when
the config in `/etc/tvmtool` has drifted from Secretnica or the daemon is
down), stops every running dev stand — native processes and docker-mode
containers, including ones started elsewhere — starts a fresh one, drives the UI with
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

### Native and docker stands

| Mode | Where | Start command | Address |
|---|---|---|---|
| native | dev VM with host nginx (+ tvmtool for YT) | `pnpm run yc:dev`, `pnpm run yt:dev` | `server_name` from `projects/yandex/dev-nginx/nginx.conf` |
| docker | local machine, containers of compose project `datalens-ui-yandex` | `pnpm run yc:dev:docker:no-typecheck`, `pnpm run yt:dev:docker:no-typecheck` | `https://<PROJECT_NAME>.<user>.<suffix>` from the compose nginx template; the host must point at the machine (`/etc/hosts`) |

The default is detected: native when the host nginx config exists, docker
otherwise. In docker mode `tvmtool` is a container, so the TVM refresh is
skipped, and the stand is stopped with `docker stop` as well as by pid.

### What it needs on the machine

| What | Why |
|---|---|
| A dev VM set up per `docs/dev/setup.md` of the DataLens repo, or docker with the certificates in `projects/yandex/dev/docker/crt/` | native or docker stand |
| `npm i -g agent-browser` | the browser |
| `projects/yandex/tests/artifacts/auth.txt` | a curl command copied from the browser devtools with a live session (gitignored); a Playwright `storageState` JSON works too |
| YT only: `tvmtool`, passwordless `sudo`, `yav` logged in | for the automatic TVM refresh |

Overrides: `STAND_URL`, `STAND_AUTH_FILE`, `STAND_REPO_ROOT`, `PROJECT_NAME` in the environment.

### Scripts

All under `plugins/dvortsovs/skills/stand-check/scripts/`, each with `--help`:

| Script | Does |
|---|---|
| `stand-config.sh <yc\|yt\|yc-docker\|yt-docker\|detect>` | prints the mode, start command, stand URL (and what it resolves to), cookie domain, auth file and whether the host TVM is needed; `detect` picks the default mode |
| `ensure-tvm.sh [--dry-run] [--force]` | checks `tvmtool`, refreshes its config from Secretnica only when needed |
| `stop-stand.sh [--dry-run] [--pattern <ere>] [url]` | stops every dev stand process by pid and the docker-mode containers, confirms nothing is left |
| `wait-stand.sh <url> [timeout]` | polls until the stand answers through nginx |

---

## `dvortsovs:task-cycle`

Runs one development task through a full cycle of agents, with the session
you invoke it in acting as the orchestrator:

| Phase | Role | Runs as |
|---|---|---|
| plan | architect — analyses the current code, writes architecture + execution plan + stand checklist | Claude subagent, Fable |
| plan review | two critics, in parallel; changes requested → back to the architect (max 3 rounds) | Claude Opus subagent + `codex exec`, frontier model |
| implement | developer — follows the plan, runs lint / typecheck / unit tests | Claude Opus subagent |
| code review | two reviewers, in parallel; changes requested → back to the developer (max 3 rounds) | Claude Opus subagent + `codex exec`, frontier model |
| test | tester — checks the plan's stand checklist on the live dev stand via `dvortsovs:stand-check` | Claude Opus subagent |

All questions are asked once at the start (stand installation, auth file,
whether to stop for plan approval), so the rest runs unattended until a loop
hits its round limit. Plans, critiques, reviews and test reports go to
`.git/task-cycle/<slug>-<timestamp>/` of the target repo — readable by every
agent, never committed. Nothing is committed or pushed unless you ask.

The workflow is in [SKILL.md](plugins/dvortsovs/skills/task-cycle/SKILL.md),
the role prompts in
[references/prompts.md](plugins/dvortsovs/skills/task-cycle/references/prompts.md).

### Usage

It runs only when invoked explicitly — by the command or by naming the skill
(«запусти task-cycle на …»); Claude never starts it on its own, since one run
spends a lot of tokens of two providers.

```text
/dvortsovs:task-cycle CHARTS-1234
/dvortsovs:task-cycle добавить сортировку в список воркбуков, без стенда
```

### What it needs

| What | Why |
|---|---|
| `codex` CLI, logged in (`codex login`) | the Codex critic and reviewer |
| everything `stand-check` needs | the tester |

Codex runs read-only (`-s read-only --ephemeral`) through
`scripts/codex-run.sh`. Overrides: `TASK_CYCLE_CODEX_MODEL` (default
`gpt-6-astra`), `TASK_CYCLE_CODEX_EFFORT` (default `xhigh`).
