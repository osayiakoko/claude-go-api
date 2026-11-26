# Background jobs

## Choose the mechanism

| Need | Use | Why |
|---|---|---|
| Housekeeping on a timer (delete expired OTPs, purge old rows) where running twice is harmless | **Ticker worker** (`runEvery`) | No infra, trivial |
| A periodic job that must run **exactly once per slot** across all instances (monthly snapshot, weekly summary) | **RunOnce** + `scheduled_jobs` table | Postgres row = lock + audit trail |
| One-off work triggered by a request (send receipt SMS, call webhook, generate PDF), retries with backoff, enqueued **atomically with the data change** | **River** (Postgres-backed queue) | `InsertTx` in the same tx as the business write — no lost or phantom jobs; no Redis |
| Already running Redis and want a queue + dashboard | **Asynq** | Redis-backed, simple API — but enqueue isn't transactional with Postgres (use an outbox) |
| Long-running, multi-step processes with external parties and compensation (loan disbursement → repayment schedule → collections; KYC pipelines; payouts) | **Temporal** | Durable execution: state survives crashes/deploys, per-step retries/timeouts, timers measured in days or months, full history per workflow |

Default for a single service on Postgres: ticker + RunOnce for schedules, River for queued
work. Reach for Temporal when the *process* (not the individual job) is the thing you need to
be reliable and observable.

All in-process workers: own them in `container/workers.go`, run them on the server's
WaitGroup, stop them via the shared background ctx that is cancelled on shutdown.

## 1. Ticker worker helper — `internal/shared/worker/run_every.go`

Removes the copy-pasted ticker/select/panic/metrics block per worker.

```go
package worker

// Metrics is satisfied by a small Prometheus adapter (see observability.md).
type Metrics interface {
	Run(job string)
	Error(job string)
}

type Spec struct {
	Name       string
	Every      time.Duration
	RunOnStart bool // run once immediately instead of waiting a full interval
	Timeout    time.Duration // per-run timeout; 0 = Every
	Fn         func(ctx context.Context) error
}

// Start runs spec.Fn every spec.Every until ctx is cancelled. Panics inside Fn are
// recovered and logged so one bad run doesn't kill the worker.
func Start(ctx context.Context, wg *sync.WaitGroup, log logger.Logger, m Metrics, spec Spec) {
	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(spec.Every)
		defer t.Stop()
		if spec.RunOnStart {
			runSafely(ctx, log, m, spec)
		}
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				runSafely(ctx, log, m, spec)
			}
		}
	}()
}

func runSafely(ctx context.Context, log logger.Logger, m Metrics, spec Spec) {
	timeout := spec.Timeout
	if timeout == 0 {
		timeout = spec.Every
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	defer func() {
		if r := recover(); r != nil {
			m.Error(spec.Name)
			log.Error("worker panicked", map[string]any{"job": spec.Name, "panic": fmt.Sprint(r)})
		}
	}()
	m.Run(spec.Name)
	if err := spec.Fn(runCtx); err != nil {
		m.Error(spec.Name)
		log.Error("worker run failed", map[string]any{"job": spec.Name, "error": err.Error()})
	}
}
```

Usage in `workers.go`:

```go
worker.Start(bgCtx, wg, log, wm, worker.Spec{
	Name: "otp_cleanup", Every: 24 * time.Hour, RunOnStart: true,
	Fn: func(ctx context.Context) error { return r.otp.DeleteExpired(ctx) },
})
```

## 2. RunOnce — exactly once per time slot

Table:

```sql
CREATE TABLE scheduled_jobs (
  id            UUID PRIMARY KEY,
  job_type      TEXT NOT NULL,
  account_id    UUID NULL REFERENCES accounts(id) ON DELETE CASCADE,
  scheduled_for TIMESTAMPTZ NOT NULL,
  status        TEXT NOT NULL DEFAULT 'pending', -- pending | running | done | failed
  attempts      INT  NOT NULL DEFAULT 0,
  max_attempts  INT  NOT NULL DEFAULT 3,
  payload       JSONB,
  last_error    TEXT,
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  version       INT  NOT NULL DEFAULT 1,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- one row per (type, slot) globally, and per (type, slot, account) for account jobs
CREATE UNIQUE INDEX scheduled_jobs_global_uq  ON scheduled_jobs (job_type, scheduled_for) WHERE account_id IS NULL;
CREATE UNIQUE INDEX scheduled_jobs_account_uq ON scheduled_jobs (job_type, scheduled_for, account_id) WHERE account_id IS NOT NULL;
```

