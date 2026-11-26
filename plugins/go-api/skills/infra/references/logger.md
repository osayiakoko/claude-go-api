# Logger

- **full** projects: zerolog behind an app-owned `Logger` interface (below).
- **lite** projects: `log/slog` from the standard library is fine
  (`slog.New(slog.NewJSONHandler(os.Stdout, nil))`, text handler locally).
- **Upgrading lite → zerolog:** add `internal/shared/logger` (or a root `logger.go` in a flat
  project) with the code below, replace every `slog.*` / `*slog.Logger` call site with the
  `Logger` interface (`log.Info("msg", map[string]any{"k": v})`), wire it in `main.go`, inject
  it into anything that logged, and add the request-logging middleware. Remove `slog` usage
  completely — one logger per project.

Dependencies: `github.com/rs/zerolog`, `github.com/rs/zerolog/pkgerrors`.

## Interface and zerolog implementation — `internal/shared/logger/logger.go`

```go
package logger

type Level int8

const (
	DebugLevel Level = iota
	InfoLevel
	WarnLevel
	ErrorLevel
	FatalLevel
	PanicLevel
)

// Logger is the only logging type the rest of the app sees. Error/Fatal/Panic accept
// an error or a string.
type Logger interface {
	Debug(msg string, props map[string]any)
	Info(msg string, props map[string]any)
	Warn(msg string, props map[string]any)
	Error(msg any, props map[string]any)
	Fatal(msg any, props map[string]any)
	Panic(msg any, props map[string]any)
	With(props map[string]any) Logger
}

type zerologLogger struct{ logger zerolog.Logger }

var (
	globalLogger Logger
	once         sync.Once
)

func InitLogger(level Level) { once.Do(func() { globalLogger = New(level) }) }

func GetLogger() Logger {
	if globalLogger == nil {
		InitLogger(InfoLevel)
	}
	return globalLogger
}

func New(level Level) Logger { return NewWithWriter(os.Stdout, level) }

// Debug level → human-readable console output; every other level → JSON for log aggregation.
func NewWithWriter(out io.Writer, level Level) Logger {
	zerolog.TimeFieldFormat = time.RFC3339
	zerolog.ErrorStackMarshaler = pkgerrors.MarshalStack
	zerolog.SetGlobalLevel(toZerologLevel(level))

	var zl zerolog.Logger
	if level == DebugLevel {
		zl = zerolog.New(zerolog.ConsoleWriter{Out: out}).With().Timestamp().Logger()
	} else {
		zl = zerolog.New(out).With().Timestamp().Logger()
	}
	return &zerologLogger{logger: zl}
}

func (l *zerologLogger) log(e *zerolog.Event, msg string, props map[string]any) {
	if props != nil {
		e.Interface("properties", props)
	}
	e.Msg(msg)
}

func (l *zerologLogger) Debug(m string, p map[string]any) { l.log(l.logger.Debug(), m, p) }
func (l *zerologLogger) Info(m string, p map[string]any)  { l.log(l.logger.Info(), m, p) }
func (l *zerologLogger) Warn(m string, p map[string]any)  { l.log(l.logger.Warn(), m, p) }
func (l *zerologLogger) Error(m any, p map[string]any)    { l.log(l.logger.Error(), msgOf(m), p) }
func (l *zerologLogger) Fatal(m any, p map[string]any)    { l.log(l.logger.Fatal(), msgOf(m), p) }
func (l *zerologLogger) Panic(m any, p map[string]any)    { l.log(l.logger.Panic(), msgOf(m), p) }

func (l *zerologLogger) With(fields map[string]any) Logger {
	return &zerologLogger{logger: l.logger.With().Fields(fields).Logger()}
}

func msgOf(m any) string {
	switch v := m.(type) {
	case error:
		return v.Error()
	case string:
		return v
	default:
		return fmt.Sprintf("%v", v)
	}
}

func toZerologLevel(l Level) zerolog.Level {
	switch l {
	case DebugLevel:
		return zerolog.DebugLevel
	case WarnLevel:
		return zerolog.WarnLevel
	case ErrorLevel:
		return zerolog.ErrorLevel
	case FatalLevel:
		return zerolog.FatalLevel
	case PanicLevel:
		return zerolog.PanicLevel
	default:
		return zerolog.InfoLevel
	}
}

// NewStandardLogger adapts Logger to *log.Logger for http.Server.ErrorLog and libraries.
func NewStandardLogger(l Logger) *log.Logger { return log.New(&stdAdapter{l}, "", 0) }

type stdAdapter struct{ l Logger }

func (a *stdAdapter) Write(p []byte) (int, error) {
	a.l.Error(string(bytes.TrimSpace(p)), nil)
	return len(p), nil
}
```

