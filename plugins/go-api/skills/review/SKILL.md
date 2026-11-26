---
name: review
description: Review Go API changes against Osayi's conventions and common Go pitfalls — layering, error handling, transactions, context, concurrency, SQL safety, money types and tests. Use when asked to review Go code, a diff, a PR or "check my changes" in a Go project.
argument-hint: "[path, package, or git range — defaults to uncommitted changes]"
---

Review: $ARGUMENTS (if empty, review `git diff HEAD` plus untracked `.go` files).

Read the changed code and enough surrounding code to judge it. Check, in this priority order:

1. **Correctness & data safety** — logic bugs, missing ownership/authorisation checks,
   nil dereferences, money as `float64`, SQL built from input, transactions that don't cover
   all the writes that must succeed together.
   - **`r.pool` vs `getQuerier`** — only a *must fix* when you can show the repository method
     is reached from inside a `Transactor.WithTx` closure (directly or through a service call)
     AND either (a) it writes, so the write escapes the rollback, or (b) it reads rows the same
     transaction has already written, so it sees stale data. Trace the call path and name the
     `WithTx` site in the finding.
   - Reads through `r.pool` inside a transaction that don't depend on the transaction's own
     writes (e.g. seeded or cached lookups) are fine for correctness — mention them once,
     grouped, as *nice to have* (they take a second pool connection while the tx holds one).
   - Outside any transaction, `r.pool` is a consistency note, not a defect. Don't list each
     occurrence; one grouped line with a count is enough.
   - Optimistic-lock conflicts (`WHERE version = $n` matching no rows) should surface as a
     conflict (409), not `ErrNotFound` (404). Flag it if you see it.
2. **Errors** — ignored errors, string-matching errors, raw infra errors leaking to clients,
   handlers choosing status codes instead of `response.HandleError`, missing `%w` wrapping.
3. **Concurrency & lifecycle** — goroutines without an exit path or ctx, shared maps without
   locks, `context.Background()` inside request paths, ctx stored in structs, per-request data
   stored on shared structs (validators, handlers, services).
4. **Background jobs** — check every ticker, worker, job and `go func()`:
   - bare `go func()` in a handler/service: no `recover` (a panic kills the process), not
     tracked by the shutdown WaitGroup, errors discarded, lost on restart → *must fix*;
     suggest the tracked background helper or a River job enqueued in the same tx.
   - side effect before bookkeeping (send/charge, *then* mark sent/advance): a failed update
     or crash repeats the side effect → *must fix* when the effect is user-visible or financial.
   - retries with no attempt cap or backoff (e.g. a failing send retried every tick forever).
   - polling due rows without `FOR UPDATE SKIP LOCKED` / a claim step: duplicates with more
     than one instance.
   - long tickers (`24*time.Hour`) with no run-on-start: they restart their countdown on every
     deploy and may never fire.
   - `RunOnce`-style claims that can't reclaim a job stuck in `running` (no lease).
   - jobs that aren't idempotent although the mechanism can run them twice.
5. **Layering** — core importing adapters/pgx/chi/net/http, concrete types constructed outside
   the container, domain structs returned from handlers instead of DTOs.
6. **Tests** — new behaviour without tests, error-type assertions missing, no race run.
7. **Style** — naming, missing doc comments on exported port methods, gofmt.

Run `go vet ./...` and `go test -race ./...` on the affected packages if possible.

Output: a list ordered by severity. Each item: `file:line`, what's wrong, a concrete fix
(code if short). Separate "must fix" from "nice to have". Say plainly if it looks good.
Do not edit files unless asked.
