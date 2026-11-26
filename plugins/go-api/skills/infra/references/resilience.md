# Resilience: timeouts, idempotency, retries, circuit breakers, bulkheads, load shedding

Priority order — do the earlier ones first; each later one depends on them:

1. **Timeouts** on everything that can block.
2. **Idempotency** — safe client retries, and atomic check-then-act.
3. **Retries** with backoff + jitter, only for operations safe to repeat.
4. **Circuit breakers** per external dependency, with a fallback.
5. **Bulkheads / load shedding** so one slow dependency can't take the whole service down.
6. **Graceful degradation** and **singleflight** for hot cache keys.

Put resilience in the **adapter layer** (HTTP clients, middleware). Core services stay unaware,
except for idempotent business operations (atomic state transitions), which belong in core +
repository.

## 1. Timeouts

```go
// One tuned client per provider — never http.DefaultClient, never &http.Client{}.
func NewHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout, // hard cap on the whole exchange, incl. reading the body
		Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			DialContext:           (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			TLSHandshakeTimeout:   5 * time.Second,
			ResponseHeaderTimeout: timeout,
			IdleConnTimeout:       90 * time.Second,
			MaxIdleConns:          100,
			MaxIdleConnsPerHost:   20,
		},
	}
}
```

Suggested budgets: SMS/WhatsApp 10s, payments init/verify 15–30s, LLM 15–20s, internal
services 2–5s. Every outbound request uses `http.NewRequestWithContext(ctx, ...)` so the
caller's deadline also applies.

- **Server:** `http.Server{ReadHeaderTimeout: 5s, ReadTimeout: 10s, WriteTimeout: 30s, IdleTimeout: 60s}`
  plus chi's `middleware.Timeout(30*time.Second)` so handlers get a ctx deadline.
- **Postgres:** kill runaway queries and abandoned transactions on the server side:

  ```go
  poolCfg.ConnConfig.RuntimeParams["statement_timeout"] = "5000"                     // ms
  poolCfg.ConnConfig.RuntimeParams["idle_in_transaction_session_timeout"] = "10000" // ms
  ```
  Raise it for a known-slow report with `SET LOCAL statement_timeout = '30s'` inside its tx.
- **Workers:** each run gets `context.WithTimeout` (the `runEvery` helper does this). A worker
  ctx that never expires + a client without a timeout = a worker hung forever.
- **Shutdown:** bounded (e.g. 30s) — then exit.

## 2. Idempotency

### 2a. Idempotency keys for client retries

Mobile networks drop responses after the server has committed. Without a key, the app's
retry of `POST /transactions` records the expense twice. Require `Idempotency-Key` (a UUID the
client generates **once per user action** and reuses on every retry of that action) on
endpoints that create money-relevant records: transactions, transfers, repayments,
payments, payouts, loan applications.

Behaviour: first request runs; a concurrent duplicate gets **409 REQUEST_IN_PROGRESS**; a later
duplicate gets the **stored response replayed** (header `Idempotent-Replayed: true`); the same
key with a different body gets **422 IDEMPOTENCY_KEY_REUSED**; a 5xx releases the key so the
client can retry. Keys are scoped per caller (user ID) + method + path.

Middleware — `adapters/primary/http/middleware/idempotency.go` (tested, incl. `-race`):

