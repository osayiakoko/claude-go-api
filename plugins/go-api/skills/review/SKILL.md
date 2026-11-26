---
name: review
description: Review Go API changes against Osayi's conventions and common Go pitfalls — layering, error handling, transactions, context, concurrency, SQL safety, money types and tests. Use when asked to review Go code, a diff, a PR or "check my changes" in a Go project.
argument-hint: "[path, package, or git range — defaults to uncommitted changes]"
---

Review: $ARGUMENTS (if empty, review `git diff HEAD` plus untracked `.go` files).

Read the changed code and enough surrounding code to judge it. Check, in this priority order:

1. **Correctness & data safety** — logic bugs, missing ownership/authorisation checks,
   nil dereferences, money as `float64`, SQL built from input, transactions that don't cover
   all the writes, repo methods using `r.pool` directly instead of `getQuerier` (escapes the tx).
2. **Errors** — ignored errors, string-matching errors, raw infra errors leaking to clients,
   handlers choosing status codes instead of `response.HandleError`, missing `%w` wrapping.
3. **Concurrency & lifecycle** — goroutines without an exit path or ctx, shared maps without
   locks, `context.Background()` inside request paths, ctx stored in structs.
4. **Layering** — core importing adapters/pgx/chi/net/http, concrete types constructed outside
   the container, domain structs returned from handlers instead of DTOs.
5. **Tests** — new behaviour without tests, error-type assertions missing, no race run.
6. **Style** — naming, missing doc comments on exported port methods, gofmt.

Run `go vet ./...` and `go test -race ./...` on the affected packages if possible.

Output: a list ordered by severity. Each item: `file:line`, what's wrong, a concrete fix
(code if short). Separate "must fix" from "nice to have". Say plainly if it looks good.
Do not edit files unless asked.
