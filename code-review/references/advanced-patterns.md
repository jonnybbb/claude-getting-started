# Advanced Review Patterns

This catalog is the primary focus of every review run by this plugin. It enumerates the bug classes that static analyzers, compilers, linters, and formatters systematically miss — not because they are exotic, but because detecting them requires **project-wide semantic reasoning** about reachability, contracts, data flow, and ordering.

Every agent and the main command must load this file before analyzing a diff. When a finding matches a pattern, prefix the finding title with the pattern number.

---

## Why static tools miss these bugs

Static analyzers operate within a file or a bounded AST window. They check local type correctness, local null-safety, local style, and local complexity. They cannot answer the questions this plugin lives to answer:

- **Who calls this?** Across every file in the project, including indirect callers through polymorphism.
- **What implements this?** Across every concrete type that satisfies an abstraction.
- **What overrides this?** Across the full type hierarchy.
- **What is reachable from here?** Walking the call graph upward to real entry points.
- **What reaches here?** Walking the call graph downward from an entry point.
- **Are all variants of this type handled?** Across every branch on a state enum, sum type, or discriminated union in the codebase.
- **Is this actually used by production?** Distinguishing references from tests from references from real code paths.
- **What happens if this runs concurrently with that?** Identifying the full set of writers and readers of shared state.

The IntelliJ IDE Index MCP server answers exactly these questions. Combined with an LLM reviewer that proposes suspicions from diff reading and then verifies them with IDE tool calls, it produces findings that carry **project-wide semantic evidence**, not speculation.

---

## The review technique

Every finding follows the same four-step pipeline:

1. **Identify** a suspicion from diff reading — an empty continuation body, a changed signature, a new state variant, a removed guard, a value computed but not propagated.
2. **Query** the IDE index with the appropriate tool — `find_references`, `call_hierarchy`, `find_implementations`, and so on.
3. **Interpret** the query result against one of the sixteen invariants below.
4. **Cite** file:line evidence from the tool result in the finding, and map the finding's evidence strength to a severity tier (see below).

### Confidence tiers and severity mapping

Every negative finding (a suspected bug report) maps to one of three confidence tiers based on how strongly the IDE tools backed the suspicion, and each tier maps to a severity emoji in the final report:

| Tier | Definition | Severity |
|---|---|---|
| **Certain** | An IDE tool result cites a specific file:line that directly contradicts the code's contract. Example: `ide_find_references` lists 3 callers that still use an old signature; `ide_diagnostics` reports a type error on the modified file; `ide_find_implementations` returns a concrete class that doesn't implement a newly-added abstract method. | 🔴 Blocking or 🟡 Important — the reviewer picks based on runtime impact (production-breaking vs should-fix). |
| **Plausible** | The diff-pattern matches a catalog shape and partial tool verification supports it, but the tool evidence is indirect, ambiguous, or covers only part of the picture. Example: `ide_find_references` returns multiple call sites and one of them looks possibly-affected without conclusive proof. | 🟡 Important or 🟢 Suggestion — again the reviewer picks based on runtime impact. |
| **Suspected** | The diff-pattern matches a catalog shape but no tool call could conclusively verify the bug, because the relevant IDE query is ambiguous or the pattern is inherently local (e.g., an uncited semantic claim in a comment). | 🟢 Suggestion — emit, do not drop. The reader sees one short line they can dismiss in five seconds; missing the bug is worse. |

Below the Suspected tier is **speculation** — a pattern-shape that doesn't even match any cataloged pattern, with no tool evidence. Speculation is dropped, not emitted. The catalog's job is to draw the line between "bug class worth telling the reader about" (emit at some tier) and "noise" (drop).

**The recall-leaning shift from strict-precision to the three-tier model** is intentional: the plugin's prior behavior of dropping Suspected-tier findings entirely caused false negatives on real bugs. Emitting them at 🟢 Suggestion restores recall while keeping reader trust (🟢 is visibly low-weight).

### Positive correctness claims still require evidence

The recall-leaning tiers apply to **negative findings only** (bug reports). They do NOT relax the rule for positive correctness claims.

**Positive claims require tool-backed evidence, always.** Do not write "tests cover both paths", "the guard is correct", "no dangling references", or any similar correctness assertion unless you ran a tool call that specifically establishes it. "I read the diff and it looks fine" is not evidence; `ide_find_references` returning a specific count and `ide_diagnostics` returning zero errors on the file **are** evidence. The asymmetry matters: an uncited negative finding at 🟢 Suggestion wastes 5 seconds of reader time, but an uncited positive claim in the summary produces a false green that hides a real bug. The summary and verdict sections must stay factual (count of files reviewed, count of symbols analyzed, count of tool calls that returned clean) and must not make affirmative judgments about correctness beyond what the tool results directly support.

### Structural search emulation

When no dedicated IDE tool exists for a query, emulate structural search by combining text search for a lexical anchor with per-hit structural verification. Example: to find empty continuation bodies, text-search for `"ifPresent("`, `".then("`, `".forEach("`, then read the surrounding structure of each hit. Use `find_definition` to resolve ambiguity and `find_references` to quantify reach.

---

## The catalog

### P1 — Reachability

**Invariant.** Every symbol that exists for a runtime purpose must be reachable on a production path from a real entry point (request handler, event listener, scheduled job, CLI command, process main). References from test files do not satisfy the invariant.

**Why static tools miss it.** Compilers check that names resolve. Linters check that definitions are used *somewhere*. Neither distinguishes "used from production" from "used from tests", and neither walks the call graph backwards from a definition to determine whether any real entry point can reach it.

**Shapes to look for.**
- A continuation body (lambda, callback, `then`, `map`, `ifPresent`, `andThen`, `forEach`) is empty or stubbed while the surrounding scaffolding remains. The hook exists; it does nothing.
- A newly added method is referenced only from tests or from a registration/DI setup, never from the integration point it was built to serve.
- A required prerequisite step (install identity, acquire lease, flush buffer, commit state, emit notification, release resource) is omitted from one branch of a control-flow fork while being present in the sibling branches.
- A value is computed and assigned to a local, field, or response slot that no production path ever reads.
- A handler class is registered with a framework but the dispatcher, router, or event bus never routes to it because the routing is configured elsewhere.
- A promise made in a comment, docstring, test name, PR description, or specification cannot be located as a real effect in the diff or the surrounding code.

**IDE tools.**
- `find_references` on every added public or exported symbol. If every reference is a test, the symbol is not production-reachable.
- `call_hierarchy` upward on every changed symbol. If the hierarchy never terminates at a real entry point, the symbol is unreachable from production.
- `find_references` on a setter or write path. If the corresponding getter or read path has no production consumer, the write is ceremonial.

**Hunting checklist.**
- For every continuation, callback, or unwrap in the diff, verify the body has an observable effect.
- For every new symbol that the PR description claims a purpose for, run `find_references` and inspect each site.
- For every new handler, widget, or feature class, verify the integration point actually dispatches to it.
- For every sibling branch of a control-flow fork, compare against the branches that exist elsewhere — do they perform the same prerequisite step?

**Confirmation rule.** A reachability finding must cite the empty or test-only reference set. Do not emit a reachability claim without running `find_references` or `call_hierarchy` first.

---

### P2 — Contract propagation

**Invariant.** When a symbol's contract changes, every dependent site must adapt. A *contract* is everything callers rely on beyond the symbol's name: signature, nullability, exception set, return shape, side effects, ordering assumptions, invariants, variance.

