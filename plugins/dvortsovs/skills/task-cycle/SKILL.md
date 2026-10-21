---
name: task-cycle
description: Run a development task through the full cycle with a team of agents — a Fable architect plans, a Claude and a Codex (frontier model) critic review the plan, a developer implements it, a Claude and a Codex reviewer review the code, a tester verifies it on the dev stand with dvortsovs:stand-check. Invoke ONLY when the user explicitly names this skill — `/dvortsovs:task-cycle`, «task-cycle», «скилл task-cycle». Never invoke it on your own for a generic request to implement, plan or review something, however large.
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
                          5 tester ──fails──► 3 ─► 4 ─► 5
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
| Tester | `Agent`, `subagent_type: general-purpose`, `model: opus`, uses `dvortsovs:stand-check` | Claude Opus |

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
   - **Стенд** — which installation the tester will use: `YC`, `YT`, `Без проверки на стенде`.
   - **Режим** — `native (dev VM)` / `docker (локальная машина)`, the one `stand-config.sh detect` reports marked `(Recommended)`. To show real commands and addresses in the descriptions, run the stand-check scripts if you can locate them (`~/.claude/plugins/cache/*/dvortsovs/*/skills/stand-check/scripts/stand-config.sh`, newest version: `detect`, then `yc`, `yt`, `yc-docker`, `yt-docker`); otherwise give the bare names.
   - **Авторизация** — `projects/yandex/tests/artifacts/auth.txt (Recommended)` or another file.
   - **Утверждение плана** — `Показать план перед разработкой (Recommended)` / `Не останавливаться`.

   That is four questions — the `AskUserQuestion` maximum, and each has at most four options (its schema allows 2–4), so do not merge installation and mode into one question. Skip a question the request already answers; drop **Режим** and **Авторизация** when the stand is skipped.

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

## 5. Tester

Skip if the user chose `Без проверки на стенде`.

Spawn the tester with the **Tester** prompt: it loads `dvortsovs:stand-check`, uses the installation and auth file the user already chose, checks the **Stand checklist** from the plan plus anything the dev report added, and writes `<run>/test/report-rN.md`. It only verifies — it never edits code — and always stops the stand.

Only one stand runs at a time on the machine: never run the tester in parallel with anything that starts a stand or runs a typecheck.

- `VERDICT: PASS` → step 6.
- `VERDICT: FAIL` because of the implementation → `SendMessage` the developer with the test report, then the review loop of step 4 on the fix, run to `APPROVE` by both reviewers exactly as there (round numbering continues, the same limit of 3 rounds counts per fix), then the tester again. Never re-test code the reviewers have not approved. **Limit: 2** tester rounds, then escalate.
- `VERDICT: BLOCKED` (dead auth, stand would not start, TVM) → the code is not at fault; relay the tester's instruction to the user and wait. Do not send it to the developer.

## 6. Report

To the user, in their language, short, outcome first:

- what was done (3–5 lines) and the branch;
- rounds: plan N, code N, stand N, and any finding left open (minor, or rejected with a reason) — with ids, so they can be looked up;
- stand result with the main evidence, or why it was skipped/blocked;
- verification the developer ran and its result;
- the run directory, for the full plans, critiques, reviews and test reports;
- next step: nothing is committed or pushed unless the user asked. Offer to commit and open a PR, with a title in the repo's format (`CHARTS-1234: Description`).

## Rules that hold throughout

- **Status lines.** After every phase transition and every round, tell the user one line: `План v2: критики — 1 major (Codex), архитектор дорабатывает`. Long phases run in the background; you are re-invoked when they finish.
- **Verdicts decide, not your opinion.** You may drop a finding as out of scope only by saying so to the user; you never "fix" a plan or code yourself to save a round.
- **Same criteria for Claude and Codex.** Both critics get the identical prompt text, both reviewers too — only the output path differs. Disagreement between them is signal; resolve it through the architect/developer, not by picking a favourite.
- **No mutations outside the task.** No commits, pushes, PRs, ticket comments or backend changes beyond what the stand check needs, unless the user asked.
- **Interruptions.** If the user interrupts with a remark, route it to the role it concerns (architect for design, developer for code) and continue the loop from there.