Service:

```go
// RunOnce runs fn at most once successfully for (jobType, accountID, scheduledFor).
// fn MUST be idempotent: if the process dies after fn succeeds but before Complete,
// the slot is retried once its lease expires.
func (s *scheduledJobService) RunOnce(ctx context.Context, jobType string, accountID *uuid.UUID,
	scheduledFor time.Time, payload map[string]any, fn func(ctx context.Context) error) error {

	if err := s.repo.Upsert(ctx, newJob(jobType, accountID, scheduledFor, payload)); err != nil {
		return err // INSERT ... ON CONFLICT DO NOTHING
	}
	job, err := s.repo.GetBySlot(ctx, jobType, accountID, scheduledFor)
	if err != nil {
		return err
	}
	if job.Status == jobdomain.JobStatusDone || (job.Status == jobdomain.JobStatusFailed && !job.IsRetryable()) {
		return nil
	}
	claimed, err := s.repo.Claim(ctx, job.ID, job.Version, s.lease)
	if err != nil || !claimed {
		return err // lost the race (or a live run holds the lease)
	}
	if runErr := fn(ctx); runErr != nil {
		if err := s.repo.Fail(ctx, job.ID, runErr.Error()); err != nil {
			s.log.Error("scheduledjob: mark failed", map[string]any{"job_id": job.ID, "error": err.Error()})
		}
		return runErr
	}
	return s.repo.Complete(ctx, job.ID)
}
```

Claim **with a lease** — a job left `running` by a crashed/killed process becomes claimable
again once `started_at` is older than the lease (set the lease well above the job's normal
runtime, e.g. 30 min):

```go
func (r *scheduledJobRepository) Claim(ctx context.Context, id uuid.UUID, version int, lease time.Duration) (bool, error) {
	q := getQuerier(ctx, r.pool)
	tag, err := q.Exec(ctx, `
		UPDATE scheduled_jobs
		SET    status = 'running', started_at = NOW(), attempts = attempts + 1,
		       version = version + 1, updated_at = NOW()
		WHERE  id = $1 AND version = $2
		  AND  attempts < max_attempts
		  AND  ( status IN ('pending', 'failed')
		         OR (status = 'running' AND started_at < $3) )
	`, id, version, time.Now().Add(-lease))
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}
```

`Fail` sets `status = CASE WHEN attempts < max_attempts THEN 'pending' ELSE 'failed' END`
and stores `last_error`. Add a cleanup worker for done rows > 30 days and failed > 90 days,
and alert on `failed` rows.

Trigger from a ticker that runs more often than the slot (e.g. hourly tick; inside, compute
the current slot such as "Sunday 00:00 Africa/Lagos" and call RunOnce if now ≥ slot). Always
compute slots in an explicit `time.Location`.

## 3. River — Postgres-backed queue

Dependencies: `github.com/riverqueue/river`, `github.com/riverqueue/river/riverdriver/riverpgxv5`.
River needs its own tables: run `river migrate-up --database-url "$DATABASE_URL"` (CLI:
`go install github.com/riverqueue/river/cmd/river@latest`) or export its migrations into
`migrations/postgres` so golang-migrate owns them.

Job + worker (adapter layer, e.g. `adapters/secondary/jobs/receipt_job.go`):

```go
type SendReceiptArgs struct {
	TransactionID uuid.UUID `json:"transaction_id"`
}

func (SendReceiptArgs) Kind() string { return "send_receipt" }

type SendReceiptWorker struct {
	river.WorkerDefaults[SendReceiptArgs]
	sms external.SMSService
	txs txrepos.TransactionRepository
}

func (w *SendReceiptWorker) Work(ctx context.Context, job *river.Job[SendReceiptArgs]) error {
	tx, err := w.txs.GetByID(ctx, job.Args.TransactionID)
	if err != nil {
		return err // returned errors are retried with backoff
	}
	return w.sms.Send(ctx, tx.Phone, receiptText(tx))
}
```

Client (container):

```go
workers := river.NewWorkers()
river.AddWorker(workers, &SendReceiptWorker{sms: ext.sms, txs: r.tx})

rc, err := river.NewClient(riverpgxv5.New(pool), &river.Config{
	Queues:  map[string]river.QueueConfig{river.QueueDefault: {MaxWorkers: 10}},
	Workers: workers,
})
// start with the bg ctx; stop gracefully on shutdown
if err := rc.Start(bgCtx); err != nil { /* fatal */ }
srv.OnShutdown(func() {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_ = rc.Stop(ctx)
})
```

