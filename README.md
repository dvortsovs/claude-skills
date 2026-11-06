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
DataLens docker dev stand, end to end: asks which installation (YT / YC
production / YC preprod / other), takes the checkout's own auth file (copying
it from the main checkout into a new worktree and asking you to refresh it),
checks that the auth session is alive before spending minutes on a build, restarts the stand of
the current checkout — the main one or a git worktree, each runs its own —
leaving the other worktrees' stands and the shared nginx alone, drives the UI
with [agent-browser](https://www.npmjs.com/package/agent-browser) against the
real backend, stops that stand, and reports each check with the evidence that
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

Run it from the DataLens checkout under test (`datalens-ui-private` or one of
its worktrees): the scripts find the checkout from the working directory.

### Attached mode

When a caller already runs the stand — `dvortsovs:task-cycle` starts one and
points several parallel testers at it — the skill skips the questions, the
auth check and the stop/start steps, works only in the browser session it
was given, prefixes the entities it creates, leaves user-level settings alone,
and never stops the stand: the caller does. Parallel agent-browser sessions are
isolated (own tabs, cookies, init scripts), so testers do not see each other's
state in the browser — only on the shared backend. A stand you point it at by
URL is treated the same way: checked, not restarted.

### One stand per checkout

The repo's launcher `projects/yandex/scripts/dev/docker-stand.js` gives every
checkout its own stand behind one shared nginx:

| Checkout | Container | Address (YT; YC follows `ENV`) |
|---|---|---|
| main | `datalens-ui-yandex-dev` | `https://<PROJECT_NAME>.<user>.ui.yandex-team.ru` |
| worktree `<dir>` | `datalens-ui-yandex-<dir>-dev` | `https://<dir>.<user>.ui.yandex-team.ru` |

The skill reads the names and addresses from the launcher's `info`, starts
the stand with `--detach`, and stops it with the launcher's `stop`. Several
sessions can check in parallel from different worktrees; within one checkout
YT and YC replace each other.

### What it needs on the machine

| What | Why |
|---|---|
| Docker (Colima) set up per `docs/dev/docker-dev.md` of the DataLens repo, the certificates in `projects/yandex/dev/docker/crt/` (a wildcard one for worktree addresses) | the stand |
| The stand address resolving to `127.0.0.1`: `pnpm docker:dev:dns` once for all worktree stands, or `/etc/hosts` | the browser reaches the local nginx |
| A checkout that has `docker-stand.js` (worktrees on old branches don't) | per-checkout stands |
| `npm i -g agent-browser` | the browser |
| `projects/yandex/tests/artifacts/auth.txt` in the checkout under test | a curl command copied from the browser devtools with a live session (gitignored); a Playwright `storageState` JSON works too. A new worktree gets a copy of the main checkout's file, to be refreshed |

Overrides: `STAND_URL`, `STAND_AUTH_FILE`, `STAND_REPO_ROOT`, `STAND_ENV` in the
environment; `DEV_INSTANCE` and `PROJECT_NAME` go to the launcher.

### Scripts

All under `plugins/dvortsovs/skills/stand-check/scripts/`, each with `--help`:

| Script | Does |
|---|---|
| `stand-config.sh <yt\|yc\|yc-preprod>` | prints this checkout's instance, container and its state, the start command, stand URL (and what it resolves to), cookie domain and auth file |
| `stop-stand.sh [--dry-run] [--pattern <ere>] [url]` | stops this checkout's stand: host processes started from it, by pid, and its containers; confirms no process, container or host-port listener of it is left (exit 0), or says what is left or unknown (1, 2) |
| `prepare-auth.sh [--dry-run]` | resolves this checkout's auth file; in a new worktree copies the main checkout's one there (never prints its contents) |
| `wait-stand.sh <url> [timeout] [container]` | polls until the stand answers through nginx, gives up early when the container stops |

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
| test | 1–4 testers in parallel on **one** stand the orchestrator starts and stops; each takes a group of the plan's stand checklist and runs `dvortsovs:stand-check` in attached mode with its own browser session and entity prefix | Claude Opus subagents |

All questions are asked once at the start (stand installation, refreshing a
worktree's copied auth file, whether to stop for plan approval), so the rest
runs unattended until a loop
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
