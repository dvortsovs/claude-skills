#!/usr/bin/env node
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const HELP = `Usage: render.mjs <screens.json> <screen> [--repo <path>]

Prints the JavaScript that draws the annotation overlay for one screen: annotate.js followed by
a window.__annotate(...) call whose item texts are resolved from the keysets. Pipe it into
\`agent-browser eval --stdin\` (shoot.sh does exactly that).

Labels: the bare key for the screen's main keyset (screen.keyset, else the first item's), and
"<keyset without its first segment> · <key>" for any other; " (<attr>)" is appended for keys
found by an attribute (title, aria-label, placeholder).
--repo defaults to the git top level of the working directory.`;

const argv = process.argv.slice(2);
if (argv.includes('--help') || argv.length < 2) {
    console.log(HELP);
    process.exit(argv.includes('--help') ? 0 : 1);
}
const [specFile, screenName] = argv;
const repoIndex = argv.indexOf('--repo');
const repo =
    repoIndex > -1
        ? argv[repoIndex + 1]
        : execFileSync('git', ['rev-parse', '--show-toplevel'], {encoding: 'utf8'}).trim();

const spec = JSON.parse(fs.readFileSync(specFile, 'utf8'));
const screen = spec.screens[screenName];
if (!screen) {
    console.error(`No screen "${screenName}" in ${specFile}. Known: ${Object.keys(spec.screens).join(', ')}`);
    process.exit(1);
}
const lang = spec.lang || 'ru';

const keysetRoots = [path.join(repo, 'src/i18n-keysets')];
const projects = path.join(repo, 'projects');
if (fs.existsSync(projects)) {
    for (const project of fs.readdirSync(projects).sort()) {
        keysetRoots.push(path.join(projects, project, 'src/i18n-keysets'));
    }
}
const textsCache = {};
const textOf = (keyset, key) => {
    if (!textsCache[keyset]) {
        const files = keysetRoots
            .map((root) => path.join(root, keyset, `${lang}.json`))
            .filter((f) => fs.existsSync(f));
        if (!files.length) {
            throw new Error(`keyset not found: ${keyset}`);
        }
        // a keyset can live in several projects (opensource and yandex); merge them the way
        // i18n:prepare does, a later project overriding an earlier one
        textsCache[keyset] = Object.assign(
            {},
            ...files.map((f) => JSON.parse(fs.readFileSync(f, 'utf8'))),
        );
    }
    const text = textsCache[keyset][key];
    if (text === undefined) {
        throw new Error(`key not found: ${keyset}:${key}`);
    }
    // markup such as <br></br> renders as whitespace; the overlay compares whitespace-normalised text
    return text.replace(/<[^>]*>/g, ' ');
};

const mainKeyset = screen.keyset || screen.items[0].key.split(':')[0];
const items = screen.items.map(({key: id, attr, selector, side, nth}) => {
    const [keyset, key] = id.split(':');
    const prefix = keyset === mainKeyset ? '' : `${keyset.split('.').slice(1).join('.') || keyset} · `;
    const label = `${prefix}${key}${attr ? ` (${attr})` : ''}`;
    const item = {id, label, side, nth};
    if (selector) {
        item.selector = selector;
        if (attr) {
            item.attr = attr;
        }
    } else if (attr) {
        item.attr = attr;
        item.value = textOf(keyset, key);
    } else {
        item.text = textOf(keyset, key);
    }
    return item;
});

const annotate = fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'annotate.js'), 'utf8');
console.log(annotate);
console.log(`window.__annotate(${JSON.stringify({title: screen.title, scope: screen.scope, items})});`);
