#!/usr/bin/env node
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const HELP = `Usage: keys.mjs [options]

Lists i18n keys that need screenshots: status <STATUS> in keyset.json (any language) and, unless
--all, text new or changed against the merge-base with <base>.

Options:
  --repo <path>         repository root (default: git top level of the cwd)
  --base <ref>          base branch (default: origin/main, else main)
  --status <STATUS>     keyset.json status to select (default: REQUIRES_TRANSLATION)
  --lang <lang>         language whose text is printed (default: ru)
  --all                 every key with <STATUS>, changed in the branch or not
  --table               print "keyset:key<TAB>text" lines instead of JSON
  --coverage <file>     check screens.json covers every selected key; exit 1 if not
  --help                this text

Keysets are read from src/i18n-keysets and projects/*/src/i18n-keysets.`;

const args = {status: 'REQUIRES_TRANSLATION', lang: 'ru'};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const name = argv[i].replace(/^--/, '');
    if (['all', 'table', 'help'].includes(name)) {
        args[name] = true;
    } else {
        args[name] = argv[++i];
    }
}
if (args.help) {
    console.log(HELP);
    process.exit(0);
}

const run = (cmd, cmdArgs) => execFileSync(cmd, cmdArgs, {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore']}).trim();
const repo = args.repo || run('git', ['rev-parse', '--show-toplevel']);
const git = (...gitArgs) => run('git', ['-C', repo, ...gitArgs]);
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));

const keysetRoots = [path.join(repo, 'src/i18n-keysets')];
const projects = path.join(repo, 'projects');
if (fs.existsSync(projects)) {
    for (const project of fs.readdirSync(projects)) {
        keysetRoots.push(path.join(projects, project, 'src/i18n-keysets'));
    }
}

let mergeBase = null;
if (!args.all) {
    const base =
        args.base ||
        (() => {
            try {
                git('rev-parse', '--verify', 'origin/main');
                return 'origin/main';
            } catch {
                return 'main';
            }
        })();
    mergeBase = git('merge-base', 'HEAD', base);
}
const baseTexts = (relFile) => {
    try {
        return JSON.parse(git('show', `${mergeBase}:${relFile}`));
    } catch {
        return {};
    }
};

const selected = [];
for (const root of keysetRoots.filter((r) => fs.existsSync(r))) {
    for (const keyset of fs.readdirSync(root).sort()) {
        const dir = path.join(root, keyset);
        const meta = path.join(dir, 'keyset.json');
        const textsFile = path.join(dir, `${args.lang}.json`);
        if (!fs.existsSync(meta) || !fs.existsSync(textsFile)) {
            continue;
        }
        const status = readJson(meta).status || {};
        const texts = readJson(textsFile);
        const before = mergeBase ? baseTexts(path.relative(repo, textsFile)) : {};
        for (const [key, langs] of Object.entries(status)) {
            if (!Object.values(langs).includes(args.status)) {
                continue;
            }
            if (mergeBase && before[key] === texts[key]) {
                continue;
            }
            selected.push({id: `${keyset}:${key}`, keyset, key, text: texts[key], dir: path.relative(repo, dir)});
        }
    }
}

if (args.coverage) {
    const spec = readJson(args.coverage);
    const covered = new Set(
        Object.values(spec.screens).flatMap((screen) => screen.items.map((item) => item.key)),
    );
    const uncovered = selected.filter(({id}) => !covered.has(id));
    const unknown = [...covered].filter((id) => !selected.some((s) => s.id === id));
    console.log(`selected: ${selected.length}, covered: ${selected.length - uncovered.length}`);
    uncovered.forEach(({id}) => console.log(`UNCOVERED ${id}`));
    unknown.forEach((id) => console.log(`extra (not selected, fine if intended) ${id}`));
    process.exit(uncovered.length ? 1 : 0);
}

if (args.table) {
    selected.forEach(({id, text}) => console.log(`${id}\t${text}`));
} else {
    console.log(JSON.stringify(selected, null, 2));
}
