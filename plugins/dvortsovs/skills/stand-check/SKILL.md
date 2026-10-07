---
name: stand-check
description: Verify the current implementation on the developer's own live dev stand in a real browser — asks which installation (YC / YT / other) and which auth file to use, resolves the stand address from the developer's nginx config, stops every running dev stand process, starts a fresh stand, drives the UI with agent-browser, then shuts the stand down and reports. Use whenever the user says «проверить на стенде», «проверь на стенде», «проверка на стенде», «посмотри на стенде», "check on the stand", "verify on the dev stand", or otherwise asks to see a change working on their stand — even when they name neither agent-browser nor the start command.
---

# Stand check

Verify that the implementation actually works in a browser against a running dev stand. Developers ask for this constantly, with the same parameters each time; this skill holds the parameters and the traps so they don't have to be retyped or rediscovered.

The whole run is one sequence: **ask → check auth → stop all stands → start a fresh stand → drive the UI → stop the stand → report**. The two "stop" steps are not optional, see why in step 4.

Scripts live in `scripts/` next to this file: `<skill-dir>` below is the base directory the Skill tool prints when it loads this skill. Run them with the DataLens repo root as the working directory — they find the checkout from there (or from `STAND_REPO_ROOT`).

## 1. Resolve the parameters, then ask

Every developer's stand has its own address: `server_name` in the generated `projects/yandex/dev-nginx/nginx.conf` of the DataLens repo declares both the YT and the YC host (see `docs/dev/setup.md` there). Resolve it first, so the question shows the user their real addresses:

```bash
bash <skill-dir>/scripts/stand-config.sh yc
bash <skill-dir>/scripts/stand-config.sh yt
```

Each prints `COMMAND`, `URL`, `HOST_SOURCE`, `COOKIE_DOMAIN`, `AUTH_FILE` and `NEEDS_TVM`:

| Installation | Start command | Address | Cookie domain |
|---|---|---|---|
| **YC** (default) | `pnpm run yc:dev` | `https://<user>.dev.preprod.datalens.ru` | `.preprod.datalens.ru` |
| **YT** | `pnpm run yt:dev` | `https://<CONFIG_NAME>.<user>.ui.yandex-team.ru` | `.yandex-team.ru` — needs a healthy `tvmtool`, step 3b |
| Other | ask the user | ask the user | parent domain shared by the stand host and the auth file's host |

`STAND_URL` and `STAND_AUTH_FILE` in the environment override the resolved values. When the script exits 1 (no nginx config, no override), the address is unknown — ask for it, do not guess.

The default auth file is `projects/yandex/tests/artifacts/auth.txt` (gitignored, per developer): a raw `curl` command copied from the browser's devtools, re-exported when it goes stale. A Playwright `storageState` JSON or a `Cookie:` header file works too.

Ask both questions in a single `AskUserQuestion` call, in the user's language, with the default first and the resolved values in the descriptions:

- **Окружение** — «На каком окружении проверять?»: `YC (Recommended)` — `<COMMAND>`, `<URL>`; `YT` — `<COMMAND>`, `<URL>`. The built-in "Other" answer covers a different environment: the user types the start command and the address there. If either is missing from what they typed, ask for it before going on.
- **Авторизация** — «Какой файл использовать для авторизации?»: `<AUTH_FILE> (Recommended)`; `Другой файл` — the user gives the path.

Skip a question only when the user's request already answers it ("проверь на YT стенде" settles the installation, the auth file is still asked). If `AskUserQuestion` is not available (you run as a subagent), take the defaults and say in the report that you did.

## 2. Decide what to check

"The implementation" is the change this conversation has been working on. In a fresh session with no such context, read it from the working tree and the branch (`git status`, `git diff`, `git diff main...HEAD`) and the ticket in the branch name.

Before touching the browser, write yourself a short checklist of user-visible behaviours the change is supposed to produce: the main path, the edge cases the code handles explicitly (validation, empty and error states, limits), and anything adjacent the change could have broken. A check that only opens the page and sees no crash proves little — the point is to exercise what was written.

## 3. Check the auth file first

Starting the stand takes from one minute (warm caches) to about five, so find out that the session is dead before that, not after.

The auth file contains live session cookies — never print its contents, and keep them out of the report.

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
- The host belongs to a different installation than the chosen one (a `preprod.datalens.ru` export for a YT check) — the cookies will not authenticate there. Tell the user and ask for the right file.
- The file is not a curl command (`storageState` JSON, `Cookie:` header) — skip the curl check; `cookies set --curl` in step 5 detects these formats itself. For JSON, check that the cookies' `expires` are in the future.

## 3b. YT only: make sure TVM is healthy

