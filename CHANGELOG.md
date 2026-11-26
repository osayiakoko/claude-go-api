# Changelog

All notable changes to this repo. The `go-api` plugin follows [semantic versioning](https://semver.org):
**MAJOR** = breaking change to a command (renamed/removed, incompatible arguments),
**MINOR** = new command, topic or behaviour, **PATCH** = fixes and wording.

The always-on rules file (`rules/go-api.md`) isn't versioned separately — it's linked into
`~/.claude/rules/` and takes effect as soon as it changes on disk. Its changes are listed
under the plugin version they shipped with, marked **Rules**.

To release: update this file, bump `version` in `plugins/go-api/.claude-plugin/plugin.json`,
commit, tag (`git tag go-api-vX.Y.Z`), push with `--tags`, then run
`/plugin marketplace update osayi-claude` and `/reload-plugins`.

## [1.4.0] — 2026-11-26

Resilience, from a review of TrakDip's payment, webhook and provider code.

### Added
- `/go-api:infra resilience` (`references/resilience.md`):
  - Timeouts: tuned per-provider `http.Client`, server timeouts, Postgres `statement_timeout`
    and `idle_in_transaction_session_timeout`, per-run worker deadlines.
  - Idempotency-key middleware for POSTs (409 while in progress, replay of the stored
    response, 422 on key reuse with a different body, key released on 5xx), with an in-memory
    store for tests and a Postgres store with lease takeover — tested, including under `-race`.
  - Atomic check-then-act for webhooks/state transitions (`UPDATE ... WHERE status = 'pending'
    RETURNING` in one tx) plus a partial unique index as a database guard.
  - `Retry` helper with exponential backoff, full jitter, `Retry-After` support and an HTTP
    retryability classifier — tested.
  - Circuit breakers with `sony/gobreaker/v2` (per provider, 4xx doesn't trip, state metric,
    fallback) and the composition order bulkhead → breaker → retry → timeout → call.
  - `Bulkhead` and `LoadShed` middleware — tested.
  - Graceful degradation guidance and `singleflight` for cache stampedes.
- `circuit_breaker_state` gauge in `observability.md`.
- `/go-api:review` has a "Resilience" item (missing timeouts, non-atomic transitions,
  POSTs without idempotency keys, unsafe or stacked retries, missing breakers/bulkheads).

### Changed
- **Rules:** new "Resilience" line (idempotency keys on money-relevant POSTs, atomic state
  transitions, timeout → retry → breaker → bulkhead for outbound calls, Postgres
  `statement_timeout`).
- `/go-api:help` and README list the `resilience` topic with examples.
- `/go-api:review` checklist renumbered (Resilience is item 5).

## [1.3.0] — 2026-11-26

Background-job awareness, from a review of TrakDip's workers.

### Added
- `/go-api:review` checks background jobs: bare `go func()` in request paths, side effects
  before bookkeeping, unbounded retries, polling without `FOR UPDATE SKIP LOCKED`, 24h tickers
  without run-on-start, `RunOnce` claims without a lease, non-idempotent job bodies.
- `jobs.md`: "Working with an existing scheduler" (inventory → keep what's sound → add
  alongside → migrate one job type at a time), a pitfalls table, and a multi-instance
  `ClaimDue` pattern with `FOR UPDATE SKIP LOCKED`, attempts and backoff.
- This changelog.

### Changed
- `/go-api:infra`: the jobs topic is an exception to "replace, don't run side by side" —
  Claude now extends an existing scheduler instead of replacing it.
- **Rules:** jobs guidance now says to extend an existing scheduler; new "Job safety" line
  (no bare `go func()` in request paths, claim before side effects, cap attempts,
  `SKIP LOCKED` polling, periodic jobs must survive restarts).
- `/go-api:review` checklist renumbered (Background jobs is item 4).

## [1.2.0] — 2026-11-26

### Added
- `/go-api:infra [topic]` with on-demand references: `postgres`, `logger`, `cache`, `jobs`,
  `security`, `observability`, `http-kit`, `external` (plus `all` and plain-English requests).
  - **security** covers JWT access/refresh tokens with session-version revocation, the
    `Authenticate` middleware, hashed API keys with a short cache, a constant-time admin
    secret, per-client rate limiting and CORS.
  - **jobs** covers ticker workers (`runEvery` helper), `RunOnce` with a lease, River
    (`InsertTx` behind a `JobQueue` port) and Temporal (workflows, activities, worker process).
  - Reference code ships with fixes for issues found in TrakDip: stateless validator,
    `RunOnce` lease reclaim, recursive log redaction, constant-time secret comparison,
    consistent empty-page shape, float-free money formatting, `RealIP` caveat.
- `lite` projects get a Makefile with a self-documenting `help` target (BSD/macOS-compatible).

### Changed
- Logging: `lite` uses `log/slog`, `full` uses zerolog; `/go-api:infra logger` upgrades a
  `lite` project to zerolog.
- `/go-api:new-project` accepts extras in the description (e.g. "with Postgres and zerolog")
  and builds `full` projects from the infra references (Docker, compose with a migrate step,
  CI, `.air.toml`, `.golangci.yml`, full Makefile).
- `add-resource` reference uses the stateless validator
  (`if errs := h.validator.Validate(input); errs != nil`), with a note that helper package
  names are placeholders.
- `/go-api:help` and README list `/go-api:infra` with examples.
- **Rules:** added `ErrConflict` (409 for version conflicts); handler validation uses the
  stateless validator; shared structs must hold no per-request state; secrets compared in
  constant time; every outbound `http.Client` has a timeout; new "Infrastructure" section
  pointing to `/go-api:infra`.

## [1.1.0] — 2026-11-26

### Added
- `/go-api:help` — prints every command with examples.
- README "Commands" section with examples for every command and plugin management.

### Changed
- `/go-api:review` only treats `r.pool` (instead of `getQuerier`) as *must fix* when the
  repository method is reached inside `Transactor.WithTx` and writes, or reads rows the same
  transaction wrote. Other uses are grouped as one consistency note. Version-conflict errors
  returned as 404 are flagged.

## [1.0.0] — 2026-11-23

### Added
- **Rules** (`rules/go-api.md`, always on via `install.sh`): Go API conventions drawn from
  TrakDip — scale-to-task (flat layout for exercises, hexagonal for real services),
  layout and import aliases, constructors returning ports, typed domain errors with a single
  `HandleError` mapping, chi handler shape, response envelope, DTOs, pgx raw SQL with
  `getQuerier` and `Transactor`, in-memory repository twins, context/concurrency/shutdown
  rules, testing conventions (black-box, fakes not mocks, rapid property tests, integration
  build tag), and the "before saying done" checklist.
- Plugin `go-api` in marketplace `osayi-claude`:
  - `/go-api:new-project [lite|full]` — scaffold a Go API.
  - `/go-api:add-resource` — add an entity through every layer, with a reference of
    canonical code shapes.
  - `/go-api:review` — review Go changes against the conventions.
  - Hook: `goimports`/`gofmt` on every `.go` file Claude writes or edits.
- `install.sh` — links the rules into `~/.claude/rules/`.

[1.4.0]: https://github.com/<your-github-username>/claude-go-api/compare/go-api-v1.3.0...go-api-v1.4.0
[1.3.0]: https://github.com/<your-github-username>/claude-go-api/compare/go-api-v1.2.0...go-api-v1.3.0
[1.2.0]: https://github.com/<your-github-username>/claude-go-api/compare/go-api-v1.1.0...go-api-v1.2.0
[1.1.0]: https://github.com/<your-github-username>/claude-go-api/compare/go-api-v1.0.0...go-api-v1.1.0
[1.0.0]: https://github.com/<your-github-username>/claude-go-api/releases/tag/go-api-v1.0.0
