# Session State — nvim-treesitter Redesign

> Last updated: 2026-04-06
> Purpose: permanent resume record for this redesign effort

---

## Context

This document records the full intent, decisions, and implementation state of the nvim-treesitter
redesign effort so that any session can resume without loss of context.

---

## Problem Statement

The original `nvim-treesitter` repo conflated three concerns:

1. **Parser registry** — catalogue of known grammars with pinned revision hashes
2. **Query maintenance** — ~330 sets of `.scm` query files
3. **Installation machinery** — Neovim plugin that downloads, compiles, installs parsers

All grammar + query changes had to flow through nvim-treesitter as a bottleneck. The "tiers"
system (stable/unstable/unmaintained) conflated curation with availability.

---

## Goals (all agreed)

- Separate concerns so each evolves independently
- **Stop blessing parser revisions** — discover latest via host APIs, no central pinning
- **Editor-agnostic registry** — plain JSON, any tool can consume it
- **Support multiple installers** — nvim-treesitter, ts-install.nvim, future editors
- **Distribute query ownership** — per-lang repos with their own maintainers
- **Drop tiers** — if it's registered, it's available

---

## Repository Structure

```
GitHub org: neovim-treesitter   (confirmed live, 0 repos as of last session)
GH auth:    georgeharker         (scopes: repo, workflow, gist, read:org)

Local disk: /Users/geohar/Development/ext/tree-sitter/

treesitter-parser-registry/         ← editor-agnostic JSON registry + Lua shim
nvim-treesitter/                    ← existing plugin (refactored)
nvim-treesitter-queries-python/     ← first concrete query repo (template/validation)
```

---

## Architecture Decisions (final)

### Source types (in registry.json `source.type`)

| Type | Meaning |
|------|---------|
| `self_contained` | Upstream parser repo ships its own nvim queries (`queries_path` field) |
| `external_queries` | Separate `nvim-treesitter-queries-<lang>` repo |
| `queries_only` | No parser binary; queries consumed via `; inherits:` only |
| `local` | Dev override pointing at local directory |

### registry.json shape
```json
{
  "python": {
    "source": {
      "type": "external_queries",
      "parser_url": "https://github.com/tree-sitter/tree-sitter-python",
      "parser_semver": true,
      "queries_url": "https://github.com/neovim-treesitter/nvim-treesitter-queries-python",
      "queries_semver": true
    },
    "filetypes": ["python", "py"]
  }
}
```

Currently has 5 entries: `ecma`, `javascript`, `python`, `rust`, `typescript`.
All 329 will be populated by `create-query-repos.sh`.

### parser.json (in each query repo root)
```json
{
  "lang": "python",
  "url": "https://github.com/tree-sitter/tree-sitter-python",
  "semver": true,
  "min_version": "v0.23.0",
  "max_version": null,
  "location": null,
  "inherits": {
    "ecma": {
      "url": "https://github.com/neovim-treesitter/nvim-treesitter-queries-ecma",
      "min_version": "v1.0.0",
      "max_version": null
    }
  }
}
```

`inherits` is critical: pins known-good versions of parent query repos so a breaking
change in `ecma` doesn't silently break `typescript`.

### Version discovery
- No pinning in the registry
- `semver: true` → track latest `vX.Y.Z` tag via host API
- `semver: false` → track HEAD commit hash
- Host adapters: GitHub REST (releases→tags fallback), GitLab API v4, Codeberg Gitea v1,
  `git ls-remote` generic fallback
- `M.register(hostname, adapter)` for extensibility

### HTTP transport
- **plenary.curl** throughout (no raw `curl` CLI calls)
- `vim.system` retained only for git CLI operations (ls-remote, clone, build)

### Caches
- `treesitter-registry.json` + `treesitter-registry-meta.lua` — 7d TTL, registry data
- `registry-cache.lua` — 24h TTL, latest available versions per lang
- All in `config.get_install_dir()`

### Inheritance resolution
- Recursive `; inherits:` parsing across repos
- `parser.json` `inherits` block constrains which version of parent is fetched
- Cycle detection via visited set
- Depth-first sequential merge (parent content prepended, child appended)

---

## Files on Disk

### treesitter-parser-registry/
```
README.md                          ← installer-agnostic, ts-install.nvim in related
registry.json                      ← 5 entries (ecma/js/python/rust/typescript)
schemas/schema.json                ← JSON Schema; includes inheritRef $def
docs/overview.md                   ← motivation, goals, governance intent
docs/architecture.md               ← full system design reference
docs/contributing.md               ← CI/CD, migration phases, governance (complete)
docs/session-state.md              ← THIS FILE
lua/treesitter-registry.lua        ← fetch/cache shim (plenary.curl)
lua/treesitter-registry/hosts.lua  ← host adapters (plenary.curl)
```