The YT installation reaches internal services through a local `tvmtool` daemon (`NEEDS_TVM=1` from `stand-config.sh`). Its config and daemon token come from Secretnica and go stale: when they do, the stand starts but every request to US and the other backends fails, which looks like a broken implementation. Check the daemon before starting the stand, on your own, without asking the user — but do not refresh it blindly on every run, a restart of `tvmtool` is noise when nothing is wrong:

```bash
bash <skill-dir>/scripts/ensure-tvm.sh            # ENV=production in front for a prod-facing stand
```

The script compares the daemon state (`/tvm/ping` answering `OK`) and the files in `/etc/tvmtool`, `/var/lib/tvmtool` with the current secret in `yav`, and runs the repo's `projects/yandex/scripts/dev/setup-tvm-env.sh` only when something differs or the daemon is down. Exit codes:

- `0` — healthy; the output says whether it was already fine or just refreshed. Mention a refresh in the report.
- `1` — refreshed, still broken: the output has the commands to inspect the service. Stop and report, the stand would not work.
- `2` — a prerequisite is missing (tvmtool not installed, no passwordless `sudo`, `yav` not logged in): the output has the exact command for the user. This is the one case that needs them.

Skip this step entirely for YC: `TVM_DISABLED` there, see `docs/dev/installations.md`. The procedure the script automates is documented at https://wiki.yandex-team.ru/ct/lib/rabota-s-tvm-pri-razrabotke/.

## 4. Stop every running stand, then start a fresh one

Stop **all** dev stand processes before starting, including ones started outside this session or by the user. YT, YC and Public share one nginx host, and a stale instance keeps `dist/run/*.sock` bound, so nginx answers 502 for the new stand or, worse, serves the old code — the check then verifies something other than the current implementation. Stands left running also pile up and eat memory until a build gets OOM-killed.

```bash
bash <skill-dir>/scripts/stop-stand.sh <stand-url>
```

The script finds the processes (pnpm chain, `app-builder dev`, ts-checker, the node server), kills them by pid and confirms nothing is left. Use it rather than `pkill -f '<pattern>'`: `pkill -f` matches the shell command line that contains the pattern and kills your own shell. For an "Other" environment whose start command the default patterns would miss, add `--pattern '<ere>'`. `--dry-run` only shows what would be stopped.

Then start the stand from the repo root as a background task, with the log in the scratchpad, and wait for it as a second background task:

```bash
<COMMAND> > <scratchpad>/stand.log 2>&1                              # run_in_background
bash <skill-dir>/scripts/wait-stand.sh <stand-url>   # run_in_background, exits when the stand answers
```

- If the stand task exits before `wait-stand.sh` reports success, the start failed — read the tail of `stand.log`.
- "Stand is up" means nginx reaches the server. The client bundle may still be compiling: a blank page or a "compiling" overlay right after start means wait and reload, not a bug.
- Do not run `pnpm typecheck` next to a running stand — together they run out of memory. Typecheck and lint belong after the stand is stopped.

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

The backend behind the stand is real (preprod by default, see `docs/dev/installations.md`). Every mutation the browser fires — create, save, delete — really happens. Creating clearly named test entities of your own is fine; changing or deleting entities you did not create is not, unless the user asked. Note what you leave behind for the report.

When a flow cannot be exercised for real (the tenant lacks the needed entities, or the action is destructive), mock the backend calls — and read [`references/agent-browser-notes.md`](references/agent-browser-notes.md) first: the obvious tool, `network route`, silently does not work on the stand. The same file has the widget-level tricks (Gravity `Select`, clearing a `TextInput`, `DateField`, toasts, drag and drop, reading form state) and the DataLens selectors that held up — open it as soon as a click or a `fill` does not do what you expected, rather than retrying variations.

If a check fails because of the implementation and you are the one implementing it in this conversation, fix it and re-check — the dev server picks the change up. If you were only asked to verify, record the failure with its evidence and go on with the rest of the checklist.

## 7. Stop the stand — always

When the checks are done, or abandoned for any reason (dead auth discovered late, failed start, user interruption you can still act on):

```bash
agent-browser --session <name> close
bash <skill-dir>/scripts/stop-stand.sh <stand-url>
```

The script must end with no processes left, no `dist/run` listeners and the stand answering 502. Do this before writing the report, so the report can state it as done.

## 8. Report

Short, with the outcome first:

- installation, address and auth file used (and whether they were defaults taken without asking);
- each checklist item: passed / failed / could not be checked, with the evidence that decided it;
- what ran against the real backend and what was mocked — a mocked run verifies the UI only, say so;
- entities created or left behind on the backend;
- confirmation that the stand is stopped.
