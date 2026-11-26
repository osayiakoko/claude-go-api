# Postgres (pgx/v5, raw SQL)

Dependencies: `github.com/jackc/pgx/v5`, migrations via the `golang-migrate` CLI.
Repository code: in **lite** projects (exercises, interviews, prototypes) use hand-written pgx
queries with scan helpers — no sqlc or testcontainers unless the user asks for them. In
**full** projects prefer **sqlc** to generate the query/scan code from your SQL (setup and the
repository pattern in `packages.md`) and **testcontainers-go** for integration tests. The pool,
`getQuerier`, `Transactor` and migrations below stay the same either way.

## Pool — `internal/infrastructure/database/postgres.go`

```go
package database

const (
	defaultMaxConns        = 25
	defaultMinConns        = 5
	defaultMaxConnLifetime = time.Hour
	defaultMaxConnIdleTime = 30 * time.Minute
	defaultConnectTimeout  = 5 * time.Second
)

// NewPool creates and validates a pgxpool. DATABASE_URL takes precedence over the
// individual host/port/user fields. Fails fast if the DB is unreachable.
func NewPool(ctx context.Context, cfg config.DatabaseConfig) (*pgxpool.Pool, error) {
	poolCfg, err := pgxpool.ParseConfig(buildDSN(cfg))
	if err != nil {
		return nil, fmt.Errorf("parse database config: %w", err)
	}
	poolCfg.MaxConns = defaultMaxConns // make configurable via env for prod tuning
	poolCfg.MinConns = defaultMinConns
	poolCfg.MaxConnLifetime = defaultMaxConnLifetime
	poolCfg.MaxConnIdleTime = defaultMaxConnIdleTime
	poolCfg.ConnConfig.ConnectTimeout = defaultConnectTimeout

	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return nil, fmt.Errorf("create connection pool: %w", err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, defaultConnectTimeout)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}
	return pool, nil
}

func buildDSN(cfg config.DatabaseConfig) string {
	if cfg.URL != "" {
		return cfg.URL
	}
	return fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=%s",
		cfg.Host, cfg.Port, cfg.User, cfg.Password, cfg.DBName, cfg.SSLMode)
}
```

Close the pool on shutdown: `srv.OnShutdown(pool.Close)` (after HTTP drain, before exit).
Size rule of thumb: total `MaxConns` across all instances < Postgres `max_connections` minus
headroom for migrations/admin.

## Transactions — `adapters/secondary/persistence/postgres/{querier,transactor}.go`

```go
// querier is satisfied by both *pgxpool.Pool and pgx.Tx.
type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// getQuerier returns the tx from ctx if one is active, else the pool.
// EVERY repository method uses this — never r.pool directly.
func getQuerier(ctx context.Context, pool *pgxpool.Pool) querier {
	if tx := TxFromContext(ctx); tx != nil {
		return tx
	}
	return pool
}

var _ sharedports.Transactor = (*Transactor)(nil)

type Transactor struct{ pool *pgxpool.Pool }

func NewTransactor(pool *pgxpool.Pool) sharedports.Transactor { return &Transactor{pool: pool} }

func (t *Transactor) WithTx(ctx context.Context, fn func(ctx context.Context) error) error {
	if TxFromContext(ctx) != nil { // already inside a tx: join it (no nested BEGIN)
		return fn(ctx)
	}
	tx, err := t.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	if err := fn(context.WithValue(ctx, txKey{}, tx)); err != nil {
		_ = tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}

type txKey struct{}

func TxFromContext(ctx context.Context) pgx.Tx {
	tx, _ := ctx.Value(txKey{}).(pgx.Tx)
	return tx
}
```

Core port (`core/shared/ports/transactor.go`) is just
`WithTx(ctx, fn func(ctx context.Context) error) error`. The memory package provides a no-op
version whose `WithTx` calls `fn(ctx)`.

