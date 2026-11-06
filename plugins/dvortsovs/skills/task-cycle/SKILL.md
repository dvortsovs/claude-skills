---
name: task-cycle
description: Run a development task through the full cycle with a team of agents — a Fable architect plans, a Claude and a Codex (frontier model) critic review the plan, a developer implements it, a Claude and a Codex reviewer review the code, parallel testers verify it on one dev stand with dvortsovs:stand-check. Invoke ONLY when the user explicitly names this skill — `/dvortsovs:task-cycle`, «task-cycle», «скилл task-cycle». Never invoke it on your own for a generic request to implement, plan or review something, however large.
---

# Task cycle

You are the **orchestrator**. You do not design, write or review code yourself: you hand work to role agents, move their artifacts between them, decide when a loop is done, and keep the user posted. Keeping your own context free of file dumps is part of the job — pass **paths** to agents, read their verdict lines, not their whole output.

```
0 intake ─► 1 architect ─► 2 critics ──changes──► 1
                              │ approve
                              ▼
                     (user approves plan)
                              ▼
            3 developer ─► 4 reviewers ──changes──► 3
                              │ approve
                              ▼
                      5 testers ∥ ──fails──► 3 ─► 4 ─► 5
                              │ passes
                              ▼
                          6 report
```

| Role | How it runs | Model |
|---|---|---|
| Architect | `Agent`, `subagent_type: general-purpose`, `model: fable` | Fable |
| Critic A | `Agent`, `subagent_type: general-purpose`, `model: opus` | Claude Opus |
| Critic B | `Bash` → `scripts/codex-run.sh` | Codex frontier (`gpt-6-astra`) |
| Developer | `Agent`, `subagent_type: general-purpose`, `model: opus` | Claude Opus |
| Reviewer A | `Agent`, `subagent_type: general-purpose`, `model: opus` | Claude Opus |
| Reviewer B | `Bash` → `scripts/codex-run.sh` | Codex frontier (`gpt-6-astra`) |
| Testers (1–4, parallel) | `Agent`, `subagent_type: general-purpose`, `model: opus`, use `dvortsovs:stand-check` in attached mode against the one stand you start | Claude Opus |

`<skill-dir>` below is the base directory the Skill tool printed when it loaded this skill. The prompt for every role is in [`references/prompts.md`](references/prompts.md) — read it once at the start; fill the placeholders, never paraphrase the verdict format, the loops below parse it.

## 0. Intake

1. **The task.** A ticket key (`CHARTS-1234`) or a link: read the ticket with whatever tracker tool the session has; if none, ask the user to paste the description. A free-form description: use it as is. Write the task, verbatim plus any clarifications, to `<run>/task.md` (step 3 below creates `<run>`).
2. **The branch.** Work happens in the current checkout. If it has uncommitted changes that are not part of this task, stop and ask. If you are on `main`, create a branch named per the repo's `AGENTS.md` (ticket key first: `CHARTS-1234-short-name`). Record the base branch (normally `main`) — reviewers diff against it.
3. **The run directory:**

   ```bash
   RUN=$(bash <skill-dir>/scripts/init-run.sh <ticket-or-branch>)
   ```

   It lives under `.git/task-cycle/`, so every agent, Codex included, can read it and nothing in it gets committed.
