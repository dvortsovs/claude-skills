---
name: stand-check
description: Verify the current implementation on the developer's own live docker dev stand in a real browser — asks which installation (YT / YC production / YC preprod / other), takes the checkout's own auth file (copying it from the main checkout into a new worktree and asking the user to refresh it), resolves the stand of the current checkout (the main one or a git worktree, each runs its own stand) with the repo's launcher, restarts only that stand, drives the UI with agent-browser, then stops that stand and reports. Use whenever the user says «проверить на стенде», «проверь на стенде», «проверка на стенде», «посмотри на стенде», "check on the stand", "verify on the dev stand", or otherwise asks to see a change working on their stand — even when they name neither agent-browser nor the start command.
---

# Stand check

Verify that the implementation actually works in a browser against a running dev stand. Developers ask for this constantly, with the same parameters each time; this skill holds the parameters and the traps so they don't have to be retyped or rediscovered.

The whole run is one sequence: **ask → check auth → stop this checkout's stand → start it fresh → drive the UI → stop it → report**.

Scripts live in `scripts/` next to this file: `<skill-dir>` below is the base directory the Skill tool prints when it loads this skill. Run them with the root of the checkout under test as the working directory — the main checkout or a git worktree; they find it from there (or from `STAND_REPO_ROOT`).

## One stand per checkout

The stand runs in docker on the local machine. Every checkout has its own stand — the main checkout the default one, each git worktree one named after its directory — with its own compose project, containers, host ports and address; one shared nginx container (`datalens-ui-yandex-nginx`) on port 443 routes each address to its stand. The repo's launcher `projects/yandex/scripts/dev/docker-stand.js` (behind `pnpm *:dev:docker*` and `pnpm docker:dev:*`) does the naming; `docs/dev/docker-runtime.md` → «Несколько стендов: git worktree» in the DataLens repo is the reference.

So the stand under test is **the stand of the checkout you work in**, and only that one is yours to stop and start:

- Stands of other worktrees may be someone's work in progress — another session, another agent, the user. Never stop, restart or remove them, and never stop the shared nginx. `pnpm docker:dev:list` shows them all, with their checkout directories.
- YT and YC of one checkout share the compose project and `dist`, so they never run at once: starting one replaces the other.
- A checkout without `docker-stand.js` (a worktree on an old branch) has no stand of its own: the scripts exit 2 — tell the user to rebase it on `main`.

## Attached mode: a stand someone else runs

Sometimes the stand is already up and owned by the caller — `dvortsovs:task-cycle` starts one stand and runs several testers against it in parallel, each with its own slice of the checklist. The caller says so explicitly ("attached mode", either **parallel** or **exclusive**) and passes the stand URL, cookie domain, auth file, a browser-session prefix and an entity prefix. Then this skill shrinks to **verify the stand answers → open it → run your checks → close your browser session → report**:

- **Skip** step 1 (no questions), step 3 (the caller checked auth), step 4 (no stop, no start) and the `stop-stand.sh` call of step 7.
- **Never** run `stop-stand.sh`, restart the stand, stop containers or kill dev processes, run `agent-browser close --all`, or touch a session outside your prefix — other testers may be using the same stand at the same time.
- First make sure the stand answers: `bash <skill-dir>/scripts/wait-stand.sh <stand-url> 60`. If it does not, or it goes down mid-run, do not try to bring it back: stop and report the checks as not run because the stand is down.
- **Browser sessions.** Every session you open is named `<session-prefix>-<n>` (`-1`, `-2`, …): a session isolates your tabs, cookies and init scripts from the other testers. Step 5's "a session name not used before" and the mock recipe in the agent-browser notes (init scripts only load when the command launches the session) work as usual — just take the next `<n>`. Close every session you opened before reporting, and only those.
- **Shared state.** All testers log in as the same user against the same backend. Prefix every entity you create with the given entity prefix and touch only those. In **parallel** mode do not change user-level or tenant-level settings (language, theme, favourites, folder or workbook permissions) — the other testers see the change mid-check; an item that needs one is reported as not checked, with the reason. In **exclusive** mode you are the only tester on the stand: such changes are allowed for the items that need them — note each original value first and restore it before reporting, and say in the report that you did.
- The report (step 8) says "attached mode, stand owned by the caller" instead of confirming the stand is stopped.

The same applies when the user points you at a stand that is already up ("проверь на `https://…`", a shared dev-proxy stand): it is theirs — check the auth file (step 3), then steps 5–6, close your browser session, and leave the stand running.

## 1. Resolve the parameters, then ask

Resolve everything first, so the question shows the user their real commands and addresses:

```bash
bash <skill-dir>/scripts/stand-config.sh yt            # likewise yc, yc-preprod
```

