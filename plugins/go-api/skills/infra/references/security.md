# Security: JWT, auth middleware, API keys, admin, rate limiting, CORS

Dependencies: `github.com/golang-jwt/jwt/v5`, `golang.org/x/time/rate`.

## JWT — `internal/shared/auth/jwt.go`

Typed tokens (access / refresh / device) so one can't be used as another, HMAC-only, and a
`SessionVersion` claim that lets you revoke every token for a user without a token store.

```go
var (
	ErrInvalidToken         = errors.New("invalid token")
	ErrExpiredToken         = errors.New("token has expired")
	ErrWrongTokenType       = errors.New("wrong token type")
	ErrInvalidSigningMethod = errors.New("unexpected signing method")
	ErrNoTokenProvided      = errors.New("no token provided")
	ErrSessionInvalidated   = errors.New("session has been invalidated, please log in again")
)

type TokenType string

const (
	TokenTypeAccess  TokenType = "access"
	TokenTypeRefresh TokenType = "refresh"
	TokenTypeDevice  TokenType = "device"
)

type Claims struct {
	UserID         uuid.UUID `json:"uid"`
	TokenType      TokenType `json:"typ"`
	SessionVersion int       `json:"sv"`
	jwt.RegisteredClaims
}

type JWTConfig struct {
	Secret          string        // ≥ 32 random bytes; from env, never committed
	Issuer          string
	AccessTokenTTL  time.Duration // e.g. 15m
	RefreshTokenTTL time.Duration // e.g. 30d
	DeviceTokenTTL  time.Duration
}

type JWTManager interface {
	GenerateAccessToken(userID uuid.UUID, sessionVersion int) (string, error)
	GenerateRefreshToken(userID uuid.UUID, sessionVersion int) (string, error)
	VerifyAccessToken(token string) (*Claims, error)
	VerifyRefreshToken(token string) (*Claims, error)
	ExtractTokenFromHeader(r *http.Request) (string, error)
}

func (m *jwtManager) generate(userID uuid.UUID, typ TokenType, sv int, ttl time.Duration) (string, error) {
	now := time.Now()
	claims := Claims{
		UserID: userID, TokenType: typ, SessionVersion: sv,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    m.cfg.Issuer,
			Subject:   userID.String(),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
			ID:        uuid.NewString(),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(m.secret)
}

func (m *jwtManager) verify(tokenStr string, expected TokenType) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok { // block alg=none / RS→HS confusion
			return nil, ErrInvalidSigningMethod
		}
		return m.secret, nil
	}, jwt.WithIssuer(m.cfg.Issuer), jwt.WithLeeway(30*time.Second))
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return nil, ErrExpiredToken
		}
		return nil, ErrInvalidToken
	}
	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, ErrInvalidToken
	}
	if claims.TokenType != expected {
		return nil, ErrWrongTokenType
	}
	return claims, nil
}

func (m *jwtManager) ExtractTokenFromHeader(r *http.Request) (string, error) {
	h := r.Header.Get("Authorization")
	if h == "" {
		return "", ErrNoTokenProvided
	}
	scheme, tok, ok := strings.Cut(h, " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") || tok == "" {
		return "", ErrInvalidToken
	}
	return tok, nil
}
```

## Request context — `internal/shared/auth/context.go`

```go
type ctxKey struct{}

func SetUserID(r *http.Request, id uuid.UUID) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), ctxKey{}, id))
}

// GetUserID is for handlers behind Authenticate; panics only on a wiring bug.
func GetUserID(r *http.Request) uuid.UUID {
	id, ok := TryGetUserID(r)
	if !ok {
		panic("auth.GetUserID called on an unauthenticated route")
	}
	return id
}

func TryGetUserID(r *http.Request) (uuid.UUID, bool) {
	id, ok := r.Context().Value(ctxKey{}).(uuid.UUID)
	return id, ok
}
```

## Authenticate middleware

```go
// SessionVersionChecker returns users.session_version (cache it — see cache.md).
type SessionVersionChecker func(ctx context.Context, userID uuid.UUID) (int, error)

func Authenticate(jm auth.JWTManager, checkVersion SessionVersionChecker, sec *SecurityMetrics) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Add("Vary", "Authorization")
			tok, err := jm.ExtractTokenFromHeader(r)
			if err != nil {
				sec.IncAuthFailure("invalid_token")
				response.InvalidAuthenticationToken(w, r, err)
				return
			}
			claims, err := jm.VerifyAccessToken(tok)
			if errors.Is(err, auth.ErrExpiredToken) {
				sec.IncAuthFailure("expired_token")
				response.ExpiredAuthenticationToken(w, r) // 401 TOKEN_EXPIRED → client refreshes
				return
			}
			if err != nil {
				sec.IncAuthFailure("invalid_token")
				response.InvalidAuthenticationToken(w, r, err) // 401 INVALID_TOKEN → client logs out
				return
			}
			current, err := checkVersion(r.Context(), claims.UserID)
			if err != nil {
				response.ServerError(w, r, err) // DB problem is not the client's fault
				return
			}
			if current != claims.SessionVersion {
				sec.IncAuthFailure("session_invalidated")
				response.InvalidAuthenticationToken(w, r, auth.ErrSessionInvalidated)
				return
			}
			next.ServeHTTP(w, auth.SetUserID(r, claims.UserID))
		})
	}
}
```

