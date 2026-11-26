---
name: help
description: List every go-api plugin command with examples.
disable-model-invocation: true
---

Print the reference below to the user exactly as written (it is Markdown). Do not add
anything before it. After it, add one line only if the user passed a question in
$ARGUMENTS, answering that question.

# go-api plugin — commands

| Command | Purpose |
|---|---|
| `/go-api:help` | This list |
| `/go-api:new-project [lite\|full] [module-path] [description]` | Scaffold a new Go API |
| `/go-api:add-resource [name] [fields / behaviour]` | Add an entity through every layer, with tests |
| `/go-api:review [path \| package \| git range]` | Review Go changes against the conventions |
| `/go-api:infra [topic] [instructions]` | Add or upgrade infrastructure: postgres, logger, cache, jobs, security, observability, http-kit, external, resilience, packages |

The short forms (`/new-project`, `/add-resource`, `/review`) also work when no other
command uses the same name. Formatting runs automatically: every `.go` file Claude writes or
edits is passed through `goimports` (or `gofmt` if goimports isn't installed).

## /go-api:new-project

```
/go-api:new-project lite example.com/wallet "wallet API: create wallet, credit, debit, balance; no overdrafts"
/go-api:new-project lite example.com/shortener "URL shortener with expiry and hit counts"
/go-api:new-project full github.com/codicra/invoicing "SME e-invoicing API with customers, invoices and payments"
/go-api:new-project lite example.com/wallet "wallet API with Postgres and zerolog"   # lite + extras
/go-api:new-project "rate limiter service"        # mode/module omitted: Claude picks lite for small tasks, else asks
```

`lite` = flat files, in-memory store, `slog`, Makefile. `full` = hexagonal layout, Postgres,
zerolog, metrics, Docker, CI, full Makefile.

Only you can start this one — Claude never scaffolds a project on its own.

## /go-api:add-resource

```
/go-api:add-resource product "name, price (decimal), status active|archived; owned by account"
/go-api:add-resource savings-goal "target amount, saved amount, deadline; contributions reduce the gap; owner-only access"
/go-api:add-resource webhook-subscription "url, secret, events []string; HMAC-signed delivery with retries"
```

Claude may also use this automatically when you say things like "add a products endpoint".

## /go-api:review

```
/go-api:review                                  # uncommitted changes (git diff HEAD + untracked .go files)
/go-api:review internal/core/debt               # one package
/go-api:review internal/adapters/secondary/persistence/postgres/debt_repository.go
/go-api:review main..feature/repay-fifo          # a branch against main
/go-api:review HEAD~3..HEAD                      # last three commits
```

Claude may also use this automatically when you ask it to review Go code.

## /go-api:infra

Topics: `postgres` · `logger` · `cache` · `jobs` · `security` · `observability` · `http-kit` · `external` · `resilience` · `packages` · `all`.
A plain-English request works too — Claude maps it to the right topic.

```
/go-api:infra postgres                         # swap the in-memory store for Postgres (keeps memory store for tests)
/go-api:infra logger                           # replace slog with zerolog in a lite project
/go-api:infra cache "cache users and plans for 5 minutes"
/go-api:infra jobs "nightly OTP cleanup and a monthly statement job that must run once per month"
/go-api:infra jobs "send a receipt SMS after each repayment using River, enqueued in the same transaction"
/go-api:infra jobs "loan disbursement workflow with Temporal: transfer, activate loan, create schedule"
/go-api:infra security "JWT access/refresh tokens, API key for client apps, rate limit login to 5/min"
/go-api:infra observability
/go-api:infra http-kit "add pagination and sortable list endpoints"
/go-api:infra external "Paystack payments with webhook verification"
/go-api:infra resilience "idempotency keys on POST /transactions and /debts/repay"
/go-api:infra resilience "timeouts, retries and a circuit breaker around WhatsApp and SMS"
/go-api:infra resilience "make payment webhook confirmation atomic"
/go-api:infra packages "move the category repository to sqlc"
/go-api:infra packages "run integration tests with testcontainers instead of TEST_DATABASE_URL"
/go-api:infra packages "replace the config loader with caarlos0/env"
/go-api:infra packages "replace the rate limiter with httprate behind Cloudflare"
/go-api:infra "add zerolog and Postgres"       # several topics at once
```

Claude may also use this automatically when you ask for any of these things.

## Managing the plugin

```
/plugin                                   # see installed plugins, enable/disable
/plugin marketplace update osayi-claude   # pull the latest version after pushing changes
/plugin                                   # → Installed → go-api shows the installed version
/reload-plugins                           # apply changes without restarting the session
/context                                  # confirm the Go rules file is loaded
```