```go
import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"sync"
	"time"
)

// Record is one remembered request.
type Record struct {
	RequestHash string
	Completed   bool
	StatusCode  int
	Body        []byte
	LockedAt    time.Time
}

// IdempotencyStore persists keys. Postgres implementation: see the table below.
type IdempotencyStore interface {
	// Begin inserts an in-progress record for key. If one already exists it returns it with
	// created=false. An in-progress record older than lease is taken over (created=true).
	Begin(ctx context.Context, key, requestHash string, lease time.Duration) (rec *Record, created bool, err error)
	// Complete stores the final response for replay.
	Complete(ctx context.Context, key string, status int, body []byte) error
	// Release deletes an in-progress record so the client can retry (used after 5xx).
	Release(ctx context.Context, key string) error
}

type IdempotencyConfig struct {
	Store    IdempotencyStore
	Required bool                       // reject requests without the header
	Lease    time.Duration              // how long an in-progress key blocks retries
	Scope    func(*http.Request) string // e.g. user ID; keys are per caller
	MaxBody  int64
}

const idempotencyHeader = "Idempotency-Key"

// Idempotency makes POST/PATCH handlers safe to retry: the first request with a key runs,
// concurrent duplicates get 409, later duplicates get the stored response replayed, and a
// key reused with a different body gets 422.
func Idempotency(cfg IdempotencyConfig) func(http.Handler) http.Handler {
	if cfg.Lease == 0 {
		cfg.Lease = time.Minute
	}
	if cfg.MaxBody == 0 {
		cfg.MaxBody = 1 << 20
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := r.Header.Get(idempotencyHeader)
			if key == "" {
				if cfg.Required {
					writeErr(w, http.StatusBadRequest, "IDEMPOTENCY_KEY_REQUIRED", "Idempotency-Key header is required")
					return
				}
				next.ServeHTTP(w, r)
				return
			}
			if len(key) > 255 {
				writeErr(w, http.StatusBadRequest, "BAD_REQUEST", "Idempotency-Key is too long")
				return
			}

			body, err := io.ReadAll(io.LimitReader(r.Body, cfg.MaxBody+1))
			if err != nil || int64(len(body)) > cfg.MaxBody {
				writeErr(w, http.StatusBadRequest, "BAD_REQUEST", "could not read request body")
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))

			scope := ""
			if cfg.Scope != nil {
				scope = cfg.Scope(r)
			}
			fullKey := scope + "|" + r.Method + "|" + r.URL.Path + "|" + key
			sum := sha256.Sum256(body)
			hash := hex.EncodeToString(sum[:])

			rec, created, err := cfg.Store.Begin(r.Context(), fullKey, hash, cfg.Lease)
			if err != nil {
				writeErr(w, http.StatusServiceUnavailable, "UNAVAILABLE", "please retry")
				return
			}
			if !created {
				switch {
				case rec.RequestHash != hash:
					writeErr(w, http.StatusUnprocessableEntity, "IDEMPOTENCY_KEY_REUSED",
						"this Idempotency-Key was used with a different request body")
				case !rec.Completed:
					w.Header().Set("Retry-After", "1")
					writeErr(w, http.StatusConflict, "REQUEST_IN_PROGRESS",
						"a request with this Idempotency-Key is still being processed")
				default:
					w.Header().Set("Content-Type", "application/json")
					w.Header().Set("Idempotent-Replayed", "true")
					w.WriteHeader(rec.StatusCode)
					_, _ = w.Write(rec.Body)
				}
				return
			}

			rw := &recorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rw, r)

			// Use a fresh ctx: the request ctx may already be cancelled.
			ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
			defer cancel()
			if rw.status >= 500 {
				_ = cfg.Store.Release(ctx, fullKey) // server failure: let the client retry
				return
			}
			_ = cfg.Store.Complete(ctx, fullKey, rw.status, rw.body.Bytes()) // 2xx and 4xx are replayed
		})
	}
}

type recorder struct {
	http.ResponseWriter
	status int
	body   bytes.Buffer
}

func (r *recorder) WriteHeader(code int) { r.status = code; r.ResponseWriter.WriteHeader(code) }
func (r *recorder) Write(p []byte) (int, error) {
	r.body.Write(p)
	return r.ResponseWriter.Write(p)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(`{"success":false,"error":{"code":"` + code + `","message":"` + msg + `"}}`))
}

// MemoryIdempotencyStore is for tests and single-instance dev only.
type MemoryIdempotencyStore struct {
	mu   sync.Mutex
	recs map[string]*Record
}

func NewMemoryIdempotencyStore() *MemoryIdempotencyStore {
	return &MemoryIdempotencyStore{recs: map[string]*Record{}}
}

func (s *MemoryIdempotencyStore) Begin(_ context.Context, key, hash string, lease time.Duration) (*Record, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if rec, ok := s.recs[key]; ok {
		if rec.Completed || time.Since(rec.LockedAt) < lease {
			cp := *rec
			return &cp, false, nil
		}
	}
	s.recs[key] = &Record{RequestHash: hash, LockedAt: time.Now()}
	return nil, true, nil
}

func (s *MemoryIdempotencyStore) Complete(_ context.Context, key string, status int, body []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.recs[key]
	if !ok {
		return errors.New("idempotency key not found")
	}
	rec.Completed, rec.StatusCode, rec.Body = true, status, append([]byte(nil), body...)
	return nil
}

func (s *MemoryIdempotencyStore) Release(_ context.Context, key string) error {
	s.mu.Lock()
	delete(s.recs, key)
	s.mu.Unlock()
	return nil
}
```