**Why static tools miss it.** Compilers enforce syntactic contracts (types and arity). They do not enforce semantic contracts: the callee may now return null where it never did, may now throw where it never did, may now have a side effect that violates loop invariants, may now require a new precondition. Static analyzers can check one call site in isolation but cannot see the full set of call sites simultaneously.

**Shapes to look for.**
- Signature expanded with an optional or default-valued parameter. Existing callers still compile, but the behavior silently shifts because they are now implicitly passing the default.
- Return type widened (method can now return more kinds of values) or narrowed (method guarantees less). Callers that dereference, pattern-match, or branch on the return value are now wrong.
- Nullability flipped. Callers that previously relied on non-null dereference at runtime.
- **Exception contract expanded — checked AND unchecked (high-value sub-trigger, prominently called out)**: a method gains a new throwable path. Checked additions (Java `throws`, Swift `throws`) are type-system-visible; the compiler forces every caller to react. Unchecked additions (Java `RuntimeException` subclasses, TypeScript/JavaScript throws, Python exceptions, Kotlin unchecked exceptions) are invisible to the type system — the compiler stays silent while the method's implicit contract widens. Diff shapes that add an unchecked throw: unguarded unwrap (`Optional.get()`, `!`, `Stream.findFirst().get()`), unchecked cast (`(Foo) bar`, `as X`), unguarded index (`arr[i]`, `list.get(i)`), division without a denominator check, deref after a lookup that may miss (`Map.get(k).field`, `map.get(k)!`), parser on untrusted input (`Enum.valueOf`, `JSON.parse`, `Integer.parseInt`, `decodeURIComponent`), or collection mutation during iteration. For each such change, walk `call_hierarchy` upward from the changed statement and verify either a specific `catch` / `try`-`catch` / `.catch(...)` on every reaching path, or an intentional handoff to a framework default handler (Spring `@ControllerAdvice`, Express error middleware, `window.onerror`, `process.on('unhandledRejection')`). When the handoff is to a default handler, the behavior change is visible to production even though no compiler complained.
- A method that was pure or idempotent gains a side effect. Loops and retry logic that relied on the old behavior now observe the side effect multiple times.
- A method gains a new required precondition (caller must hold a lock, must be inside a transaction, must have validated input). Callers that do not satisfy the precondition silently misbehave.
- An abstraction (interface, abstract class, protocol, trait) adds a member. Every concrete implementation must adopt it.
- An abstraction removes a member. Every override of the removed member becomes dead code or a compile error in some languages and silent no-op in others.
- A parent's template-method contract changes. Subclass hook methods now run at the wrong point in the lifecycle or receive different state.
- An override weakens a precondition the parent promised to callers of the parent type. Callers using the parent type get surprises.
- **Enum-variant exhaustiveness (high-value subtype of this pattern, prominently called out)**: a discriminated type — Java `enum`, Kotlin `sealed class`, TypeScript literal-discriminant union, Rust `enum` — gains a variant. Every `switch` / `match` / `when` / `if`-chain in the codebase that branches on the type must be updated to handle the new variant. `default:` branches that throw `IllegalStateException`, `UnsupportedOperationException`, or equivalent become reachable at runtime and silently turn correctness bugs into crash bugs. `case _:` rust-style catch-alls silently swallow the new variant with the fallback behavior. Use `ide_find_references` on the discriminated type (and on each variant constant) to locate every branching site, then inspect each for exhaustiveness.
- A discriminated type loses a variant. Every branching site that still handles the removed variant has dead code that may mask bugs elsewhere.

**IDE tools.**
- `find_references` on the changed symbol to enumerate every caller.
- `find_implementations` on an interface or abstract type to enumerate every concrete implementation.
- `find_super_methods` on an override to walk upward to the parent contract.
- `type_hierarchy` on a base type to enumerate every subtype that may be affected.
- `find_references` on the declared variants of a discriminated type to reach every branching site.
- `call_hierarchy` upward from a changed statement to walk every reaching path — required when the diff adds an implicit unchecked throw (see the exception-contract sub-trigger above).

**Hunting checklist.**
- For every signature, nullability, exception-list, or behavior change in the diff, enumerate dependent sites with the appropriate tool and inspect each for compatibility.
- For every added or removed member of an abstraction, enumerate implementations and verify each.
- For every added variant of a discriminated type, enumerate branching sites and verify coverage.
- For every override change, walk upward to the parent and check the contract still holds.

**Confirmation rule.** Every contract-propagation finding must cite at least one specific dependent site (file:line) that is out of date with the new contract. "There might be callers that haven't been updated" is not a finding; "line N in file X still passes the old arity" is.

---

### P3 — Data-flow completeness

**Invariant.** Data produced at one layer must reach every consumer that depends on it, and every field a consumer reads must be populated by the producer.

**Why static tools miss it.** Types at boundaries tell you the shape of what can flow, not whether the values flowing through are complete with respect to downstream use. A DTO can be perfectly well-typed and still omit a field the consumer reads.

**Shapes to look for.**
- A custom selector, projection, builder, or serializer populates a subset of a domain object's fields. A caller reads a field outside the subset and gets null, zero, a default, or an exception at a site distant from the bug.
- A new field is added to a producer but the consumer's type declaration is not updated. The field silently crosses the boundary and is dropped.
- A consumer's type declares a field but no code path populates it. The consumer silently sees a default forever.
- A value is computed and persisted to one store, but the consumer reads from a different store that never received it.
- A result is returned from a service but the transport layer (response DTO, event payload, IPC message, serialized form) omits it.
- A lookup returns a value that depends on an input key. For some keys the lookup is not total (returns null, `None`, `undefined`, or throws) and the caller dereferences without a guard.
- A field crosses N layers correctly but the (N+1)th layer drops it.
- User input is accepted at a boundary and flows to a dangerous sink (query, command, template, HTML) without the validation or escaping the sink requires.

**IDE tools.**
- `find_references` on getters and setters of the field in question. Trace from the producer through every layer boundary to the consumer.
- `find_definition` on the consumer's type to verify the field is actually declared on the path the consumer reads from.
- `find_references` on a lookup method. Inspect each caller for an absence guard when the lookup is not total.

**Hunting checklist.**
- For every new field in the diff, trace from producer to final consumer through the entire stack. Missing link at any layer → 🔴.
- For every unguarded lookup, index access, or "find" that may not find, verify a guard exists.
- For every selector or projection touched in the diff, enumerate callers and verify every field access is covered by the selector.
- For every input arriving at a boundary that can reach a dangerous sink, verify validation/escaping is on the path.

**Confirmation rule.** Cite both endpoints — the file:line where the value is produced (or should be) and the file:line where it is consumed. A finding that cites only one end is weak.

---

### P4 — Lifecycle pairing

**Invariant.** Every acquire has a matching release on every reachable path out of the acquiring scope, and the temporal order is acquire-before-use, use-before-release.

**Why static tools miss it.** Block-structured resource management (try-with-resources, `defer`, `using`, RAII) covers the single-scope case. Pairing across function boundaries, asynchronous continuations, and state-machine transitions is not a syntactic property a linter can enforce.

**Shapes to look for.**
- A resource is acquired in one function and must be released by another. Some call paths reach the releasing function; some do not.
- A lock is taken but not released on the error path.
- A subscription, listener, or observer is registered but never deregistered when the owner is destroyed. The subscription leaks memory and runs after its context is gone.
- A trace span, metric timer, or logging context is started but not ended on every branch.
- A reference count is incremented but not decremented symmetrically.
- A transaction or session is begun but not committed or rolled back on a rare code path.
- A buffered write is enqueued but not flushed on some exit path.
- A state-machine "begin" step has no corresponding "end" step for one terminal state.

