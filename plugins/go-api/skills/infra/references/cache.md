# Cache

Pattern: a small `Store` interface + **decorators** that wrap a repository port and return the
same port. Core never knows caching exists. Writes evict immediately; TTL is only a safety net.

## Store — `adapters/secondary/cache/store.go`

```go
package cache

// Store is the cache backend contract. Swap memory ↔ Redis in container/repos.go.
type Store interface {
	Get(ctx context.Context, key string) ([]byte, bool, error)
	Set(ctx context.Context, key string, val []byte, ttl time.Duration) error
	Delete(ctx context.Context, keys ...string) error
}
```

## In-memory store — `cache/memory/store.go`

```go
type entry struct {
	val       []byte
	expiresAt time.Time
}

type Store struct {
	mu   sync.RWMutex
	data map[string]entry
}

// NewStore starts a janitor that stops when ctx is cancelled (pass the server's bg ctx).
func NewStore(ctx context.Context, sweepEvery time.Duration) *Store {
	s := &Store{data: make(map[string]entry)}
	go func() {
		t := time.NewTicker(sweepEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-t.C:
				s.mu.Lock()
				for k, e := range s.data {
					if now.After(e.expiresAt) {
						delete(s.data, k)
					}
				}
				s.mu.Unlock()
			}
		}
	}()
	return s
}

func (s *Store) Get(_ context.Context, key string) ([]byte, bool, error) {
	s.mu.RLock()
	e, ok := s.data[key]
	s.mu.RUnlock()
	if !ok || time.Now().After(e.expiresAt) {
		return nil, false, nil
	}
	return e.val, true, nil
}

func (s *Store) Set(_ context.Context, key string, val []byte, ttl time.Duration) error {
	s.mu.Lock()
	s.data[key] = entry{val: val, expiresAt: time.Now().Add(ttl)}
	s.mu.Unlock()
	return nil
}

func (s *Store) Delete(_ context.Context, keys ...string) error {
	s.mu.Lock()
	for _, k := range keys {
		delete(s.data, k)
	}
	s.mu.Unlock()
	return nil
}
```

## Redis store (multi-instance) — `cache/redis/store.go`

`github.com/redis/go-redis/v9`:

```go
type Store struct{ rdb *redis.Client }

func (s *Store) Get(ctx context.Context, key string) ([]byte, bool, error) {
	b, err := s.rdb.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, false, nil
	}
	return b, err == nil, err
}
func (s *Store) Set(ctx context.Context, k string, v []byte, ttl time.Duration) error {
	return s.rdb.Set(ctx, k, v, ttl).Err()
}
func (s *Store) Delete(ctx context.Context, keys ...string) error {
	return s.rdb.Del(ctx, keys...).Err()
}
```

Use the in-memory store only while you run a single instance — with several instances each
holds its own copy and evictions don't propagate.

## Decorator — `cache/user_cache.go`

```go
var _ userrepos.UserRepository = (*userRepository)(nil)

type userRepository struct {
	inner userrepos.UserRepository
	store Store
	ttl   time.Duration
}

func NewUserRepository(inner userrepos.UserRepository, store Store, ttl time.Duration) userrepos.UserRepository {
	return &userRepository{inner: inner, store: store, ttl: ttl}
}

func userKey(id uuid.UUID) string { return "user:" + id.String() }

func (r *userRepository) GetByID(ctx context.Context, id uuid.UUID) (*userdomain.User, error) {
	if b, ok, _ := r.store.Get(ctx, userKey(id)); ok { // cache errors never fail the request
		var u userdomain.User
		if json.Unmarshal(b, &u) == nil {
			return &u, nil
		}
	}
	u, err := r.inner.GetByID(ctx, id)
	if err != nil {
		return nil, err // never cache errors / not-found
	}
	if b, err := json.Marshal(u); err == nil {
		_ = r.store.Set(ctx, userKey(id), b, r.ttl)
	}
	return u, nil
}

func (r *userRepository) Update(ctx context.Context, u *userdomain.User) error {
	if err := r.inner.Update(ctx, u); err != nil {
		return err
	}
	_ = r.store.Delete(ctx, userKey(u.ID)) // evict after a successful write
	return nil
}

// Methods that aren't cached just delegate:
func (r *userRepository) Create(ctx context.Context, u *userdomain.User) error {
	return r.inner.Create(ctx, u)
}
```

Wiring: `r.user = cache.NewUserRepository(postgres.NewUserRepository(pool), store, 5*time.Minute)`.

## Rules

- Cache **reads that are hot and tolerate a few minutes of staleness**: users, plans,
  categories, capability lists, config. Don't cache balances, payment status, or anything on
  a checkout/disbursement path where correctness beats speed.
- **Writes inside a transaction:** evict *after* commit, or a concurrent reader can repopulate
  the cache with the pre-commit value. Simplest: evict in the decorator (fine for low-contention
  data) and also evict again in the service after `WithTx` returns for hot keys.
- Keys: `<entity>:<id>` and `<entity>:list:<scope>`; when a write affects a list, delete both.
- Serialize with JSON; make sure domain structs round-trip (exported fields, `decimal` is fine).
- Add cache hit/miss counters if you need to tune TTLs (see observability).
