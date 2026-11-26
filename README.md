# claude-go-api

My Claude Code setup for Go API projects: the conventions I want followed, plus skills
for scaffolding, adding resources and reviewing code.

## What's in here

| Path | What it does | How it loads |
|---|---|---|
| `rules/go-api.md` | Always-on Go API conventions (layout, errors, HTTP, persistence, testing) | Symlinked into `~/.claude/rules/` by `install.sh`, so every session reads it |
| `plugins/go-api/skills/new-project` | `/go-api:new-project lite\|full <module> <description>` — scaffold a flat (interview: slog, in-memory, Makefile) or hexagonal (real: Postgres, zerolog, Docker, CI) API | Plugin |
| `plugins/go-api/skills/add-resource` | `/go-api:add-resource <name> <fields>` — domain → ports → service → repos → migration → DTO → handler → wiring → tests | Plugin (Claude also picks it up on its own when you ask for a new resource) |
| `plugins/go-api/skills/help` | `/go-api:help` — list every command with examples | Plugin |
| `plugins/go-api/skills/infra` | `/go-api:infra <topic>` — infrastructure patterns with reference code (`references/*.md`) | Plugin (loaded only when used) |
| `plugins/go-api/skills/review` | `/go-api:review [path\|range]` — review against the conventions | Plugin |
| `plugins/go-api/hooks` | Runs `goimports`/`gofmt` on every `.go` file Claude writes or edits | Plugin |

Plugins can't ship always-on instructions (Claude Code ignores a CLAUDE.md inside a plugin),
which is why the conventions live in `rules/` and are linked by the install script.

## Commands

Run `/go-api:help` inside Claude Code to print this list.

| Command | Purpose | Who can start it |
|---|---|---|
| `/go-api:help` | List every command with examples | You |
| `/go-api:new-project [lite\|full] [module-path] [description]` | Scaffold a new Go API | You only |
| `/go-api:add-resource [name] [fields / behaviour]` | Add an entity through every layer, with tests | You, or Claude when you ask for a new resource |
| `/go-api:review [path \| package \| git range]` | Review Go changes against the conventions | You, or Claude when you ask for a review |
| `/go-api:infra [topic] [instructions]` | Add/upgrade postgres, logger, cache, jobs, security, observability, http-kit, external | You, or Claude when you ask for any of these |

Short forms (`/new-project`, `/add-resource`, `/review`) work when no other command has the
same name. The formatting hook has no command; it runs after every `.go` edit.

### Examples

```
# Scaffold
/go-api:new-project lite example.com/wallet "wallet API: create wallet, credit, debit, balance; no overdrafts"
/go-api:new-project lite example.com/shortener "URL shortener with expiry and hit counts"
/go-api:new-project full github.com/codicra/invoicing "SME e-invoicing API with customers, invoices and payments"
/go-api:new-project lite example.com/wallet "wallet API with Postgres and zerolog"   # lite + extras
/go-api:new-project "rate limiter service"          # Claude picks lite for small tasks, otherwise asks

# Add a resource to an existing API
/go-api:add-resource product "name, price (decimal), status active|archived; owned by account"
/go-api:add-resource savings-goal "target amount, saved amount, deadline; owner-only access"
/go-api:add-resource webhook-subscription "url, secret, events []string; HMAC-signed delivery with retries"

# Infrastructure (topics: postgres, logger, cache, jobs, security, observability, http-kit, external, all)
/go-api:infra postgres                              # swap the in-memory store for Postgres
/go-api:infra logger                                # replace slog with zerolog in a lite project
/go-api:infra cache "cache users and plans for 5 minutes"
/go-api:infra jobs "monthly statement job that must run exactly once per month"
/go-api:infra jobs "send a receipt SMS after each repayment using River"
/go-api:infra jobs "loan disbursement workflow with Temporal"
/go-api:infra security "JWT access/refresh tokens, API key for client apps, rate limit login"
/go-api:infra external "Paystack payments with webhook verification"
/go-api:infra "add zerolog and Postgres"

# Review
/go-api:review                                      # uncommitted changes
/go-api:review internal/core/debt                   # one package
/go-api:review internal/adapters/secondary/persistence/postgres/debt_repository.go
/go-api:review main..feature/repay-fifo             # a branch against main
/go-api:review HEAD~3..HEAD                         # last three commits

# Manage the plugin
/plugin                                             # installed plugins, enable/disable
/plugin marketplace update osayi-claude             # pull the latest after pushing changes
/reload-plugins                                     # apply without restarting
/context                                            # confirm the Go rules file is loaded
```

## Install on a new machine

```bash
git clone https://github.com/<your-github-username>/claude-go-api.git ~/claude-go-api
~/claude-go-api/install.sh
```

Then inside Claude Code:

```
/plugin marketplace add <your-github-username>/claude-go-api
/plugin install go-api@osayi-claude
```

Check it worked: start Claude Code in any folder and run `/memory` — `go-api.md` should be
listed under rules. Type `/go-api:` to see the skills.

## Update

- Rules: edit `rules/go-api.md`, commit, push. On other machines `git pull` (the symlink picks it up).
- Plugin: add an entry to [`CHANGELOG.md`](CHANGELOG.md), bump `version` in
  `plugins/go-api/.claude-plugin/plugin.json` (semantic versioning — see the changelog header),
  commit, `git tag go-api-vX.Y.Z`, `git push --follow-tags`, then
  `/plugin marketplace update osayi-claude` and `/reload-plugins` on each machine.

## Per-project overrides

A project's own `CLAUDE.md` adds to these rules. The rules tell Claude that the repo's
established patterns win when they differ.

## Optional

Install a Go language server plugin for diagnostics and go-to-definition: browse `/plugin`
for the official Go code-intelligence plugin (needs `gopls` on your PATH:
`go install golang.org/x/tools/gopls@latest`). Also worth having:
`go install golang.org/x/tools/cmd/goimports@latest`.