`noop.go`: `func NewNoOpLogger() Logger` with empty methods (`With` returns itself) — use in tests.

## Context-scoped logger — `context.go`

```go
type contextKey struct{}

func WithCtx(ctx context.Context, l Logger) context.Context {
	return context.WithValue(ctx, contextKey{}, l)
}

// FromCtx returns the request-scoped logger (carries request_id), or the global one.
func FromCtx(ctx context.Context) Logger {
	if l, ok := ctx.Value(contextKey{}).(Logger); ok {
		return l
	}
	return GetLogger()
}
```

## main.go level selection

```go
stat, _ := os.Stdout.Stat()
if cfg.Env.IsDevelopment() && stat.Mode()&os.ModeCharDevice != 0 {
	logger.InitLogger(logger.DebugLevel) // readable console when run in a terminal
} else {
	logger.InitLogger(logger.InfoLevel) // JSON in Docker/CI/staging/prod
}
```

Pass `logger.NewStandardLogger(log)` as `http.Server.ErrorLog`.

## Request logging middleware — `adapters/primary/http/middleware/logger_middleware.go`

Behaviour:
1. Scope a logger with `request_id` (from chi `middleware.RequestID`) and put it in ctx.
2. Skip infra paths (`/health`, `/metrics`, `/debug/vars`, swagger).
3. Capture up to 64KB of a JSON request body and restore `r.Body` for the handler.
4. Put an internal-error capture slot in ctx (see http-kit) so a 500 logs its real cause.
5. Wrap the writer to capture status + up to 64KB of response body (forward `Flush`).
6. Always log one `http request` line: method, path, status, duration.
7. For status ≥ 400 log Warn (4xx) / Error (5xx) with query, **redacted** request body,
   response body and, for 5xx, the captured internal error.

## Redaction — `redact.go` (recursive, applied in every environment)

```go
// Keys are stored normalised (lowercase, letters/digits only).
var sensitiveKeys = map[string]bool{
	"password": true, "pin": true, "newpin": true, "otp": true, "token": true,
	"accesstoken": true, "refreshtoken": true, "devicetoken": true, "secret": true,
	"key": true, "apikey": true, "authorization": true, "bvn": true, "nin": true,
	"accountnumber": true, "cardnumber": true, "cvv": true, "pan": true,
}

// normaliseKey makes "refreshToken", "Refresh-Token", "refresh_token" and "REFRESH_TOKEN"
// all become "refreshtoken".
func normaliseKey(k string) string {
	var b strings.Builder
	for _, r := range k {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return b.String()
}

// redact walks maps and slices at any depth and masks sensitive values.
func redact(v any) any {
	switch t := v.(type) {
	case map[string]any:
		for k, val := range t {
			if sensitiveKeys[normaliseKey(k)] {
				t[k] = "[REDACTED]"
			} else {
				t[k] = redact(val)
			}
		}
		return t
	case []any:
		for i := range t {
			t[i] = redact(t[i])
		}
		return t
	default:
		return v
	}
}

func redactJSON(data []byte) any {
	var v any
	if json.Unmarshal(data, &v) != nil {
		return nil
	}
	return redact(v)
}
```

Never log full headers (Authorization, X-API-Key, cookies). Log phone numbers masked
(`+234****5678`) if they must appear.
