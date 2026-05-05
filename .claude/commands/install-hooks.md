---
description: Inspect this project and install 4 stack-tailored hooks (Stop notification, auto-format on edit, run tests on edit, block dangerous Bash) into .claude/settings.local.json + .claude/hooks/ after user approval.
argument-hint: (no args)
---

# Install hook recipe pack

You will install four hooks tailored to **this** project, in two phases:
1. **Inspect & propose** — survey the repo to identify formatter and test commands, then propose the four hook configs and wait for explicit user approval.
2. **Write** — only after the user replies "approve" / "yes" / "go", create `.claude/hooks/*.sh` scripts and merge the hook config into `.claude/settings.local.json`.

Do not write any files in phase 1.

## Phase 1 — inspect & propose

### Step 1.1: Inspect

Identify, with one-line evidence each:

- **Formatter command** that runs without arguments on a single file or whole repo.
  - JVM: `./gradlew spotlessApply`, `./gradlew ktlintFormat`, `mvn spotless:apply`.
  - Dart/Flutter: `dart format <file>`.
  - JS/TS: `npx prettier --write <file>`, or `npm run format` if defined in `package.json`.
  - Python: `ruff format <file>`, `black <file>`.
- **Test command** that runs a focused test for a single source file.
  - JVM: `./gradlew test --tests "*<ClassName>Test"`.
  - Dart: `dart test test/<name>_test.dart`.
  - JS/TS: `npx vitest run <file>` or `npx jest <file>`.
  - Python: `pytest <file>`.
- **Source-to-test mapping convention** in this repo (look at `src/test/java/`, `test/`, co-located `*.test.ts`, `*_test.dart` etc.) so the test hook knows which test file to run when a source file is edited.
- **OS** — assume macOS unless evidence says otherwise (the desktop-notification hook uses `osascript`).

Read at most ~10 files. Skip dependency / build directories.

### Step 1.2: Propose

Print this block exactly and stop:

```
## Detected commands

- Formatter: <command>  (evidence: <file>)
- Test (focused): <command template>  (evidence: <file>)
- Source→test mapping: <description>
- OS: macOS

## Proposed hooks

### 1. Stop → desktop notification
Fires when Claude finishes responding. Uses osascript to show a macOS banner.

### 2. PostToolUse on Edit|Write → auto-format
Fires after each successful Edit or Write. Reads the changed file from the hook payload and runs `<formatter>` scoped to that file's language. No-op for files outside the formatter's scope.

### 3. PostToolUse on Edit|Write → run focused tests
Fires after each successful Edit or Write to a source file under `<source-root>`. Maps to the corresponding test and runs `<test-command>`. No-op for non-source files.

### 4. PreToolUse on Bash → block dangerous patterns
Fires before each Bash invocation. Blocks commands matching: `rm -rf`, `git push --force`, `git push -f`, `gh pr merge`, `git reset --hard`, `git clean -fd`. Returns a clear block reason.

Reply **approve** to install (writes `.claude/hooks/*.sh` and merges into `.claude/settings.local.json`), or tell me what to change.
```

Then wait for the user.

## Phase 2 — write

Only after explicit approval:

### Step 2.1: Create hook scripts

Create `.claude/hooks/` and write four executable scripts (`chmod +x` each):

**`.claude/hooks/stop-notify.sh`**
```bash
#!/usr/bin/env bash
osascript -e 'display notification "Claude is done." with title "Claude Code" sound name "Glass"' >/dev/null 2>&1 || true
exit 0
```

**`.claude/hooks/format-on-edit.sh`** (parameterize the formatter line per stack):
```bash
#!/usr/bin/env bash
INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | /usr/bin/env jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0
case "$FILE" in
  # Replace these branches with the detected formatter(s) for this project:
  *.java|*.kt|*.kts|*.groovy) (cd "$(git rev-parse --show-toplevel)" && <FORMATTER_COMMAND>) >/dev/null 2>&1 || true ;;
  *.dart)                      dart format "$FILE" >/dev/null 2>&1 || true ;;
  *.ts|*.tsx|*.js|*.jsx)       npx --no-install prettier --write "$FILE" >/dev/null 2>&1 || true ;;
  *.py)                        <PY_FORMATTER> "$FILE" >/dev/null 2>&1 || true ;;
esac
exit 0
```
Trim the case branches to only those that fit the detected stack. Replace `<FORMATTER_COMMAND>` with the inspected command (e.g., `./gradlew spotlessApply`). Skip languages not present.

**`.claude/hooks/test-on-edit.sh`** (parameterize the source→test mapping per stack):
```bash
#!/usr/bin/env bash
INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | /usr/bin/env jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0

# Replace this block with the inspected mapping. Examples below — pick one and delete the others.
case "$FILE" in
  src/main/java/*/*.java)
    BASENAME=$(basename "$FILE" .java)
    (cd "$(git rev-parse --show-toplevel)" && ./gradlew test --tests "*${BASENAME}Test" -q) >/dev/null 2>&1 || true
    ;;
  lib/*.dart)
    NAME=$(basename "$FILE" .dart)
    (cd "$(git rev-parse --show-toplevel)" && dart test "test/${NAME}_test.dart" -r compact) >/dev/null 2>&1 || true
    ;;
  src/*.ts|src/*.tsx)
    BASENAME=$(basename "$FILE" | sed 's/\.[^.]*$//')
    (cd "$(git rev-parse --show-toplevel)" && npx --no-install vitest run --silent --testPathPattern "${BASENAME}.test") >/dev/null 2>&1 || true
    ;;
esac
exit 0
```
Trim to the one mapping that matches this project. Keep it best-effort and silent — the hook never fails the tool call; output goes to a log if anyone wants it.

**`.claude/hooks/block-dangerous-bash.sh`**
```bash
#!/usr/bin/env bash
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | /usr/bin/env jq -r '.tool_input.command // empty')
if printf '%s' "$CMD" | /usr/bin/env grep -Eq 'rm[[:space:]]+-rf|git[[:space:]]+push[[:space:]]+(--force|-f)|gh[[:space:]]+pr[[:space:]]+merge|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-fd'; then
  printf '{"decision":"block","reason":"Dangerous command blocked by training hook. Run it yourself if intended."}'
  exit 0
fi
exit 0
```

After writing each script: `chmod +x .claude/hooks/<name>.sh`.

### Step 2.2: Merge into `.claude/settings.local.json`

Read the existing `.claude/settings.local.json` if present (otherwise start from `{}`). Merge in this `hooks` block, preserving any other top-level keys:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": ".claude/hooks/stop-notify.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/format-on-edit.sh" },
          { "type": "command", "command": ".claude/hooks/test-on-edit.sh" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/block-dangerous-bash.sh" }
        ]
      }
    ]
  }
}
```

If a `hooks` key already exists in the file, **append** to the relevant arrays rather than overwriting; do not duplicate identical entries.

### Step 2.3: Summarize

Print:

```
Installed 4 hooks:
- .claude/hooks/stop-notify.sh        (Stop)
- .claude/hooks/format-on-edit.sh     (PostToolUse: Edit|Write)
- .claude/hooks/test-on-edit.sh       (PostToolUse: Edit|Write)
- .claude/hooks/block-dangerous-bash.sh (PreToolUse: Bash)

Merged hook config into .claude/settings.local.json.
Restart the Claude Code session for the hooks to take effect.

Try: ask me to edit a source file and watch the format/test hooks fire,
or ask me to `rm -rf something` and watch the block-dangerous hook stop me.
```

Do not commit. Do not modify any other files.
