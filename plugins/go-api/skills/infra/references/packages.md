# Preferred packages (use these instead of hand-rolling)

| Need | Use | Instead of |
|---|---|---|
| Postgres data access | **sqlc** (generates typed Go from your SQL, pgx/v5) | hand-written `Scan` helpers per repository |
| Integration tests against Postgres | **testcontainers-go** (`modules/postgres`) | a manually started DB + `TEST_DATABASE_URL`, or large in-memory repository twins |
| Background jobs / queues | **River** (see `jobs.md`) | ad-hoc pollers and `go func()` |
| Config from env | **caarlos0/env** (v11) | `getEnv` + `strconv.Atoi` with ignored errors |
| HTTP rate limiting | **go-chi/httprate** (+ `httprate-redis` for multi-instance) | hand-rolled token-bucket maps |
| CORS | **go-chi/cors** | hand-rolled origin checks |
| Circuit breakers | **sony/gobreaker/v2** (see `resilience.md`) | hand-rolled failure counters |
| Cache stampede protection | **golang.org/x/sync/singleflight** | — |

Already-standard choices to keep: chi, pgx/v5, golang-migrate, zerolog (full) / slog (lite),
go-playground/validator, golang-jwt/jwt/v5, shopspring/decimal, google/uuid,
nyaruka/phonenumbers, prometheus/client_golang, pgregory.net/rapid.

`lite` projects stay standard-library-first; pull these in when the project grows into what
they solve (sqlc once there's Postgres, httprate once there's a public API, etc.).

