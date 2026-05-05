# code-review

Local, semantic PR reviews for Claude Code — uses the **IntelliJ IDE Index MCP server** for cross-file impact analysis. No cloud indexing, no vendor dependency.

## What it does

Provides a single slash command, `/code-review:review`, that reviews changes on the current branch (or a GitHub PR) using the IntelliJ IDE Index MCP server as a project-wide semantic oracle. The review is explicitly focused on **bug classes that require cross-file, cross-layer, or cross-actor reasoning** — the things a senior reviewer catches that static analyzers, compilers, and linters cannot, because the analysis needs project-wide visibility into callers, implementations, references, and reachability.

The sixteen generic invariants this plugin hunts for are documented in [`references/advanced-patterns.md`](references/advanced-patterns.md):

1. **Reachability** — every definition must reach a real production entry point; promises in PR descriptions must reach fulfilling code.
2. **Contract propagation** — when a symbol's contract changes, every dependent site (callers, implementations, overrides, variant branches) must adapt. Includes explicit **enum-variant exhaustiveness** as a first-class trigger.
3. **Data-flow completeness** — values produced at one layer must reach every consumer that depends on them, with every consumed field populated.
4. **Lifecycle pairing** — every acquire has a matching release on every reachable path.
5. **Path parity** — happy, error, retry, compensation, and fallback paths stay in lockstep.
6. **Concurrent reachability** — shared state must be ordering-correct across writers and readers.
7. **Ordering invariants** — when X must precede Y, the call graph must enforce it on every path.
8. **External-reality anchoring** — code mirroring external systems must be anchored to the external source of truth, not merely self-consistent.
9. **Authorization reachability & trust-boundary integrity** — every sensitive sink must be dominated by an authorization check on every reaching path; every trust-boundary crossing must be explicit; new public surfaces must default to safe.
10. **Observability integrity** — error signals must preserve cause chains until they reach a handler; logs and metrics must be bounded in cardinality and must not sink sensitive data; silent swallows are bugs.
11. **Test efficacy** — every test must actually exercise the code path it claims to cover; mocks must track the SUT's real call graph; unit tests must not hit external I/O; assertions must observe the behavior the test name promises.
12. **Return-value discipline** — every non-void method whose return carries outcome / error / result / state information must be used by every caller; discarding such a return is a silent information loss. Unread local variables assigned from such methods are the same bug in a different syntactic dress.
13. **Framework-contract consistency** — framework annotations carry implicit runtime contracts (return type for `@Async`, scheduling budget for `@Scheduled`, property-key existence for `@ConditionalOnProperty`, lifecycle binding for `@BeforeAll`) that the compiler does not enforce. Violating them produces code that compiles and runs but silently misbehaves.
14. **Symmetry integrity** — when a class gains a field that participates in identity or construction, every parallel method (`equals`/`hashCode`, builder, copy constructor, factory) must be updated in lockstep. Asymmetry silently corrupts `HashMap` lookups and clones.
15. **Planned-work reconciliation** — when a diff modifies code that is referenced in project planning artifacts (TODO comments, `docs/**/*.md`, `specs/**/*.md` checkbox tasks) as scheduled for removal or rewrite, the conflict is surfaced. Prevents feature work from silently prolonging deprecated code.
16. **Team-convention and custom-rule reachability** — repo-local conventions live in a free-form `.code-review-rules.md` file at the project root. The plugin reads the file, passes its rules to the specialist agents, and emits `[CUSTOM]`-tagged findings with `**Rule source:**` citations. Teams define their own rules without plugin modifications.

Patterns P12–P16 were added after empirical validation against past PRs in production repos. Patterns P9–P11 were added in an earlier round after the same empirical review surfaced three bug classes the original P1–P8 missed.

### Recall-leaning mode with confidence tiers

Every negative finding (a bug report) is emitted at one of three severity levels based on the strength of the IDE-tool evidence backing it:

