// Browser init script, registered at launch by launch.sh (AGENT_BROWSER_INIT_SCRIPTS).
// Runs before any page script on every navigation and is driven by localStorage, so a state is
// staged with one `eval` + `reload`:
//
//   localStorage.__xhrMocks = JSON.stringify({'<url substring>': {status: 200, body: {...}}})
//     Matching XHR / fetch requests never reach the network; they resolve with that response.
//     Every intercepted request appends its url substring to window.__xhrMockHits.
//   localStorage.__dlOverrides = JSON.stringify({userIsOrgAdmin: false, ...})
//     Shallow-merged into window.DL the moment the page assigns it.
(() => {
    const read = (name) => {
        try {
            return JSON.parse(localStorage.getItem(name) || '{}');
        } catch {
            return {};
        }
    };
    const findMock = (url) => {
        const mocks = read('__xhrMocks');
        const key = Object.keys(mocks).find((k) => String(url).includes(k));
        if (!key) {
            return null;
        }
        (window.__xhrMockHits = window.__xhrMockHits || []).push(key);
        return mocks[key];
    };

    const origOpen = XMLHttpRequest.prototype.open;
    const origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url, ...rest) {
        this.__url = String(url);
        return origOpen.call(this, method, url, ...rest);
    };
    XMLHttpRequest.prototype.send = function (body) {
        const mock = findMock(this.__url);
        if (!mock) {
            return origSend.call(this, body);
        }
        const {status = 200, body: resp = {}} = mock;
        const text = JSON.stringify(resp);
        const define = (name, value) => Object.defineProperty(this, name, {value, configurable: true});
        define('readyState', 4);
        define('status', status);
        define('statusText', status < 400 ? 'OK' : 'Error');
        define('responseText', text);
        define('response', this.responseType === 'json' ? resp : text);
        define('responseURL', this.__url);
        this.getAllResponseHeaders = () => 'content-type: application/json; charset=utf-8\r\n';
        this.getResponseHeader = (h) =>
            h.toLowerCase() === 'content-type' ? 'application/json; charset=utf-8' : null;
        setTimeout(() => {
            this.dispatchEvent(new Event('readystatechange'));
            this.dispatchEvent(new ProgressEvent('load'));
            this.dispatchEvent(new ProgressEvent('loadend'));
        }, 50);
    };

    const origFetch = window.fetch;
    window.fetch = function (input, init) {
        const mock = findMock(typeof input === 'string' ? input : input.url);
        if (!mock) {
            return origFetch.call(this, input, init);
        }
        const {status = 200, body = {}} = mock;
        return Promise.resolve(
            new Response(JSON.stringify(body), {status, headers: {'content-type': 'application/json'}}),
        );
    };

    const overrides = read('__dlOverrides');
    if (Object.keys(overrides).length) {
        let dl;
        Object.defineProperty(window, 'DL', {
            configurable: true,
            get: () => dl,
            set: (value) => {
                dl = value && typeof value === 'object' ? Object.assign(value, overrides) : value;
            },
        });
    }
})();
