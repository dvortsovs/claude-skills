# claude-skills

A Claude Code plugin marketplace. `.claude-plugin/marketplace.json` lists the
plugins; each plugin is `plugins/<name>/` with `.claude-plugin/plugin.json` and
`skills/<skill>/SKILL.md`, invoked as `<plugin>:<skill>`. `README.md` is for
consumers only: install, update, what each skill does. Publishing and
development notes live here; `CLAUDE.md` is a symlink to this file.

## Release

Installed plugins are cached copies pinned by `version` in
`plugins/dvortsovs/.claude-plugin/plugin.json`; the catalog is a clone of `main`.
A change reaches users only when all three hold:

1. `version` is bumped (patch for fixes, minor for new flags, skills, or
   removed behaviour);
2. `claude plugin validate .` and `claude plugin validate ./plugins/dvortsovs`
   pass;
3. it is on `main` — other branches are invisible to the catalog.

## Develop

- `claude --plugin-dir ./plugins/dvortsovs` loads the working tree for one
  session, overriding the installed copy; `/reload-plugins` picks up edits.
- A new skill in the namespace is `plugins/dvortsovs/skills/<name>/SKILL.md`,
  no manifest change. A separate plugin needs
  `plugins/<plugin>/.claude-plugin/plugin.json` and an entry in
  `marketplace.json`.
- Skill scripts live in `scripts/`, reference docs in `references/`; scripts
  are installed outside any project checkout, so they must locate the target
  repo from the working directory (`git rev-parse --show-toplevel`) or an
  explicit env var, never from their own location.
- `stand-check` scripts are exercised against the real machine state with
  `--dry-run`; `stop-stand.sh` can be tested with a fake process whose command
  line matches the pattern (`exec -a "node …/app-builder/dist/cli.js dev" sleep 300`).
  The skill itself is verified by one real run — a stand check on a branch — not
  by parallel test agents, which would kill each other's stands.
- `task-cycle` scripts take `--dry-run` / `--help`; `codex-run.sh` is checked
  with one real read-only run on a tiny prompt. The skill itself is verified by
  one real cycle on a small task — it spends tokens of two providers, so not
  as a routine check.

## Contents

The skills hold internal-installation specifics (dev stand host patterns, the
TVM secret id, wiki links), so the repository stays private.
