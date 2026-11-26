---
name: new-project
description: Scaffold a new Go HTTP API — either a small flat layout for exercises/interviews or the full hexagonal (ports & adapters) layout with chi, pgx, zerolog, config, graceful shutdown and a DI container. Use when starting a new Go API, service or live-coding exercise from an empty or near-empty folder.
argument-hint: "[lite|full] [module-path] [what the API does]"
disable-model-invocation: true
---

Scaffold a Go API. Arguments: $ARGUMENTS

Mode is the first argument. If missing: choose **lite** when the task sounds like an exercise,
interview question or prototype with a handful of endpoints; otherwise ask once.
Module path is the second argument; if missing use `example.com/<folder-name>`.
If the description asks for something beyond the mode's defaults (e.g. "use Postgres",
"use zerolog", "add JWT auth"), include it, using the matching `/go-api:infra` reference
(read `../infra/references/<topic>.md` relative to this SKILL.md).

## lite (exercises, interviews — aim for something running in under 10 minutes)

```
go.mod
Makefile           # see below
main.go            # config from env/flags, router, server with timeouts + graceful shutdown
handler.go         # handlers: decode → validate → call service → encode
service.go         # business rules; depends on a Store interface
store.go           # type Store interface + in-memory implementation (sync.RWMutex)
errors.go          # ErrNotFound / ErrValidation / ErrConflict + writeError mapping
service_test.go    # table-driven tests against the in-memory store
handler_test.go    # httptest tests for status codes and JSON
```

- Standard library `net/http` with Go 1.22+ method patterns (`mux.HandleFunc("GET /items/{id}", ...)`,
  `r.PathValue("id")`) unless chi is already in use or asked for.
- JSON envelope `{"success":true,"data":...}` / `{"success":false,"error":{"code","message"}}`.
- Logging: `log/slog` (JSON handler; text handler when `ENV=development`). It can be upgraded
  later with `/go-api:infra logger`.
- Storage: in-memory unless the task asks for a database. Postgres can be added later with
  `/go-api:infra postgres` (the in-memory store stays for unit tests).
- Makefile:

  ```make
  .PHONY: help run build test test-race cover fmt vet lint tidy
  help:      ## list targets
  	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "}{printf "  %-12s %s\n",$$1,$$2}'
  run:       ## run the API
  	go run .
  build:     ## build binary to bin/api
  	go build -o bin/api .
  test:      ## unit tests
  	go test ./...
  test-race: ## tests with race detector
  	go test -race ./...
  cover:     ## coverage report
  	go test -coverprofile=coverage.out ./... && go tool cover -func=coverage.out | tail -1
  fmt:       ## format
  	gofmt -w .
  vet:       ## go vet
  	go vet ./...
  lint:      ## golangci-lint if installed
  	@command -v golangci-lint >/dev/null && golangci-lint run ./... || echo "golangci-lint not installed"
  tidy:      ## tidy modules
  	go mod tidy
  ```
  (Recipe lines must start with a real tab.)
- Run `make test-race` and `make run`, then curl one endpoint before saying done.

## full (real services)

Create the layout from the "Layout" section of the Go API rules (internal/core,
adapters, infrastructure, shared, migrations, cmd/api) and build each piece from the
`/go-api:infra` references (read them from `../infra/references/`):

- `cmd/api/main.go`: load config → init logger (debug console in a dev terminal, JSON
  otherwise) → `container.New(cfg)` → `Start()`.
- `infrastructure/config`: typed `Config` parsed with caarlos0/env (`packages.md`): defaults,
  `required` secrets, startup fails on invalid values; `Env` type with
  `IsDevelopment / IsProductionLike`.
- `infrastructure/server`: `http.Server` with timeouts, SIGINT/SIGTERM graceful shutdown,
  `OnShutdown` hooks, a WaitGroup for background work, `ErrorLog` via the app logger.
- **postgres.md** + **packages.md**: `infrastructure/database` pool, `querier.go` +
  `transactor.go`, repositories on **sqlc** (`sqlc.yaml`, `queries/`, generated `sqlcdb`),
  migrations, docker-compose with a migrate service, integration tests on
  **testcontainers-go**. Memory package only for a no-op transactor and DB-less dev.
- **logger.md**: zerolog `Logger` interface, `WithCtx/FromCtx`, no-op logger, request-logging
  middleware with recursive redaction.
- **http-kit.md**: response envelope + `HandleError` + internal-error capture, `Page[T]`,
  `ReadJSON/ReadQuery`, stateless validator, phone + money helpers.
- **security.md** + **packages.md**: JWT manager (access/refresh, session version),
  `Authenticate`, API-key middleware, admin secret, **httprate** with a trusted
  `ClientIPFrom*` middleware, **go-chi/cors** — auth parts only if the description mentions
  users/auth or it's clearly a multi-user API; otherwise leave a TODO in the router.
- **observability.md**: Prometheus registry, HTTP metrics, `/health`, `/ready`, expvar.
- **jobs.md**: `infrastructure/container/workers.go` using the `runEvery`-style worker helper
  (no jobs yet unless the description needs them).
- `infrastructure/container`: `container.go`, `repos.go` (memory vs postgres via
  `USE_POSTGRES`), `services.go`, `handlers.go`, `workers.go`.
- Makefile with: `help, build, run, dev (air), test, test-race, test-integration, cover, lint,
  fmt, vet, tidy, sqlc, generate (sqlc + swag), swagger, migrate-create name=..., migrate-up,
  migrate-down, docker-up, docker-down, docker-down-v, gen-apikey` (self-documenting `help`
  target as in lite). CI also runs `sqlc diff`.
- `.env.example`, multi-stage `Dockerfile` (distroless or alpine, non-root user),
  `docker-compose.yml` (db + migrate + api), `.golangci.yml`, `.air.toml`,
  `.github/workflows/ci.yml` (race tests, migrations, integration tests), and a project
  `CLAUDE.md` describing commands and architecture.
- One sample resource built with the add-resource checklist so every layer has a working example.

Finish by running `go mod tidy`, `go vet ./...`, `go test -race ./...` and reporting results.
