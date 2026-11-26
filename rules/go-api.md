# Go API conventions (Osayi)

These rules apply when the working directory is a Go project (has `go.mod`, or the task is
to write Go). Ignore them for NestJS, Flutter or other non-Go work.
If the repo has its own CLAUDE.md or established patterns that differ, the repo wins:
match what is already there and mention the difference instead of "fixing" it.

## Scale the structure to the task

- **Small task (live-coding exercise, kata, one or two endpoints, < ~300 lines):** do NOT
  scaffold the full hexagonal layout. Use a flat package: `main.go`, `handler.go`,
  `service.go`, `store.go` (interface + in-memory impl), `*_test.go`. Keep every principle
  below (interfaces at the consumer, typed errors, context, tests) — just fewer folders.
  Say in one line that you'd split into layers as it grows.
- **Real service:** hexagonal layout below. Use `/go-api:new-project` to scaffold it.
- Prefer the standard library. Reach for a dependency only when it clearly earns its place.

## Layout (real services) — hexagonal, dependencies point inward

```
cmd/api/main.go                  # load config, init logger, container.New(cfg), Start()
internal/
  core/<domain>/
    domain/                      # entities, value objects, enums, domain methods — no I/O
    ports/repositories/          # interfaces core needs from storage
    ports/services/              # interfaces handlers call
    services/                    # business logic implementing ports/services
  core/shared/domain/            # BaseEntity, typed domain errors
  core/shared/ports/             # Transactor, external service ports
  adapters/primary/http/         # chi router, handlers, middleware, dto/
  adapters/secondary/persistence/{memory,postgres}/
  adapters/secondary/external/   # third-party API clients
  infrastructure/{config,database,server,container}/
  shared/{logger,validator,response,auth,utils}/
migrations/postgres/             # golang-migrate, NNNNNN_name.{up,down}.sql
```

- `core/` never imports adapters, infrastructure, pgx, chi or net/http.
- `infrastructure/container/` is the ONLY place concrete types are constructed and wired.
  Split it: `repos.go`, `external.go`, `services.go`, `handlers.go`, `workers.go`.
- When several packages share a name (`domain`, `services`), import with aliases:
  `userdomain`, `userrepos`, `usersvc`, `shareddomain`.

## Types and constructors

- Constructors return the port interface: `func NewXService(repo xrepos.XRepository) xservices.XService`.
  The concrete struct is unexported.
- Compile-time interface checks next to every implementation:
  `var _ xrepos.XRepository = (*xRepository)(nil)`.
- Dependencies are injected through constructors. No package-level mutable state, no `init()` wiring.
- Entities embed `shareddomain.BaseEntity` (`ID uuid.UUID`, `CreatedAt`, `UpdatedAt`) built via
  `NewBaseEntity()`.
- Enums are typed strings with constants: `type Status string; const StatusActive Status = "active"`.
- Money is `github.com/shopspring/decimal` — never `float64`. Nullable fields are pointers.
- Document every exported interface method, including which domain errors it returns.

## Errors

- Domain errors are typed structs in `core/shared/domain/errors.go`: `ErrNotFound{Resource}`,
  `ErrDuplicate{Resource, Field}`, `ErrValidation{Field, Message}`, `ErrUnauthorised{Reason}`,
  `ErrInternal{Cause}` (with `Unwrap`). Return them by pointer.
- Repositories translate storage errors into domain errors (`pgx.ErrNoRows` → `ErrNotFound`,
  unique violation `23505` → `ErrDuplicate`, `RowsAffected()==0` on update/delete → `ErrNotFound`).
- Services return domain errors as-is; wrap unexpected infrastructure errors with context:
  `fmt.Errorf("create order: %w", err)`. Never discard an error; `_ =` only with a comment.
- Check with `errors.As` / `errors.Is`, never string comparison.
- Handlers never pick status codes for domain errors themselves — call
  `response.HandleError(w, r, err)`, the single mapping point (NotFound→404, Duplicate→409,
  Validation→400, Unauthorised→403, default→500 with a generic message, real error logged).
