---
name: infra
description: Add or upgrade infrastructure in a Go API — Postgres (pgxpool, transactions, migrations), zerolog logger, caching, background jobs (tickers, RunOnce, River, Temporal), JWT/API-key auth and rate limiting, Prometheus metrics, HTTP helpers (response envelope, pagination, validation), external provider integrations, and resilience (timeouts, idempotency keys, retries, circuit breakers, bulkheads). Use when asked to set up, add, switch to or improve any of these.
argument-hint: "[postgres|logger|cache|jobs|security|observability|http-kit|external|resilience|all] [extra instructions]"
---

Task: $ARGUMENTS

## 1. Pick the topic(s)

Each topic has a reference file in `references/` next to this SKILL.md. Read ONLY the ones
the task needs (they are long):

| Topic | File | Use for |
|---|---|---|
| postgres | `references/postgres.md` | pool setup, querier/transactor, migrations, docker-compose, integration tests, swapping an in-memory store for Postgres |
| logger | `references/logger.md` | zerolog Logger interface, ctx-scoped logger, request logging with redaction, slog → zerolog upgrade |
| cache | `references/cache.md` | Store interface, memory/Redis stores, cached repository decorators |
| jobs | `references/jobs.md` | ticker workers, RunOnce (exactly-once per slot), River queue, Temporal workflows — and how to choose |
| security | `references/security.md` | JWT (typed tokens, session version), auth middleware, API keys, admin secret, rate limiting, CORS |
| observability | `references/observability.md` | Prometheus registry, HTTP/worker/external metrics, health, expvar |
| http-kit | `references/http-kit.md` | response envelope + HandleError, pagination, ReadJSON/ReadQuery, validator wrapper, phone + money formatting |
| external | `references/external.md` | third-party provider ports, real vs mock by env, HTTP client timeouts, webhooks (signature + dedup) |
| resilience | `references/resilience.md` | timeouts (HTTP, server, Postgres, workers), idempotency keys for POSTs, atomic check-then-act, retries with backoff + jitter, circuit breakers, bulkheads, load shedding, graceful degradation, singleflight |

If the argument is a phrase rather than a topic name ("add zerolog", "switch to postgres",
"add JWT auth"), map it to the topic(s). `all` = every topic, in the order listed.

## 2. Fit the project you're in

- Read the project's `go.mod`, CLAUDE.md and existing layout first.
- **Flat (lite) project:** keep it flat — put the code in a few files at the root or one
  small package (e.g. `logger.go`, `db.go`, `auth.go`) instead of creating the full
  `internal/...` tree. Same patterns, fewer folders.
- **Hexagonal (full) project:** use the paths given in the reference.
- Replace the existing implementation rather than running two side by side, unless the
  reference says to keep both (e.g. keep the in-memory store for unit tests when adding Postgres).
- **Exception — jobs:** never rip out a working scheduler. Inventory what exists first
  (tickers, `RunOnce`/`scheduled_jobs`, River, Temporal, ad-hoc `go func()`), keep what's
  sound, fix its pitfalls, and add new mechanisms alongside, migrating one job type at a time.
  See "Working with an existing scheduler" in `references/jobs.md`.
- Use the module path from `go.mod` in imports.

## 3. Finish

- `go mod tidy`, `gofmt`, `go vet ./...`, `go test -race ./...`.
- Update the Makefile, `.env.example` and the project CLAUDE.md with any new commands or
  env vars.
- Summarise what you added, new env vars, and any follow-ups (e.g. "run `make migrate-up`").