Enqueue **in the same transaction** as the business write. Keep River out of core with a port:

```go
// core/shared/ports/job_queue.go
type JobQueue interface {
	EnqueueSendReceipt(ctx context.Context, transactionID uuid.UUID) error
}
```

The River adapter's implementation calls `client.InsertTx(ctx, postgres.TxFromContext(ctx), args, nil)`
when a tx is in ctx (else `client.Insert`). The service just calls `s.jobs.EnqueueSendReceipt(ctx, tx.ID)`
inside `WithTx` — if the tx rolls back, the job never existed.

Useful options: `&river.InsertOpts{UniqueOpts: river.UniqueOpts{ByArgs: true}}` for dedup,
`ScheduledAt` for delayed jobs, `MaxAttempts`, separate queues for slow vs fast work, and
`river.NewPeriodicJob` for cron-like schedules. River UI is available for inspecting jobs.

Tests: unit-test the worker's `Work` directly with fakes; integration-test that a rolled-back
tx leaves no job row.

## 4. Temporal — durable workflows

Dependencies: `go.temporal.io/sdk`. Needs a Temporal server (local: `temporal server start-dev`;
prod: self-hosted cluster or Temporal Cloud).

Concepts:
- **Workflow** — orchestration code. Must be deterministic: no direct I/O, no `time.Now()`,
  no `rand`, no goroutines/maps-iteration-order dependence. Use `workflow.Now`,
  `workflow.Sleep`, `workflow.Go`, `workflow.SideEffect`.
- **Activity** — the real work (DB, HTTP, SMS). Retried automatically per its RetryPolicy;
  must be idempotent (use the workflow ID + step as an idempotency key with providers).
- **Worker** — a long-running process that polls a task queue and executes both.

```go
// Workflow
func DisburseLoanWorkflow(ctx workflow.Context, in DisburseInput) error {
	ctx = workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: 30 * time.Second,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval: time.Second, BackoffCoefficient: 2, MaximumInterval: time.Minute,
			MaximumAttempts: 10,
			NonRetryableErrorTypes: []string{"InsufficientFundsError"},
		},
	})
	var a *LoanActivities // nil pointer is fine: only used to reference method names

	var transferRef string
	if err := workflow.ExecuteActivity(ctx, a.TransferFunds, in).Get(ctx, &transferRef); err != nil {
		_ = workflow.ExecuteActivity(ctx, a.MarkDisbursementFailed, in.LoanID).Get(ctx, nil)
		return err
	}
	if err := workflow.ExecuteActivity(ctx, a.ActivateLoan, in.LoanID, transferRef).Get(ctx, nil); err != nil {
		return err
	}
	return workflow.ExecuteActivity(ctx, a.CreateRepaymentSchedule, in.LoanID).Get(ctx, nil)
}

// Activities: a struct holding real dependencies (ports)
type LoanActivities struct {
	payments external.PaymentProvider
	loans    loanrepos.LoanRepository
}

func (a *LoanActivities) TransferFunds(ctx context.Context, in DisburseInput) (string, error) {
	return a.payments.Transfer(ctx, in.AccountNumber, in.Amount, "disb-"+in.LoanID.String())
}
```

Worker process (`cmd/worker/main.go`, separate from `cmd/api`):

```go
c, err := client.Dial(client.Options{HostPort: cfg.Temporal.HostPort, Namespace: cfg.Temporal.Namespace})
w := worker.New(c, "loans", worker.Options{})
w.RegisterWorkflow(DisburseLoanWorkflow)
w.RegisterActivity(&LoanActivities{payments: ext.payments, loans: r.loan})
err = w.Run(worker.InterruptCh())
```

Starting from the API (behind a `LoanWorkflows` port in core):

```go
_, err := c.ExecuteWorkflow(ctx, client.StartWorkflowOptions{
	ID:        "disburse-" + loanID.String(), // deterministic ID = idempotent start
	TaskQueue: "loans",
}, DisburseLoanWorkflow, in)
```

Test with `go.temporal.io/sdk/testsuite` (`WorkflowTestSuite`, mock activities, time skipping).

Trade-offs to state in design discussions: extra infrastructure and an operational learning
curve; determinism rules; versioning workflows that are mid-flight (`workflow.GetVersion`).
In return you get crash-proof multi-step processes, built-in retries/timeouts/timers, and a
complete per-execution history for audits — which is why lenders use it for disbursement and
collections.