**IDE tools.**
- `find_references` on the acquire method. For each caller, verify a matching release on every path out of the scope.
- `find_references` on the release method. For each caller, verify it pairs with an acquire in the same logical unit.
- `call_hierarchy` downward from the acquire to enumerate all reachable paths that must contain the release.

**Hunting checklist.**
- Search the diff for acquire/release verb pairs: `open`/`close`, `begin`/`end`, `start`/`stop`, `acquire`/`release`, `lock`/`unlock`, `subscribe`/`unsubscribe`, `claim`/`release`, `enter`/`leave`.
- For every acquire in the diff, enumerate every exit path from its scope (normal return, early return, exception, async-cancellation, timeout) and verify the release is reachable on each.
- Error paths and early returns are the usual failure points. Exception paths in async code are particularly prone.

**Confirmation rule.** Cite the acquire site and every unpaired exit path (or the missing release site).

---

### P5 — Path parity

**Invariant.** When a behavior is added to one path, all logically equivalent alternative paths must gain the equivalent behavior. Alternative paths include error handling, retry, compensation, fallback, migration, re-entry, replay, restart, and siblings of a logically equivalent operation (different auth methods, different tenants, different channels, different commands).

**Why static tools miss it.** "These two paths should be kept in sync" is a design claim about intended symmetry, not a syntactic property of the code. Nothing in the type system tells a linter that handler A is a mirror of handler B.

**Shapes to look for.**
- A guard is added to one entry point but not to a sibling entry point that handles the same resource through a different authentication method or channel.
- A compensating or rollback operation updates state but omits a user-visible signal (notification, log, metric, event) that the forward operation emits.
- A migration adds a constraint without a dedupe step that a parallel rebuild script handles.
- A fallback path skips a validation the primary path performs.
- A state-machine guard covers some states (completed, in-progress) but not others (failed, abandoned). Re-entry from uncovered states is unguarded.
- A retry path re-runs an operation without re-checking the idempotency guard, producing duplicates.
- The error response envelope is missing a field the success response just gained.
- A new field is added to one operation's audit log entry but not to the parallel operation's log.
- A restart-recovery path does not reclaim state left by an interrupted in-flight operation. Sentinel state becomes zombie state.
- An alternate authentication method is updated with a mitigation (session fixation, CSRF, rate limit) while the other methods are not.

**IDE tools.**
- `find_references` on the updated method to discover alternative paths that wrap, mirror, or share an ancestor with it.
- `find_implementations` on a common abstraction when multiple paths implement the same interface — compare bodies directly.
- `find_references` on discriminated-type variants to verify every handling site covers every variant.
- `type_hierarchy` to find sibling types that may require symmetric updates.

**Hunting checklist.**
- For every new guard, new step, or new effect added to a public entry point, enumerate the parallel entry points and check for the same addition.
- For every added state variant, verify every branching site covers it with the correct behavior, not just a default.
- For every compensating or cleanup method, compare its body against the forward operation.
- For every new field on a success envelope, check the error envelope.
- For every new mitigation added to one auth or access path, check the other paths.

**Confirmation rule.** Cite both the updated path and the non-updated parallel path as file:line pairs. Name the observable difference between them.

---

### P6 — Concurrent reachability

**Invariant.** When two code paths can execute concurrently and both touch overlapping state, ordering and visibility must be explicit and correct under the storage and memory model in use.

**Why static tools miss it.** Concurrency correctness requires enumerating the full set of writers and readers of shared state, which is a project-wide property. Local analysis sees at most one actor at a time and cannot reason about interleavings.

**Shapes to look for.**
- A single-use resource (token, slot, seat, lease, reservation, idempotency key) can be consumed twice because the read-check-write sequence is not atomic and the underlying storage does not linearize the contention window.
- A conditional update returns a rows-affected or compare-and-swap result that the caller must check to detect lost updates. The caller ignores the return value.
- A listener, hook, or observer is fired inside a transactional or locked context and reads state the context has not yet committed or released.
- An async continuation reads captured state that was mutated between the capture and the continuation's execution.
- A cache is read before the writer commits, serving stale data as fresh.
- A fast-path user action completes before a background enqueue runs. The background path sees uncommitted fast-path state and cannot reconcile.
- A scheduler reads a flag set by a user request through an older snapshot than the write.
- Two workers both claim ownership of a resource because check-then-update is non-atomic and the workers operate on different storage partitions.
- A state machine's "holding" branch releases state before the "claiming" branch has acknowledged the release.

**IDE tools.**
- `find_references` on the shared state (field, row key, cache key, file) to enumerate every writer and every reader.
- `call_hierarchy` on each writer and reader to identify the entry point that activates it — a user request, a scheduler, a background job, a webhook, an event listener.

**Hunting checklist.**
- For every operation described as "single-use", "once", "exactly-one", "unique", or "idempotent", inspect the read→write sequence for atomicity. Is the write conditional on the read? Does the caller verify the condition held at write time?
- For every event or message published inside a transactional context, verify the listener does not require committed state, or that listener delivery is deferred until after commit.
- For every asynchronous continuation that reads captured mutable state, verify ordering with the writer.
- For every background operation that reads state a user action just set, verify the visibility guarantees — transaction isolation level, memory ordering, cache coherence.

**Confirmation rule.** Describe the interleaving — two actors, the ordering they can observe, and the state they see. A concurrency finding that only cites "missing synchronization" without naming the race is weak.

---

### P7 — Ordering invariants

**Invariant.** When operation X must happen before operation Y, the call graph must guarantee X dominates Y on every path from the relevant entry points.

**Why static tools miss it.** Temporal ordering between operations in different files is a global reachability property. Local analysis can see that both operations exist but not whether their call graphs are ordered correctly.

**Shapes to look for.**
- A handler is registered after the events it must handle have already been fired (a startup race with message ingestion).
- Configuration is read before it is populated by its loader.
- A cache is queried before any writer has run.
- An authorization check is placed after the resource access it is supposed to gate.
- A data migration depends on a column that is added in a later migration.
- A feature-flag read occurs before the flag provider finishes initialization.
- A destructor or finalizer assumes the constructor finished, but the constructor bailed partway.
- A logging or tracing setup runs after the first error path can fire.
- A lifecycle hook (on-mount, on-create, on-ready) runs after a dependent operation has already started.
- A warmup step is expected but not reachable from the code path that first triggers the expensive operation.

**IDE tools.**
- `call_hierarchy` upward from the "must run after" operation. Verify every path passes through the "must run before" operation.
- `find_references` on the ordering-critical symbol in both directions — who sets it, who reads it.

**Hunting checklist.**
- For every operation whose name, comment, or convention implies a precondition, locate the enforcement and verify it holds on every reachable path.
- For every explicit initialization step, enumerate readers and verify they are unreachable before initialization completes.
- For every pair of operations with a known ordering (init then use, auth then access, validate then commit, warm then query), confirm the ordering holds structurally, not just in the author's mental model.

**Confirmation rule.** Cite the required-before operation, the required-after operation, and name a specific reachable path on which the ordering can be violated.

---

### P8 — External-reality anchoring

**Invariant.** When code mirrors an external system — an API response shape, protocol codes, enum mappings, lookup tables, wire formats — the mirror must be anchored to the external source of truth, not merely self-consistent.