**Adopting in an existing project:** migrate incrementally — one repository to sqlc at a time
(keep the port interface unchanged so services and tests don't move), testcontainers first so
each step is covered by real-DB tests.

---

## sqlc

Install: `go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest` (or `brew install sqlc`).

`sqlc.yaml` at the repo root — schema comes straight from the golang-migrate directory:

```yaml
version: "2"
sql:
  - engine: "postgresql"
    schema: "migrations/postgres"
    queries: "internal/adapters/secondary/persistence/postgres/queries"
    gen:
      go:
        package: "sqlcdb"
        out: "internal/adapters/secondary/persistence/postgres/sqlcdb"
        sql_package: "pgx/v5"
        emit_pointers_for_null_types: true   # *string instead of pgtype.Text
        emit_empty_slices: true              # [] instead of nil from :many
        emit_interface: true                 # Querier interface for fakes if needed
        overrides:
          - db_type: "uuid"
            go_type: { import: "github.com/google/uuid", type: "UUID" }
          - db_type: "uuid"
            nullable: true
            go_type: { import: "github.com/google/uuid", type: "UUID", pointer: true }
          - db_type: "pg_catalog.numeric"
            go_type: { import: "github.com/shopspring/decimal", type: "Decimal" }
          - db_type: "pg_catalog.numeric"
            nullable: true
            go_type: { import: "github.com/shopspring/decimal", type: "NullDecimal" }
```

(Each `db_type` override applies to either nullable or non-nullable columns, hence two
entries. Run `sqlc generate` and check the generated types; adjust the overrides if a column
type differs.)

Queries — `.../postgres/queries/categories.sql`:

```sql
-- name: CreateCategory :one
INSERT INTO categories (id, account_id, name, type, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING created_at, updated_at;

-- name: GetCategoryByID :one
SELECT id, account_id, name, type, created_at, updated_at
FROM categories WHERE id = $1;

-- name: ListCategoriesForAccount :many
SELECT id, account_id, name, type, created_at, updated_at
FROM categories
WHERE account_id IS NULL OR account_id = sqlc.narg('account_id')
ORDER BY type, name;

-- name: UpdateCategoryName :execrows
UPDATE categories SET name = $2, updated_at = NOW() WHERE id = $1;
```

Repository — the **port and domain types don't change**; the repo maps sqlc rows ↔ domain and
keeps translating errors. sqlc's generated `New(db DBTX)` accepts anything with
`Exec/Query/QueryRow`, so the existing `getQuerier` keeps transactions working:

```go
func (r *categoryRepository) GetByID(ctx context.Context, id uuid.UUID) (*catdomain.Category, error) {
	row, err := sqlcdb.New(getQuerier(ctx, r.pool)).GetCategoryByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &shareddomain.ErrNotFound{Resource: "category"}
	}
	if err != nil {
		return nil, err
	}
	return toCategory(row), nil
}

func (r *categoryRepository) Update(ctx context.Context, c *catdomain.Category) error {
	n, err := sqlcdb.New(getQuerier(ctx, r.pool)).UpdateCategoryName(ctx, sqlcdb.UpdateCategoryNameParams{ID: c.ID, Name: c.Name})
	if err != nil {
		return err
	}
	if n == 0 {
		return &shareddomain.ErrNotFound{Resource: "category"}
	}
	return nil
}

func toCategory(r sqlcdb.Category) *catdomain.Category {
	return &catdomain.Category{
		BaseEntity: shareddomain.BaseEntity{ID: r.ID, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt},
		AccountID:  r.AccountID,
		Name:       r.Name,
		Type:       catdomain.CategoryType(r.Type),
	}
}
```

Rules:
- Generated code lives only in the adapter package; never import `sqlcdb` from core.
- Commit the generated code; add `make sqlc` (`sqlc generate`) and a CI step
  `sqlc diff` (fails if generated code is stale) plus `sqlc vet`.
- Dynamic filters/sorting: use `sqlc.narg()` for optional params, or a small set of named
  queries per safelisted sort; don't build SQL strings at runtime.
- Timestamps: if `timestamptz` comes out as `pgtype.Timestamptz`, add an override to `time.Time`.

Makefile: `sqlc: ; sqlc generate` and run it in `make generate` with `swag`.

---

## testcontainers-go (integration tests)

Requires Docker locally and in CI (GitHub-hosted Ubuntu runners have it).

`tests/integration/main_test.go`:

```go
//go:build integration

var testPool *pgxpool.Pool

func TestMain(m *testing.M) {
	ctx := context.Background()

	// Use an existing DB when provided (e.g. a CI service container), else start one.
	dsn := os.Getenv("TEST_DATABASE_URL")
	var ctr *postgres.PostgresContainer
	if dsn == "" {
		var err error
		ctr, err = postgres.Run(ctx, "postgres:16-alpine",
			postgres.WithDatabase("app_test"), // not "postgres": snapshots drop the connected DB
			postgres.WithUsername("test"),
			postgres.WithPassword("test"),
			postgres.BasicWaitStrategies(),
		)
		if err != nil {
			log.Fatalf("start postgres: %v", err)
		}
		dsn, err = ctr.ConnectionString(ctx, "sslmode=disable")
		if err != nil {
			log.Fatalf("dsn: %v", err)
		}
	}

	if err := migrateUp(dsn); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	var err error
	testPool, err = pgxpool.New(ctx, dsn)
	if err != nil {
		log.Fatalf("pool: %v", err)
	}

	code := m.Run()

	testPool.Close()
	if ctr != nil {
		_ = testcontainers.TerminateContainer(ctr)
	}
	os.Exit(code)
}

// migrateUp runs the real migrations with golang-migrate's library (pgx v5 driver).
func migrateUp(dsn string) error {
	m, err := migrate.New("file://../../migrations/postgres",
		strings.Replace(dsn, "postgres://", "pgx5://", 1))
	if err != nil {
		return err
	}
	defer m.Close()
	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		return err
	}
	return nil
}
```

Imports: `github.com/testcontainers/testcontainers-go`,
`github.com/testcontainers/testcontainers-go/modules/postgres`,
`github.com/golang-migrate/migrate/v4`, `_ "github.com/golang-migrate/migrate/v4/database/pgx/v5"`,
`_ "github.com/golang-migrate/migrate/v4/source/file"`.

Isolation between tests (pick one):
- **DELETE cleanup** helper (current pattern) — simple; keep seeded reference tables out of it.
- **Transaction per test** — begin a tx, put it in ctx (so `getQuerier` uses it), roll back in
  `t.Cleanup`. Fast, but can't test code that commits/uses its own `WithTx`, or concurrency.
- **Snapshot/Restore** — `ctr.Snapshot(ctx)` once after migrations, `ctr.Restore(ctx)` in each
  test's cleanup. Close pool connections first; import `pgx/v5/stdlib` and pass
  `postgres.WithSQLDriver("pgx")` to avoid the slower `docker exec` fallback.

What this buys: tests exercise real constraints, locks and transactions — the bugs in-memory
twins can't show (races on check-then-act, unique violations, `FOR UPDATE SKIP LOCKED`). With
it in place, keep in-memory implementations only where they earn their keep (DB-less local
dev, or a fake that forces an error path) instead of maintaining one per repository.

Makefile: `test-integration: ; go test -tags integration -race ./tests/integration/...`

---

## caarlos0/env (config)

```go
type Config struct {
	Env         Env           `env:"ENV" envDefault:"development"`
	UsePostgres bool          `env:"USE_POSTGRES" envDefault:"false"`
	Server      ServerConfig  `envPrefix:"SERVER_"`
	Database    DatabaseConfig `envPrefix:"DB_"`
	JWT         JWTConfig     `envPrefix:"JWT_"`
	Cors        CorsConfig    `envPrefix:"CORS_"`
	Phone       PhoneConfig   `envPrefix:"PHONE_"`
}

type ServerConfig struct {
	Port         int           `env:"PORT" envDefault:"4000"`
	ReadTimeout  time.Duration `env:"READ_TIMEOUT" envDefault:"10s"`
	WriteTimeout time.Duration `env:"WRITE_TIMEOUT" envDefault:"30s"`
}

type DatabaseConfig struct {
	URL      string `env:"URL"` // DB_URL; or keep DATABASE_URL with env:"DATABASE_URL" at top level
	MaxConns int32  `env:"MAX_CONNS" envDefault:"25"`
}

type JWTConfig struct {
	Secret     string        `env:"SECRET,required,notEmpty"`
	AccessTTL  time.Duration `env:"ACCESS_TTL" envDefault:"15m"`
	RefreshTTL time.Duration `env:"REFRESH_TTL" envDefault:"720h"`
}

type CorsConfig struct {
	TrustedOrigins []string `env:"TRUSTED_ORIGINS" envSeparator:","`
}

type PhoneConfig struct {
	SupportedRegions []string `env:"SUPPORTED_REGIONS" envSeparator:"," envDefault:"NG"`
}

func Load() (*Config, error) {
	_ = godotenv.Load() // local .env only; real env wins
	cfg, err := env.ParseAs[Config]()
	if err != nil {
		return nil, fmt.Errorf("config: %w", err) // e.g. JWT_SECRET missing, DB_MAX_CONNS="2o"
	}
	// Environment-dependent requirements go here, after parsing, e.g.:
	// if cfg.Env.IsProductionLike() && cfg.Payment.PaystackSecretKey == "" {
	// 	return nil, errors.New("config: PAYSTACK_SECRET_KEY is required outside development")
	// }
	return &cfg, nil
}
```

Rules: invalid values fail startup (no silent defaults on typos); secrets are `required`
where the app can't run without them; environment-dependent requirements are checked after
parsing; `Env` is a custom type — implement `encoding.TextUnmarshaler` on it so invalid values
are rejected. Keep `.env.example` in sync with the struct.

---

## go-chi/httprate (rate limiting)

Resolve the **trusted** client IP first with chi's `middleware.ClientIPFrom*` (chi v5.3.0+;
upgrade chi if older), choosing exactly one:

