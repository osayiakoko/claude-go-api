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

The short forms (`/new-project`, `/add-resource`, `/review`) also work when no other
command uses the same name. Formatting runs automatically: every `.go` file Claude writes or
edits is passed through `goimports` (or `gofmt` if goimports isn't installed).

## /go-api:new-project

```
/go-api:new-project lite example.com/wallet "wallet API: create wallet, credit, debit, balance; no overdrafts"
/go-api:new-project lite example.com/shortener "URL shortener with expiry and hit counts"
/go-api:new-project full github.com/codicra/invoicing "SME e-invoicing API with customers, invoices and payments"
/go-api:new-project "rate limiter service"        # mode/module omitted: Claude picks lite for small tasks, else asks
```

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

## Managing the plugin

```
/plugin                                   # see installed plugins, enable/disable
/plugin marketplace update osayi-claude   # pull the latest version after pushing changes
/reload-plugins                           # apply changes without restarting the session
/context                                  # confirm the Go rules file is loaded
```
