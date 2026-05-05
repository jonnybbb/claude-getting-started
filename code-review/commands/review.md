---
description: Local semantic code review of the current branch against a target branch, using the IntelliJ IDE Index MCP server for semantic cross-reference and impact analysis.
argument-hint: "[target-branch | A..B | #N | <pr-url> | --pr] [--force] [--max-files=N] [--max-lines=N] [--max-aux-symbols=N] [--no-inspector] [--inspector-budget=Ns]"
allowed-tools: Agent, Bash, Read, Grep, Glob, mcp__intellij-index__ide_index_status, mcp__intellij-index__ide_sync_files, mcp__intellij-index__ide_diagnostics, mcp__intellij-index__ide_find_references, mcp__intellij-index__ide_call_hierarchy, mcp__intellij-index__ide_find_implementations, mcp__intellij-index__ide_find_super_methods, mcp__intellij-index__ide_type_hierarchy, mcp__intellij-index__ide_find_definition, mcp__intellij-index__ide_find_class, mcp__intellij-index__ide_find_file, mcp__intellij-index__ide_search_text
---

# /code-review:review

Review a diff using the IntelliJ IDE Index MCP server as a project-wide semantic oracle. The goal is catching **bug classes that static analyzers cannot detect** — invariants that span multiple files, multiple layers, or multiple actors and therefore require cross-file reasoning about reachability, contracts, data flow, and ordering. Output is a single severity-tagged terminal report. Read-only: never edit files, never invoke any `ide_refactor_*` or `ide_move_file` tool.

**Before starting any phase, read `${CLAUDE_PLUGIN_ROOT}/references/advanced-patterns.md` with the `Read` tool.** That file defines the sixteen generic invariants this plugin exists to enforce (P1–P16), each tied to specific IDE index queries. Do not skip it — the entire value proposition of this plugin hinges on applying the catalog consistently. When a finding matches a cataloged pattern, prefix the finding title with the pattern number (e.g. `[P2]` for a contract-propagation finding, `[P5,P7]` for a finding that touches path parity and ordering). Findings sourced from `.code-review-rules.md` are tagged `[CUSTOM]` instead and must include a `**Rule source:**` line.

**De-emphasize**: anything PMD, Checkstyle, ErrorProne, SpotBugs, ESLint, `tsc --strict`, or SonarLint would already flag — unused imports, missing `final`, raw generics, naming, style, cyclomatic complexity. Only mention those when they are materially relevant to a real bug nearby.

## Arguments

`$ARGUMENTS` is a free-form string that may contain, in any order:

- A **scope token** — the first non-flag token. Three forms are accepted:
  - A **target branch** like `main`, `develop`, `origin/main`. Optional; auto-detected if omitted. Selects **branch mode**.
  - A **commit range** like `A..B` (two refs separated by `..`). `A..HEAD`, `A..`, and bare SHAs with `..` all work. Selects **range mode**.
  - A **PR reference**: either `#N` (e.g. `#42`), a GitHub PR URL (e.g. `https://github.com/org/repo/pull/42`), or the flag `--pr` with no value (auto-detects the PR attached to the current branch). Selects **PR mode**.
- `--force` — bypass the size cap and review anyway. Use sparingly; a too-large review produces shallow findings.
- `--max-files=N` — override the default 25-semantic-file cap for this run.
- `--max-lines=N` — override the default 2000-changed-line cap for this run.
- `--max-aux-symbols=N` — override the default 30-symbol cap for the auxiliary detectors (P12–P16). The core detectors (P1–P11) keep their own 60-symbol budget. Combined default cap is 90 symbols per run.
- `--no-inspector` — skip the JetBrains command-line code inspector step entirely (Phase 2.5). Catalog-only review proceeds. Use when the inspector is producing too much noise on a particular branch, or in a CI environment without the JetBrains binary installed.
- `--inspector-budget=Ns` — override the default 180-second wall-clock budget for the inspector subprocess. Accepts forms `--inspector-budget=600`, `--inspector-budget=600s`, `--inspector-budget=10m`. Clamped to `[30, 1800]` seconds; below-minimum aborts the review with a usage error; above-maximum clamps with a warning. If both `--inspector-budget` and `--no-inspector` are passed, `--no-inspector` wins.

Parse flags first, then classify the scope token in this order: PR reference (`#`, URL, or bare `--pr`) → commit range (contains `..`) → branch name. `--force` is equivalent to `--max-files=9999 --max-lines=999999`. `--force` does NOT remove the inspector budget — use `--inspector-budget=Ns` for that.

## Review scope

**Branch mode** (the default): review everything git knows about that differs between the target's fork point and the working tree. Includes committed branch commits, staged changes, unstaged modifications to tracked files, and `git add`-ed new files. Excludes untracked files, tmp files, gitignored files, and anything else git doesn't know about.

**Range mode** (`A..B`): review exactly what changed between commits `A` and `B`. The working tree is NOT part of the review in this mode. If `B` is `HEAD`, the IntelliJ index matches the review scope exactly. If `B` differs from `HEAD`, cross-reference results (from the IntelliJ index) reflect the current working-tree state rather than `B`'s state — this is noted in the report but does not block the review.

**PR mode** (`#42`, URL, or `--pr`): look up the PR on GitHub via the `gh` CLI, validate that the current local HEAD matches the PR's head commit, and review the diff from `merge-base(pr-base, pr-head)` to `pr-head` — the same diff github.com shows. PR metadata (body, title, state, commits) is pulled into the report context and the Phase 4 review includes an intent-vs-code check: if the PR description claims behavior the diff does not deliver (or vice versa), emit a 🟡 Important finding. The command never runs `gh pr checkout` or `git fetch` to mutate the working tree — if HEAD doesn't match the PR head, it aborts and tells the user to check out the PR branch themselves.

In all three modes, git's own file-tracking rules do all the filtering: a stray scratch file in the working directory cannot accidentally pollute the review because `git diff` simply does not see untracked paths.

## Phase 0: Pre-flight

Run these checks in order. Any failure aborts the review with a clear, actionable message. Do not proceed past a failed check.

**Precondition assumed, not enforced:** the plugin assumes CI runs a standard Java static analysis pass (PMD, Checkstyle, ErrorProne, SpotBugs, FindSecBugs, or IntelliJ inspections) before this review is invoked, and that findings from that pass have been addressed. The catalog specialists' "de-emphasize static-analyzer noise" rules rely on this assumption — they do not emit findings for purely-local shapes that a single-file static analyzer would catch. If CI does not run static analysis, expect the review to miss some bugs that would otherwise surface in those tools; the catalog specialists will still catch cross-file shapes, but local issues (unused imports, simple resource leaks within a method, single-file `==` vs `.equals()`, etc.) will pass through unflagged. This is a deliberate trade: the plugin invests its budget in cross-file reasoning that static tools cannot do, and trusts CI to handle the rest.

1. **IntelliJ MCP server reachable.** Call `mcp__intellij-index__ide_index_status`. If the call errors out or the server is unreachable, abort:
   > "IntelliJ IDE Index MCP server is unavailable. Start IntelliJ with the target project open, install the 'IDE Index MCP Server' plugin (JetBrains Marketplace id 29174), and register the MCP endpoint: `claude mcp add --transport http intellij-index http://127.0.0.1:29170/index-mcp/streamable-http --scope user`. Verify with `claude mcp list`."

2. **IDE has the same project open.** Compare the project root reported by `ide_index_status` against `git rev-parse --show-toplevel`. If they differ (after resolving symlinks), abort:
   > "IntelliJ has a different project open than this git repo. Open `<git-toplevel>` in IntelliJ, wait for indexing, then re-run."

   If `ide_index_status` does not report a project root, fall back to a sanity check: pick one changed file from Phase 1's diff, call `ide_find_file` with its basename, and verify at least one returned path matches the git-relative path. If no match, abort with the same message.

