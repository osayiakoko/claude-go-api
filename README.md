# claude-go-api

My Claude Code setup for Go API projects: the conventions I want followed, plus skills
for scaffolding, adding resources and reviewing code.

## What's in here

| Path | What it does | How it loads |
|---|---|---|
| `rules/go-api.md` | Always-on Go API conventions (layout, errors, HTTP, persistence, testing) | Symlinked into `~/.claude/rules/` by `install.sh`, so every session reads it |
| `plugins/go-api/skills/new-project` | `/go-api:new-project lite\|full <module> <description>` — scaffold a flat (interview) or hexagonal (real) API | Plugin |
| `plugins/go-api/skills/add-resource` | `/go-api:add-resource <name> <fields>` — domain → ports → service → repos → migration → DTO → handler → wiring → tests | Plugin (Claude also picks it up on its own when you ask for a new resource) |
| `plugins/go-api/skills/review` | `/go-api:review [path\|range]` — review against the conventions | Plugin |
| `plugins/go-api/hooks` | Runs `goimports`/`gofmt` on every `.go` file Claude writes or edits | Plugin |

Plugins can't ship always-on instructions (Claude Code ignores a CLAUDE.md inside a plugin),
which is why the conventions live in `rules/` and are linked by the install script.

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
- Plugin: bump `version` in `plugins/go-api/.claude-plugin/plugin.json`, push, then
  `/plugin marketplace update osayi-claude` on each machine.

## Per-project overrides

A project's own `CLAUDE.md` adds to these rules. The rules tell Claude that the repo's
established patterns win when they differ.

## Optional

Install a Go language server plugin for diagnostics and go-to-definition: browse `/plugin`
for the official Go code-intelligence plugin (needs `gopls` on your PATH:
`go install golang.org/x/tools/gopls@latest`). Also worth having:
`go install golang.org/x/tools/cmd/goimports@latest`.