Rules:
- Read-modify-write on money/balances: either `SELECT ... FOR UPDATE` inside the tx, or
  optimistic locking (`version` column, `WHERE id = $1 AND version = $2`). A version miss is
  a **conflict** → return `ErrConflict` (409), not `ErrNotFound`.
- Translate `pgx.ErrNoRows` → `ErrNotFound`; `*pgconn.PgError` code `23505` → `ErrDuplicate`;
  `23503` (FK violation) → `ErrValidation`.
- Keep transactions short: no HTTP calls to third parties inside `WithTx`.

## Migrations

```
migrations/postgres/000001_create_users.up.sql
migrations/postgres/000001_create_users.down.sql
```

Makefile:
```make
migrate-create: ; migrate create -ext sql -dir migrations/postgres -seq $(name)
migrate-up:     ; migrate -path migrations/postgres -database "$(DATABASE_URL)" up
migrate-down:   ; migrate -path migrations/postgres -database "$(DATABASE_URL)" down 1
```

Table conventions: `id UUID PRIMARY KEY`, `created_at/updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`,
money as `NUMERIC(20,2)` (or `(20,4)` for rates), explicit `ON DELETE` on every FK, an index
for every column used in a WHERE/JOIN by the repo, `version INT NOT NULL DEFAULT 1` where
optimistic locking is used. Seed reference data (plans, global categories) in migrations.

## docker-compose (local)

```yaml
services:
  db:
    image: postgres:16-alpine
    environment: { POSTGRES_USER: postgres, POSTGRES_PASSWORD: password, POSTGRES_DB: app }
    ports: ["5432:5432"]
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U postgres"], interval: 5s, retries: 10 }
    volumes: [pgdata:/var/lib/postgresql/data]
  migrate:
    image: migrate/migrate
    command: ["-path", "/migrations", "-database", "postgres://postgres:password@db:5432/app?sslmode=disable", "up"]
    volumes: ["./migrations/postgres:/migrations"]
    depends_on: { db: { condition: service_healthy } }
  api:
    build: .
    env_file: .env
    environment: { USE_POSTGRES: "true", DATABASE_URL: "postgres://postgres:password@db:5432/app?sslmode=disable" }
    ports: ["4000:4000"]
    depends_on: { migrate: { condition: service_completed_successfully } }
volumes: { pgdata: {} }
```

## Memory vs Postgres switch — `container/repos.go`

```go
if cfg.UsePostgres {
	pool, err := database.NewPool(ctx, cfg.Database)
	// handle err: log.Fatal
	r.product = postgres.NewProductRepository(pool)
	r.tx = postgres.NewTransactor(pool)
} else {
	r.product = memory.NewProductRepository()
	r.tx = memory.NewTransactor()
}
```

When upgrading a project from an in-memory store: keep the memory implementation (unit tests
and DB-less dev use it), add the postgres implementation behind the same interface, and add
an integration test.

## Integration tests

Preferred setup: start Postgres with testcontainers-go and run the real migrations in
`TestMain` — see `packages.md`. The cleanup helper below works with either setup.

```go
//go:build integration

func TestMain(m *testing.M) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		fmt.Println("TEST_DATABASE_URL not set; skipping integration tests")
		os.Exit(0)
	}
	var err error
	testPool, err = pgxpool.New(context.Background(), url)
	if err != nil { panic(err) }
	code := m.Run()
	testPool.Close()
	os.Exit(code)
}

// cleanup deletes rows (DELETE, not TRUNCATE, so migration-seeded rows in other tables survive).
func cleanup(t *testing.T, tables ...string) {
	t.Helper()
	t.Cleanup(func() {
		for _, tbl := range tables {
			if _, err := testPool.Exec(context.Background(), "DELETE FROM "+tbl); err != nil {
				t.Errorf("cleanup %s: %v", tbl, err)
			}
		}
	})
}
```

Run with `go test -tags integration ./tests/integration/...`. Never pass seeded global tables
to `cleanup`. Always include a test that a write inside `WithTx` rolls back when a later step
fails.