Wire it per route, after `Authenticate` so `Scope` can read the user ID:

```go
r.With(middleware.Idempotency(middleware.IdempotencyConfig{
	Store: idemStore, Required: true, Lease: time.Minute,
	Scope: func(r *http.Request) string { return auth.GetUserID(r).String() },
})).Post("/transactions", h.CreateTransaction)
```

Postgres store — table and `Begin`:

```sql
CREATE TABLE idempotency_keys (
  key           TEXT PRIMARY KEY,          -- scope|method|path|client key
  request_hash  TEXT NOT NULL,
  completed     BOOLEAN NOT NULL DEFAULT FALSE,
  status_code   INT,
  response_body BYTEA,
  locked_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idempotency_keys_created_at_idx ON idempotency_keys (created_at);
```

```go
func (s *idempotencyStore) Begin(ctx context.Context, key, hash string, lease time.Duration) (*Record, bool, error) {
	q := getQuerier(ctx, s.pool)
	// Insert, or take over an in-progress key whose lease expired (crashed request).
	tag, err := q.Exec(ctx, `
		INSERT INTO idempotency_keys (key, request_hash, locked_at) VALUES ($1, $2, NOW())
		ON CONFLICT (key) DO UPDATE
		  SET request_hash = EXCLUDED.request_hash, locked_at = NOW()
		  WHERE idempotency_keys.completed = FALSE AND idempotency_keys.locked_at < $3
	`, key, hash, time.Now().Add(-lease))
	if err != nil {
		return nil, false, err
	}
	if tag.RowsAffected() == 1 {
		return nil, true, nil
	}
	var rec Record
	err = q.QueryRow(ctx, `
		SELECT request_hash, completed, COALESCE(status_code, 0), COALESCE(response_body, ''::bytea), locked_at
		FROM idempotency_keys WHERE key = $1`, key,
	).Scan(&rec.RequestHash, &rec.Completed, &rec.StatusCode, &rec.Body, &rec.LockedAt)
	return &rec, false, err
}
```

`Complete` = `UPDATE ... SET completed = TRUE, status_code = $2, response_body = $3`;
`Release` = `DELETE ... WHERE key = $1 AND completed = FALSE`. Purge rows older than 24–72h
with a ticker worker. At high volume, Redis `SET key val NX PX <lease>` is an alternative store.

For the most critical writes (money movement), also store the client key on the business row
with a unique constraint (e.g. `transactions.client_request_id UNIQUE`) in the same transaction
— then even a middleware failure can't create a duplicate.

### 2b. Atomic check-then-act (webhooks, state transitions)

"Read status → if pending, do work → mark done" in separate statements is **not** idempotent:
two concurrent deliveries both see `pending`. Make the transition itself the guard, in one tx:

```go
func (s *subscriptionService) ConfirmPayment(ctx context.Context, p *external.PaymentWebhookPayload) error {
	return s.tx.WithTx(ctx, func(ctx context.Context) error {
		// Only one caller can move pending → processing; everyone else gets ok=false.
		payment, ok, err := s.paymentRepo.ClaimPending(ctx, p.Reference)
		if err != nil {
			return err
		}
		if !ok {
			return nil // already confirmed (or being confirmed) — idempotent no-op
		}
		if !payment.Amount.Equal(p.Amount) || payment.Currency != p.Currency {
			return &shareddomain.ErrValidation{Field: "amount", Message: "paid amount does not match"}
		}
		if err := s.subRepo.ExpireActive(ctx, payment.AccountID); err != nil {
			return err
		}
		sub, err := s.createActiveSubscription(ctx, payment)
		if err != nil {
			return err
		}
		return s.paymentRepo.MarkSuccessful(ctx, payment.ID, sub.ID, p) // all or nothing
	})
}
```

```sql
-- ClaimPending
UPDATE subscription_payments SET status = 'processing', updated_at = NOW()
WHERE reference = $1 AND status = 'pending'
RETURNING id, account_id, amount, currency, plan_name, billing_period;
```

Add a database guard for invariants too, e.g. at most one active subscription per account:
`CREATE UNIQUE INDEX one_active_sub ON subscriptions (account_id) WHERE status IN ('active','trial');`
Verify amounts against your own record (and, for payments, the provider's verify API) rather
than trusting the webhook body. Webhook/message consumers also dedup by provider event ID
(see `external.md`).

## 3. Retries with backoff + jitter — `internal/shared/resilience/retry.go` (tested)

```go
import (
	"context"
	"errors"
	"math/rand/v2"
	"net"
	"net/http"
	"strconv"
	"time"
)

type RetryPolicy struct {
	MaxAttempts int           // total attempts including the first (e.g. 3)
	BaseDelay   time.Duration // e.g. 200ms
	MaxDelay    time.Duration // e.g. 5s
	Retryable   func(error) bool
}

// RetryAfterError lets a call tell Retry how long the server asked us to wait.
type RetryAfterError struct {
	Err   error
	After time.Duration
}

func (e *RetryAfterError) Error() string { return e.Err.Error() }
func (e *RetryAfterError) Unwrap() error { return e.Err }

// Retry calls fn until it succeeds, returns a non-retryable error, attempts run out or ctx
// ends. Backoff is exponential with full jitter. Only wrap operations that are safe to
// repeat (reads, or writes carrying an idempotency key).
func Retry(ctx context.Context, p RetryPolicy, fn func(ctx context.Context) error) error {
	if p.MaxAttempts < 1 {
		p.MaxAttempts = 1
	}
	var err error
	for attempt := 1; ; attempt++ {
		if err = fn(ctx); err == nil {
			return nil
		}
		if attempt >= p.MaxAttempts || (p.Retryable != nil && !p.Retryable(err)) {
			return err
		}
		delay := backoff(p.BaseDelay, p.MaxDelay, attempt)
		var ra *RetryAfterError
		if errors.As(err, &ra) && ra.After > delay {
			delay = min(ra.After, p.MaxDelay)
		}
		t := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			t.Stop()
			return errors.Join(err, ctx.Err())
		case <-t.C:
		}
	}
}

func backoff(base, maxDelay time.Duration, attempt int) time.Duration {
	d := base << (attempt - 1)
	if d <= 0 || d > maxDelay {
		d = maxDelay
	}
	return time.Duration(rand.Int64N(int64(d) + 1)) // full jitter
}

// HTTPStatusError carries the status of a failed outbound call.
type HTTPStatusError struct{ Status int }

func (e *HTTPStatusError) Error() string { return "upstream returned " + strconv.Itoa(e.Status) }

// RetryableHTTP: retry network timeouts/resets and 429/502/503/504; never other 4xx.
func RetryableHTTP(err error) bool {
	if errors.Is(err, context.Canceled) {
		return false
	}
	var se *HTTPStatusError
	if errors.As(err, &se) {
		switch se.Status {
		case http.StatusTooManyRequests, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			return true
		}
		return false
	}
	var ne net.Error
	return errors.As(err, &ne) || errors.Is(err, context.DeadlineExceeded)
}

// ParseRetryAfter reads a Retry-After header given in seconds.
func ParseRetryAfter(h string) time.Duration {
	if s, err := strconv.Atoi(h); err == nil && s >= 0 {
		return time.Duration(s) * time.Second
	}
	return 0
}
```

Usage inside an adapter:

```go
err := resilience.Retry(ctx, resilience.RetryPolicy{
	MaxAttempts: 3, BaseDelay: 200 * time.Millisecond, MaxDelay: 3 * time.Second,
	Retryable: resilience.RetryableHTTP,
}, func(ctx context.Context) error {
	return c.send(ctx, req) // returns *HTTPStatusError / *RetryAfterError for non-2xx
})
```

Rules:
- Retry only **reads** and **writes that carry an idempotency key** the provider honours
  (Paystack/Flutterwave transfer `reference`, your own `disb-<loanID>`). Never blindly retry a
  non-idempotent POST to a payment provider — reconcile with its status/verify call instead.
- Keep in-request retries small (2–3 attempts, total well inside the request deadline). For
  longer horizons hand the work to a job (River attempts/backoff, Temporal activity
  `RetryPolicy`) instead of sleeping in a request.
- Don't stack retries at several layers (SDK + helper + job queue) — attempts multiply. Many
  SDKs retry by default (e.g. OpenAI's Go SDK); set their max retries explicitly.

## 4. Circuit breakers — `github.com/sony/gobreaker/v2`

When a provider is failing, stop calling it for a cool-down period and fail fast (or fall back)
instead of making every request wait for a timeout.

```go
func NewBreaker[T any](name string, m *metrics.ExternalMetrics, log logger.Logger) *gobreaker.CircuitBreaker[T] {
	return gobreaker.NewCircuitBreaker[T](gobreaker.Settings{
		Name:        name,
		MaxRequests: 3,                // trial calls allowed while half-open
		Interval:    60 * time.Second, // closed-state counts reset this often
		Timeout:     30 * time.Second, // open → half-open after this
		ReadyToTrip: func(c gobreaker.Counts) bool {
			return c.Requests >= 10 && float64(c.TotalFailures)/float64(c.Requests) >= 0.5
		},
		// Caller mistakes (4xx except 429) must not open the breaker.
		IsSuccessful: func(err error) bool {
			var se *resilience.HTTPStatusError
			return err == nil || (errors.As(err, &se) && se.Status < 500 && se.Status != 429)
		},
		OnStateChange: func(name string, from, to gobreaker.State) {
			log.Warn("circuit breaker state change", map[string]any{"breaker": name, "from": from.String(), "to": to.String()})
			m.SetBreakerState(name, int(to)) // gauge: 0 closed, 1 half-open, 2 open
		},
	})
}
```

Wrap the adapter. Composition order (outside → in): **bulkhead → breaker → retry → timeout → call**.

```go
type resilientSMS struct {
	inner external.SMSService
	cb    *gobreaker.CircuitBreaker[struct{}]
	bh    *resilience.Bulkhead
	retry resilience.RetryPolicy
}

func (s *resilientSMS) Send(ctx context.Context, to, msg string) error {
	return s.bh.Do(ctx, func(ctx context.Context) error {
		_, err := s.cb.Execute(func() (struct{}, error) {
			return struct{}{}, resilience.Retry(ctx, s.retry, func(ctx context.Context) error {
				return s.inner.Send(ctx, to, msg)
			})
		})
		if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
			return fmt.Errorf("sms provider unavailable: %w", err) // caller can fall back / enqueue
		}
		return err
	})
}
```

It implements the same port, so the container just wraps it:
`sms = resilience.NewResilientSMS(termii.New(cfg, extMetrics), ...)`. One breaker **per
provider** (per host/operation if one is much flakier) — never one global breaker.

## 5. Bulkheads and load shedding — `internal/shared/resilience/bulkhead.go` (tested)

```go
import (
	"context"
	"errors"
	"net/http"
)

var ErrBulkheadFull = errors.New("too many concurrent calls")

// Bulkhead caps concurrent calls to one dependency so a slow provider can't consume every
// goroutine and DB connection.
type Bulkhead struct{ slots chan struct{} }

func NewBulkhead(max int) *Bulkhead { return &Bulkhead{slots: make(chan struct{}, max)} }

// Do waits for a slot until ctx ends. Give ctx a short deadline to fail fast.
func (b *Bulkhead) Do(ctx context.Context, fn func(ctx context.Context) error) error {
	select {
	case b.slots <- struct{}{}:
	case <-ctx.Done():
		return errors.Join(ErrBulkheadFull, ctx.Err())
	}
	defer func() { <-b.slots }()
	return fn(ctx)
}

// LoadShed rejects requests with 503 once maxInFlight are already running, instead of
// queueing until everything times out. Put it early in the middleware chain.
func LoadShed(maxInFlight int) func(http.Handler) http.Handler {
	sem := make(chan struct{}, maxInFlight)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
				next.ServeHTTP(w, r)
			default:
				w.Header().Set("Retry-After", "1")
				writeErr(w, http.StatusServiceUnavailable, "OVERLOADED", "server is busy, please retry")
			}
		})
	}
}
```

- One bulkhead per provider, sized to what it (and your DB pool) can handle — e.g. WhatsApp
  20, LLM 5. Give ctx a short deadline when acquiring so callers fail fast.
- `LoadShed` near the top of the middleware chain (after recoverer/request ID); size it from
  load tests. Exempt `/health`.
- Don't let background work exhaust the DB pool: give workers their own small pool or a bulkhead.

## 6. Graceful degradation and stampede protection

- **Fallbacks when a dependency is down:** queue the notification (River) instead of failing
  the user's request; serve cached data marked stale; use the deterministic path (rule-based
  parser) when the LLM breaker is open; disable a non-essential feature behind a flag.
  Decide per dependency: *must succeed* (payments → fail clearly) vs *nice to have*
  (notifications, analytics → degrade with a metric).
- **Singleflight** (`golang.org/x/sync/singleflight`) collapses concurrent cache misses for the
  same key into one DB/provider call:

  ```go
  var group singleflight.Group

  func (r *planRepository) GetAll(ctx context.Context) ([]*subdomain.Plan, error) {
  	if plans, ok := r.fromCache(ctx); ok {
  		return plans, nil
  	}
  	v, err, _ := group.Do("plans:all", func() (any, error) {
  		return r.loadAndCache(ctx)
  	})
  	if err != nil {
  		return nil, err
  	}
  	return v.([]*subdomain.Plan), nil
  }
  ```
- **Readiness:** `/ready` fails when the DB is unreachable so the load balancer stops routing;
  don't fail readiness for optional providers (that turns a provider outage into a full outage).

## Testing resilience

- Idempotency: same key twice → one side effect + replay; concurrent duplicate → 409;
  different body → 422; 5xx → retry allowed. Run with `-race`.
- Atomic transitions: fire the same webhook from N goroutines → exactly one subscription.
- Retry: 503 then 200 → success; 400 → no retry; ctx cancelled → stops.
- Breaker: N failures → `ErrOpenState` without calling the provider; after `Timeout` → trial call.
- Timeouts: an `httptest.Server` that sleeps past the client timeout → error within budget.