3. **Index ready.** If `ide_index_status` reports indexing in progress, wait ~15 seconds and re-check once. If still not ready, abort with the current status.

4. **Sync files.** Call `mcp__intellij-index__ide_sync_files` to pick up any recent git operations or staging changes so the index reflects current on-disk state.

5. **Inspector pre-flight.** Test that `${CLAUDE_PLUGIN_ROOT}/scripts/run-inspector.sh` exists and is executable: run `test -x ${CLAUDE_PLUGIN_ROOT}/scripts/run-inspector.sh`. If the file is missing or not executable, set the run-state flag `INSPECTOR_AVAILABLE=false` and log to stderr "Inspector wrapper not found at ${CLAUDE_PLUGIN_ROOT}/scripts/run-inspector.sh; inspector step will be skipped." Otherwise set `INSPECTOR_AVAILABLE=true`. Never abort the review on inspector pre-flight failure — the inspector is an enhancement, not a hard requirement (see FR-006). Only the IntelliJ MCP server is mandatory; the inspector is optional and gracefully skipped when missing. Also resolve `INSPECTOR_BUDGET_S` from the parsed `--inspector-budget=Ns` flag (default 180; clamped to [30, 1800]) and `INSPECTOR_DISABLED` from the `--no-inspector` flag (default false). These are read in Phase 2.5.

## Phase 1: Parse arguments, resolve scope, capture diff

1. **Parse `$ARGUMENTS`.** Tokenize on whitespace. Extract flags `--force`, `--max-files=N`, `--max-lines=N`, `--max-aux-symbols=N`, `--no-inspector`, `--inspector-budget=Ns`. The first remaining (non-flag) token is the scope token. Determine the effective caps:
   - `maxFiles` = 25 (default), or the `--max-files` value, or 9999 if `--force`.
   - `maxLines` = 2000 (default), or the `--max-lines` value, or 999999 if `--force`.
   - `maxSymbolsCore` = 60 (default), or the `--max-symbols` value if passed, or proportionally scaled if `--max-files` was passed (`60 * maxFiles / 25`, rounded), or 9999 if `--force`. Covers the "core" catalog patterns P1–P11 plus the sharpened P2.
   - `maxSymbolsAuxiliary` = 30 (default), or the `--max-aux-symbols` value if passed, or proportionally scaled the same way `maxSymbolsCore` is, or 9999 if `--force`. Covers the new "auxiliary" patterns P12–P16. The default combined cap per run is therefore 90 symbols (60 core + 30 auxiliary).
   - Historical alias: `maxSymbols` (single-tier) is retained as an alias for `maxSymbolsCore` in any prompt fragments that still reference it; new logic should prefer the split form.
   - `INSPECTOR_DISABLED` = true if `--no-inspector` was passed; false otherwise. Read in Phase 0 step 5 + Phase 2.5.
   - `INSPECTOR_BUDGET_S` = 180 (default). If `--inspector-budget=Ns` was passed, parse the value: a bare integer is seconds; trailing `s` is seconds; trailing `m` is minutes (multiply by 60). Validate the parsed value:
     - If < 30 → abort the review with usage error: *"--inspector-budget value too small (got Ns, minimum 30s). Lower budgets cannot complete a meaningful inspector run."*
     - If > 1800 → clamp to 1800 and emit a one-line warning to stderr: *"--inspector-budget=Ns clamped to 1800s; the cap exists to keep total review runtime bounded; pass --no-inspector if you want to skip entirely."*
     - Otherwise → use the parsed value as `INSPECTOR_BUDGET_S`.
   - Note: `--force` does NOT bypass the inspector budget. Inspector controls are independent of the file/line/symbol caps.

2. **Classify scope.** Check the scope token in this order:
   - If the token matches `#<digits>`, is a GitHub PR URL (`https://github.com/<owner>/<repo>/pull/<n>`), or the user passed the bare `--pr` flag with no value — **PR mode**.
   - Otherwise, if the token contains `..` — **range mode**.
   - Otherwise (including when the token is absent) — **branch mode**.

3. **PR mode resolution:**
   - **Check `gh` prerequisites.** Run `gh auth status 2>&1`. If exit code is non-zero or the output indicates unauthenticated, abort: *"PR mode requires the `gh` CLI to be installed and authenticated. Install from https://cli.github.com, then run `gh auth login`."*
   - **Verify GitHub remote.** Run `git remote get-url origin`. If the URL does not contain `github.com` (or `github.com:` for ssh), abort: *"PR mode requires a GitHub remote. Detected `<url>`. Use branch or range mode instead."*
   - **Resolve the PR number:**
     - If the token is `#N`, use `N`.
     - If the token is a GitHub PR URL, extract `N` from the path.
     - If the user passed bare `--pr`, run `gh pr status --json number --jq '.currentBranch.number'`. If the result is null or empty, abort: *"No PR found for the current branch. Pass an explicit number: `/code-review:review #N`."*
   - **Fetch PR metadata.** Run one call: `gh pr view <N> --json number,title,body,state,baseRefName,headRefOid,headRefName,commits,url`. Capture the JSON.
   - **Fetch the base branch** so `merge-base` can resolve: `git fetch origin <baseRefName> 2>&1`. If the fetch fails, abort with the git error. This is the only git network operation the command runs.
   - **Verify HEAD matches the PR head.** Compare `git rev-parse HEAD` against the PR's `headRefOid`:
     - If they match exactly: proceed.
     - If they differ: abort with a specific message that includes both SHAs, the PR head branch name, and instructions: *"Current HEAD `<local-sha>` doesn't match PR #N head `<remote-sha>` (branch `<headRefName>`). Run `gh pr checkout <N>` (handles fork PRs too), let IntelliJ reindex the project, then re-run this command."*
   - Set `DIFF_BASE=$(git merge-base origin/<baseRefName> HEAD)`, `DIFF_HEAD=$(git rev-parse HEAD)`, `RANGE_LABEL="PR #<N> \"<title>\" (<state>) — <baseRefName> ← <headRefName>"`.
   - Capture the PR body and commit messages for later use in Phase 4's intent-vs-code check. If the body exceeds ~8000 characters, truncate and note the truncation.
   - Set `WORKTREE_DRIFT=false` (HEAD-match check above already guarantees the index matches the review scope).

4. **Branch mode resolution:**
   - If a scope token was parsed, use it as `<target>`.
   - Otherwise run `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`. If non-empty, use the result.
   - Otherwise try `main`, then `master`. Verify existence with `git rev-parse --verify <target> 2>/dev/null`.
   - If neither exists, abort: *"Could not determine a target branch. Pass one explicitly: `/code-review:review <branch>`."*
   - Verify `git symbolic-ref -q HEAD` succeeds (not detached). If detached, abort.
   - Compute `FORK=$(git merge-base <target> HEAD)`. If this fails (disjoint histories), abort: *"No common ancestor between `<target>` and HEAD."*
   - Set `DIFF_BASE=$FORK`, `DIFF_HEAD=""` (empty means "working tree"), `RANGE_LABEL="<current-branch> → <target> (fork $FORK)"`.

5. **Range mode resolution:**
   - Split the scope token on `..`. Left side is `A` (required, the base). Right side is `B` (optional; empty or missing means `HEAD`).
   - If `A` is empty, abort: *"Range mode requires a base commit: `/code-review:review A..B`."*
   - Verify both `git rev-parse --verify <A>` and `git rev-parse --verify <B>`. Resolve each to a full SHA.
   - Verify `git merge-base --is-ancestor <A> <B>` — `A` must be an ancestor of `B`. If not, abort: *"`A` is not an ancestor of `B`. For non-linear comparisons use branch mode."*
   - Set `DIFF_BASE=<A-sha>`, `DIFF_HEAD=<B-sha>`, `RANGE_LABEL="<A-short>..<B-short>"`.
   - If `<B-sha> != $(git rev-parse HEAD)`, note `WORKTREE_DRIFT=true` for the final report — the IntelliJ index reflects HEAD, not `B`, so cross-reference findings may be slightly stale. Proceed anyway.