### nvim-treesitter/ (new/modified files)
```
scripts/gen-parser-manifest.lua    ← reads parsers.lua, emits parser.json (TESTED)
scripts/create-query-repos.sh      ← bulk migration script (bash -n OK, chmod+x)
scripts/templates/query-validate.yml    ← CI template for query repos
scripts/templates/query-repo-README.md  ← README template with {{LANG}}

lua/nvim-treesitter/registry.lua        ← loads registry JSON (shim vendored inline)
lua/nvim-treesitter/version.lua         ← version discovery, plenary.curl, semaphore
lua/nvim-treesitter/cache.lua           ← 24h version cache + parser-info state
lua/nvim-treesitter/queries_resolver.lua ← recursive ; inherits: resolver
lua/nvim-treesitter/install.lua         ← full rewrite (was parsers.lua-based)
lua/nvim-treesitter/treesitter-registry/hosts.lua  ← vendored hosts adapter
plugin/nvim-treesitter.lua              ← TSInstall/TSUpdate/TSUninstall/TSStatus
```

### nvim-treesitter-queries-python/
```
parser.json        ← lang=python, semver=true, min_version=v0.25.0
queries/*.scm      ← 5 files copied from nvim-treesitter runtime/queries/python/
.github/workflows/validate.yml
(README.md missing — needs writing)
```

---

## Pending Checklist

### Immediate (next session start)

- [ ] **Confirm GH token scope** — test with:
  ```bash
  gh repo create neovim-treesitter/test-repo-delete-me --public && \
  gh repo delete neovim-treesitter/test-repo-delete-me --yes
  ```
  If 403: add `write:org` or `admin:org` scope to token, or use a PAT with `repo` scope
  in the org context.

- [ ] **Test run (3 langs)**:
  ```bash
  cd /Users/geohar/Development/ext/tree-sitter/nvim-treesitter
  ./scripts/create-query-repos.sh neovim-treesitter python rust typescript
  ```
  Verify: repos created, parser.json correct, CI workflow present, README populated.

- [ ] **Full run (329 langs)**:
  ```bash
  ./scripts/create-query-repos.sh neovim-treesitter
  ```
  Script is idempotent — skips existing repos. Prints summary: N created, N skipped, N failed.

### Git setup for registry + example query repo

- [ ] Init and push `treesitter-parser-registry`:
  ```bash
  cd /Users/geohar/Development/ext/tree-sitter/treesitter-parser-registry
  git init && git add -A
  git commit -m "feat: initial treesitter-parser-registry"
  git remote add origin https://github.com/neovim-treesitter/treesitter-parser-registry
  git push -u origin main
  ```

- [ ] Init and push `nvim-treesitter-queries-python`:
  ```bash
  cd /Users/geohar/Development/ext/tree-sitter/nvim-treesitter-queries-python
  git init && git add -A
  git commit -m "feat: initial extraction from nvim-treesitter"
  git tag v0.1.0
  git remote add origin https://github.com/neovim-treesitter/nvim-treesitter-queries-python
  git push -u origin main --follow-tags
  ```

### Code remaining

- [ ] **`nvim-treesitter-queries-python/README.md`** — missing; run template manually:
  ```bash
  sed "s/{{LANG}}/python/g" \
    nvim-treesitter/scripts/templates/query-repo-README.md \
    > nvim-treesitter-queries-python/README.md
  ```

- [ ] **`plugin/filetypes.lua`** — currently reads `parsers.lua` for filetype→lang mappings.
  Needs to use `registry.filetypes` field instead. Pattern:
  ```lua
  local registry = require('nvim-treesitter.registry')
  registry.load(function(reg)
    for lang, entry in pairs(reg) do
      if entry.filetypes then
        vim.treesitter.language.register(lang, entry.filetypes)
      end
    end
  end)
  ```

- [ ] **`lua/nvim-treesitter/init.lua`** — public API surface. Review whether `setup()`,
  `install()`, `update()`, `indentexpr()` still re-export correctly from new install.lua.

### registry.json bulk update

The `create-query-repos.sh` script does NOT currently update `registry.json` automatically.
After the bulk run, either:
- Run a separate script to generate all 329 entries from `parsers.lua`, or
- Treat `registry.json` as manually curated (5 concrete entries now; community adds the rest)

Recommended: write `scripts/gen-registry-json.lua` that iterates all parsers and emits
the full `registry.json`. Pattern mirrors `gen-parser-manifest.lua` but for the registry shape.

---

## Key Design Rationale (for future discussions)

**Why no pinning?**
Central pinning was the bottleneck. Every upstream parser release required a PR here.
With version discovery, users get updates as upstream publishes; the installer checks
compatibility via `min_version`/`max_version` in `parser.json`.

**Why JSON for registry/manifests?**
Editor-agnostic. Any language, any tool, no Lua runtime required. The Lua shim is
a reference implementation for nvim-based installers only.

**Why separate query repos?**
Distributes ownership. Query maintainers for a language don't need to understand the
full nvim-treesitter codebase. They own `.scm` files + `parser.json`. CI validates
correctness automatically.

**Why `inherits` bounds in parser.json?**
Without them, a breaking change in `ecma` queries silently breaks `typescript`.
The `inherits` block lets each query repo maintainer declare which parent version
they've tested against, decoupling release cycles between parent and child langs.

**Why plenary.curl?**
Removes the dependency on `curl` CLI being in PATH, gives consistent error handling,
and integrates with Neovim's async model. plenary.nvim is already a standard dep in
the Neovim plugin ecosystem.

---

## Related Projects

- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) — original repo
- [ts-install.nvim](https://github.com/lewis6991/ts-install.nvim) — alternative installer; should be able to consume this registry
- [neovim-treesitter org](https://github.com/neovim-treesitter) — new home for registry + query repos
