---
description: Inspect this project and scaffold 4 stack-tailored subagents (frontend-engineer, backend-engineer, security-reviewer, code-quality-reviewer) into .claude/agents/ after user approval.
argument-hint: (no args)
---

# Scaffold project subagents

You will create four subagents tailored to **this** project, in two phases:
1. **Inspect & propose** — survey the repo, identify the stack, propose the 4 agent definitions, and wait for explicit user approval.
2. **Write** — only after the user replies "approve" / "yes" / "go" (or equivalent), write the four agent files into `.claude/agents/`.

Do not write any files in phase 1. Do not skip phase 1 even if the project looks obvious.

## Phase 1 — inspect & propose

### Step 1.1: Inspect

Read enough of the repo to identify, with evidence:

- **Backend stack**: language, framework, build tool, and persistence/data layer. Check for `pom.xml`, `build.gradle(.kts)`, `package.json`, `requirements.txt`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `composer.json`, `Gemfile`, `*.csproj`, etc. Look at the top-level source layout (`src/main/java/`, `app/`, `cmd/`, `internal/`, …).
  - For JVM projects, look beyond Spring/Spring Boot: also check for **Ratpack** (`io.ratpack:ratpack-*`, `ratpack-groovy`, handler chains, `Ratpack.start { … }`), Micronaut, Quarkus, Vert.x, Helidon, Dropwizard, plain Servlet/Jetty.
  - For data layer, look for **jOOQ** (`org.jooq:jooq`, generated `org.jooq.generated.*` classes, `DSL.using(...)`), Hibernate/JPA, MyBatis, Exposed, or raw JDBC.
- **Frontend stack**: framework (React, Vue, Svelte, Angular, Lit, **Flutter**, vanilla, server-rendered), bundler (Vite, Webpack, esbuild, Next, Nuxt), styling (Tailwind, CSS modules, styled-components, plain CSS). Inspect `package.json` dependencies and `index.html`/entry points. For **Flutter**, look for `pubspec.yaml`, `lib/main.dart`, widget tree conventions, state management (Provider, Riverpod, Bloc, GetX) — note that the "frontend" may target mobile, web, or both. If there is no separate frontend, say so — the `frontend-engineer` agent should still exist but be scoped to "templates and assets" or similar.
- **Test commands**: how tests are run (`./gradlew test`, `npm test`, `pytest`, `go test ./...`, …). Read CI files (`.github/workflows/*.yml`, `.gitlab-ci.yml`, `Jenkinsfile`) to confirm canonical commands.
- **Lint / format commands**: `eslint`, `prettier`, `ktlint`, `spotless`, `ruff`, `black`, `gofmt`, …. Again confirm via CI where possible.
- **Build / run commands**: `./gradlew build`, `npm run build`, `docker compose up`, …
- **Available skills** the implementer agents can preload. Check both `.claude/skills/<name>/SKILL.md` and `.claude/<name>/SKILL.md` for known-relevant skills. In particular: a **`tdd`** skill (`.claude/skills/tdd/SKILL.md` or `.claude/tdd/SKILL.md`) — if present, the `frontend-engineer` and `backend-engineer` agents should preload it via `skills: [tdd]` in their frontmatter.

Keep inspection focused. Read at most ~15 files. Skip `node_modules`, `target/`, `build/`, `dist/`, `.gradle/`. If the repo is huge, sample: top-level files, one or two source files per layer, the CI config.

### Step 1.2: Propose

Present a single proposal block to the user with this exact shape:

```
## Detected stack

- Backend: <language + framework + build tool, with one-line evidence>
- Frontend: <framework + bundler + styling, with one-line evidence>
- Tests: <command(s)>
- Lint/format: <command(s)>
- Build/run: <command(s)>

## Proposed agents

### frontend-engineer
- Responsibility: <one sentence>
- Tools: <Bash patterns, Read, Edit, Write, Grep, Glob — list explicitly>
- Skills: <list, e.g. `tdd` if a tdd skill was detected; otherwise omit the line>
- Model: sonnet (default)
- Stack-specific notes in prompt: <bullets>

### backend-engineer
- (same shape, including the Skills line when tdd is detected)

### security-reviewer
- (same shape, mostly stack-agnostic but referencing project lint/test commands and dependency files)

### code-quality-reviewer
- (same shape, mostly stack-agnostic but referencing project lint/format/test commands)

Reply **approve** to write these into `.claude/agents/`, or tell me what to change.
```