4. **Codex is usable:** `command -v codex`. If it is missing or a later run fails with an auth error, tell the user (`codex login`) — do not silently drop the Codex roles. Continuing with Claude-only critics and reviewers is the user's call, ask.
5. **Ask once, up front, in a single `AskUserQuestion`** (in the user's language), so the rest of the cycle can run unattended:
   - **Стенд** — which installation the tester will use: `YT`, `YC production`, `YC preprod`, `Без проверки на стенде`. The stand is the docker stand of the current checkout (the main one or a git worktree — each runs its own, see stand-check «One stand per checkout»). To show real commands and addresses in the descriptions, run `<skill-dir>/../stand-check/scripts/stand-config.sh` (stand-check ships in the same plugin) with `yt`, `yc`, `yc-preprod` from the checkout root. An installation whose `stand-config.sh` exits 1 (address unknown) or prints a non-empty `WARNING` (the host does not resolve to this machine, docker is down) carries that in its option description, as stand-check step 1 does; if the user picks it, settle it (the user gives the address, runs `pnpm docker:dev:dns` or fixes `/etc/hosts`, starts docker) before going on, and keep a given address as `STAND_URL` for step 5. Exit 2 (the checkout has no per-worktree launcher) — tell the user to rebase on `main`.
   - **Авторизация** — only when `<skill-dir>/../stand-check/scripts/prepare-auth.sh --dry-run` reports `AUTH_STATUS=would-copy` (a new worktree without its own auth file; the dry run copies nothing): «В worktree нет файла авторизации. Если стенд нужен, скопирую его из основного checkout в `<AUTH_FILE>` — обновите его до тестов: свежий запрос из devtools как cURL в этот файл.» — `Обновлю после копирования (Recommended)` / `Использовать копию как есть`.
   - **Утверждение плана** — `Показать план перед разработкой (Recommended)` / `Не останавливаться`.

   The number of parallel testers is not asked: the default is up to 3 (step 5); the user can set it in the request ("тестеров: 2", "один тестировщик").

   Each question has at most four options (the `AskUserQuestion` schema allows 2–4). Skip a question the request already answers. The auth file is this checkout's `projects/yandex/tests/artifacts/auth.txt`, or the one the user names in the request (pass it as `STAND_AUTH_FILE=<path>` to the stand-check scripts, here and in step 5). After the answers, and only when the stand is not skipped, run `prepare-auth.sh` without `--dry-run`: it copies the file in a new worktree (exit 3 — the copy failed, tell the user). `AUTH_STATUS=missing` from the dry run — ask for a file in the same call (`Без проверки на стенде` makes it unnecessary). Whether the refreshed file is alive is checked in step 5b. When `stand-config.sh` reports `STATE=running`, this checkout's stand is already up and is the user's: tell them in the **Стенд** question that step 5 restarts it.

Tell the user in one line that the cycle has started and where the artifacts are.

## 1. Architect

Spawn the architect with the **Architect** prompt. It reads the code, writes `<run>/plan/plan-v1.md` and returns a short summary. It must not edit the repository.

Keep the architect's agent id: revisions go to the **same** agent through `SendMessage`, so it keeps what it learned about the code. If the agent is gone (the session was resumed), spawn a fresh one with the Architect prompt plus the latest plan and the critiques.

## 2. Critics — loop until the plan holds

Each round `N` runs both critics **in parallel, in one message**:

- Critic A: `Agent` with the **Critic** prompt, output `<run>/review/plan-critic-claude-rN.md`.
- Critic B: write the same **Critic** prompt (with Codex's output path) to `<run>/prompts/plan-critic-codex-rN.md`, then

  ```bash
  bash <skill-dir>/scripts/codex-run.sh <run>/prompts/plan-critic-codex-rN.md <run>/review/plan-critic-codex-rN.md
  ```

  with `run_in_background: true`. A frontier run at `xhigh` takes minutes; wait for the notification, do not poll. The script writes Codex's final message to the output path itself.

When both are back, read only the first line (`VERDICT: …`) and the severities of each file:

```bash
head -1 <file>; grep -oE '\[(claude|codex)-[0-9]+\] (blocker|major|minor)' <file>
```

Do not anchor the grep at line start — Codex tends to put the findings in a bulleted list (`- [codex-1] …`). Read the full text of a finding only when you need it for a status line or an escalation.

- Both `APPROVE` (only `minor` findings left) → the plan is accepted. Minor findings go to the architect too if it is cheap, but they never block.
- Any `blocker` or `major` → `SendMessage` the architect: the paths of both critique files and the instruction to write `plan-v(N+1).md` with a **Resolution** section that answers every blocker/major by id — accepted and how, or rejected and why. A rejection with a reason is legitimate; the critics see it in the next round and either accept it or escalate.
- **Watch for whack-a-mole.** When a round's new blockers/majors are caused by the previous round's fixes and are of the same kind (each patch opens the next scenario of one state problem), name the shared root cause in the revision message and ask the architect to fix the cause, not the next scenario.
- **Round limit: 3.** If round 3 still has blockers/majors, stop the loop and bring the open disagreements to the user (each in two lines: what the critic says, what the architect says, plus the shared root cause if you see one) with `AskUserQuestion` — options: one more round with a stated direction, accept the plan and hand the open findings to the developer (who must report per id how it closed them; the reviewers check), or stop. Do not run a fourth round on your own.

A critic that failed to produce the file (Codex error, agent crash): retry once; if it fails again, tell the user and ask whether to continue with one critic.

**Plan approval** (if the user asked for it in step 0): show a summary — the approach in 3–5 lines, the files to touch, the stand checklist, rounds taken and anything rejected by the architect — plus the plan path, and ask `Начинаем разработку?` with options to proceed, to send a remark back to the architect (another plan revision, then the critics again), or to stop.

## 3. Developer

Spawn the developer with the **Developer** prompt and the accepted plan path. It implements the plan in the working tree, runs the repo's verification (lint, typecheck for the touched trees, the relevant unit tests) after its last edit, and writes `<run>/dev-report.md`. It does not commit unless the user asked for commits.

Keep its agent id: review fixes and tester fixes go back to the same agent through `SendMessage`.

## 4. Reviewers — loop until the code holds

Same mechanics as step 2, with the **Reviewer** prompt, both in parallel: Claude → `<run>/review/code-reviewer-claude-rN.md`, Codex → prompt in `<run>/prompts/code-reviewer-codex-rN.md`, output `<run>/review/code-reviewer-codex-rN.md`.

- Any `blocker`/`major` → `SendMessage` the developer with both review paths: fix or rebut each finding by id, re-run verification for what changed, append a **Fixes round N** section to `dev-report.md`. Then round `N+1` — the reviewers get the previous reviews and the dev report, and check that the findings are really closed, not only the new diff.
- **Round limit: 3**, then escalate to the user exactly as in step 2.

## 5. Testers — one stand, parallel checks

Skip if the user chose `Без проверки на стенде`.

You own the stand; the testers only attach to it. The stand is the docker stand of the current checkout (stand-check «One stand per checkout»): stop and start only that one — stands of other worktrees and the shared nginx belong to other work. Nothing that starts a stand or runs a typecheck may run in this checkout while the stand is up. `<sc>` below is `<skill-dir>/../stand-check` — the stand-check skill of the same plugin; read its `SKILL.md` once ("One stand per checkout", steps 3, 4, 7 and "Attached mode"), its scripts do the work.

**5a. Split the checklist.** Take the plan's **Stand checklist** plus the extra checks in `dev-report.md` (in a re-test: every item the previous round did not pass — failed, blocked, not checked, or in a group whose report was missing — plus the items the latest Fixes section lists and a short smoke of the main path; an item drops out only once it has passed after the latest fix). Split them into `K` groups and write them to `<run>/test/groups-rN.md`, one `## Group gk` section each (`g1`, `g2`, …):

- `K` = the user's number, else `min(3, ceil(items / 4))`, at most 4 — each tester runs its own Chromium next to the stand, and memory is the limit.
- Group by UI area/flow, so one tester does not reopen what another already set up.
- Items that share an entity or form a sequence (create → edit → reopen) stay in one group.
- Items that change user- or tenant-level state (language, theme, favourites, permissions) go together into one **exclusive** group, which runs **after** the parallel ones, alone — all testers share one logged-in user. Mark it `## Group gk (exclusive)`.

**5b. Bring the stand up** — stand-check steps 3 and 4, done by you, from the checkout root:

```bash
bash <sc>/scripts/stand-config.sh <yt|yc|yc-preprod>        # URL, CONTAINER, COMMAND, COOKIE_DOMAIN, WARNING
# step 3: prepare-auth.sh + the auth curl check from stand-check (never print the file)
bash <sc>/scripts/stop-stand.sh <url>                       # this checkout's stand only
<COMMAND> > <run>/test/stand-start-rN.log 2>&1              # --detach: returns once the containers are up
docker logs -f <CONTAINER> > <run>/test/stand-rN.log 2>&1   # run_in_background
bash <sc>/scripts/wait-stand.sh <url> 1800 <CONTAINER>      # run_in_background
```

Before starting: if `stand-config.sh` exits 1 or prints a `WARNING` the user has not settled in step 0, stop and settle it with the user — a host that resolves to another machine answers `wait-stand.sh` with someone else's code. Use `STAND_URL=<settled address>` in front of the scripts when step 0 settled one. The launcher's warnings in `stand-start-rN.log` (a certificate that does not cover the address, a name taken by another directory) are stand-check step 4's to handle.

Dead auth, a launcher that refuses to start, a container that stops (`wait-stand.sh` prints its log tail), a stale `SERVICE_ACCOUNT_IAM_TOKEN` for YC production → this round is `BLOCKED`: stop the stand, tell the user what to do (stand-check says what), wait.

**Warm-up, bounded.** Once `wait-stand.sh` succeeds, open the stand in a throwaway agent-browser session `tc-rN-warmup` exactly as stand-check step 5 does — `open --ignore-https-errors` on a session name not used before, `cookies set --curl <auth-file> --domain <cookie-domain>`, then open the stand again — and reload until the app renders, for at most 5 minutes. A landing or login page instead of the app is an auth problem, not a build problem: `BLOCKED`, stop the stand, ask the user to re-export the auth file. A compile-error overlay (or errors in `stand-rN.log`) means the code does not build: stop the stand, and the round is `FAIL` with the error text — it goes to the developer. Still blank after 5 minutes with no error → `BLOCKED`, stop the stand. Close the warm-up session either way.

**5c. Spawn the testers in parallel, in one message**, with the **Tester** prompt — one per parallel group, each with: its group id (`gk`) and `groups-rN.md`, mode `parallel`, the stand URL and cookie domain, the auth file, a session prefix `tc-rN-gk`, an entity prefix `tc-rN-gk-`, and output `<run>/test/report-rN-gk.md`. When they are all back, the exclusive group, if any, alone, with mode `exclusive`.

**5d. Stop the stand — always**, once every tester is back (or the round is abandoned for any reason): `bash <sc>/scripts/stop-stand.sh <url>` — it must exit 0, nothing of this checkout left (1: something is left or docker did not answer; 2: nothing was stopped) — and stop the background `docker logs -f` task. A tester that never returns does not keep the stand alive: stop it, and that group counts as `BLOCKED` (step 5e).

**5e. Merge the verdicts.** First normalise each group: a missing report file, one whose first line is not a valid `VERDICT:`, or a `PASS` that leaves any of its assigned items "not checked" counts as `BLOCKED` for that group (list the unchecked items). Then: `FAIL` if any group failed because of the implementation; otherwise `BLOCKED` if any group is blocked; `PASS` only when every group passed with every assigned item checked. Write `<run>/test/report-rN.md`: the merged verdict line, the stand and auth used, one line per group (verdict + report path), and the failed items with their evidence copied from the group reports.

- `PASS` → step 6.
- `FAIL` → `SendMessage` the developer with `report-rN.md` (the stand is down by now — the developer's typecheck must not run next to it), then the review loop of step 4 on the fix, run to `APPROVE` by both reviewers exactly as there (round numbering continues, the same limit of 3 rounds counts per fix), then step 5 again with a re-test split. Never re-test code the reviewers have not approved. **Limit: 2** tester rounds, then escalate.
- `BLOCKED` (dead auth, stand would not start, an expired token, missing data) → the code is not at fault; relay the instruction to the user and wait. Do not send it to the developer.

## 6. Report

To the user, in their language, short, outcome first:

- what was done (3–5 lines) and the branch;
- rounds: plan N, code N, stand N, and any finding left open (minor, or rejected with a reason) — with ids, so they can be looked up;
- stand result with the main evidence (testers × groups), or why it was skipped/blocked;
- verification the developer ran and its result;
- the run directory, for the full plans, critiques, reviews and test reports;
- next step: nothing is committed or pushed unless the user asked. Offer to commit and open a PR, with a title in the repo's format (`CHARTS-1234: Description`).

## Rules that hold throughout

- **Status lines.** After every phase transition and every round, tell the user one line: `План v2: критики — 1 major (Codex), архитектор дорабатывает`. Long phases run in the background; you are re-invoked when they finish.
- **Verdicts decide, not your opinion.** You may drop a finding as out of scope only by saying so to the user; you never "fix" a plan or code yourself to save a round.
- **Same criteria for Claude and Codex.** Both critics get the identical prompt text, both reviewers too — only the output path differs. Disagreement between them is signal; resolve it through the architect/developer, not by picking a favourite.
- **No mutations outside the task.** No commits, pushes, PRs, ticket comments or backend changes beyond what the stand check needs, unless the user asked.
- **Interruptions.** If the user interrupts with a remark, route it to the role it concerns (architect for design, developer for code) and continue the loop from there.
