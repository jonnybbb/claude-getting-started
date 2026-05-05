# claude-getting-started

Opinionated starter slash commands for [Claude Code](https://docs.claude.com/claude-code).

## What's here

`.claude/commands/` ships three propose-then-write commands that all follow the same pattern: inspect the current repo, propose what they would write, wait for `approve`, then write. Nothing lands without your sign-off.

- **`/scaffold-project-agents`** — inspects the stack and proposes 4 tailored subagents (`frontend-engineer`, `backend-engineer`, `security-reviewer`, `code-quality-reviewer`). Recognises Spring/Ratpack/Quarkus/Micronaut/Vert.x on the JVM, jOOQ/Hibernate/JPA for data, React/Vue/Svelte/Flutter on the frontend. Writes to `.claude/agents/`.
- **`/scaffold-rules`** — proposes 3–6 focused rule files in `.claude/rules/*.md` (e.g. `git.md`, `testing.md`, `gradle.md`, `ratpack.md`, `jooq.md`, `flutter.md`/`react.md`) and wires them into `CLAUDE.md` via `@`-imports. Bullets that aren't clearly evidenced in the repo are tagged `[verify]` for you to confirm.
- **`/install-hooks`** — installs four hooks: Stop → desktop notification, PostToolUse auto-format on Edit/Write, PostToolUse focused-test runner on Edit/Write, PreToolUse blocker for dangerous Bash patterns. Stack-aware formatter and test commands.

The repo is also a Claude Code plugin marketplace (`.claude-plugin/marketplace.json` at the root) hosting one plugin:

- **`code-review`** — local, semantic PR reviews powered by the IntelliJ IDE Index MCP server plus the JetBrains command-line code inspector. Adds the `/code-review:review` slash command, six specialist review agents, and the catalog of sixteen cross-file invariants documented in [`code-review/references/advanced-patterns.md`](code-review/references/advanced-patterns.md). See [`code-review/README.md`](code-review/README.md) for prerequisites (JetBrains IDE 2025.1+, the IDE Index MCP plugin, optional CLI inspector).

`.claude/settings.json` registers this repo as a marketplace (`github: jonnybbb/claude-getting-started`) and lists `code-review` under `enabledPlugins`. When someone opens Claude Code in a project that includes this `.claude/settings.json`, Claude Code prompts to trust the marketplace and install the plugin — no manual `/plugin install` step. To opt out locally, set `enabledPlugins["code-review@claude-getting-started"]` to `false` in `.claude/settings.local.json`.

## Use

Either copy `.claude/commands/*.md` into your project, or symlink them into `~/.claude/commands/` for global use:

```bash
ln -s "$PWD"/.claude/commands/*.md ~/.claude/commands/
```

Then open Claude Code in your repo and run any of the slash commands.

## Notes

- `.claude/settings.local.json` is git-ignored on purpose — it's per-user.
- The `/install-hooks` command writes to `.claude/settings.local.json`, so the hooks stay local to your machine. Move the config to `.claude/settings.json` if you want to share with the team.