Each prints `INSTANCE`, `CONTAINER`, `STATE`, `RUNNING_ENV`, `COMMAND`, `URL`, `RESOLVES_TO`, `COOKIE_DOMAIN`, `AUTH_FILE` and `WARNING`:

| Installation | Start command (`--detach`: in the background) | Address: main checkout / worktree `<dir>` | Cookie domain |
|---|---|---|---|
| **YT** | `ENV=development pnpm run yt:dev:docker:no-typecheck --detach` | `https://<PROJECT_NAME>.<user>.ui.yandex-team.ru` / `https://<dir>.<user>.ui.yandex-team.ru` | `.yandex-team.ru` |
| **YC production** | `ENV=production pnpm run yc:dev:docker:no-typecheck --detach` | `https://local.datalens.ru` / `https://<dir>.<user>.dev.datalens.ru` | `.datalens.ru` |
| **YC preprod** | `ENV=development pnpm run yc:dev:docker:no-typecheck --detach` | `https://<PROJECT_NAME>.<user>.dev.preprod.datalens.ru` / `https://<dir>.<user>.dev.preprod.datalens.ru` | `.preprod.datalens.ru` |
| Other | ask the user | ask the user | parent domain shared by the stand host and the auth file's host |

The addresses come from the launcher (`docker-stand.js info`), not from a template copied here. `STAND_URL`, `STAND_AUTH_FILE` and `STAND_ENV` (the app's `ENV`; a plain `ENV` exported by the shell is ignored on purpose) in the environment override the resolved values; `DEV_INSTANCE` and `PROJECT_NAME` are read by the launcher itself. When the script exits 1 the address is unknown — ask for it, do not guess. A non-empty `WARNING` means the address must be confirmed with the user, in the same question — put the warning into the option's description:

- the host does not resolve to `127.0.0.1` — usual for the first worktree stand. Wildcard DNS for all worktree stands is `pnpm docker:dev:dns` once (it asks for `sudo`, so the user runs it: suggest `! pnpm docker:dev:dns`); a line in `/etc/hosts` works for one address;
- docker is unreachable — the user starts it (`colima start`).

`STATE=running` means this checkout's stand is already up (`RUNNING_ENV` shows its installation and `ENV`). It is the user's stand: ask in the same call whether to restart it or to use it as is (step 4).

The auth file is `projects/yandex/tests/artifacts/auth.txt` **of the checkout under test** (gitignored, per developer; `AUTH_FILE` is its absolute path): a raw `curl` command copied from the browser's devtools, re-exported when it goes stale. A Playwright `storageState` JSON or a `Cookie:` header file works too. It is not asked about — step 3 prepares it. When the user names another file in the request, put `STAND_AUTH_FILE=<that path>` in front of `stand-config.sh` and `prepare-auth.sh` (relative paths are taken from the checkout root): then nothing is copied.

Ask the questions in a single `AskUserQuestion` call, in the user's language, with the recommended option first and the resolved values in the descriptions:

- **Окружение** — «На каком окружении проверять?»: `YT`, `YC production`, `YC preprod` — each with `<COMMAND>` and `<URL>` in the description; the one matching `RUNNING_ENV` (or the change: a YC-only feature, a YT-only one) marked `(Recommended)`. The built-in "Other" answer covers a different environment: the user types the start command and the address there. If either is missing from what they typed, ask for it before going on.
- **Стенд** — only when `STATE=running`: «Стенд этого checkout уже запущен (`<RUNNING_ENV>`). Что с ним сделать?»: `Перезапустить (Recommended)` — a clean start on the current code; `Использовать как есть` — faster, the dev server has picked up the source changes, but not a `.env`, dependency or installation change.

Skip a question only when the user's request already answers it ("проверь на YT стенде" settles the installation). If `AskUserQuestion` is not available (you run as a subagent), take the defaults (restart included) and say in the report that you did.

## 2. Decide what to check

"The implementation" is the change this conversation has been working on. In a fresh session with no such context, read it from the working tree and the branch (`git status`, `git diff`, `git diff main...HEAD`) and the ticket in the branch name.

Before touching the browser, write yourself a short checklist of user-visible behaviours the change is supposed to produce: the main path, the edge cases the code handles explicitly (validation, empty and error states, limits), and anything adjacent the change could have broken. A check that only opens the page and sees no crash proves little — the point is to exercise what was written.

## 3. Check the auth file first

Starting the stand takes from one minute (warm caches) to well over ten (a new worktree installs its dependencies first), so find out that the session is dead before that, not after.

The auth file contains live session cookies — never print its contents, and keep them out of the report.

First make sure the checkout has its own file:

```bash
bash <skill-dir>/scripts/prepare-auth.sh        # AUTH_FILE, AUTH_STATUS, COPIED_FROM
```

- `AUTH_STATUS=present` — use it, nothing to ask.
- `AUTH_STATUS=copied` — a new worktree had no file, so the main checkout's one was copied to `AUTH_FILE`. The copy may be stale and from now on is this worktree's own, so ask the user to refresh it, with `AskUserQuestion`: «В worktree не было файла авторизации — скопировал его из основного checkout в `<AUTH_FILE>`. Обновите его: скопируйте из devtools свежий запрос как cURL и сохраните в этот файл.» — options `Обновил файл (Recommended)` and `Продолжить с копией`. Then run the checks below on whatever is in the file; if the copy turns out dead, ask for the refresh again instead of going on. As a subagent without `AskUserQuestion`, go on with the copy and say in the report that it was copied and should be refreshed.
- `AUTH_STATUS=missing` (exit 1) — no file here or in the main checkout, or the file the user named does not exist: ask the user to export one into `AUTH_FILE`; do not start the stand without it.
- exit 3 — the copy failed (the message says why); nothing was left behind. Tell the user, do not start the stand.

Then check the session:

```bash
grep -oE "^curl '[^']+'" <auth-file>                                  # which host it was exported from
bash -c "$(cat <auth-file>) -k -s -o /dev/null -w '%{http_code}\n'"    # 200 = session alive
```

- `401` — the session is dead. No login flow will rescue it (SAML needs a live SSO session). Stop here and ask the user to re-export the file; do not start the stand.
- `403` — not necessarily dead: the file keeps whatever request the user happened to copy, and that endpoint may simply be forbidden for them (a `lakehouse/*` call from an org without clouds answers 403 with a perfectly live session). Re-check against a neutral endpoint before giving up — swap the URL for `<same host>/gateway/root/us/getStructureItems` and the body for `{}`:

  ```bash
  cmd=$(sed -E "s#^curl '[^']+'#curl 'https://<host>/gateway/root/us/getStructureItems'#; s#--data-raw '[^']*'#--data-raw '{}'#" <auth-file>)
  bash -c "$cmd -k -s -o /dev/null -w '%{http_code}\n'"               # 200 = alive; 401/403 here = dead
  ```

  The same rewrite is how you call any other gateway action from the shell later (checking what a save actually persisted, probing backend rules).
- The host belongs to a different installation than the chosen one (a `preprod.datalens.ru` export for a YT check, a production `datalens.ru` export for YC preprod) — the cookies will not authenticate there. Tell the user and ask for the right file.
- The file is not a curl command (`storageState` JSON, `Cookie:` header) — skip the curl check; `cookies set --curl` in step 5 detects these formats itself. For JSON, check that the cookies' `expires` are in the future.

## 4. Stop this checkout's stand, then start it fresh

Skip this step when the user chose to use the running stand as is (step 1): go to step 5, and leave the stand running in step 7.

Stop the stand of this checkout before starting, including one the user started in a terminal: a foreground `pnpm *:dev:docker*` keeps its dev-proxy and attached compose on the host, and a stand of the other installation holds the same compose project. Starting over it would either fail or leave you checking a stand built from another `ENV`.

```bash
bash <skill-dir>/scripts/stop-stand.sh <stand-url>
```

The script kills the host processes whose working directory is inside this checkout (launcher, dev-proxy, attached compose, native `yc:dev:native`) by pid, then stops the checkout's containers with the launcher's `stop`, and confirms nothing of this checkout is left — no process, no running container, no listener on the stand's host ports (8010/8020 for the main checkout, the worktree's own pair otherwise). Exit 0 is the only "stopped": 1 means something is left or docker did not answer, 2 means the launcher did not name the stand and nothing was stopped — read the output and settle it (with the user if needed) before starting. Stands of other worktrees and the shared nginx are not touched — the same commands run there, only the working directory tells them apart. Use the script rather than `pkill -f '<pattern>'`: `pkill -f` matches the shell command line that contains the pattern and kills your own shell, and it would hit the other worktrees' stands. For an "Other" environment whose start command the default patterns would miss, add `--pattern '<ere>'`. `--dry-run` only shows what would be stopped.

