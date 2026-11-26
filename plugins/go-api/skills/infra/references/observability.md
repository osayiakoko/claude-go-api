# Observability: metrics, health, runtime vars

Dependencies: `github.com/prometheus/client_golang`.

## One registry, passed everywhere

Create it in `container.New` and pass it to anything that registers metrics (repos, router,
workers, external clients). Don't use the global default registry — it makes tests flaky.

```go
reg := prometheus.NewRegistry()
reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
```

Expose with `r.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))`. Keep
`/metrics`, `/debug/vars` and swagger off the public internet (internal network, or behind
the admin secret).

## HTTP metrics middleware

```go
type HTTPMetrics struct {
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
}

func NewHTTPMetrics(reg prometheus.Registerer) *HTTPMetrics {
	m := &HTTPMetrics{
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total", Help: "HTTP requests by route, method and status.",
		}, []string{"route", "method", "status"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "http_request_duration_seconds", Help: "HTTP request latency.",
			Buckets: prometheus.DefBuckets,
		}, []string{"route", "method"}),
	}
	reg.MustRegister(m.requests, m.duration)
	return m
}

func (m *HTTPMetrics) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := chimw.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		// Route PATTERN (/v1/debts/{id}), never the raw path — raw paths explode cardinality.
		route := chi.RouteContext(r.Context()).RoutePattern()
		if route == "" {
			route = "unmatched"
		}
		m.requests.WithLabelValues(route, r.Method, strconv.Itoa(ww.Status())).Inc()
		m.duration.WithLabelValues(route, r.Method).Observe(time.Since(start).Seconds())
	})
}
```

## External provider errors

```go
const (
	ProviderSMS = "sms"; ProviderPaystack = "paystack"; ProviderFlutterwave = "flutterwave"
	OpSend = "send"; OpInitializePayment = "initialize_payment"; OpVerify = "verify"
)

type ExternalMetrics struct {
	errors   *prometheus.CounterVec
	latency  *prometheus.HistogramVec
	breakers *prometheus.GaugeVec
}

func NewExternalMetrics(reg prometheus.Registerer) *ExternalMetrics {
	m := &ExternalMetrics{
		errors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "external_api_errors_total", Help: "Errors from outbound API calls.",
		}, []string{"provider", "operation"}),
		latency: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "external_api_duration_seconds", Help: "Outbound API latency.",
		}, []string{"provider", "operation"}),
		breakers: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "circuit_breaker_state", Help: "0 closed, 1 half-open, 2 open.",
		}, []string{"breaker"}),
	}
	reg.MustRegister(m.errors, m.latency, m.breakers)
	return m
}

func (m *ExternalMetrics) SetBreakerState(name string, state int) {
	if m != nil {
		m.breakers.WithLabelValues(name).Set(float64(state))
	}
}

// nil-safe so tests can pass nil.
func (m *ExternalMetrics) IncError(provider, op string) {
	if m != nil {
		m.errors.WithLabelValues(provider, op).Inc()
	}
}

func (m *ExternalMetrics) Observe(provider, op string, start time.Time) {
	if m != nil {
		m.latency.WithLabelValues(provider, op).Observe(time.Since(start).Seconds())
	}
}
```

## Worker metrics (adapter for worker.Metrics in jobs.md)

```go
type WorkerMetrics struct{ runs, errs *prometheus.CounterVec }

func NewWorkerMetrics(reg prometheus.Registerer) *WorkerMetrics {
	w := &WorkerMetrics{
		runs: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "worker_runs_total", Help: "Worker runs by job."}, []string{"job"}),
		errs: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "worker_errors_total", Help: "Worker errors by job."}, []string{"job"}),
	}
	reg.MustRegister(w.runs, w.errs)
	return w
}

func (w *WorkerMetrics) Run(job string)   { w.runs.WithLabelValues(job).Inc() }
func (w *WorkerMetrics) Error(job string) { w.errs.WithLabelValues(job).Inc() }
```

Also worth counting: auth failures by reason, API-key failures, rate-limited requests, cache
hits/misses, DB pool stats (`pool.Stat()` exported as gauges on a ticker).

## Health

- `GET /health` (liveness): always 200 with `{status, env, version}` — no dependencies.
- `GET /ready` (readiness): pings the DB pool with a 1–2s timeout; 503 if it fails. Point the
  load balancer / k8s readiness probe here so instances that lost the DB stop receiving traffic.

## Runtime vars

```go
expvar.NewString("version").Set(version)
expvar.Publish("goroutines", expvar.Func(func() any { return runtime.NumGoroutine() }))
r.Handle("/debug/vars", expvar.Handler()) // internal only
```

Label rules: never use user IDs, phone numbers, raw paths or error messages as label values.
