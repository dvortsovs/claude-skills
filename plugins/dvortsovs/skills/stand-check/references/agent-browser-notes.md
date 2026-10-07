# Driving the DataLens UI with agent-browser

Things that cost time on earlier stand checks. Read the part that matches what you are stuck on.

## Session and HTTPS

- `--ignore-https-errors` and `--init-script` take effect only when the command launches the session daemon. On an already running session they are silently ignored, and `close --all` does not always kill the daemon. When a launch went wrong, pick a new `--session` name instead of retrying the old one.
- The dev-server error overlay (`#webpack-dev-server-client-overlay`) can cover the page and swallow clicks. Hide or remove it with `eval` when it is in the way — and read it first, it may be reporting a real compile error in the change under test.

## Mocking backend calls

- `agent-browser network route` does **not** intercept the stand's gateway XHRs: the CLI reports the route as set while the request reaches the real backend. A "mocked" create flow once created a real entity this way. Do not rely on it to keep a mutation from happening.
- What works: an init script that replaces `window.XMLHttpRequest` with a subclass whose `send()` answers the chosen `/gateway/root/<service>/<action>` URLs itself. Define `readyState`, `status`, `responseText`, `response`, `responseURL` on the instance with `Object.defineProperty`, stub `getAllResponseHeaders`, then dispatch `readystatechange`, `load`, `loadend` (axios listens to `loadend`). Keep the mock state on a `window.__mock` object so `eval` can flip flags between steps. The state resets on every full navigation, because the init script runs again.
- Launch order with a mock: `agent-browser --session <s> --ignore-https-errors --init-script mock.js open about:blank`, then `cookies set --curl …`, then `open <stand url>`.
- Gateway error shape to mimic: HTTP 400, body `{status, message, code: 'GATEWAY_REQUEST_ERROR', details: {grpcCode}}`.

## Calling the backend from the shell

The auth file is a curl command, so its `-H` headers and `-b` cookie can be reused for read-only calls to `<stand>/gateway/root/<service>/<action>` (add `-k` for the stand certificate, replace the URL and `--data-raw`). Handy for confirming what the UI should show, or what a submit actually saved, without disturbing the browser flow.

## Widgets

- **Gravity `Select`:** options do not react to `click @ref` or `find text … click`. Open the trigger by its `id`, then click the option through `eval` (`document.querySelectorAll('[role=option]')`).
- **`TextInput`:** `fill @ref ""` does not clear it. Focus it through `eval`, then `press Control+a` and `press Backspace`. Its error message is `.g-outer-additional-content__error`.
- **Key handlers:** `keyboard type` inserts text without keydown events. When the code under test reacts to a key (comma, space, Enter), use `press`.
- **Below the fold:** `click <selector>` can land before the auto-scroll settles, focus ends up on `body` and the following typing goes nowhere. `eval "el.scrollIntoView({block:'center'})"`, `wait 500`, then click; repeat after anything that moves focus back to the top.
- **Menus:** a `role=menuitem` popup opens only from a real `click <selector>`; a programmatic `.click()` leaves it empty.
- **Toasts** hide after about 5 seconds: read `.g-toast` innerText through `eval` within 2–3 seconds of the action.
- **Stale refs:** snapshot `@e` refs go stale once a popup opens. Click by selector or `eval` rather than by an old ref.
- **Flaky vs reliable:** `find role link --name` and `wait --url` with globs were flaky; `click "a[href='…']"`, `wait --text`, `back` and short `wait <ms>` were reliable. When `find text … click` does not submit a form, a programmatic `button.click()` through `eval --stdin` does.

## Drag and drop

`agent-browser drag <from> <to>` works (wizard: `.wizard-dataset-item[data-qa="<field title>"]` → `[data-qa="placeholder-x|y|colors|filters"]`), but only when the source is inside the viewport: an item below the fold of a scrolling list is "dragged" without effect and the CLI still reports success. `eval "el.scrollIntoView({block:'center'})"` + `wait 400` before each drag.

## Network log

`agent-browser --json network requests` returns `{success, data: {requests: [...]}}`; each request has `url`, `method`, `postData`, `status`, `responseHeaders`. Useful for reading the exact payload a save or a chart run sent. For what the backend actually persisted, a shell call to the gateway (see above) is more direct.

## DataLens selectors that held up

- Dataset page tabs are segmented radio labels: click the `input` inside `label.g-segmented-radio-group__option` whose text matches («Параметры», «Поля»).
- Dataset field/parameter rows: `.dataset-tab-field-list-row`; the row menu button `[data-qa=dataset-tab-field-row-menu]` needs a real `click` (tag it with a temporary attribute via `eval`, then `click "[data-test-target=…]"`), after which `[role=menuitem]` entries can be `.click()`ed from `eval`. Add button `[data-qa=dataset-tab-section-add-button]`, save `[data-qa=dataset-create-button]`.
- Parameter dialog: `[data-qa=dialog-parameter]`, `…-name-input`, `…-type_selector`, `…-default-value-input`, `…-apply-btn`, `…-cancel-btn`, `…-reset-btn`. A disabled Gravity `Select` has `[disabled]` on its inner button.
- Gravity `DateField` (masked `ДД.ММ.ГГГГ`): focus lands on the last segment; `press ArrowLeft` to the first segment, then `press` digits one by one. `keyboard type` into it does not work.
- Wizard sidebar item actions: `.wizard-dataset-item[data-qa="<title>"] [data-qa=field-actions]` (real click) → «Редактировать» opens the parameter dialog. Placeholder items (`[data-qa=placeholder-colors] .wizard-visualization-item`) do not open it on click.

## Reading state the UI does not render

- **react-final-form values:** from an `input[name=…]` take its `__reactFiber*` key and walk `.return` until `memoizedProps.value` has both `getState` and `change` — that is the form API, and `getState().values` is what a submit would send.
- **react-router `location.state`:** `history.replaceState({usr: <state>, key, idx}, '', location.href)` followed by `reload` mounts the page with that state. A dev-server hot reload drops it.