Then start the stand from the checkout root and wait for it as a background task:

```bash
<COMMAND> > <scratchpad>/stand-start.log 2>&1                                      # returns in seconds to minutes
docker logs -f <CONTAINER> > <scratchpad>/stand.log 2>&1                           # run_in_background
bash <skill-dir>/scripts/wait-stand.sh <stand-url> 1800 <CONTAINER>                # run_in_background
```

- `<COMMAND>` with `--detach` prepares `.env`, nginx and the host ports, creates the containers and exits; the app keeps starting inside the container. A non-zero exit means the launcher refused — read `stand-start.log`: a stand of the same name created from another directory (set `DEV_INSTANCE=<name>` after asking the user), a reserved name, a broken `.env`.
- `stand-start.log` also carries the launcher's warnings: the host does not resolve here (step 1), or `dev.pem ... does not cover <host>` — the certificate has no wildcard for worktree addresses, the browser will refuse the stand; tell the user (`docs/dev/docker-credentials.md` → «Сертификат») rather than working around it.
- `wait-stand.sh` gives up early, with the tail of the container log, when the container stops — the start failed. Otherwise the address answers `502` until the app listens.
- The first start of a worktree is slow: the launcher copies `.env` and the certificates from the main checkout, the container installs dependencies (`pnpm install`, from the shared pnpm store) and builds from scratch. If the install hangs or aborts on a pnpm confirmation, stop the stand and start again with `CI=true` in front of `<COMMAND>`.
- A worktree's `.env` is a copy made at its first start and is not refreshed afterwards. For YC production it holds `SERVICE_ACCOUNT_IAM_TOKEN`, which expires in 12 hours: a 500 on `/` with `failed to fetch token from metadata service` in `stand.log` means a stale token — tell the user (`docs/dev/running.md` → YC), it is not the change under test.
- "Stand is up" means nginx reaches the server. The client bundle may still be compiling: a blank page or a "compiling" overlay right after start means wait and reload, not a bug.
- Do not run `pnpm typecheck` next to a running stand — together they run out of memory. Typecheck and lint belong after the stand is stopped. Several worktree stands running at once compete for the docker VM's memory too: if the build gets OOM-killed, show the user `pnpm docker:dev:list` and let them decide what to stop.