Then **stop** and wait for the user's reply. Do not write files yet.

## Phase 2 — write

Only after explicit approval, create exactly four files. Use this format for each:

```markdown
---
name: <agent-name>
description: <one-line description that ends with concrete trigger conditions; this is what Claude reads to decide when to delegate>
tools: <comma-separated tool list; restrict to what the agent needs>
skills:
  - <skill-name>   # optional; only include the block if relevant skills were detected (see per-agent guidance below). Omit the whole `skills:` key if none.
model: sonnet
---

You are the <role> for this project.

<Stack-specific context, 3–6 bullets, derived from inspection.>

## Responsibilities

- <bulleted, concrete>

## How to work

- <preferred test command>
- <preferred lint/format command>
- <build command if relevant>
- Project conventions to honor: <2–4 bullets>

## What to avoid

- <agent-specific pitfalls>
```

### Per-agent guidance

**frontend-engineer**
- Tools: `Read, Edit, Write, Grep, Glob` plus a package-manager Bash allowance — `Bash(npm:*), Bash(pnpm:*), Bash(yarn:*), Bash(npx:*)` for JS, or `Bash(flutter:*), Bash(dart:*)` for Flutter. Add `Bash(<test-cmd>:*)` for the frontend test runner (`vitest`, `jest`, `flutter test`, …).
- Skills: if a `tdd` skill was detected during inspection (`.claude/skills/tdd/SKILL.md` or `.claude/tdd/SKILL.md`), include `skills: [tdd]` in the frontmatter. Skip the `skills:` key entirely otherwise.
- Prompt should reference the detected framework, bundler/styling system (or Flutter widget/state-management approach), and component conventions visible in the repo.
- If there is no real frontend, scope the agent to templates/assets and note it.

**backend-engineer**
- Tools: include `Bash(<build-tool>:*)` (e.g., `Bash(./gradlew:*)`, `Bash(mvn:*)`, `Bash(go:*)`, `Bash(python:*)`, `Bash(pytest:*)`) — pick from inspection. Plus `Read, Edit, Write, Grep, Glob`.
- Skills: same rule as `frontend-engineer` — include `skills: [tdd]` when a `tdd` skill is present in the project, omit otherwise.
- Prompt should reference the detected framework, persistence layer (if visible), and testing conventions. For **Ratpack**, mention handler-chain composition, async/Promise idioms, and Groovy-vs-Java conventions in the codebase. For **jOOQ**, mention the generated DSL classes, `DSLContext` injection patterns, and where the codegen output lives.

**security-reviewer**
- Tools: read-mostly. `Read, Grep, Glob, Bash(<dependency-audit-cmd>:*)` if applicable (e.g., `npm audit`, `./gradlew dependencyCheckAnalyze`). No `Edit`/`Write`.
- Prompt: focus on OWASP top 10 in this stack, dependency CVEs, secret leakage, authn/authz patterns visible in the repo.

**code-quality-reviewer**
- Tools: read-mostly + ability to run lint/test. `Read, Grep, Glob, Bash(<lint-cmd>:*), Bash(<test-cmd>:*)`. No `Edit`/`Write`.
- Prompt: duplication, overly clever code, dead code, naming, test gaps; reference the project's lint/format rules and test command.

### After writing

Print a short summary:

```
Wrote 4 agent files to .claude/agents/:
- frontend-engineer.md
- backend-engineer.md
- security-reviewer.md
- code-quality-reviewer.md

Try them with: "Use the security-reviewer subagent to review the most recent commit."
```

Do not commit. Do not modify any other files.