6. **Capture the diff once and reference the capture throughout.**
   - **Branch mode** (`DIFF_HEAD=""`): capture `git diff $DIFF_BASE` — includes committed + staged + unstaged tracked changes. Also capture `git log $DIFF_BASE..HEAD --format='%h %s%n%b'` and `git status --short` for commit-vs-uncommitted annotation.
   - **Range mode or PR mode** (`DIFF_HEAD=<sha>`): capture `git diff $DIFF_BASE $DIFF_HEAD`. Also capture `git log $DIFF_BASE..$DIFF_HEAD --format='%h %s%n%b'`. `git status` is not needed.
   - In all modes, also capture `--name-status` form of the same diff for file classification.

   Never pass a branch ref by name when a SHA is available — branch names can move mid-review.

8. **Empty-diff check:** If the diff is empty, report *"No changes to review in `$RANGE_LABEL`."* and stop.

9. **Non-code filter.** From the file list, classify each entry:
   - **Skip entirely** (do not review, do not count toward the cap): binary files, lockfiles (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `poetry.lock`, `Cargo.lock`, `Gemfile.lock`, `go.sum`), minified/bundled files (`*.min.*`, `*.bundle.*`), snapshots (`*.snap`), generated code (contents of `dist/`, `build/`, `out/`, `target/`, `.next/`, `node_modules/`), and explicitly-generated files marked with `@generated`.
   - **Plain-diff review** (no IDE tool calls, just diff inspection for correctness/secrets/conventions): markdown, YAML, JSON, TOML, Dockerfile, shell scripts, config files.
   - **Semantic review** (full Phase 2): everything else — source files in languages IntelliJ indexes.

10. **Size cap.** Count semantic files after filtering (`F`) and total changed lines in the captured diff (`L` = sum of `+` and `-` lines, excluding hunk headers, across all semantic + plain files). If `F > maxFiles` OR `L > maxLines`, abort:
   > "Review scope too large: F semantic files (cap maxFiles), L changed lines (cap maxLines). Options:
   > • Narrow the review: `/code-review:review <closer-ref>`
   > • Raise the cap for this run: `/code-review:review <target> --max-files=N --max-lines=N`
   > • Bypass all caps: `/code-review:review <target> --force` (quality degrades on very large diffs)
   > • Split the change into smaller PRs (recommended)."

   The symbol cap (`maxSymbols`) is enforced in Phase 2 after extraction.

## Phase 2: Impact analysis

This is the highest-value phase. Stay within the ~2-3 minute run budget by working only on the capped set of changed symbols.

### 2-dispatch. Group files by language, pre-run shared evidence, delegate to specialist agents

**HARD RULE — READ THIS FIRST.** If the diff contains **any** file in a supported language (see below), the corresponding specialist agents **must** be launched via the `Agent` tool. There is no file-count threshold, no "small scope" shortcut, no "I can handle this inline" exception. The specialist agents carry language-specific trigger heuristics (advanced-pattern catalog items P1–P16 expressed in Java / TypeScript idioms) that the generic inline reviewer does **not** replicate. Skipping dispatch silently loses the plugin's core value. If you skip it, you are producing a lower-quality review than the plugin is designed to deliver.

The only time the dispatcher may run inline logic for a supported-language file is when the specialist agent has already been invoked and has errored out or timed out (step 6 below). "The diff is only 4 files" is **not** a valid reason to skip dispatch.

1. **Group semantic files by language** using file extension:
   - **java**: `*.java` → **five parallel specialists**: `java-contract`, `java-runtime`, `java-security`, `java-framework`, `java-semantic`. Each receives the full Java file set and the same pre-run cache (step 2). Four are catalog-disciplined and own disjoint pattern slices; the fifth is unconstrained and catches what the catalog shape does not anticipate:
     - `java-contract` (catalog) — P1, P2, P3, P5, P7, P8, P12, P14, P15 (contract + symmetry).
     - `java-runtime` (catalog) — P4, P6, P10, P11 (resources + concurrency + observability + test efficacy).
     - `java-security` (catalog) — P9 (auth + trust boundary).
     - `java-framework` (catalog) — P13, P16 (framework contracts + `[CUSTOM]` rules).
     - `java-semantic` (unconstrained) — no catalog, no lanes, file-reading-primary. Emits `[SEMANTIC]` findings capped at 🟡 Important. Catches product-intent bugs: values built and dropped, silently-empty placeholders, cross-language parallel-data drift, narrowing filters on data exits, spec-vs-code divergence, tests that assert structure but not completeness. Every `[SEMANTIC]` finding cites a mandatory `**Source of intent:**` field (spec, PR body, Javadoc, test name, README, mirror declaration, field contract).
   - **typescript**: `*.ts`, `*.tsx`, `*.mts`, `*.cts` → `typescript-reviewer` (single specialist for now; may split on the Java model in a future round).
   - **generic**: everything else with a semantic classification (no specialist).