**Why static tools miss it.** Code can be perfectly self-consistent and still disagree with reality. A lookup table `{1: A, 2: B}` is well-formed regardless of what the external system means by `1` and `2`. Unit tests that round-trip through the same mapping pass happily in both directions.

**Shapes to look for.**
- Lookup tables translating external codes to internal types, inverted.
- Enums that mirror an external enum but are missing a recently added variant. External input falls through to a default branch.
- Parsers that assume a field is a scalar when the external system may return an object or array.
- Unit mismatches (metric vs imperial, cents vs dollars, seconds vs milliseconds, radians vs degrees).
- Time-zone mismatches (UTC vs local, naive vs aware, instant vs wall-clock).
- Precision or scale mismatches (floating point vs decimal, 32-bit vs 64-bit).
- Protocol version mismatches encoded in a constant.
- Unknown-enum-variant handling that defaults to the wrong branch.
- Date format strings that assume a locale the external system does not use.
- Documentation (Javadoc, markdown spec, OpenAPI comment) promising behavior the code does not implement — "doc drift" is an external-contract mismatch where the documentation is the external system.

**IDE tools.**
- `find_references` on the mapping, parser, or constant. The tool does not verify correctness, but it quantifies the blast radius if the mapping is wrong — every caller is affected.
- `find_references` on the external-facing type to see which callers depend on it.

**Hunting checklist.**
- When the diff adds or modifies a constant table translating external codes, flag it as "needs external verification" unless the PR description cites external documentation or a real captured sample.
- When a parser is added or modified for a third-party format, verify at least one test exercises a real response recorded from the external system, not only a hand-crafted example.
- When the diff introduces a new unit, currency, precision, or time representation at an external boundary, verify both sides of the boundary agree.
- When the diff changes behavior in a function whose Javadoc/spec/README cites specific semantics, verify the documentation is updated in lockstep.

**Confirmation rule.** External-reality findings are usually 🟡 Important unless the wrongness is self-evident. The reviewer cannot always verify the external contract independently; framing the finding as "needs human verification against the cited source" is better than asserting a specific error.

---

### P9 — Authorization reachability and trust-boundary integrity

**Invariant.** Every sensitive operation must be preceded by an authorization check on every reachable path that leads to it. Every trust-boundary crossing — untrusted input reaching a privileged sink (query, shell, template, file path, deserialization, reflection, log, response) — must be guarded by explicit validation or escaping. Every new public surface must default to safe.

**Why static tools miss it.** Local analyzers can flag individual sink-shaped calls, but cannot verify that an authorization check dominates every reaching path to a sink. They cannot see that a filter registered with a specific `@Order` runs before the security context is populated. They cannot see that a new endpoint inherited a permissive default from a parent configuration that was intended for another purpose. These are global call-graph and configuration properties.

**Shapes to look for.**
- A sensitive operation (DB write, external API call, file write, response with sensitive content, log with sensitive content) is added without an authorization check — or with a check that is bypassed on at least one reaching path.
- A new public endpoint, route, or handler defaults to `permitAll` / `anonymous` / unauthenticated while its siblings require authentication.
- A filter, interceptor, or middleware is registered at an order that places it before the framework's security filter — the custom filter sees an anonymous principal even when the user is actually authenticated.
- Session-fixation mitigation (new session id, cookie refresh, token rotation) is on one authentication path but not on an alternate authentication path (OAuth, magic link, SSO, account switch).
- A distinguishable error (user-not-found vs wrong-password, valid-email vs invalid-email) leaks enumeration in a context where the sibling path returns a generic error.
- User-controllable input reaches a query, shell, template, deserializer, reflection sink, file path, or logging sink without explicit sanitization on the specific path.
- Configuration surfaces that default to permissive in dev mode or behind a profile bleed into production (hardcoded admin passwords, `PermissiveCORS`, debug endpoints, `/actuator/**` exposed).
- A secret (token, API key, password, cookie value) flows from its source to a log, response, or serialized store on one branch while being redacted on sibling branches.
- A new endpoint receives an identifier (user id, resource id) in the request and trusts it without verifying ownership against the authenticated principal (IDOR).

**IDE tools.**
- `call_hierarchy` upward from every sensitive sink — verify every reaching path passes through the authorization check.
- `find_references` on authorization primitives (`@PreAuthorize`, `@Secured`, `AuthorizationManager.check`, request authentication getters) to see which sinks have the check in their reaching set.
- `find_references` on filter / interceptor classes; inspect `@Order` or registration mechanism against the framework's security filter order.
- `find_references` on secret constants and environment variables to see which layers read them and whether any layer persists, serializes, or logs them.
- `find_implementations` on authorization check interfaces to verify every concrete checker covers the new access path.

**Hunting checklist.**
- For every new public-surface symbol (endpoint, route, handler, resolver, listener), verify explicit authentication/authorization exists on its reaching path, or that an inherited default is demonstrably safe.
- For every new filter / interceptor / middleware, verify its order is after the framework's security filter chain.
- For every new error response in an authentication-related path, check it returns a generic message that does not leak principal existence or type.
- For every new log statement or response field, check whether it echoes user-controllable input that could contain PII, tokens, or cross-tenant identifiers.
- For every new `permitAll` / `anonymous` configuration change, verify the surface it exposes is intentional.
- For every identifier received from a client and used as a lookup key, verify an ownership check against the authenticated principal.

**Confirmation rule.** A P9 finding must identify either (a) a specific sink reachable without the check, (b) a specific default that exposes a surface, (c) a specific path where the check runs too early or too late, or (d) a specific sink that receives unescaped user input. "The auth story is loose" is not a finding.

---

### P10 — Observability integrity

**Invariant.** Error signals must preserve cause chains and specific context until they reach a handler that can act on them. Logs and metrics must be bounded in cardinality and must not sink sensitive data. Silent swallows (empty catches, generic fallthrough handlers, `.catch(() => {})`, log-and-return in async callbacks) are bugs because they blind operators to the exact events they need to see in order to debug production.

**Why static tools miss it.** Static analyzers can flag empty catches as a warning, but cannot reason about whether a specific exception's cause chain is load-bearing for a specific upstream caller, or whether a specific log cardinality is bounded, or whether a specific field is PII. These are project-wide, domain-specific judgments that require understanding the full path of an error signal from origin to handler, and the full set of call sites of a log or metric sink.

**Shapes to look for.**
- `catch (Exception e)` that rethrows a wrapper without passing `e` as the cause — original stack trace is lost.
- `catch (SpecificException e)` that reads `e.getMessage()` but discards `e.getStatusCode()`, `e.getRequestId()`, `e.getHeaders()`, or other actionable context before rethrowing.
- Empty `.catch(() => {})` on a user-facing async operation — the user sees nothing, the server sees nothing, the UI stays in a broken state forever.
- A generic exception handler (`@ExceptionHandler(IllegalStateException.class)` or an overly broad status-mapping filter) mapping multiple distinct exception types to the same response code and same opaque message. Specific failures become indistinguishable from each other and from unrelated bugs.
- A log statement at INFO or higher whose cardinality is bounded by a user-controllable input (log-the-unknown-value pattern) — produces log spam and can be used as a resource exhaustion vector.
- A log statement, metric label, or response field that echoes user PII, email addresses, coordinates, free-form preferences, tokens, or cross-tenant identifiers. Compliance violation on the log path.
- A metric or log field emitted on one path but not on a parallel path — dashboards and traces lie about which code produced which event.
- Structured logging that drops key correlation fields (trace id, user id, request id) on one branch while including them on siblings.
- An async callback that logs an error and returns silently when the caller expected either a thrown exception or a user-visible signal.
- Rate-limited or sampled logging configured in a way that silently drops the specific events operators need for debugging a particular failure mode.
- `InterruptedException` caught without restoring the interrupt flag — upstream cancellation semantics are lost.

