---
name: i18n-screenshots
description: Annotated i18n screenshots for translators — full-viewport screenshots of the local docker dev stand (brought up with dvortsovs:stand-check) where every key awaiting translation is pointed at by a red arrow from a label with its key name, in as few screenshots as the UI states allow, saved to i18n-screenshots/<branch>/ in the checkout root. Use when keys awaiting translation (REQUIRES_TRANSLATION) need screenshot context, e.g. for the documentators' ticket, or when asked to screenshot keysets or keys («сделай скриншоты для переводчиков», «скриншоты ключей»).
---

# i18n screenshots

Produce, on the local dev stand of this checkout, PNGs of the whole viewport where every
selected key is arrowed from a label with its key name — as few PNGs as the UI states allow.
Light theme, 2x scale. Built for the DataLens repo (`projects/*/src/i18n-keysets`, `window.DL`),
driven through `agent-browser`.

`$S` below is the directory this `SKILL.md` lives in (Claude Code prints it as "Base directory
for this skill"); `$SC` is the sibling `$S/../stand-check`. Every script has a `--help`. Run
from the root of the checkout under test (the main one or a git worktree); needs `node` and
`agent-browser` (`npm i -g agent-browser && agent-browser install`).

## What a screenshot looks like

This is the reference; check every PNG against it.

- **The whole viewport, nothing cropped.** The page is shown as the user sees it — sidebar,
  header, list behind the dialog, the dialog's own backdrop. No white frame, no cut-out of one
  block, no zoom on a fragment.
- **Labels at the left and right edges** of the image: the key name in red monospace text on a
  solid black plate, one line each. Stacked top to bottom without overlapping, each as close to
  the height of its text as the stack allows.
- **One red arrow per key**, a thin straight line from the label's inner edge to the text, the
  arrowhead at the text: at its near side, or at its bottom or top edge when a straight line
  would run through other annotated texts. No boxes around the texts — the arrow alone points.
- **Label text.** The bare key (`section-title-unavailable`) for the screen's main keyset; for
  any other keyset `<keyset without its first segment> · <key>`
  (`shared-entry-icon.view · delegated`). A key that is not visible text gets its attribute in
  brackets: `label-bind-entry (aria-label)`, `delegated (title)`, `search (placeholder)` — the
  arrow then points at the element that carries the attribute (an icon, an icon button, a field).
- **Caption at the bottom left**: a white box with a thin grey border and black sans-serif text —
  the keysets on the screen joined by ` · `, then ` — ` and the state in the user's language:
  `component.dialog-copy-shared-entry-bindings.view · component.shared-entry-icon.view — диалог
  «Управление привязками» при копировании в воркбук`.
- **Several layers at once are fine** and expected: a dialog over a page, a nested dialog over a
  dialog, an open dropdown menu over the dialog — if it fits one viewport, it is one screenshot.

## Steps

### 1. Bring up the stand with stand-check

Load `dvortsovs:stand-check` with the Skill tool and follow its own steps, with this skill's
task instead of a checklist:

- **its step 1** — ask the installation (and restart vs. use as is) in one `AskUserQuestion`
  call. A stand the user names by URL is used as is, per stand-check's "a stand that is already
  up";
- **its step 3** — prepare and check the auth file;
- **its step 4** — stop and start this checkout's stand fresh, so it runs this branch; wait for it
  in the background.

Skip its steps 2, 5 and 6 — steps 2–5 here replace them. Keep `URL`, `COOKIE_DOMAIN` and
`AUTH_FILE` from `stand-config.sh`. While the stand builds, do steps 2 and 3.

### 2. Select the keys

```bash
node $S/scripts/keys.mjs --table        # REQUIRES_TRANSLATION, new/changed vs merge-base with main
```

`--all` drops the "changed in this branch" filter; `--status` picks another status. Done when the
user has seen the list (count + ids) — it is the coverage target for the whole run.

### 3. Plan the fewest screenshots

The out directory is `<checkout root>/i18n-screenshots/<branch>/` (branch `/` → `-`). Create it,
delete the PNGs a previous run left there, and keep it out of git for this clone:

```bash
OUT="$(git rev-parse --show-toplevel)/i18n-screenshots/$(git branch --show-current | tr / -)"
mkdir -p "$OUT" && rm -f "$OUT"/*.png
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
grep -qx '/i18n-screenshots/' "$EXCLUDE" || echo '/i18n-screenshots/' >> "$EXCLUDE"
```

For each key find where and under which condition it renders: `grep` the keyset
(`I18n.keyset('<keyset>')`) and the key across `projects/*/src/ui`. Then pack the keys into as
few screens as possible — a screen is one UI state, and every extra one is extra work for the
translator:

- **Start from the deepest state** and put everything visible there into one screen: the page,
  the dialog over it, the nested dialog, the open menu or dropdown on top.
- **Attribute texts need no extra state.** `title`, `aria-label` and `placeholder` are in the DOM
  without hovering or focusing — annotate them with `attr` on the same screen.
- **Make variants coexist through data.** When a list shows a variant per item (delegated / not
  delegated, available / unavailable), stage data (`__xhrMocks`) that holds one item of each,
  so all the variants render side by side.
- **Split only for mutually exclusive texts** — the same place showing one text or the other
  (empty vs. filled, admin vs. non-admin, success vs. error toast), or texts that do not fit one
  viewport. A tooltip that needs hover, a toast or a validation error belongs to the screen of
  the state it appears over.

Write the plan to `$OUT/screens.json` (format below) and check it:

```bash
node $S/scripts/keys.mjs --coverage "$OUT/screens.json"
```

Done when it exits 0. Tell the user the screen count and why each split was unavoidable.

### 4. Open the stand in agent-browser

```bash
bash $S/scripts/launch.sh i18n-<HHMMSS> <URL>/<page> <AUTH_FILE> <COOKIE_DOMAIN>
```

A session name not used before in this conversation: the HTTPS flag and the stub init script
apply only when the session launches. Done when the output shows the target url (not a login or
landing page), `"light":true` and `"stub":true`, and one selected key's text is visible on the
page — proof the stand runs this branch. Open other pages with
`agent-browser --session <s> open <url>`. A login or landing page means the cookies — wrong
domain, installation or expired auth; go back to stand-check's step 3. If `light` is false, the
user's DataLens theme is dark: ask them to switch it to light or "system".

### 5. Shoot each screen

For every screen, in order: stage its state (recipes below), then

```bash
bash $S/scripts/shoot.sh <session> "$OUT/screens.json" <screen> "$OUT"
```

and `Read` the PNG. A screen is done when the script exits 0 (`missing`, `offscreen` and
`covered` are all `[]`) and the image matches the reference above: every arrow ends at its own
text, no label on top of a text that matters, the caption readable. Fixes:

- `missing` — the text is not rendered in this state, or rendered differently (interpolation:
  use `selector`; markup: whitespace-normalised already). Several equal texts — `nth`.
- `offscreen` — scroll the container with `eval "el.scrollIntoView({block:'center'})"`, or move
  the key to another screen.
- `covered` / an arrow through the wrong text — pin the item's `side`.

### 6. Finish

Close the session (`agent-browser --session <s> close`), stop the stand with stand-check's
step 7 (not a stand the user chose to keep), then report: a table file → keys, which states
were simulated and how (mocks, overrides), why each split was needed, the out directory (in the
checkout root, excluded from git through `.git/info/exclude`), and stand-check's lines about the
stand and the auth file.

## screens.json

```json
{
  "lang": "ru",
  "screens": {
    "bindings-dialog": {
      "title": "component.dialog-copy-shared-entry-bindings.view · component.shared-entry-icon.view — диалог «Управление привязками» при копировании в воркбук",
      "keyset": "component.dialog-copy-shared-entry-bindings.view",
      "items": [
        {"key": "component.dialog-copy-shared-entry-bindings.view:section-title-unavailable"},
        {"key": "component.dialog-copy-shared-entry-bindings.view:delegation-mode-keep", "side": "right"},
        {"key": "component.dialog-copy-shared-entry-bindings.view:label-bind-entry", "attr": "aria-label"},
        {"key": "component.shared-entry-icon.view:delegated", "attr": "title"},
        {"key": "component.dialog-copy-shared-entry-bindings.view:action-cancel", "nth": 1}
      ]
    },
    "toast-error": {"title": "…", "items": [{"key": "…", "selector": ".g-toast .g-toast__title"}]}
  }
}
```

- `title` — the caption: keysets, then ` — ` and the state.
- `keyset` — the main keyset, whose keys get bare labels; defaults to the first item's.
- An item is found by its rendered text (whitespace-normalised, markup such as `<br></br>`
  treated as a space; also a text node next to other elements), by `attr` (an element whose
  `title` / `aria-label` / `placeholder` / any attribute equals the text), or by `selector` —
  for texts with interpolated values (`{{count}}`); with `attr` too, the selector's box is used.
- Of several matches the one on top (not under a backdrop) wins; `nth` (0-based, top to bottom)
  picks explicitly.
- `side` — `left` / `right`; by default the half of the viewport the text is in, switched when the
  label would cover its own text.
- `scope` (screen level) — a selector to search items in, when the whole page is ambiguous.
- File order (`NN-<screen>.png`) follows the order of `screens`.

## Staging states

`stub.js` runs before the page on every load and reads `localStorage`, so a state is one
`eval` plus `reload`:

```bash
agent-browser --session <s> eval "localStorage.setItem('__xhrMocks', JSON.stringify({'alphaRequests/getV2': {status: 200, body: {status: 'rejected'}}}))"
agent-browser --session <s> eval "localStorage.setItem('__dlOverrides', JSON.stringify({userIsOrgAdmin: false}))"
agent-browser --session <s> reload && agent-browser --session <s> wait --load networkidle
```

- **API response** — `__xhrMocks`: url substring → `{status, body}`. Matching XHR/fetch never
  hit the network; `window.__xhrMockHits` lists what was intercepted. Read the real response
  first (`agent-browser --json network requests`, or a shell call per stand-check's notes) and
  edit it, rather than writing a body from scratch.
- **Role, flags, tenant** — `__dlOverrides`: shallow-merged into `window.DL` (read by
  `DL_CLOSED` getters, e.g. `userIsOrgAdmin`).
- **Component memory** — the component's own `localStorage` key (e.g. a collapsed banner), or
  click the control.
- **Menus and dropdowns** — open them last, after the dialog under them is in place; a
  `role=menuitem` popup opens only from a real `click <selector>`.
- **Validation errors** — submit the empty form (step through *Mutating actions* anyway).
- **Toasts** — mock the endpoint with 200 / 500, submit, `wait .g-toast`, shoot immediately:
  toasts hide after ~5 s.
- Remove a mock or override (`localStorage.removeItem`) and reload before the next screen that
  needs the real behaviour.

Widget tricks (Gravity `Select`, `TextInput`, menus, stale refs) are in
`$SC/references/agent-browser-notes.md` — read it once a click does not do what you expected.

## Mutating actions

The backend behind the stand is real. Any click that would create, send or delete something
follows this sequence:

1. Put the endpoint in `__xhrMocks` and reload; confirm it with an `eval` of
   `localStorage.__xhrMocks`.
2. Click by an exact CSS selector scoped to the dialog or form
   (`.dl-dialog-… button[type=submit]`).
3. Wrap the click in `agent-browser set offline on` / `set offline off`.
4. Confirm `window.__xhrMockHits` contains the endpoint and
   `agent-browser network requests --filter <endpoint>` shows no request.

Only a mocked submit is safe. Entities a screen needs (a workbook to copy into, a dataset with
bindings) may be created for real, clearly named; list them in the report.

## Gotchas

- `agent-browser network route` does not intercept the app's XHR on DataLens stands; mocks go
  through `stub.js`.
- `find role button --name "X"` matches substrings, including buttons behind a modal: clicking
  "Отправить" hit "Отправить заявку" under the backdrop and closed the dialog. Use selectors.
- `agent-browser set media light` only matters for users on the "system" theme; the body class
  `g-root_theme_light` is the truth.
- `document.activeElement.blur()` before shooting a form: a focused field hides its validation
  error. Move the mouse away (`agent-browser mouse move 0 0`) unless the hover is the state.
- The dev-server error overlay can cover the page — read it (it may be a real compile error),
  then remove it with `eval`.
- The viewport is `1600 1000 2` (width, height, scale) by default; a taller one fits a long
  dialog without splitting the screen: `agent-browser --session <s> set viewport 1600 1200 2`
  on the running session, or `VIEWPORT=…` in front of `launch.sh`.
