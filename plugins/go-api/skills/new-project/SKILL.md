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

## lite (exercises, interviews — aim for something running in under 10 minutes)

```
go.mod
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
- `log/slog` for logging. No database unless the task asks for one.
- Run `go test -race ./...` and `go run .` and curl one endpoint before saying done.

## full (real services)

Create the layout from the "Layout" section of the Go API rules (internal/core,
adapters, infrastructure, shared, migrations, cmd/api) with:

- `cmd/api/main.go`: load config → init logger → `container.New(cfg)` → `Start()`.
- `infrastructure/config`: typed `Config`, env loading with defaults, `Env` type with
  `IsDevelopment / IsProductionLike`.
- `infrastructure/server`: `http.Server` with timeouts, SIGINT/SIGTERM graceful shutdown,
  `OnShutdown` hooks and a WaitGroup for background work.
- `infrastructure/database`: pgxpool setup with ping and pool sizing from config.
- `infrastructure/container`: `container.go`, `repos.go` (memory vs postgres via `USE_POSTGRES`),
  `services.go`, `handlers.go`, `workers.go`.
- `core/shared/domain`: `BaseEntity`, typed errors. `core/shared/ports`: `Transactor`.
- `adapters/secondary/persistence/postgres`: `querier.go` (`getQuerier`) and `transactor.go`.
  Memory package with a no-op transactor.
- `shared/`: `logger` (interface over zerolog + `WithCtx/FromCtx`), `response` (envelope +
  `HandleError`), `validator` (go-playground wrapper with friendly messages), `utils`
  (`ReadJSON`, `WriteJSON`, query readers), `auth` (JWT + `GetUserID`).
- `adapters/primary/http`: router with the standard middleware stack, `/health`, `/v1` group.
- `Makefile` (build, run, dev, test, test-race, test-integration, lint, swagger, migrate-*),
  `.env.example`, `Dockerfile` (multi-stage, distroless or alpine), `docker-compose.yml`
  (api + postgres), `.golangci.yml`, `.github/workflows/ci.yml` (race tests, migrations,
  integration tests), and a project `CLAUDE.md` describing commands and architecture.
- One sample resource (`health` + one CRUD resource via the add-resource checklist) so every
  layer has a working example.

Finish by running `go mod tidy`, `go vet ./...`, `go test -race ./...` and reporting results.
