---
name: add-resource
description: Add a new domain resource (entity) end to end in a hexagonal Go API — domain, ports, service, memory and postgres repos, migration, DTOs, handler, routes, container wiring and tests. Use when asked to add a feature, entity, resource or CRUD endpoints to a Go API that follows the internal/core + adapters layout.
argument-hint: "[resource-name] [short description of fields/behaviour]"
---

Add the resource described in: $ARGUMENTS

First read the project's CLAUDE.md and one existing resource end to end (domain → ports →
service → postgres repo → handler → dto → container) so the new code matches the repo's real
names, helpers and import aliases. If the repo uses a flat layout, follow that instead and
skip the layers it doesn't have.

Then work through this checklist in order. Mark each done before moving on. The canonical
shapes are in `reference.md`, next to this SKILL.md — read it and use them as the pattern, adapting names.

1. **Domain** `internal/core/<res>/domain/<res>.go` — struct embedding `BaseEntity`, typed
   enums, domain methods for invariants. No I/O, no JSON concerns beyond what the repo already does.
2. **Ports** — `ports/repositories/<res>_repository.go` and `ports/services/<res>_service.go`.
   Doc comment on every method listing the domain errors it can return.
3. **Service** `services/<res>_service.go` — unexported struct, `New<Res>Service(...)` returns
   the port. Ownership/authorisation checks here, not in the handler. Use the `Transactor` for
   multi-step writes.
4. **Memory repo** `adapters/secondary/persistence/memory/<res>_repository.go` — mutex + map,
   returns the same domain errors as postgres. `var _` interface check.
5. **Migration** — `make migrate-create name=create_<res>s` (or the repo's equivalent);
   write both up and down. UUID PK, FKs with explicit ON DELETE, `created_at`/`updated_at`,
   indexes for the lookups the repo performs.
6. **Postgres repo** `adapters/secondary/persistence/postgres/<res>_repository.go` —
   if the project has `sqlc.yaml`: add `queries/<res>.sql`, run `sqlc generate`, and map
   generated rows ↔ domain in the repo (`sqlcdb.New(getQuerier(ctx, r.pool))`, see the infra
   `packages.md` reference). Otherwise hand-written SQL with scan helpers. Either way:
   `getQuerier` in EVERY method and error translation to domain errors.
7. **DTOs** `adapters/primary/http/dto/<res>_dto.go` — Create/Update request structs with
   `validate` tags, `<Res>Response`, `To<Res>Response` mapper. camelCase JSON.
8. **Handler** `adapters/primary/http/handlers/<res>_handler.go` — standard handler shape,
   swagger annotations, `response.HandleError` for all service errors.
9. **Routes** — register under the right auth group in the router; add the handler to `RouterDeps`.
10. **Wiring** — container: repo in `repos.go` (memory vs postgres switch), service in
    `services.go`, handler in `handlers.go`.
11. **Tests** — service tests against the memory repo (happy path, not found, duplicate,
    unauthorised/ownership, validation edge cases); handler tests with httptest; integration
    test for the postgres repo behind `//go:build integration` (testcontainers-go if the
   project uses it).
12. **Verify** — `gofmt -l .` empty, `go vet ./...`, `go test -race ./...`, `make swagger` if
    the repo uses swag. Report results.

Finish with a short summary: files added, endpoints (method + path), and anything you chose
not to do.