| Deployment | Middleware |
|---|---|
| Exposed directly | `middleware.ClientIPFromRemoteAddr` |
| Behind nginx/Cloudflare that sets one header | `middleware.ClientIPFromHeader("X-Real-IP")` (or `CF-Connecting-IP`) |
| Behind proxies in known ranges | `middleware.ClientIPFromXFF("10.0.0.0/8")` |
| Behind a fixed number of proxies | `middleware.ClientIPFromXFFTrustedProxies(2)` |

Do **not** use `middleware.RealIP` or httprate's deprecated `LimitByRealIP`/`KeyByRealIP`/`KeyByIP`
— they trust client-supplied headers.

```go
func clientIPKey(r *http.Request) (string, error) {
	return httprate.CanonicalizeIP(middleware.GetClientIP(r.Context())), nil // IPv6 bucketed by /64
}

func userKey(r *http.Request) (string, error) {
	return auth.GetUserID(r).String(), nil // only on routes behind Authenticate
}

func limitHandler(w http.ResponseWriter, r *http.Request) {
	response.RateLimitExceeded(w, r) // keep the JSON envelope
}

r.Use(middleware.ClientIPFromXFF("10.0.0.0/8"))
r.Use(httprate.LimitBy(100, time.Minute, clientIPKey, httprate.WithLimitHandler(limitHandler)))

r.Group(func(r chi.Router) { // authenticated: per user, per endpoint
	r.Use(middleware.Authenticate(jwtm, sessionVersion, sec))
	r.Use(httprate.LimitBy(60, time.Minute, httprate.JoinKeys(userKey, httprate.KeyByEndpoint),
		httprate.WithLimitHandler(limitHandler)))
})
```

Per-identifier limits inside a handler (OTP/login by phone number):

```go
var otpLimiter = httprate.NewRateLimiter(5, 10*time.Minute) // build in the handler constructor

if otpLimiter.RespondOnLimit(w, r, normalisedPhone) {
	return
}
```

Multiple instances: use the `github.com/go-chi/httprate-redis` backend via
`httprate.WithLimitCounter(...)` (see its README for setup) so limits are shared.

---

## go-chi/cors

```go
r.Use(cors.Handler(cors.Options{
	AllowedOrigins:   cfg.Cors.TrustedOrigins, // never "*" with credentials
	AllowedMethods:   []string{"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"},
	AllowedHeaders:   []string{"Authorization", "Content-Type", "X-API-Key", "Idempotency-Key"},
	ExposedHeaders:   []string{"Idempotent-Replayed", "Retry-After"},
	AllowCredentials: false,
	MaxAge:           300,
}))
```