2. **Pre-run shared evidence for Java (`javaPrerunCache`).** When the Java file group has ≥1 file, the dispatcher **must** pre-compute the evidence that all four Java specialists would otherwise each request independently. This cuts wall-clock and prevents four concurrent agents from storming the IDE index with duplicate queries. Run the following in the main context, not in any specialist:

   1. **Diagnostics per file.** For every Java file in the group, call `mcp__intellij-index__ide_diagnostics`. Record: file path, error count, warning count, and up to the first 10 error messages with `line:col` for each file.
   2. **Enumerate changed Java symbols.** Read every Java hunk in the captured diff. Identify changed symbols (classes, interfaces, enums, records, methods, fields, static initializers, annotations). Consider a symbol "changed" if any line inside its body is in a `+` or `-` line, or if the symbol itself is added/removed/renamed/re-signatured/re-annotated. For each symbol record `{fqn, kind, status, visibility, file, line}` where `status ∈ {added, modified, removed, renamed, signature-changed, annotation-changed}` and `visibility ∈ {public, protected, package, private}`.
   3. **Enforce the symbol cap.** If total Java changed symbols across all files exceeds `maxSymbolsCore + maxSymbolsAuxiliary`, abort with the standard too-large message (section 10 of Phase 1). Otherwise proceed.
   4. **References per changed non-private symbol.** For each changed symbol whose visibility is not `private`, call `mcp__intellij-index__ide_find_references`. Classify each returned site as:
      - **diff-covered**: the reference's `file:line` falls inside the captured diff's `+` or `-` ranges.
      - **test-only**: the reference lives in a file under `src/test/**` or `**/test/**` or matching `*Test.java` / `*Tests.java`.
      - **production**: everything else.
      Cap per-class enumeration at 10 file:line pairs; record `+N more` if there are more. Do not deep-inspect the references yet — the specialists do that for their own patterns.
   5. **Impl lists for added abstractions.** For every added interface, abstract class, or abstract/default method on an existing abstraction, call `mcp__intellij-index__ide_find_implementations` on the declaring type. Record the result.
   6. **Dangling-reference scan for removed symbols.** For every removed symbol whose name is NOT short/generic (blocklist: `get`, `set`, `save`, `update`, `run`, `apply`, `of`, `create`, `from`, `build`), call `mcp__intellij-index__ide_search_text` with the removed name project-wide. Record outside-diff hits up to 10 file:line per removed symbol; skip structural verification (the specialists will do that). For short/generic names, record `"skipped due to generic name"`.

   Assemble the above into a single markdown block named `javaPrerunCache` with this shape:

   ```markdown
   ## Pre-computed evidence

   ### Diagnostics
   - `<relative-path>`: E errors, W warnings
     (if E > 0, up to 10 errors as `<line>:<col> <message>`)
   ...

   ### Changed symbols
   - `<fqn-signature-or-field>` — <kind>, <status>, <visibility>
     References: total=N
     - diff-covered: N at <file:line>, ...
     - test-only: N at <file:line>, ...
     - production: N at <file:line>, ...

     (For added abstract/interface members:)
     Implementations: N
     - <fqn-of-impl> at <file:line>

     (For removed symbols:)
     search_text hits outside diff: N
     - <file:line>, ...
     (or "skipped due to generic name")
   ...
   ```

   If any pre-run call errors or times out, catch per-call, record the affected file / symbol in a `prerun-degraded` list, and continue with the rest. The specialists will fall back to issuing their own queries for missing entries (see each specialist's "fallback-to-uncached" Counts field).

3. **Mandatory dispatch.** Launch every Java specialist with a file-group ≥1 file in parallel, concurrently with `typescript-reviewer` if the TypeScript group is non-empty. Emit all specialist `Agent` tool calls in a single assistant message. A PR touching 8 Java files and 2 TypeScript files fires **six** concurrent `Agent` calls (five Java specialists + one TypeScript). Non-negotiable.

   Pass each **catalog-disciplined** Java specialist (java-contract, java-runtime, java-security, java-framework) a self-contained prompt containing:
   - A reminder: "Read `${CLAUDE_PLUGIN_ROOT}/references/advanced-patterns.md` before analyzing anything. Prefix findings with `[P<n>]` when they match one of your owned patterns, or `[CUSTOM]` when they match a team-convention rule from the `conventionRules` list below. Stay in lane — do not emit findings for patterns owned by sibling specialists."
   - The diff range label (`$RANGE_LABEL`) and diff mode (`branch`, `range`, or `pr`).
   - The list of Java files assigned (the full Java group; every Java specialist gets the same list).
   - The subset of the captured diff restricted to those files.
   - The per-agent symbol budget: a single `maxSymbols` number computed as `maxSymbolsCore + maxSymbolsAuxiliary` by default (e.g., 90). Do not subdivide across the specialists — each focuses on its own pattern slice and consumes from its own budget. If `--max-files` scaled the totals, scale `maxSymbols` proportionally (`(maxSymbolsCore + maxSymbolsAuxiliary) * files_in_group / total_semantic_files`, rounded up).
   - The `DIFF_BASE` SHA (for `git show` lookups of removed symbols).
   - A one-line note about `WORKTREE_DRIFT` if set.
   - **`javaPrerunCache`** (the block built in step 2) — include verbatim in a `## Pre-computed evidence` section of the prompt. Each specialist is instructed to consume this cache and NOT re-issue `ide_diagnostics` / `ide_find_references` / `ide_find_implementations` / `ide_search_text` on any symbol already listed. Each specialist runs its own specialist queries (`call_hierarchy`, `find_super_methods`, `type_hierarchy`, `find_definition`, etc.) on top of the cache.
   - In PR mode: the PR title, body, and commit messages for the intent-vs-code check.
   - **Project configuration keys**: the `configKeys` set from Phase 3-config. Include verbatim in a `## Project configuration keys` subsection (or `Project configuration keys: none found`). Critical for `java-framework`'s P13 dangling-key detector.
   - **Active planning markers**: the `planningMarkers` list from Phase 3-planning, active-status only, with `sourceFile:sourceLine`, `markerType`, and `body` (truncate body to 200 chars). Critical for `java-contract`'s P15 reconciliation.
   - **Team-convention rules**: the `conventionRules` list from Phase 3-convention with each rule's `sourceLine` and verbatim `ruleText`. Critical for `java-framework`'s P16 `[CUSTOM]` emission. The other catalog specialists receive the list for awareness but do not emit `[CUSTOM]`.
   - Instruction: "Return findings as markdown in the standard severity format (`## 🔴 Blocking`, `## 🟡 Important`, `## 🟢 Suggestion`) plus a terse `## Counts` block with `files-reviewed`, `symbols-analyzed: S / <maxSymbols>`, `cache-consumed: {diagnostics: D files, refs: R symbols}`, `specialist-calls: { <per-tool counts> }`, `per-pattern: <P_n = N for every pattern that fired>`, `degraded-files`, `fallback-to-uncached`."

   Pass the **unconstrained** Java specialist (`java-semantic`) a **different** prompt shape — do NOT reuse the catalog prompt verbatim, because the catalog prompt's "stay in lane / every finding maps to `[P<n>]`" reminder would defeat the point of having an unconstrained fifth agent:
   - A reminder: "Your role is defined in `${CLAUDE_PLUGIN_ROOT}/agents/java-semantic.md`. Read it first. You have NO catalog discipline, NO lane restrictions, and reading files is your primary action. Every finding must carry a `**Source of intent:**` citation. Your severity caps at 🟡 Important — 🔴 Blocking is reserved for the catalog specialists."
   - The diff range label, diff mode, file list, diff fragment (same as the catalog specialists).
   - The `javaPrerunCache` — included as reference material, not primary grounding. The semantic agent consults the cache when an AST question arises but does not feel obligated to exhaust it.
   - In PR mode: **the full PR title + body + commit messages verbatim** — this is the semantic agent's primary intent source and must not be truncated below ~8000 chars.
   - The `configKeys`, `planningMarkers`, `conventionRules` lists — forwarded for awareness.
   - The `mirrorPairs` and `fieldContracts` lists (if a future round adds them) — forwarded as high-confidence intent sources.
   - No `maxSymbols` number — the semantic agent runs on file-reading rather than symbol analysis. It self-paces on reading depth.
   - Instruction: "Return findings as markdown in the format defined by `agents/java-semantic.md`: `## 🟡 Important` and `## 🟢 Suggestion` sections only (no Blocking), each finding with `**Source of intent:**` as a mandatory field, plus the agent's specific Counts block (files-read-in-full, specs-read, tests-read, cross-language-files-grepped, pr-body-consulted, intent-source-breakdown, specialist-calls, degraded, dropped-due-to-catalog-dedup)."

   For the TypeScript specialist, pass the equivalent catalog-style prompt but without `javaPrerunCache` — TypeScript dispatch remains single-specialist until a future round.

4. **While specialist agents run**, the main command handles **only the generic group** inline using sections 2a-2c below. If the generic group is empty, the main command does nothing in Phase 2 except wait for specialists to return. Main-context Phase-2 work on Java/TypeScript files is forbidden, even on the same symbols the pre-run cache already touched — the specialists own those.

5. **Collect and merge agent responses.** Each specialist returns a finding list plus a Counts block. Merge all findings into one list for the Phase 5 output, preserving severity tags and per-agent per-pattern counts. Deduplication rules, applied in order:
   - Two findings citing the **same file:line** AND the **same pattern tag** AND the **same finding title prefix** → merge into one (rare, but possible when a bug touches multiple specialists' lanes and each routes it correctly via cross-link).
   - A `[NOVEL]` finding and a `[P<n>]` / `[CUSTOM]` finding at the **same file:line** describing the same issue → **drop the `[NOVEL]` finding**. The catalog finding is the stronger claim (pattern number + established false-positive rate). The catalog-specialist prompt already instructs agents to prefer cataloged tags when they fit; a surviving `[NOVEL]` duplicate suggests two specialists disagreed about whether the shape fits the catalog — prefer the catalog tag.
   - A `[SEMANTIC]` finding and a catalog / `[NOVEL]` / `[CUSTOM]` finding at the **same file:line** describing the same issue → **drop the `[SEMANTIC]` finding**. The catalog / `[NOVEL]` finding carries AST evidence; the semantic finding is redundant confirmation. Exception: when the `[SEMANTIC]` finding cites an *intent source* the other finding does not (e.g., a spec quote or PR body excerpt that anchors the issue to product intent rather than code structure), keep both — the catalog / `[NOVEL]` finding is the "what" and the semantic finding is the "why". In that exception case, reduce the semantic finding's severity to 🟢 Suggestion if it isn't already, to avoid double-counting severity.
   - Two findings citing the same file:line with **different pattern tags** and **different issues** → keep both; the bug has multiple angles.
   - Two findings with overlapping but non-identical line ranges describing different issues → keep both.

   The final report's "**Reviewers:**" header line **must** enumerate every specialist that ran along with its file count — e.g. `Reviewers: java-contract (8 files), java-runtime (8 files), java-security (8 files), java-framework (8 files), java-semantic (8 files), typescript-reviewer (2 files)`. If the line reads `generic (inline)` when the diff contains Java or TypeScript files, dispatch was skipped in violation of the hard rule and the review must be re-run.

6. **Agent failure handling.** Failure semantics differ between catalog specialists and the semantic agent:
   - **Catalog specialist failure** (`java-contract`, `java-runtime`, `java-security`, `java-framework`, `typescript-reviewer`): capture the error, emit a 🟡 Important finding ("Specialist agent `<name>` failed: `<error>` — pattern slice `<P<n>, ...>` received no specialist review"), and do NOT fall through to inline main-context review for those patterns. The pre-run cache alone is insufficient to replace a specialist's pattern queries. In particular, if `java-security` fails, do not attempt inline P9 review — surface the failure prominently so the human reviewer knows security was not checked. This inverts the prior behavior (inline fallback) because partial coverage on security/runtime/framework is worse than no coverage, which the reviewer can consciously compensate for.
   - **Semantic agent failure** (`java-semantic`): capture the error, emit a 🟢 Suggestion ("Semantic specialist `java-semantic` failed: `<error>` — intent-driven review was skipped; the catalog specialists still ran"), and proceed. The semantic agent is a ceiling-extender, not a floor. Its absence degrades the review's ability to catch product-intent bugs but does not invalidate the catalog specialists' findings.

### 2a. Extract changed symbols (generic group only)

Sections 2a-2c apply only to files in the **generic group** — files in languages without a specialist agent. Java and TypeScript files are handled entirely by their specialist agents and must not be processed here.

For each semantic file in the generic group:

1. Read the diff hunks and identify changed symbols — functions, methods, classes, interfaces, types, enums, exported constants, top-level lambdas. Consider a symbol "changed" if any line inside its body is in a `+` or `-` line, or if the symbol itself is added/removed/renamed/re-signatured.
2. Call `mcp__intellij-index__ide_diagnostics` on the file to ground the parse-tree view. Cross-check that the symbols you identified actually exist in the current index (for added/modified symbols) or are absent (for removed ones). Use the diagnostics result to recover any symbols the diff-reading missed.

Accumulate a deduplicated list `changedSymbols` with fields `{name, file, kind, status}` where status ∈ {added, modified, removed, renamed}.

**Enforce the symbol cap.** If `len(changedSymbols) > maxSymbols`, abort:
> "Review scope too large: N changed symbols (cap maxSymbols). Narrow the target, split the change, or pass `--max-files=N` / `--force` to raise the cap."

### 2b. Per-symbol analysis

For each entry in `changedSymbols`, run the tools appropriate to its status:

**Modified / renamed symbols** (body or signature changed, symbol still exists):
- `ide_find_references` — every returned reference whose `(file, line)` is NOT covered by the captured diff is a **potential unupdated caller**. Flag it.
- `ide_call_hierarchy` (upward/callers) — trace up to 2 levels. If a path reaches a file matching `*Controller*`, `*Handler*`, `*Endpoint*`, `*Route*`, `*Job*`, `*Worker*`, a file with `@app.route`/`@api`/`@RestController`/etc., or a known public-API surface per `CLAUDE.md`, flag the transitive impact.
- If the symbol is a method that overrides a parent: `ide_find_super_methods` — check the parent contract still holds after the change.
- If the symbol is in a class that has subclasses: `ide_type_hierarchy` — enumerate subclasses. For any subclass that overrides this method, check whether the override bypasses new invariants added in the change (e.g. validation added to base `save()` that subclass override doesn't inherit).

**Added symbols** (new functions, methods, classes, interfaces):
- `ide_find_references` to confirm the new symbol is actually wired up somewhere. Newly-added public/exported symbols with zero references are **dead code** — flag as Suggestion.
- If the added symbol is an interface method or abstract method: `ide_find_implementations` — verify all implementations include the new method.

**Removed symbols** (deleted from the change):
- The symbol is gone from the current index, so `find_references` on the current name returns nothing useful.
- Instead: run `git show $DIFF_BASE:<file>` to read the pre-change file contents at the base commit, confirm the symbol existed there and capture its exact name.
- Call `mcp__intellij-index__ide_search_text` with the removed symbol's name against the current index. Any hit that is NOT inside the diff's `+` side is a **dangling reference to a removed symbol** — 🔴 Blocking.
- For well-known public-API names (short, generic: `save`, `update`, `get`), skip the text-search to avoid false positives; rely on diagnostics instead.

**Interface/abstract type changes** (adding/removing/changing abstract members):
- `ide_find_implementations` on the interface/abstract class — verify every implementation is updated in the diff. Unupdated implementations are 🔴 Blocking.

**Any changed file**:
- `ide_diagnostics` results already captured in 2a — promote every error-level diagnostic to 🔴 Blocking (type errors, unresolved symbols, missing imports). Include the IDE's suggested fix verbatim in the finding.

### 2c. Graceful degradation

Some tools return "not supported for this language" errors on files in languages the IntelliJ index handles only partially (e.g. Bash, Dockerfile, niche DSLs). Catch those errors per-call, skip that particular analysis step, and continue. At the end of Phase 2, note any symbols or files that were only partially analyzed so the final summary can mention the degradation.

## Phase 2.5: Inspector subprocess

Runs in parallel with the specialist agents launched in Phase 2-dispatch. The JetBrains command-line code inspector emits findings the catalog (P1–P16) does not encode — control-flow, framework-contract, and breadth-coverage issues. Findings are tagged `[INSPECTOR:<inspection-short-name>]` and merged into the final report at Phase 4 (see `references/advanced-patterns.md` § "Inspector findings (third source class)").

This phase is **opt-out**: it runs by default but is gracefully skipped when the inspector is unavailable, disabled, or fails. The catalog-only review path is preserved on every failure mode. Aborting the review for inspector reasons is forbidden (FR-006).

1. **Skip-when-disabled gate.**
   - If `INSPECTOR_AVAILABLE=false` (set in Phase 0 step 5) → synthesize a manifest `{ "status": "skipped", "warning": "Inspector wrapper not found at ${CLAUDE_PLUGIN_ROOT}/scripts/run-inspector.sh", "budget_s": ${INSPECTOR_BUDGET_S} }` and skip to step 4 below.
   - If `INSPECTOR_DISABLED=true` (the reviewer passed `--no-inspector`) → invoke the wrapper with `--no-inspector` so it emits its own skipped manifest, then proceed to step 4.
   - Otherwise proceed to step 2.

2. **Build the diff-scope file list.** Write the repo-relative paths of every file in the review's diff scope (committed branch commits + staged + unstaged + git-add'ed; untracked excluded — same set Phase 1 captured) to a temp file at `${TMPDIR:-/tmp}/code-review-diff-scope-$$.txt`, one path per line. This file is the wrapper's `--diff-scope` argument.

3. **Invoke the wrapper.** Run:

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/run-inspector.sh \
     --project-root "$(git rev-parse --show-toplevel)" \
     --diff-scope "${TMPDIR:-/tmp}/code-review-diff-scope-$$.txt" \
     --budget-seconds "${INSPECTOR_BUDGET_S}"
   ```

   Capture the wrapper's stdout into a variable `INSPECTOR_MANIFEST_JSON`. Capture stderr into `${TMPDIR:-/tmp}/code-review-inspector-stderr-$$.log` for diagnostic-on-failure surfacing. The wrapper must exit 0 in normal operation (the manifest's `.status` field carries success/failure semantics); a non-zero exit indicates the wrapper itself crashed and the dispatcher MUST synthesize `{ "status": "failed", "warning": "inspector wrapper crashed (exit <N>); see stderr at <path>" }` to keep the rest of Phase 2.5 well-formed.

4. **Handle `requires-prompt` (multi-profile selection).** If `.status == "requires-prompt"`, parse `.available_profiles[]` and use the `AskUserQuestion` tool with:
   - `question`: `"Multiple inspection profiles found in .idea/inspectionProfiles/. Which one should the inspector use for this review?"`
   - `header`: `"Profile"`
   - `multiSelect`: false
   - `options`: one option per profile basename, in the order returned. Each option's `label` is the basename without the `.xml` suffix; `description` is `"Use this profile for the inspector run. Path: .idea/inspectionProfiles/<basename>.xml"`.

   On reviewer cancel, synthesize `{ "status": "skipped", "warning": "Inspector skipped — multi-profile prompt was cancelled" }` and skip step 5.

   On reviewer answer, re-invoke the wrapper exactly as in step 3 but add `--profile <chosen-basename>`. Capture the new manifest into `INSPECTOR_MANIFEST_JSON`. The re-invocation MUST emit a non-prompt status (`ok` / `failed` / `budget-exceeded`); a second `requires-prompt` is treated as `failed` with warning `"inspector returned requires-prompt twice — wrapper bug"`.

5. **Stash the manifest.** Pass `INSPECTOR_MANIFEST_JSON` forward to Phase 4 for finding rendering and run-summary footer emission. Phase 3 does NOT consume it; only the final report does.

The inspector subprocess uses its own sandboxed config / system / log dirs (see `scripts/run-inspector.sh`) so it does NOT contend with the running IntelliJ IDE on the same project. The subprocess is read-only — no project files are modified.

## Phase 3: Convention and pattern checks

Phase 3 begins with three project-input sub-steps that collect configuration, planning, and team-rule context for the auxiliary detectors (P12–P16). These sub-steps run **before** the existing convention checks and their outputs are passed into the specialist agents' prompts in Phase 2-dispatch (even though Phase 2 dispatch happens before Phase 3 in the current execution order, the sub-steps must logically precede dispatch — implementers should execute the 3-x sub-steps as the very first phase-3 action, immediately after Phase 2-dispatch begins but before the dispatched agents return, so the collected outputs can be included in the final specialist prompt context).

None of the 3-x sub-steps consume from the symbol budget; they are cheap file I/O. All three must degrade gracefully when their inputs are missing (no config file, no planning docs, no rules file) — the run must not abort.

### 3-config. Configuration-file reachability

Locate and read project-local configuration files so P13 (framework-contract consistency) can detect dangling property references like `@ConditionalOnProperty("key.that.isnt.in.any.yml")`.

1. Use `ide_find_file` to locate configuration files at the project root, trying each pattern in order: `application.yml`, `application-*.yml`, `application.properties`, `application-*.properties`, `.env`, `.env.*`.
2. For each file found, `Read` its contents.
3. Extract property keys from each file via a textual convention:
   - YAML (`*.yml`): match lines `^[a-zA-Z][\w.-]*\s*:` and record the key (left of the colon).
   - Properties (`*.properties`): match lines `^[a-zA-Z][\w.-]*\s*=` and record the key (left of the equals).
   - `.env*`: match lines `^[A-Z][A-Z0-9_]*=` and record the key.
4. Union all keys across all files into a single set. Profile-specific variants with conflicting values are unioned at the key level — duplicate keys are not flagged.
5. Record the list of config files found for the final Counts block: `config-files-read: <count>`.
6. Store the result as the `configKeys` field of the Project Configuration Snapshot (in memory for this run only — not persisted).

**Graceful degradation**: zero config files found → `configKeys` is the empty set and `config-files-read: 0` in the Counts block. Unreadable file → skip with a note, continue with remaining files. Never abort.

### 3-planning. Planning-marker discovery

Search for task-marker and TODO strings in code and planning docs so P15 (planned-work reconciliation) can detect diff changes that conflict with documented plans.

1. Run `ide_search_text` twice:
   - **Scope A (changed code)**: the set of files changed in the diff (from Phase 1's `--name-status` capture), limited to source-code files.
   - **Scope B (planning docs)**: files matching `docs/**/*.md` and `specs/**/*.md` under the repo root.
2. Search each scope for the following patterns:
   - Literal markers: `TODO:`, `FIXME:`, `XXX:`, `HACK:`, `DEPRECATED`.
   - Task references: `T\d+`, `FR-\d+`, `TD-[A-Z]\d+`.
   - Markdown task checkboxes: `- [ ]` (unchecked) and `- [x]` (checked).
3. For each hit, extract: `sourceFile`, `sourceLine`, `markerType`, `body` (the text following the marker), `referencedSymbols` (Java/TypeScript identifier-shaped strings in the body — best effort, loose regex).
4. Classify each marker's `status`:
   - `resolved` if the marker is `- [x]` or the body contains `done`, `fixed`, `complete` (case-insensitive).
   - `stale` if the marker's file has not been modified in the last 90 days (per `git log -1 --format=%at`) OR the referenced symbols can't be found via `ide_find_class`/`ide_find_definition`.
   - `active` otherwise.
5. Record the count in the final Counts block: `planning-markers-found: <active-count>` (stale/resolved markers are not counted for P15's purposes).
6. Store the list of `active`-status markers as the `planningMarkers` field of the Project Configuration Snapshot.

**Graceful degradation**: no `docs/` or `specs/` directories → skip Scope B, run Scope A only. No changed code files → skip Scope A, run Scope B only. `ide_search_text` errors → treat as zero hits, continue.

### 3-convention. Team-convention rules loading

Read `.code-review-rules.md` if present so P16 (team-convention reachability) can surface repo-local rule violations as `[CUSTOM]` findings.

1. Use `ide_find_file` to check if `.code-review-rules.md` exists at the project root.
2. If present, `Read` its contents.
3. Split the file on `##` heading boundaries (markdown level-2 headings) into a list of rule records. Each rule record has: `sourceFile` (always `.code-review-rules.md`), `sourceLine` (line number of the heading), `ruleText` (the full prose of the rule, heading and body), `scope` (optional — if the rule text contains a path pattern like `in src/controllers/**` or `under .../tests/**`, extract the scope pattern; otherwise null = whole-repo scope).
4. If the file has no `##` headings but contains prose, treat the entire file as one unnamed rule with `sourceLine: 1`.
5. Record the count in the final Counts block: `convention-rules-loaded: <count>`.
6. Store the result as the `conventionRules` field of the Project Configuration Snapshot.

**Graceful degradation**: no `.code-review-rules.md` → `conventionRules` is empty, `convention-rules-loaded: 0`. Empty or whitespace-only file → same. Malformed file (heading split fails) → treat as one unnamed rule covering the full file content. Never abort.

---

### 3-convention-existing. CLAUDE.md and sibling conventions (existing behavior)

1. Read `CLAUDE.md`, `AGENTS.md`, and `.cursorrules` at repo root and in subdirectories touched by the diff (use `Read` — do not grep the whole repo). Treat documented conventions as normative. Flag violations at the severity the convention implies.
2. For each added public/exported symbol, check for a corresponding test file: call `ide_find_file` with the same basename + common test suffixes (`.test.`, `.spec.`, `_test.`, `Test.`, `Spec.`) or in parallel `tests/`, `test/`, `__tests__/` directories. Missing test coverage for new public surface → 🟡 Important.
3. If you notice a pattern in the change that feels unusual (unusual error handling, ad-hoc retry logic, hand-rolled code that duplicates a utility): use `ide_search_text` or `ide_find_class` to check whether the codebase already has an idiomatic version. Flag deviations.

## Phase 4: Per-hunk code review

Walk every `+` hunk in the captured diff and review for:

- **Correctness** — logic errors, off-by-one, null/undefined handling, wrong operators, missed edge cases, incorrect async/await, incorrect mutation of shared state.
- **Error handling** — swallowed exceptions, unhandled promise rejections, missing retries on fallible I/O, resources not closed (files, connections, locks), error paths that leave state inconsistent.
- **Security** — injection (SQL, shell, template), missing authn/authz checks at boundaries, secrets in code or logs, unsafe deserialization, path traversal, ReDoS-prone regexes, SSRF.
- **Concurrency** — races, deadlocks, unsynchronized shared state, async code inside locks.
- **Performance** — N+1 queries in loops, unbounded allocations in hot paths, missing indexes implied by new queries, blocking calls in async contexts.
- **Readability** — unclear naming, dead code, commented-out code, complex expressions needing explanation.

Use `ide_find_definition` liberally to read the bodies of callees before judging correctness. Do not speculate about callee behavior — look it up. Use `ide_type_hierarchy` to verify the safety of casts and generic usage.

For the plain-diff-review files (YAML, JSON, config), skip phases 2-3 and run only a lightweight version of Phase 4 focused on correctness, secrets, and convention drift.

### 4-pr. Intent-vs-code check (PR mode only) — [P1]

This is Pattern P1 (Reachability) applied to promises made in the PR description. A promise that cannot be located as a real effect in the diff or the surrounding code is a reachability gap — the same bug class as a defined-but-uncalled method, just triggered from a textual source.

If this run is PR mode and the PR body is non-empty:

1. Read the captured PR title, body, and commit subjects.
2. Extract concrete behavioral claims: what the PR says it does, fixes, adds, or prevents. Ignore vague phrasing; focus on specific observable effects.
3. For each claim, try to locate the effect in the diff. If a symbol is named ("adds `UserService.rebuild()`"), use `ide_find_references` to verify it exists and is reachable. If an effect is promised ("rejects empty strings"), verify the diff contains a guard, validation, or test that enforces it.
4. Missing deliverables → 🟡 Important finding, tagged `[P1]`.
5. Also flag significant diff changes that the description does NOT mention as scope creep → 🟡 Important.
6. Do NOT emit a finding if the description is empty, trivially short, or a boilerplate template. Silence is better than noise.

Phrase each finding cautiously: *"Description says X; cannot locate X in the diff or surrounding code — verify or update the description."* This lets the developer dismiss a false positive quickly.

## Phase 4.5: Merge inspector findings

After all specialist agents return AND the inspector subprocess returns (Phase 2.5), merge inspector findings into the catalog finding list before rendering. The inspector manifest captured in Phase 2.5 lives at the variable `INSPECTOR_MANIFEST_JSON`. Skip this entire section if `.status` is `skipped`, `failed`, or `requires-prompt-cancelled` — those statuses produce zero findings and only the run-summary footer fires (see "Inspector run-summary footer" below).

For each inspector finding `F_i` in `INSPECTOR_MANIFEST_JSON.findings`:

1. **Coarse line filter.** For each catalog finding `F_c` already accumulated by specialists / Phase 4:
   - If `F_i.file != F_c.file` → not a candidate; continue.
   - If `min(|F_i.line_start - F_c.line_start|, |F_i.line_end - F_c.line_end|) > 2` → not a candidate; continue.

2. **Cause match.** Look up `F_i.inspection_short_name` in the curated `inspection_pattern_map` (defined in `${CLAUDE_PLUGIN_ROOT}/references/advanced-patterns.md` § "Inspector findings (third source class)" → "Inspection-pattern map"):
   - If absent (no curated catalog equivalent for this inspection) → no match; `F_i` stays `top-level` and is rendered as its own report entry. Continue to next `F_i`.
   - If the lookup returns a pattern (e.g. `P3`), search the candidate `F_c` set for one tagged with that pattern (e.g. `[P3]` or `[P3,P5]`). If exactly one matches → same-cause pair found. If multiple → pick the smallest line distance; ties broken by `F_c.line_start` ascending.

3. **Reclassify on match.** Set `F_i.dedup_state = "corroborates"` and append the following text to `F_c.body` immediately before the catalog finding's closing severity marker:

   ```markdown
   **Inspector corroboration:** `[INSPECTOR:<name>]` line <F_i.line_start> — "<F_i.message>" (severity <F_i.review_tier>).
   ```

4. **Render top-level.** Inspector findings whose `dedup_state == "top-level"` after the merge step are rendered as their own report entries in the matching severity section using the `[INSPECTOR:<name>]` finding format (see "Output format" below). Inspector findings whose `dedup_state == "corroborates"` do NOT get their own entry — only the corroboration field on the catalog finding.

**Properties.** The merge is idempotent (running it twice produces the same output); each inspector finding can corroborate at most one catalog finding (the first matched wins by stable order); no inspector finding is silently dropped at this step (drops happen only at severity-mapping time inside the wrapper).

Full algorithm + map: `specs/20260503-163219-add-idea-inspections/contracts/dedup-merge.md`.

## Output format

Emit a single markdown response directly in the terminal. Do not write any file.

```
# Code Review: $RANGE_LABEL

**Files:** N semantic, K plain   **Lines:** L changed   **Commits:** M (+U uncommitted in branch mode)
**Reviewers:** <e.g. "java-contract (12 files), java-runtime (12 files), java-security (12 files), java-framework (12 files), java-semantic (12 files), typescript-reviewer (4 files), generic (2 files)">
<if PR mode: "**PR:** #N • <state> • base `<baseRefName>` ← head `<headRefName>` • <url>">
**Verdict:** <one-sentence overall assessment>
<if WORKTREE_DRIFT: "**Note:** Cross-reference findings reflect HEAD's state and may be slightly stale.">

## 🔴 Blocking
<findings that must be fixed before merge — bugs, security issues, broken references, type errors, unupdated consumers of changed APIs, dangling references to removed symbols, unupdated interface implementations>

## 🟡 Important
<findings that should be addressed — missing error handling, convention violations, missing tests for new public APIs, concerning transitive impact, overridden methods that bypass new invariants>

## 🟢 Suggestion
<nice-to-haves — readability, performance micro-opts, alternative approaches, added symbols with no references, recall-leaning suspected-tier findings>

## Counts
- files-reviewed: N
- symbols-in-prerun-cache: S   # distinct Java symbols pre-enumerated by the dispatcher
- diagnostics-errors (prerun): D
- impl-lists-built (prerun): I
- dangling-scans-run (prerun): R
- prerun-degraded: <list of calls that failed during prerun, or "none">
- per-specialist:
  - java-contract: symbols-analyzed S / <maxSymbols>, specialist-calls {find_implementations=N, find_super_methods=N, type_hierarchy=N, call_hierarchy_up=N, find_definition=N, search_text=N}, per-pattern {P1=N P2=N P3=N P5=N P7=N P8=N P12=N P14=N P15=N}, novel-findings=N, fallback-to-uncached=<list or "none">
  - java-runtime:  symbols-analyzed S / <maxSymbols>, specialist-calls {call_hierarchy_up=N, call_hierarchy_down=N, find_references=N, find_definition=N, find_implementations=N, search_text=N}, per-pattern {P4=N P6=N P10=N P11=N P2-P10-cross-link=N}, novel-findings=N, fallback-to-uncached=<list or "none">
  - java-security: symbols-analyzed S / <maxSymbols>, specialist-calls {call_hierarchy_up=N, find_references=N, find_definition=N, find_class=N, search_text=N}, per-pattern {P9=N}, novel-findings=N, fallback-to-uncached=<list or "none">
  - java-framework: symbols-analyzed S / <maxSymbols>, specialist-calls {find_references=N, find_definition=N, find_class=N, call_hierarchy_up=N, call_hierarchy_down=N, search_text=N}, per-pattern {P13=N CUSTOM=N}, novel-findings=N, configKeys-consulted=K, conventionRules-applied=R, fallback-to-uncached=<list or "none">
  - java-semantic: files-read-in-full=N, specs-read=N, tests-read=N, cross-language-files-grepped=N, pr-body-consulted=<true|false>, intent-source-breakdown={javadoc=N, spec=N, pr-description=N, test-name=N, mirror-declaration=N, field-contract=N, readme=N, other=N}, specialist-calls {ide_find_references=N, ide_call_hierarchy=N, ide_find_definition=N, ide_find_file=N, ide_search_text=N}, dropped-due-to-catalog-dedup=N
  - typescript-reviewer: <its own counts block as returned>
  - generic (inline): symbols-analyzed=S, refs-checked=R, impls-checked=I, diagnostics-errors=D
- novel-findings-total: N   # sum of novel-findings across catalog specialists; signal for catalog evolution when this grows
- degraded-files (aggregated across all reviewers): <list or "none">
- Phase-3 inputs:
  - config-files-read: C
  - planning-markers-found: P
  - convention-rules-loaded: R
- inspector: <one of four status branches — see "Inspector run-summary footer" below>

## Inspector run-summary footer

Render exactly one line for the `- inspector:` entry above, chosen by the manifest's `.status` field:

| `.status` | Footer line |
|---|---|
| `ok` | `**Inspector:** ran for <duration_s> s, profile \`<profile.name>\` (<profile.source>), covered <scope.files_inspector_covered> files; surfaced <K> findings (<X> top-level, <Y> corroborating); <Z> dropped over cap.` |
| `skipped` | `**Inspector:** skipped — <warning>.` |
| `failed` | `**Inspector:** failed — <warning>; catalog findings unaffected.` |
| `budget-exceeded` | `**Inspector:** exceeded <budget_s> s budget; <K> partial findings emitted (<X> top-level, <Y> corroborating); raise budget with --inspector-budget=Ns.` |

Where:
- `K` = total inspector findings emitted (after dedup against catalog).
- `X` = inspector findings with `dedup_state == "top-level"` (their own report entries).
- `Y` = inspector findings with `dedup_state == "corroborates"` (folded into a catalog finding's `**Inspector corroboration:**` field).
- `Z` = number of inspector findings dropped due to the per-run finding cap (default 50).

The footer line MUST appear on every run regardless of `.status` — a successful zero-finding inspector run still emits the line ("surfaced 0 findings, 0 dropped"). Silence is informative: it tells the reviewer the inspector ran cleanly.

The contract that drives this format lives at `specs/20260503-163219-add-idea-inspections/contracts/inspector-finding-format.md`.

## Summary
<overall assessment, key risks, explicit merge-ready or not>
<if Phase 2 degraded for any files due to language support, mention here>
<positive correctness claims must be tool-backed or neutral factual — see advanced-patterns.md review-technique section>
```

Each finding uses this form:

```
### [<pattern-tags>] <short, specific title>
**File:** `path/to/file.ext:line-range`
**What:** <concise description of the issue>
**Why:** <impact or risk — why this matters>
**Fix:**
```lang
<1-5 line suggested snippet>
```
**See also:** `path/to/canonical-example.ext:line` — <optional one-line reason>   # OPTIONAL: omit entirely when no canonical example located
**Rule source:** `.code-review-rules.md:line`   # REQUIRED when pattern tag is [CUSTOM], omitted otherwise
**Source of intent:** <spec, PR body, Javadoc, test name, mirror, or field contract>   # REQUIRED when pattern tag is [SEMANTIC], omitted otherwise
```

Pattern tags:
- Single cataloged pattern: `[P12]`, `[P13]`, etc.
- Multiple cataloged patterns: comma-separated, ascending numeric order, no spaces, max 3: `[P12,P14]`, `[P2,P5,P7]`.
- Custom rule from `.code-review-rules.md`: exactly `[CUSTOM]`. Never combined with pattern numbers or `[NOVEL]`. Requires `**Rule source:**` field.
- Semantic / product-intent finding from `java-semantic`: exactly `[SEMANTIC]`. Never combined with pattern numbers, `[CUSTOM]`, or `[NOVEL]`. Requires `**Source of intent:**` field. Severity capped at 🟡 Important — never 🔴 Blocking.
- Novel finding from a catalog specialist (bug in its domain that doesn't fit P1–P16): exactly `[NOVEL]`. Never combined with pattern numbers, `[CUSTOM]`, or `[SEMANTIC]`. Requires `**Why not catalog:**` field. Severity cap 🟡 Important by default; 🔴 Blocking only when evidence is Certain-tier AND impact is production-breaking. `[NOVEL]` findings are the plugin's catalog-evolution signal — when the same `**Why not catalog:**` reason appears across multiple reviews, that's a candidate for a new P-pattern in `references/advanced-patterns.md`.
- Inspector finding (sourced from the JetBrains command-line code inspector subprocess in Phase 2.5): `[INSPECTOR:<inspection-short-name>]`, e.g. `[INSPECTOR:NullableProblems]`, `[INSPECTOR:RedundantThrows]`. Never combined with pattern numbers, `[CUSTOM]`, `[SEMANTIC]`, or `[NOVEL]`. Disjoint tag namespace — the colon-prefix is mandatory; bare `[INSPECTOR]` is reserved.

Inspector findings use a slightly extended form because the source attribution and silencing instructions are useful boilerplate for the reviewer:

```
### [INSPECTOR:<name>] <heading line — first 100 chars of inspector message, truncated with "…" if longer>
**File:** `path/to/file.ext:line-range`
**Source:** JetBrains command-line code inspector (profile: `<profile-name>` (<profile-source>)).
**Message:** <full inspector message, no truncation>
**Inspection:** `<name>` — to silence, edit `.idea/inspectionProfiles/<profile-name>.xml` and disable or scope this inspection. (For `default` profiles: configure inspection severities under Settings → Editor → Inspections in the IDE, then export the profile.)
```

`<profile-source>` is one of `auto-single`, `user-prompted`, or `default` — copied verbatim from the inspector manifest's `profile.source` field.

Inspector findings whose `dedup_state == "corroborates"` after Phase 4.5 do NOT appear as their own entries in the severity-sorted list — they appear as a `**Inspector corroboration:**` field on the catalog finding they corroborate (see Phase 4.5).

Rules for the output:

- **Omit any empty severity section.** Do not print `## 🔴 Blocking\n\nNone.` — just skip it.
- **Cite evidence.** Every Blocking finding must reference a file:line from either the diff or an IDE tool result. No speculation.
- **Severity discipline.** Blocking = will break production or obviously-wrong. Important = real impact, should fix. Suggestion = optional. When in doubt, drop a level.
- **Snippets in findings**: 1-5 lines, language-tagged fenced block, showing the corrected code (not a diff). For YAML/config findings, the snippet is the fixed config line.
- **Empty review (no findings at all)**: skip all three severity sections and emit a Summary like:
  > "Reviewed N semantic files and K config files (M commits, S symbols). Checked R references, I interface implementations, H call-hierarchies, D diagnostics — all clean. No issues. Ready to merge."

  The counts are real — they come from the tool calls you actually made. If you degraded for any language, say so.

## Hard rules

- **Read-only.** Never call `ide_refactor_rename`, `ide_refactor_safe_delete`, `ide_move_file`. Never edit or create files. The command is a reporter, not a fixer.
- **Capture the diff once.** Run `git diff $FORK` a single time at the start of Phase 1 and reference the captured output throughout. Do not re-run it per phase.
- **Uncommitted changes are in scope.** The review covers committed + staged + unstaged tracked changes vs the target fork point. When a finding lives in an uncommitted hunk, mention that in the finding's `What` line so the developer knows which state is being critiqued.
- **Prefer IDE tools over grep.** Use `Grep`/`Glob` only for plain-text searches the IDE index cannot answer (scanning config files, markdown, build output).
- **Stay within the cap.** Once the 25/60 gates pass, finish the review. Do not exceed the budget by partial-analysis gymnastics.
- **Single pass, single context.** No sub-agents in v1. If the cap feels wrong, the answer is to split the PR, not to loop.