Session version: increment `users.session_version` on logout-everywhere, password/PIN change,
phone change, admin block. Every old token fails on the next request. Refresh flow:
`VerifyRefreshToken` → check session version → issue a new access token (and rotate the
refresh token). Store PINs/passwords with `golang.org/x/crypto/bcrypt` (or argon2id), never
reversible.

## API keys (client apps)

Store only `sha256(key)`; look up by hash; cache valid hashes briefly.

```go
type APIKeyChecker func(ctx context.Context, keyHash string) (bool, error)

func RequireAPIKey(check APIKeyChecker, sec *SecurityMetrics) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw := r.Header.Get("X-API-Key")
			if raw == "" {
				sec.IncAPIKeyFailure()
				response.InvalidAPIKey(w, r)
				return
			}
			sum := sha256.Sum256([]byte(raw))
			ok, err := check(r.Context(), hex.EncodeToString(sum[:]))
			if err != nil || !ok {
				sec.IncAPIKeyFailure()
				response.InvalidAPIKey(w, r)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// WithAPIKeyCache caches only VALID keys for ttl (revocation takes ≤ ttl). Invalid results
// and errors are never cached, so a new key works immediately.
func WithAPIKeyCache(check APIKeyChecker, ttl time.Duration) APIKeyChecker {
	var mu sync.RWMutex
	cache := map[string]time.Time{}
	return func(ctx context.Context, hash string) (bool, error) {
		mu.RLock()
		exp, hit := cache[hash]
		mu.RUnlock()
		if hit && time.Now().Before(exp) {
			return true, nil
		}
		ok, err := check(ctx, hash)
		if err != nil || !ok {
			return false, err
		}
		mu.Lock()
		cache[hash] = time.Now().Add(ttl)
		mu.Unlock()
		return true, nil
	}
}
```

Makefile target to mint a key: `openssl rand -hex 32`, print the key once and its sha256
for the INSERT.

## Admin / operator secret — constant-time, fail closed

```go
func RequireAdminSecret(secret string) func(http.Handler) http.Handler {
	want := []byte(secret)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			got := []byte(r.Header.Get("X-Admin-Secret"))
			if len(want) == 0 || subtle.ConstantTimeCompare(got, want) != 1 {
				response.Unauthorized(w, r, nil)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
```

Never compare secrets, signatures or hashes with `==`/`!=`.

## Rate limiting (per client, token bucket)

```go
type RateLimiter struct {
	mu      sync.Mutex
	clients map[string]*rlClient
	rps     rate.Limit
	burst   int
}

type rlClient struct {
	lim      *rate.Limiter
	lastSeen time.Time
}

// NewRateLimiter's janitor stops when ctx is cancelled (pass the server bg ctx).
func NewRateLimiter(ctx context.Context, rps float64, burst int) *RateLimiter {
	rl := &RateLimiter{clients: map[string]*rlClient{}, rps: rate.Limit(rps), burst: burst}
	go func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				rl.mu.Lock()
				for k, c := range rl.clients {
					if time.Since(c.lastSeen) > 3*time.Minute {
						delete(rl.clients, k)
					}
				}
				rl.mu.Unlock()
			}
		}
	}()
	return rl
}

func (rl *RateLimiter) Middleware(keyFn func(*http.Request) string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := keyFn(r)
			rl.mu.Lock()
			c, ok := rl.clients[key]
			if !ok {
				c = &rlClient{lim: rate.NewLimiter(rl.rps, rl.burst)}
				rl.clients[key] = c
			}
			c.lastSeen = time.Now()
			allowed := c.lim.Allow()
			rl.mu.Unlock()
			if !allowed {
				w.Header().Set("Retry-After", "1")
				response.RateLimitExceeded(w, r) // 429
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
```

**Client IP:** `chi/middleware.RealIP` trusts `X-Forwarded-For`/`X-Real-IP` from anyone, so a
caller can rotate a fake IP per request and bypass per-IP limits. Only use it when the app is
reachable **only** through your proxy/load balancer and that proxy overwrites those headers;
otherwise key on `r.RemoteAddr`. Prefer keying authenticated routes by user ID, and give
OTP/login/PIN endpoints their own stricter limiter (e.g. 5/min per phone number + per IP).
With several instances, use a shared store (Redis) or limit at the gateway.

## CORS and headers

Allow-list origins from config (`CORS_TRUSTED_ORIGINS`); never `*` with credentials. Set
`Vary: Origin`. Add `X-Content-Type-Options: nosniff` and `Cache-Control: no-store` on
authenticated JSON responses.

## Router wiring order

```go
// Add chimw.RealIP after RequestID ONLY when behind a trusted proxy (see above).
r.Use(middleware.Recoverer(log), chimw.RequestID,
	middleware.RequestLogger(log, isProd), chimw.Timeout(60*time.Second),
	middleware.CORS(cfg.Cors.TrustedOrigins), middleware.Metrics(reg))
r.Route("/v1", func(r chi.Router) {
	r.Use(middleware.RequireAPIKey(apiKeyCheck, sec))
	r.Use(rl.Middleware(clientIP))
	r.Group(func(r chi.Router) { /* public: register, login, otp (stricter limiter) */ })
	r.Group(func(r chi.Router) {
		r.Use(middleware.Authenticate(jwtm, sessionVersion, sec))
		/* authenticated routes */
	})
})
r.Route("/admin", func(r chi.Router) { r.Use(middleware.RequireAdminSecret(cfg.Admin.Secret)) })
```

Tests: expired vs invalid vs wrong-type tokens, session-version mismatch, missing/invalid API
key, admin secret empty → always rejected, limiter returns 429 after burst.