- No `panic` outside `main` and truly impossible states.

## HTTP layer

- Router: `go-chi/chi/v5`. Global middleware order: recoverer, RequestID, RealIP, request
  logger, timeout, CORS, metrics. Routes versioned under `/v1`.
- Handler struct per resource holding service ports + `*validator.Validator`; constructor `NewXHandler`.
- Handler shape, in this order: parse path params (`uuid.Parse(chi.URLParam(r, "id"))` → 400)
  → `helpers.ReadJSON` (1MB cap, `DisallowUnknownFields`, single JSON value) → validate
  (`go-playground/validator` tags; failures → `response.FailedValidation`, 422) → auth context
  (`auth.GetUserID(r)`) → call service with `r.Context()` → map to DTO → respond.
- Request/response DTOs live in `adapters/primary/http/dto`, with `ToXResponse(*domain.X)`
  mappers. Never return domain structs directly. JSON keys are camelCase.
- Envelope: success `{"success": true, "data": ...}`; error
  `{"success": false, "error": {"code": "NOT_FOUND", "message": "..."}}`. Use
  `response.Ok`, `response.Created`, `response.HandleError`, `response.BadRequest`.
- Swagger (swaggo) annotations on every handler: `@Summary @Tags @Security @Param @Success @Router`.

## Persistence

- PostgreSQL with `jackc/pgx/v5` and raw SQL. No ORM. Positional params (`$1`) only — never
  build SQL with string concatenation of input (whitelist sort columns).
- Every repository method gets its executor via `q := getQuerier(ctx, r.pool)` so it takes
  part in a transaction started by `Transactor.WithTx(ctx, fn)`. Never call `r.pool` directly.
- Multi-step writes that must succeed together go through the `Transactor` port in the service.
- Scan into the domain struct in small `scanX(row pgx.Row)` / `scanXRow(rows pgx.Rows)` helpers;
  always `defer rows.Close()` and return `rows.Err()`.
- Every postgres repo has an in-memory twin in `persistence/memory` (mutex-guarded maps)
  used by unit tests and DB-less local dev (`USE_POSTGRES=false`).
- Migrations are always an up/down pair; down must fully reverse up.

## Context, concurrency, lifecycle

- `ctx context.Context` is the first parameter of anything that does I/O. Never store it in a struct.
- Request-scoped logger via `logger.FromCtx(ctx)`; structured fields as `map[string]any`. Never
  log secrets, tokens, OTPs or full card/account numbers.
- Every goroutine has an owner and an exit: background workers `select` on a shared ctx that is
  cancelled on shutdown and are tracked by the server's WaitGroup.
- Server: explicit Read/Write/Idle timeouts; graceful shutdown on SIGINT/SIGTERM (drain
  in-flight requests, cancel workers, wait).
- Config only from env (`.env` for local via godotenv), loaded once into a typed `Config`.

## Testing

- Black-box tests: `package xservice_test`. Test names `TestXService_Method_Condition_Result`.
- Use in-memory repos / hand-written fakes that satisfy the port (with the `var _` check).
  No mocking frameworks.
- Table-driven with `t.Run` for input variations; `pgregory.net/rapid` property tests for
  invariants (parsing, money maths, normalisation).
- Assert error *types* with `errors.As`, not messages.
- Handlers: `httptest.NewRecorder` + real router/handler with fake services; assert status and envelope.
- Integration tests behind `//go:build integration`, real Postgres from `TEST_DATABASE_URL`,
  clean tables between tests with DELETE.
- Run `go test -race ./...` before calling work done.

## Before saying "done"

`gofmt`/`goimports` clean → `go vet ./...` → `go test -race ./...` → `golangci-lint run` if
configured. Report what you ran and the result. In an interview, also explain the trade-offs
you made in two or three sentences.