**IDE tools.**
- `find_references` on exception types to enumerate every handler; inspect each for cause preservation and context passthrough.
- `find_references` on logging sinks (`log.info`, `log.warn`, `log.error`, telemetry emitters) to inspect payloads for user-controllable cardinality and PII.
- `find_references` on metric emission methods; verify parity across parallel paths by comparing call sites between the happy and alternate paths.
- `call_hierarchy` upward from a catch block to see what the caller expected the exception to convey.
- `find_references` on `InterruptedException` to check that every handler restores the interrupt.

**Hunting checklist.**
- For every new `catch` block, verify the cause chain propagates if the exception carries actionable information beyond its type.
- For every new `.catch(() => {})`, empty catch, or silent async handler, verify the operation's failure surface reaches either an upstream caller or a user-visible UI state.
- For every new log statement that interpolates a non-constant value, verify the value's cardinality is bounded — enum, fixed dictionary, or explicitly limited.
- For every new log statement or response, verify it carries no PII, secrets, or cross-tenant identifiers.
- For every new metric or log field, compare against sibling paths to verify consistent emission.
- For every new exception handler, verify distinct exception types map to distinguishable responses where distinction is actionable.

**Confirmation rule.** A P10 finding must identify the specific information that is lost (cause, status code, request id, correlation id, parallel-path metric) or the specific data being sunk into an inappropriate channel. "Error handling feels sloppy" is not a finding.

---

### P11 — Test efficacy

**Invariant.** Every test must actually exercise the code path it claims to cover. A test that bypasses production wiring misses wiring bugs. A mock whose stub set is incomplete passes today and breaks tomorrow when the SUT calls a new method. A test whose assertion targets the stub rather than the contract proves nothing. A unit test that hits the network is not a unit test. An integration test that asserts on pure-Java structures wastes the boot cost.

**Why static tools miss it.** Static analyzers cannot reason about whether a test's setup matches the production wiring, whether a mock's stub set covers the SUT's full call graph, whether a test assertion actually observes the behavior the test name promises, or whether a test's isolation boundary is coherent. These are project-wide relationships between test code and production code that require semantic call-graph reasoning.