- **Certain** (IDE tool result directly contradicts the code's contract) → 🔴 Blocking or 🟡 Important.
- **Plausible** (diff-pattern matches a catalog shape plus partial tool verification) → 🟡 Important or 🟢 Suggestion.
- **Suspected** (diff-pattern alone, no tool verification possible) → 🟢 Suggestion; emitted, not dropped.

This **recall-leaning** stance shifted from strict-precision after real validation runs exposed false negatives on patterns the plugin had hints about but lacked evidence to cite. Positive correctness claims in the summary section still require tool-backed evidence — the relaxation applies only to negative findings.

Every finding follows the same evidence-backed pipeline: a suspicion raised from diff reading is **verified** with an IDE index query (`find_references`, `call_hierarchy`, `find_implementations`, `find_super_methods`, `type_hierarchy`, `find_definition`, `diagnostics`) before being emitted. Speculation that does not match any cataloged pattern is dropped.

Findings are organized by severity (🔴 Blocking / 🟡 Important / 🟢 Suggestion), prefixed with the pattern number (`[P2]`, `[P5,P7]`, etc.) or `[CUSTOM]` for rules from `.code-review-rules.md`, and include file:line citations plus a short corrected-code snippet. Optional `**See also:**` fields point at canonical examples of the correct pattern already in the codebase.

## Prerequisites

1. **JetBrains IDE 2025.1+** running with the target project open.
2. **IDE Index MCP Server** plugin installed in the IDE (JetBrains Marketplace plugin ID 29174 — <https://github.com/hechtcarmel/jetbrains-index-mcp-plugin>).
3. **`gh` CLI** installed and authenticated (`gh auth login`) — required only for PR mode.
4. **Claude Code** wired to the MCP server:

   ```bash
   # IntelliJ IDEA (default port 29170)
   claude mcp add --transport http intellij-index \
     http://127.0.0.1:29170/index-mcp/streamable-http --scope user

   # Other IDEs — adjust port:
   #   GoLand: 29171, PyCharm: 29172, WebStorm: 29173
   ```

5. **Recommended: enable these optional tools** in the IDE under Settings → Tools → Index MCP Server:
   - Build Project
   - Symbol Search
   - File Structure

6. **Optional: JetBrains command-line code inspector.** When the JetBrains CLI inspector binary is discoverable, the review additionally runs `idea inspect` against the diff scope and surfaces findings tagged `[INSPECTOR:<inspection-short-name>]` alongside the catalog (P1–P16) findings. This adds breadth coverage — JetBrains' built-in inspections (probable bugs, framework anti-patterns, contract violations) catch bug classes the catalog does not encode. The inspector is **opt-out** — the plugin works without it, gracefully skipping the inspector step with a one-line warning when the binary is missing or fails. To enable:

   - Confirm a JetBrains IDE 2025.1+ is installed (any of IntelliJ IDEA Ultimate, WebStorm, GoLand, PyCharm). Discovery is layered: env override (`CODE_REVIEW_INSPECT_BIN`) → macOS `.app` bundles in `/Applications` and `~/Applications` → `idea` on `PATH` (with a Toolbox-wrapper sniff to skip GUI-only `open -na` scripts) → JetBrains Toolbox apps dir → `${JETBRAINS_IDE_HOME}/bin/`.
   - If discovery fails, set the override env var manually:

     ```bash
     export CODE_REVIEW_INSPECT_BIN="/path/to/IntelliJ IDEA.app/Contents/MacOS/idea"
     ```

   - Inspection profile selection: the inspector honors `${PROJECT_ROOT}/.idea/inspectionProfiles/`. One profile XML → auto-used; multiple → the dispatcher prompts you to pick one; none → IntelliJ defaults. Edit your profile XML to silence noisy inspections (the JetBrains-native lever — plugin-side severity overrides are deferred to v2).
   - The inspector subprocess uses sandboxed config / system / log dirs and does **not** contend with your live IDE running on the same project.

   Severity mapping (frozen for v1): `ERROR` → 🔴 Blocking, `WARNING` → 🟡 Important, `WEAK_WARNING` → 🟢 Suggestion, `INFO` / `TYPO` / `GRAMMAR_ERROR` → dropped. Unknown JetBrains severities default to 🟢 Suggestion (never 🔴, never 🟡). Full table: `references/advanced-patterns.md` § "Inspector findings".

## Installation

Install as a local plugin:

```bash
claude plugin install /path/to/code-review
```

Or point Claude Code at the plugin directory directly:

```bash
cc --plugin-dir /path/to/code-review
```

## Usage

```text
# Branch mode — review the current branch vs a target
/code-review:review                         # auto-detect target branch from origin/HEAD
/code-review:review develop                 # explicit target
/code-review:review origin/main             # explicit remote ref

# Range mode — review a specific commit range (great for slicing big branches)
/code-review:review abc123..def456          # two explicit SHAs or refs
/code-review:review abc123..HEAD            # from a commit to HEAD
/code-review:review origin/main..feature    # classic A..B form

# PR mode — review a GitHub pull request (via gh CLI)
/code-review:review #42                                             # by PR number
/code-review:review https://github.com/org/repo/pull/42             # by URL
/code-review:review --pr                                            # auto-detect PR for current branch

# Cap overrides (work in any mode)
/code-review:review main --max-files=50            # raise file cap for this run
/code-review:review main --max-lines=5000          # raise line cap for this run
/code-review:review main --max-aux-symbols=60      # raise the auxiliary-detector budget (P12–P16 patterns)
/code-review:review main --force                   # bypass all size caps

# Inspector overrides (work in any mode)
/code-review:review main --no-inspector            # skip the JetBrains inspector step entirely
/code-review:review main --inspector-budget=10m    # raise the inspector wall-clock cap to 10 minutes
/code-review:review main --inspector-budget=600s   # equivalent: 600 seconds
```

The review runs in a single Claude turn and prints the full report to the terminal. It is read-only: the command never modifies files.

### Expected runtime

Typical runtimes at default budget (`maxFiles=25`, `maxLines=2000`, `maxSymbolsCore=60`, `maxSymbolsAuxiliary=30`, inspector budget 180s):

- **Small PR** (≤10 changed files): 2–4 minutes catalog + 0–1 min inspector ≈ 2–5 min total.
- **Mid-size PR** (20–40 changed files): 5–8 minutes catalog + 1–3 min inspector ≈ 6–11 min total.
- **Large PR** at the cap: 8–12 minutes catalog + up to 3 min inspector ≈ 11–15 min total at default budget; above the size cap, the run aborts with guidance. Above the inspector budget, the inspector emits partial findings + a budget-exceeded warning and the rest of the review continues.

The auxiliary-detector budget (P12–P16) adds ~2 minutes to a typical mid-size PR vs the previous 11-pattern baseline. Raise it with `--max-aux-symbols=N` when you want deeper coverage at the cost of runtime.

The inspector budget (default 180s = 3 min) caps the JetBrains command-line inspector subprocess. On large monorepos a cold-cache run can hit the cap; raise with `--inspector-budget=10m` for fuller coverage, or skip the inspector with `--no-inspector` for fast iteration. The inspector contributes recall over the JetBrains-built-in inspection set — turning it off does not affect the catalog (P1–P16) or `[CUSTOM]` finding paths.

### Team conventions (`.code-review-rules.md`)

Create a `.code-review-rules.md` file at your project root to have the plugin apply repo-local rules alongside the cataloged patterns. The format is free-form markdown — each `##` heading is treated as one rule, its body is the rule's prose, and the specialist agents interpret the rules via the LLM. Violations produce `[CUSTOM]`-tagged findings with `**Rule source:**` fields citing the rules-file line.

Example starter file: [`testing/fixtures/sample-code-review-rules.md`](testing/fixtures/sample-code-review-rules.md) — copy a subset to your project root and tweak the scopes and rules to your team's needs.

Rules are natural-language, not a DSL. Rules too vague to apply deterministically are silently ignored. Rules that conflict with a cataloged pattern finding produce both findings, and the developer resolves the conflict.

## Language-specialist reviewers

For supported languages, the main command dispatches files to specialist subagents in parallel. Each specialist applies the same sixteen-pattern catalog, through language-specific syntactic triggers that locate each pattern in real code:

- **Java** — five parallel specialists, each owning a disjoint slice of P1–P16:
  - **`java-contract`** — P1, P2, P3, P5, P7, P8, P12, P14, P15: `Optional` / `Result` unwrap bodies, unchecked-exception propagation, data-flow completeness, path parity, ordering invariants, external-reality anchoring, return-value discipline (including rows-affected discards in conditional updates), equals/hashCode/builder/copy-constructor symmetry, planned-work reconciliation.
  - **`java-runtime`** — P4, P6, P10, P11: `try`-with-resources and lock pairing, concurrent reachability, observability integrity (cause chains, log cardinality, silent swallows), JUnit/Mockito test efficacy.
  - **`java-security`** — P9: authorization reachability, trust-boundary integrity, safe-by-default public surfaces.
  - **`java-framework`** — P13, P16: `@Async` / `@Transactional` / `@Scheduled` / `@Valid` / `@ConditionalOnProperty` / `@Cacheable` framework-contract consistency, plus `[CUSTOM]` rules from `.code-review-rules.md`.
  - **`java-semantic`** — unconstrained (no catalog, `[SEMANTIC]`-tagged findings capped at 🟡 Important): product-intent drift, values built and dropped, silently-empty placeholders, cross-language parallel-data drift, spec-vs-code divergence.
- **`typescript-reviewer`** — TypeScript-syntax triggers across P1–P16: Promise `await` shapes and effect cleanups, discriminated-union exhaustiveness, stale closures and dependency arrays, schema-vs-runtime validation gaps, zod/TanStack Query / NestJS / Vitest contract consistency, `Result<T, E>` / `Promise<T>` return-value discipline, component prop symmetry, planned-work reconciliation against markdown planning docs.

Files in other languages fall through to a generic inline reviewer in the main command. Specialist agents run concurrently when a diff touches multiple supported languages, and their findings are merged into a single severity-sorted report. Every finding — regardless of language — is tagged with one of the sixteen pattern numbers or `[CUSTOM]` (when sourced from `.code-review-rules.md`).

## Scope and constraints

- **Review scope = anything git knows about that differs from the fork point** (`git merge-base <target> HEAD`). That means: committed branch commits, staged changes, unstaged modifications to tracked files, and new files that have been `git add`-ed. **Untracked files are excluded** — a stray tmp file or a new file you haven't `git add`-ed yet is completely invisible to the review. Run the command before committing to catch issues early, or after committing for a pre-merge review. Same result either way.
- **IntelliJ must have the same project open.** The command compares `ide_index_status`'s project root against `git rev-parse --show-toplevel` and aborts on mismatch.
- **Default size cap: 25 semantic files OR 2000 changed lines OR 60 changed symbols.** Either dimension triggers the gate. Non-code files (lockfiles, generated output, minified assets) are filtered before counting. Override per-run with `--max-files=N`, `--max-lines=N`, or bypass entirely with `--force`. Findings get shallower as the diff grows — `--force` is an escape hatch, not a default.
- **No MCP fallback.** If the IntelliJ MCP server is unavailable, the command aborts with setup guidance rather than degrading to grep-based review — quality over availability.
- **Read-only.** The command never edits files and never invokes IntelliJ's refactoring tools.

## Trade-offs vs. cloud-based reviewers

| Aspect | This plugin | Cloud-based (e.g., Greptile) |
|---|---|---|
| Semantic understanding | ✅ IntelliJ warm index | ✅ Embeddings |
| Cross-file references | ✅ `find_references` + `call_hierarchy` | ✅ Pre-indexed |
| Type hierarchy analysis | ✅ `type_hierarchy` + `find_implementations` | ⚠️ Embedding-based |
| IDE dependency | Yes — IntelliJ must be running | No |
| Vendor dependency | None | Yes |
| CI integration | Not yet | Built-in |

## Roadmap

- **v2**: ast-grep rules for recurring convention violations
- **v3**: Multi-agent split for very large PRs (impact / correctness / summary)
- **v4**: CI integration (headless IntelliJ, LSP-only, or pre-built index)
