---
description: Inspect this project and scaffold a modular rule set under .claude/rules/*.md after user approval; wire each file into CLAUDE.md via @-imports.
argument-hint: (no args)
---

# Scaffold project rule files

You will create a small set of focused rule files tailored to **this** project, then wire them into `CLAUDE.md` via `@.claude/rules/<name>.md` imports. Two phases:

1. **Inspect & propose** — survey the repo, decide which rule files apply, sketch the contents of each, and wait for explicit user approval.
2. **Write** — only after the user replies "approve" / "yes" / "go", create `.claude/rules/*.md` and add an `@`-import section to `CLAUDE.md` (creating CLAUDE.md if absent).

Do not write any files in phase 1.

## Phase 1 — inspect & propose

### Step 1.1: Inspect

Identify, with one-line evidence each:

- Languages, frameworks, build tool (re-detect from scratch — don't assume earlier scaffolds ran).
- Formatter / linter config files: `.editorconfig`, `spotless` config in `build.gradle`, `.prettierrc`, `analysis_options.yaml`, `pyproject.toml [tool.ruff]`, …
- Testing layout: where tests live, naming conventions, runner.
- Git conventions visible in recent commits: `git log --oneline -n 30` for commit-message style; `git branch -a` for branch naming patterns.
- Stack-specific signals: Ratpack handler chains, jOOQ generated package, Flutter state-management library, React component conventions.

Read at most ~15 files plus the recent git log. Skip dependency directories.

### Step 1.2: Decide which rule files apply

From this menu, pick only the ones with real evidence in the repo. Skip any that don't apply.

- `git.md` — commit-message format, branch naming, PR description style. (Always include.)
- `testing.md` — test layout, focused-test command, coverage expectations. (Always include.)
- `gradle.md` — task conventions, plugin choices, where new modules go, build-performance defaults. (JVM only.)
- `java-style.md` / `kotlin-style.md` / `groovy-style.md` — formatting, naming, idioms; pick the language(s) actually present.
- `ratpack.md` — handler-chain composition, async/Promise idioms, registry patterns. (Only if Ratpack detected.)
- `jooq.md` — generated DSL location, `DSLContext` injection, query style, codegen workflow. (Only if jOOQ detected.)
- `flutter.md` — widget conventions, state management, folder layout, navigation. (Only if Flutter detected.)
- `react.md` — component conventions, state, styling system, file layout. (Only if React detected.)
- `python-style.md`, `node.md`, etc. — same idea for other stacks.

Aim for **3 to 6 files**. More than 6 dilutes signal; fewer than 3 means you're under-using the modular pattern.

### Step 1.3: Propose

Print this block and stop:

```
## Detected signals

- <one line per signal, with evidence>

## Proposed rule files

### .claude/rules/<name>.md
**Why this file:** <one sentence>
**Sketch (5–10 bullets):**
- <bullet derived from observed code, marked [verify] if uncertain>
- ...

(repeat for each proposed file)

## CLAUDE.md wiring

A `## Rules` section will be appended (or inserted) containing:

@.claude/rules/<name1>.md
@.claude/rules/<name2>.md
...

Reply **approve** to write these, or tell me which to drop / merge / rename.
```

Wait for the user.

## Phase 2 — write

Only after explicit approval:

### Step 2.1: Write the rule files

For each approved file, create `.claude/rules/<name>.md` with this shape:

```markdown
# <Topic title>

> Project-specific rules for <topic>. Rules marked [verify] should be confirmed by the project owner.

## Conventions

- <bullet, concrete, derived from the repo>
- ...

## Commands

- <relevant commands, e.g., `./gradlew spotlessApply`>

## Don't

- <pitfalls specific to this project>
```

Keep each file under ~40 lines. Concrete > comprehensive. If a rule isn't clearly evidenced in the codebase, mark it `[verify]` rather than asserting it.

### Step 2.2: Wire into CLAUDE.md

If `CLAUDE.md` does not exist at the repo root, create a minimal one:

```markdown
# Project rules

@.claude/rules/<name1>.md
@.claude/rules/<name2>.md
...
```

If `CLAUDE.md` exists:
- If it already has a `## Rules` (or similarly named) section with `@`-imports, append the new imports there, deduplicated.
- Otherwise, append a new `## Rules` section at the bottom with the imports.
- Do not modify any other content in CLAUDE.md.

### Step 2.3: Summarize

Print:

```
Wrote N rule files to .claude/rules/:
- <name1>.md
- <name2>.md
- ...

Wired @-imports into CLAUDE.md.

Open each rule file once and replace any [verify] bullets with confirmed wording.
```

Do not commit. Do not modify any files outside `.claude/rules/` and `CLAUDE.md`.