**Shapes to look for.**
- A test that directly constructs the SUT, bypassing the dependency-injection or module-loading mechanism that wires it in production. Wiring bugs (auto-configuration precedence, conditional registration, profile/environment activation, decorator chain order) are invisible to the test.
- A test that reaches into package-private or non-public internals of a third-party library to observe state — brittle across library upgrades and makes the test a false guarantor.
- A test that mocks a collaborator but omits a stub for a newly-added method the SUT now calls. The mock default returns a zero-value, and the SUT either fails at the default's deref or silently accepts a nonsense value and reports "pass".
- A test whose name makes a specific behavioral claim but whose assertions verify only unrelated structural properties (a test named for "quality check" that only asserts non-null output).
- A unit test that performs real network, filesystem, or clock I/O. Hermeticity is broken; the test becomes flaky when external dependencies are slow or down, and passes for reasons unrelated to the code.
- A test that relies on ordering the test framework does not guarantee — insertion order of a hash-based collection, registration order of plugins/beans, reflective method order.
- A test-framework lifecycle hook silently ignored because the test is in the wrong lifecycle binding (instance vs static, sync vs async, declarative vs programmatic). The setup never runs, but the test still claims to cover the setup-dependent behavior.
- A test injecting a deterministic collaborator (clock, random source, id generator) that the SUT then ignores by calling a static default. The test is non-deterministic and the injection is ceremonial. (Also a P1 finding; the test-efficacy angle is that the test's own setup implies a contract the SUT silently breaks.)
- A test class that extends a heavyweight integration base (booting a full application context, containers, or fixtures) but asserts only on in-process structures — pays the boot cost without exercising any integration.
- A test helper that silently catches assertion failures and continues, producing false green.
- A test whose production coverage is zero because the SUT path it exercises is not reachable from any production entry point — covers ceremony, not behavior.
- A test-only flag, accessor, or side channel that leaks into production code; the test observes an artifact the real code would never produce.
- A test that mutates shared module-level or global state without resetting it, leaking state into subsequent tests.

**IDE tools.**
- `call_hierarchy` downward from the test method — what production code does it actually reach? If the reach is shallow or obviously stubbed, the test's claim is suspect.
- `find_references` on mocked collaborator methods — enumerate every method the SUT calls on the collaborator type (use `call_hierarchy` on the SUT), then check the mock's stub set covers them.
- `find_definition` on annotations (`@MockBean`, `@Mock`, `@Spy`, `@TestConfiguration`) to verify the test's isolation model is coherent with production's wiring.
- `find_references` on a `Clock`, `Random`, or id-generator bean to verify tests inject test doubles and the SUT honors them.
- `find_references` on test-only flags or test-only accessors to verify they do not leak into production call sites.

**Hunting checklist.**
- For every new test that exercises framework wiring (security filter chain, advisor chain, MVC pipeline, event listener, scheduled jobs), verify it boots the real configuration rather than hand-constructing one.
- For every mock setup in a test that was modified alongside SUT changes, verify the stub set covers the SUT's current call graph on that collaborator.
- For every test name that makes a specific behavioral claim, read the assertions and verify they actually observe that specific behavior.
- For every test that constructs time-sensitive, random, or id-generating behavior, verify the test double is honored by the SUT body.
- For every test under a fast / unit tag, verify no network, filesystem, or time-dependent I/O occurs.
- For every integration test base class, verify its extensions assert on integration-level properties, not pure-Java structures that don't need the boot cost.
- For every test helper that catches exceptions, verify assertion errors propagate.

**Confirmation rule.** A P11 finding must identify either (a) the real wiring the test bypasses, (b) the specific SUT-called method the mock doesn't stub, (c) the specific behavior the assertion fails to observe, or (d) the specific test-environment property (network, clock, bean order) the test depends on that should be controlled.

---

### P12 — Return-value discipline

**Invariant.** Every non-void method whose return value carries outcome, error, result, or state information must be used by every caller. Discarding such a return value is a silent loss of the information the method exists to communicate. A local variable assigned from such a method and never subsequently read is the same bug in a different syntactic dress.

**Why static tools miss it.** Static analyzers classify return types syntactically — `@CheckReturnValue`, `@WarnUnusedResult`, and similar annotations cover a tiny fraction of outcome-carrying methods, and most annotations are opt-in rather than opt-out. A method returning `int` (rows-affected), `boolean` (was-removed), `Optional<T>` (empty-on-absent), `Promise<T>`, `CompletableFuture<T>`, or a library `Result<T, E>` / `Try<T>` / `Either<L, R>` type carries outcome information that no local analyzer can recognize without project-wide knowledge of what each method is for.

**Shapes to look for.**
- A method returning an outcome-wrapper type (`Optional<T>`, `Result<T, E>`, `Try<T>`, `Either<L, R>`, `Promise<T>`, `CompletableFuture<T>`) is called as a statement with no assignment, no `.ifPresent`/`.await`/`.map` continuation, no pattern match, no inspection.
- A conditional-update method (e.g., `markConsumed`, `claimSlot`, `acquireToken`) returns a rows-affected `int` or a boolean "was-unique" flag. The caller invokes it as a statement and never inspects the count — double-consume races become invisible.
- An immutable-arithmetic method (`BigDecimal.add`, `String.replace`, `List.plus` in Kotlin, `Array.prototype.concat`) returns a new instance and the caller discards it, expecting an in-place side effect that doesn't exist.
- A method whose only purpose is to report success/failure (`list.remove(Object)`, `Set.add(E)`, `Map.remove(K)`) is called as a statement without inspecting the boolean return, where the boolean is the only way to know if the operation succeeded.
- An immutable-builder `.withX(y)` chain whose intermediate or final result is discarded. The caller uses the old builder reference (lost update) or throws away the built object.
- A local variable `var result = foo();` (or `const result = foo();`) is assigned and never read on any reachable path out of its scope. The assignment is ceremonial.
- A fire-and-forget `Promise<T>` / `CompletableFuture<T>` with no `.catch`/`.exceptionally`/`.whenComplete` — the caller loses both the result and any exception signal.

**IDE tools.**
- `ide_find_references` on every non-void method in the diff to enumerate every call site.
- `ide_find_definition` on the method to resolve the declared return type and determine whether it carries outcome information (outcome-wrapper types are a fixed, recognizable set).
- `ide_call_hierarchy` upward from the discarded call site to understand what the caller expected.

**Hunting checklist.**
- For every non-void method in the diff, run `ide_find_references` and inspect every caller's use of the return value. Flag statement-level discards where the return carries outcome information.
- For every newly-declared local variable in the diff, check whether it is read on any subsequent reachable path in its scope. Unread locals are flagged (this overlaps P1 reachability but is a specific sub-shape worth naming).
- When the return type looks outcome-carrying but the caller's discard is idiomatic (mutable-builder `this` chain, void-returning-alias for readability), downgrade to 🟢 Suggestion rather than silence.

**Confirmation rule.** A P12 finding must cite the exact discarded call site (file:line from `ide_find_references`) and must show that the return type carries outcome information — either by citing the method's return-type declaration from `ide_find_definition`, or by matching a well-known outcome-wrapper type name. When the outcome-carrying nature is partial or ambiguous (e.g., the method sometimes is called for side effects and sometimes for its return), emit at 🟢 Suggestion per the recall-leaning tiers.

---

### P13 — Framework-contract consistency

**Invariant.** Framework annotations carry implicit runtime contracts that the compiler does not enforce. Every annotation usage in the diff must satisfy its framework's contract at the semantic level — the right return type, the right method visibility, the right parameter shape, the right configuration key, the right test-lifecycle binding. Violating a framework contract produces code that compiles and often runs but silently misbehaves at runtime.

**Why static tools miss it.** Framework contracts live outside the language's type system. The compiler sees `@Async User getUser(Long id)` as a legal Java method declaration. It does not know that Spring's Async proxy infrastructure requires `void`, `Future<T>`, or `CompletableFuture<T>` as the return type; any other return type means the caller receives a placeholder, not the real result. Every framework has dozens of such semantic contracts and no static analyzer implements them all.

**Shapes to look for.**
- A framework annotation that requires a specific return type is applied to a method with a non-matching return type (e.g., `@Async` returning a concrete domain object instead of `CompletableFuture<T>`).
- A framework annotation that enforces a scheduling, caching, or rate-limiting contract is applied to a method whose body contains calls that violate the contract (e.g., `@Scheduled(fixedRate=1000)` body with a blocking call that likely exceeds 1000ms).
- A framework annotation is applied to a method whose parameter types are incompatible with the framework's expectations (e.g., `@Cacheable` on a method whose cache key is a mutable object without `equals`/`hashCode`).
- A framework configuration annotation references a property key that does not appear in any loaded configuration source — the annotation is inert.
- A validation annotation is applied to a parameter whose type declares zero validation annotations, or a validation annotation is applied to a primitive where a richer validation annotation would be correct.
- A test-framework lifecycle annotation is applied on a method that sits in the wrong lifecycle binding (e.g., non-static `@BeforeAll` in a JUnit 5 class without `@TestInstance(PER_CLASS)`), and the framework silently ignores the method.
- A framework-annotated method is called via self-invocation inside the same class, bypassing the framework's proxy-based interception (already covered by P6 for `@Transactional`; the pattern generalizes to any proxy-mediated annotation).

**IDE tools.**
- `ide_find_references` on each annotation type to locate every site that uses it in the diff.
- `ide_find_definition` on the annotated method or field to inspect the signature, return type, and body.
- `ide_search_text` on configuration files to verify property keys referenced by `@ConditionalOnProperty`, `@Value`, and similar annotations. The Phase 3-config sub-step of the main command collects configKeys for this purpose.
- `ide_call_hierarchy` on proxy-mediated methods (`@Transactional`, `@Async`, `@Cacheable`) to detect self-invocation.

**Hunting checklist.**
- For every framework annotation in the diff, verify the annotated member's signature matches the annotation's documented contract.
- For every configuration-key-referencing annotation (`@ConditionalOnProperty`, `@Value("${...}")`, feature-flag lookups), cross-reference the key against the Project Configuration Snapshot's `configKeys` set. A dangling reference is a 🟡 Important finding.
- For every test-framework annotation, check the test class's lifecycle binding, member visibility, and parent-class requirements.
- For every proxy-mediated method annotation, run `ide_call_hierarchy` and check for self-invocation among callers.

**Confirmation rule.** A P13 finding must cite the annotation site and the specific contract violation (return type, property key, lifecycle binding, etc.). When the contract is partially violated or the framework's documented behavior is ambiguous for the exact usage, downgrade to 🟡 Important or 🟢 Suggestion per the tier rules.

---

### P14 — Symmetry integrity

**Invariant.** When a class gains a field that participates in the class's identity or its construction surface, every parallel method in the class that must co-reference the field does so. The paired methods stay in sync; adding a field without updating its paired methods is a silent correctness break.

**Why static tools miss it.** The parallel-method pairing (equals ↔ hashCode, field ↔ builder-setter, field ↔ copy-constructor parameter) is a semantic convention, not a type-system rule. The compiler allows adding a field and updating `equals` without touching `hashCode`. The resulting class has a silently broken `equals`/`hashCode` contract: two objects that are `equals()` can return different `hashCode()` values, corrupting `HashMap` and `HashSet` lookups at scale, with symptoms that surface far from the cause.

**Shapes to look for.**
- A class with existing `equals` and `hashCode` overrides gains a field. The field is referenced in `equals` but not in `hashCode` (or vice versa). The `equals`/`hashCode` contract is silently broken.
- A class with existing overrides gains a field, and neither `equals` nor `hashCode` is updated. The class's identity semantics exclude the new field — this may be intentional but is worth a 🟡 Important flag asking the developer to confirm.
- A class has an inner `Builder` class with `withX`-style setters for every existing field. The class gains a new field, but the builder has no corresponding setter. Callers cannot set the new field at construction time.
- A class has a copy constructor `Foo(Foo other)` that copies each field. The class gains a new field but the copy constructor does not copy it. Cloning produces incomplete objects.
- A class has a factory method (`of`, `from`, `copyOf`, `create`) that accepts parameters matching the class's fields. The class gains a new field but the factory method does not accept it. Factory-created instances are incomplete.
- A class's `toString` enumerates every field. The class gains a new field but `toString` is not updated — low-severity but worth a 🟢 Suggestion flag.

**IDE tools.**
- `ide_find_definition` on the class to inspect every method body in the class.
- `ide_find_references` on the new field to locate every method that already references it (to identify the ones that *should* reference it but don't).

**Hunting checklist.**
- For every added or renamed field on a class in the diff, check whether the class has `equals` / `hashCode` overrides. If yes, read both method bodies and verify the field appears in both (or is intentionally excluded from both).
- For every such class, check for an inner `Builder` / `BuilderImpl` class and verify it has a setter for the new field.
- For every such class, check for a copy constructor, a factory method, and `toString`; verify the new field appears in each.
- **Out of scope for this round**: Jackson, Gson, and other JSON-serialization symmetry. This is a known gap — the detector focuses on `equals`/`hashCode`/builder/copy-constructor/factory symmetry only. A future round may extend the detector to serializer symmetry.

**Confirmation rule.** A P14 finding must name both the changed member and the parallel member that is out of sync (e.g., *"field `status` added; referenced in `equals` at line 45 but not in `hashCode` at line 52"*). Severity maps as: both overrides exist and asymmetric → 🔴 Blocking (contract violation); both overrides exist and field excluded from both → 🟡 Important (intentional? confirm); no overrides exist and the class looks data-only → 🟢 Suggestion; builder/copy-constructor/factory gap → 🟡 Important.

---

### P15 — Planned-work reconciliation

**Invariant.** When a diff touches code that is referenced in the project's planning artifacts as scheduled for removal, rewrite, or replacement, the diff must either acknowledge the planned work (by completing it, updating the plan, or citing the plan in the commit message) or be flagged as a possible conflict with the team's own intentions.

**Why static tools miss it.** Planning markers live in prose documents (TODO comments, markdown task lists, spec checkboxes) that static analyzers do not parse. Even if they did, matching planning-doc symbol references against diff changes requires reading natural language and relating it to the code's symbol graph — a task outside the scope of any lint-style tool.

**Shapes to look for.**
- A `TODO:` / `FIXME:` / `HACK:` / `DEPRECATED` marker in a source file says "remove this when X is done" or "rewrite this to use Y". The diff modifies the marked code in a way that prolongs its life rather than removing it.
- A project planning document (`docs/planning.md`, `specs/<feature>/tasks.md`, or similar) contains an unchecked task checkbox (`- [ ]`) that references a specific symbol or file. The diff modifies that symbol or file without completing the task.
- A commit message or PR description says "fixes T123" while the planning document says task T123 is "pending dependency on T120" — the diff is claiming to fix work that was gated on other work.
- A planning doc says "these files should be reviewed together for consistency" and the diff touches only one of them.
- A caller of a method marked `// TODO: remove this method when T025 ships` is itself being modified — the caller extends the lifetime of the TODO-marked method.

**IDE tools.**
- `ide_search_text` for the marker patterns (`TODO:`, `FIXME:`, `XXX:`, `HACK:`, `DEPRECATED`, `T\d+`, `FR-\d+`, `- [ ]`, `- [x]`) scoped to changed files (Scope A) and planning doc directories (Scope B: `docs/**/*.md`, `specs/**/*.md`). The Phase 3-planning sub-step of the main command collects these markers as `planningMarkers`.
- `ide_find_references` on the symbols named in the marker bodies to cross-reference against the diff's changed symbols.
- `ide_find_file` to locate the planning doc directories.

**Hunting checklist.**
- Iterate the `planningMarkers` list (active-status only) from the Phase 3-planning output. For each marker, check whether its `referencedSymbols` or `sourceFile` overlap with the diff's changed surface.
- For every overlap, compose a finding that cites both the code change (file:line from the diff) and the planning marker (file:line from the marker).
- Skip markers classified as `resolved` (checked tasks, body containing "done"/"fixed") or `stale` (file last-modified > 90 days ago) — the Phase 3-planning sub-step already filters these out, but re-verify for defense in depth.
- A planning doc referencing a symbol that the diff *removes* is also a P15 finding (a 🟢 Suggestion because removing a TODO-marked symbol is often the intended completion of the planned work, but worth surfacing so the task can be checked off).

**Confirmation rule.** A P15 finding must cite both ends: the code-side file:line where the marked or planning-referenced change lives, and the plan-side file:line where the marker or task appears. A finding that cites only one end is weak; prefer to drop it.

---

### P16 — Team-convention and custom-rule reachability

**Invariant.** Teams have repo-local conventions that the cataloged patterns (P1–P15) do not cover — rules like "never use `@Transactional` on controllers", "DTOs must be immutable records", "no `var` in service classes", "all integration tests must use `Testcontainers`, not Docker directly". These rules are documented in a repo-local `.code-review-rules.md` file at the project root. The plugin reads the rules file during Phase 3-convention and applies its rules alongside the cataloged patterns, emitting findings tagged `[CUSTOM]` (not `[P<n>]`) with a `**Rule source:**` citation pointing at the rules-file line.

**Why static tools miss it.** No static analyzer supports a free-form natural-language rules file. The closest analogue — custom rules written in a DSL (semgrep, ast-grep) — requires the rule author to learn the DSL and write a syntactic pattern, which is a much higher barrier than writing a prose description of what the team wants. The plugin's approach is to pass the natural-language rules to a language-specialist LLM agent and let the LLM evaluate the rule against the diff's code. This works at no additional engineering cost for the team.

**Shapes to look for.**
- The `conventionRules` list from the Phase 3-convention sub-step is non-empty. Each rule has a `ruleText` (verbatim prose from `.code-review-rules.md`), a `sourceLine` (its line in the file), and an optional `scope` path pattern.
- The diff contains code that matches the pattern described in a rule's `ruleText`. Example: rule says *"In `src/controllers/**`, `@Transactional` is forbidden"*; the diff adds `@Transactional` to `src/controllers/UserController.java`.
- The diff contains code that a rule says should exist. Example: rule says *"Every service method must have SLF4J log statements at INFO or higher"*; the diff adds a service method with no logging.
- A rule's scope clause (`in`, `under`, `within`) matches files touched by the diff.

**IDE tools.**
- `Read` on `.code-review-rules.md` (performed once by the Phase 3-convention sub-step; the content is passed to specialist agent prompts as context).
- `ide_find_references` / `ide_find_definition` on code symbols that a rule mentions, so the specialist can locate canonical examples or similar patterns for the `See also:` field.

**Hunting checklist.**
- For each rule in `conventionRules`, parse the rule's scope (if present) and filter the diff's changed files accordingly.
- For each in-scope file, evaluate the rule against the diff hunks. Use LLM judgment; no parser is introduced.
- When a violation is found, compose a `[CUSTOM]`-tagged finding with a `**Rule source:**` line citing `.code-review-rules.md:<sourceLine>`.
- When the rule has a canonical counter-example already located in the codebase (via `ide_find_references` on a symbol mentioned in the rule, or via `ide_find_class` on a class the rule cites), populate the finding's `**See also:**` field with that canonical example.
- Rules that are too vague to apply deterministically (e.g., "write clean code") are ignored — emit no finding rather than a noisy one.
- Rules that conflict with a cataloged pattern finding (e.g., team rule says *"catch broad exceptions is fine for legacy code"* but P10 flags the catch) produce both findings, and the developer resolves the conflict.

**Confirmation rule.** A `[CUSTOM]` finding must identify the specific violation site (file:line) and must cite the rule source (`.code-review-rules.md:<line>`). Without the rule-source citation, the finding is indistinguishable from a cataloged pattern finding and must be tagged with the pattern number instead. Severity is the specialist's judgment based on the rule's wording (rules phrased as "must never" → 🔴 or 🟡, rules phrased as "prefer" or "avoid when possible" → 🟢).

---

## What NOT to flag

These categories are handled by static analyzers, compilers, linters, and formatters. They are not the work of this plugin. Do not spend findings on them unless they are the proximate cause of a bug already being flagged under a cataloged pattern.

- Unused imports, unused locals, unused parameters.
- Missing immutability modifiers (`final`, `const`, `readonly`).
- Raw generics, missing type annotations, missing return types.
- Line length, brace style, indentation, formatting, naming conventions.
- Equality-operator choice on primitives or strings.
- Method length, class length, cyclomatic complexity.
- Missing override annotations.
- Style-only preferences that do not change runtime behavior.
- Deprecated API calls whose replacements are behaviorally equivalent.
- Any diagnostic the IDE itself already reports at the same severity.

A finding in these categories is noise. Noise trains the reader to dismiss the entire report, costing more than it saves.

---

## Inspector findings (third source class)

Findings from the JetBrains command-line code inspector are admitted as a **third finding source**, parallel to the cataloged P1–P16 patterns and `[CUSTOM]` rules from `.code-review-rules.md`. The inspector's full inspection profile catches bug classes the catalog does not encode (and is not designed to encode) — deprecation, redundant code, framework-specific anti-patterns, control-flow inspections, and so on.

Inspector-sourced findings carry the tag `[INSPECTOR:<inspection-short-name>]`, where `<inspection-short-name>` is the JetBrains inspection identifier (e.g., `NullableProblems`, `RedundantThrows`, `ContractViolation`). The colon-prefix is mandatory in v1 — bare `[INSPECTOR]` is reserved.

### Severity mapping (frozen for v1)

The wrapper script (`scripts/run-inspector.sh`) translates JetBrains-emitted severities to the plugin's three-tier system using this **frozen-for-v1** table:

| Inspector severity | Review tier |
|---|---|
| `ERROR` | 🔴 Blocking |
| `WARNING` | 🟡 Important |
| `WEAK_WARNING` | 🟢 Suggestion |
| `INFO` | (dropped — not surfaced) |
| `INFORMATION` | 🟢 Suggestion (unknown-source default) |
| `SERVER_PROBLEM` | 🟢 Suggestion (unknown-source default) |
| `TYPO` | (dropped — too noisy for code review) |
| `GRAMMAR_ERROR` | (dropped — same reason) |
| (any other JetBrains-emitted value) | 🟢 Suggestion (unknown-source default) |

The mapping is **NOT user-configurable from the plugin side in v1.** Teams who want a finding at a different tier MUST elevate or demote the corresponding inspection inside the project's `.idea/inspectionProfiles/*.xml` file (the JetBrains-native lever). The JetBrains-elevated severity then flows through the table above unchanged. Plugin-side configuration (e.g., a `.code-review-inspector.yml`) is deferred to v2.

The unknown-source default is **never** 🔴 Blocking and **never** 🟡 Important — only 🟢 Suggestion. This guarantees that a future JetBrains release introducing a new severity name cannot silently escalate findings.

### Dedup against catalog findings

Inspector findings deduplicate against catalog findings only when both diagnose the **same underlying cause** at the **same file:line** (with a ±2-line tolerance window). The curated `inspection_pattern_map` below drives the cause-match check by linking inspection short-names to catalog patterns. On a same-cause collision the catalog finding is kept and the inspector evidence is referenced as `**Inspector corroboration:**` on the surviving finding. When the file:line collides but the causes differ, both findings are emitted as independent top-level entries.

Full algorithm: see the feature spec at `specs/20260503-163219-add-idea-inspections/contracts/dedup-merge.md`.

### Inspection-pattern map

Curated mapping from JetBrains inspection short-name to the catalog pattern that diagnoses the same cause class. The dispatcher's Phase 4.5 merge step uses this map. **Initial v1 entries** — to be expanded as real-world review runs surface high-frequency inspections:

| Inspection short-name | Catalog pattern | Rationale |
|---|---|---|
| `NullableProblems` | `P3` | Both diagnose data-flow / null-reachability defects. |
| `ConstantConditions` | `P3` | Inspector flags reachable-but-impossible branches; same data-flow class. |
| `ContractViolation` | `P2` | JetBrains' `@Contract` runtime-contract checking; same family as catalog contract propagation. |
| `MethodWithMultipleReturnPoints` | (no map) | Style-only; no catalog pattern. Always emit independently. |
| `RedundantThrows` | (no map) | Style-only; no catalog pattern. |
| `UnusedDeclaration` | (no map) | Static-tool territory; no catalog pattern. |
| `MissingOverride` | `P2` | Override chain integrity overlaps with catalog contract propagation when method signatures change. |
| `EmptyMethod` | (no map) | Style; no catalog pattern. |
| `JpaQlInspection` | `P13` | Framework-contract consistency for JPA query strings. |
| `SpringConfigurationProxyMethods` | `P13` | Spring `@Configuration` lifecycle contract. |

Inspections **not** in this map are **always emitted as independent top-level entries** — no dedup is attempted. Adding a map entry is the only way to enable dedup against a catalog pattern. Map expansion is a low-risk, additive change; the merge step does not need to know about removed entries.

---

## Finding format

Prefix each finding title with the pattern number. A single finding may match more than one pattern; list them comma-separated. Findings sourced from `.code-review-rules.md` are tagged `[CUSTOM]` instead of a pattern number.

```markdown
### [<pattern-tags>] <short specific title>
**File:** `path/to/file:line-range`
**What:** <concise description of the issue>
**Why:** <impact or risk — why this matters>
**Fix:**
```<lang>
<1-5 line suggested snippet showing the corrected code>
```
**See also:** `path/to/canonical-example:line` — <optional one-line reason>   # OPTIONAL
**Rule source:** `.code-review-rules.md:<line>`                                 # REQUIRED when tag is [CUSTOM]
```

**Pattern tag rules**:
- Single cataloged pattern: `[P12]`, `[P13]`, etc.
- Multiple cataloged patterns: comma-separated, ascending numeric order, no spaces, max 3: `[P12,P14]`, `[P2,P5,P7]`.
- Custom rule from `.code-review-rules.md`: exactly `[CUSTOM]`. Never combined with pattern numbers.

**`See also:` field rules**:
- **Optional.** Populated only when the plugin has already located a canonical example of the correct pattern in the codebase during Phase 3 convention checks or P16 custom-rule evaluation.
- **File:line reference, wrapped in backticks.** The reference must point at a real line in the codebase at review time — never hallucinated.
- **At most two entries**, comma-separated on the same line.
- **Omitted entirely when no example is available.** Never populated with placeholder text like "none", "N/A", or "see elsewhere".
- The `See also:` example is a **positive counter-example** — the finding says "don't do X", and the See also points at where X is correctly done elsewhere. It's not a link to similar bug reports.

**`Rule source:` field rules**:
- **Required when the pattern tag is `[CUSTOM]`.** Omitted otherwise.
- **Must cite `.code-review-rules.md:<line>`** where `<line>` is the line number of the rule's heading in the rules file.
- Without this field, a `[CUSTOM]` finding is indistinguishable from a cataloged finding and must be re-tagged with the pattern number instead.

If a finding does not match any cataloged pattern and is not sourced from `.code-review-rules.md`, emit it without a prefix and reconsider whether it is worth including. If no pattern applies, the finding's importance is suspect — the pattern catalog is intentionally designed to cover every bug class worth reporting at scale.