## 5. Open the stand in agent-browser

`agent-browser` must be installed globally (`npm i -g agent-browser`). Use a session name that has not been used before in this conversation (for example `stand-<HHMMSS>`): the HTTPS flag only works when the command launches the session daemon, and the stand certificate is not trusted.

```bash
agent-browser --session <name> open --ignore-https-errors <stand-url>
agent-browser --session <name> cookies set --curl <auth-file> --domain <cookie-domain>
agent-browser --session <name> open <stand-url>/<page-under-test>
```

Confirm you are authenticated before checking anything: the app UI renders, not a landing or login page. If it is a landing page, the cause is the cookies (wrong domain, wrong installation, expired), not the change under test.

## 6. Run the checks

Go through the checklist from step 2. For each item, collect evidence instead of an impression: a `snapshot` or `eval` reading of the relevant text or value, a `screenshot` saved to the scratchpad for anything visual, the request payload when the change is about what gets sent.

The backend behind the stand is real (production for YC production, preprod otherwise, see `docs/dev/installations.md`). Every mutation the browser fires — create, save, delete — really happens. Creating clearly named test entities of your own is fine; changing or deleting entities you did not create is not, unless the user asked. Note what you leave behind for the report.

When a flow cannot be exercised for real (the tenant lacks the needed entities, or the action is destructive), mock the backend calls — and read [`references/agent-browser-notes.md`](references/agent-browser-notes.md) first: the obvious tool, `network route`, silently does not work on the stand. The same file has the widget-level tricks (Gravity `Select`, clearing a `TextInput`, `DateField`, toasts, drag and drop, reading form state) and the DataLens selectors that held up — open it as soon as a click or a `fill` does not do what you expected, rather than retrying variations.

If a check fails because of the implementation and you are the one implementing it in this conversation, fix it and re-check — the dev server in the container picks the change up. If you were only asked to verify, record the failure with its evidence and go on with the rest of the checklist.

## 7. Stop the stand — always

When the checks are done, or abandoned for any reason (dead auth discovered late, failed start, user interruption you can still act on):

```bash
agent-browser --session <name> close
bash <skill-dir>/scripts/stop-stand.sh <stand-url>          # not for a stand the user chose to keep as is
```

Stop the background `docker logs -f` task too. The script must exit 0 — no processes, no running containers and no port listeners of this checkout — with the stand answering 502 — the shared nginx stays up and answers for the other stands. Do this before writing the report, so the report can state it as done. A stand you used as is (step 1) or one the user pointed you at stays running: close only your browser session.

## 8. Report

Short, with the outcome first:

- installation, checkout (main or worktree, `INSTANCE`), address and auth file used (and whether it was copied from the main checkout and refreshed or not; which values were defaults taken without asking);
- each checklist item: passed / failed / could not be checked, with the evidence that decided it;
- what ran against the real backend and what was mocked — a mocked run verifies the UI only, say so;
- entities created or left behind on the backend;
- confirmation that this checkout's stand is stopped, or that it was left running because it was the user's.
