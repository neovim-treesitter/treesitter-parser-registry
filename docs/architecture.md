# Architecture Reference

## Repository Map

```
neovim-treesitter org
├── treesitter-parser-registry    ← this repo; editor-agnostic parser catalogue
│   ├── registry.json             ← all known parsers + their source locations
│   ├── schemas/schema.json       ← JSON Schema for registry.json + parser.json
│   └── lua/
│       ├── treesitter-registry.lua          ← fetch/cache/decode shim
│       └── treesitter-registry/
│           └── hosts.lua                    ← git host adapters
│
├── nvim-treesitter-queries-python   ← one repo per language
│   ├── parser.json               ← which parser + compat version bounds
│   └── queries/
│       ├── highlights.scm
│       ├── injections.scm
│       ├── folds.scm
│       ├── indents.scm
│       └── locals.scm
│
├── nvim-treesitter-queries-ecma     ← queries-only (no parser binary)
│   ├── parser.json               ← { queries_only: true }
│   └── queries/
│       └── ...
│
└── nvim-treesitter                  ← Neovim plugin; installer only
    ├── lua/nvim-treesitter/
    │   ├── install.lua           ← download, build, update logic
    │   ├── version.lua           ← latest-version discovery via host APIs
    │   ├── cache.lua             ← 24h version cache (Lua, nvim-internal)
    │   └── queries.lua           ← ; inherits: resolver
    └── plugin/                   ← :TSInstall, :TSUpdate, :checkhealth
```

## registry.json

The central catalogue. Each key is a language name; each value is a `registryEntry`.

### Source types

| `type` | Meaning |
|--------|---------|
| `self_contained` | Upstream parser repo ships its own Neovim queries |
| `external_queries` | Queries live in a separate `nvim-treesitter-queries-<lang>` repo |
| `queries_only` | No parser binary; queries exist only to be inherited by other languages |
| `local` | Development override pointing at a local directory |

### Example entries

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
  },

  "typescript": {
    "source": {
      "type": "external_queries",
      "parser_url": "https://github.com/tree-sitter/tree-sitter-typescript",
      "parser_semver": false,
      "parser_location": "typescript",
      "queries_url": "https://github.com/neovim-treesitter/nvim-treesitter-queries-typescript",
      "queries_semver": true
    },
    "filetypes": ["typescript", "ts"],
    "requires": ["ecma"]
  },

  "ecma": {
    "source": {
      "type": "queries_only",
      "url": "https://github.com/neovim-treesitter/nvim-treesitter-queries-ecma",
      "semver": true
    }
  }
}
```

### `semver` flag

Each parser and query source carries a `semver` boolean:

- `true` — track the latest `vX.Y.Z` tag. Strongly recommended; enables clean version comparisons
  and meaningful `min_version` / `max_version` bounds in `parser.json`.
- `false` — track HEAD of the default branch (or a named branch). Used for upstreams that do not
  publish semver tags. Updates are available whenever HEAD changes.

## parser.json (query repo manifest)

Each query repo carries a `parser.json` at its root declaring which exact parser version its
queries are tested against, and — for languages with inherited queries — which exact version of
each parent query repo was used.

### Simple case (no inheritance)

```json
{
  "lang": "python",
  "url": "https://github.com/tree-sitter/tree-sitter-python",
  "semver": true,
  "parser_version": "v0.23.0",
  "location": null
}
```

### With inherited queries

```json
{
  "lang": "typescript",
  "url": "https://github.com/tree-sitter/tree-sitter-typescript",
  "semver": false,
  "parser_version": "abc123def456",
  "location": "typescript",
  "inherits": {
    "ecma": {
      "url": "https://github.com/neovim-treesitter/nvim-treesitter-queries-ecma",
      "parser_version": "v1.0.0"
    }
  }
}
```

| Field | Purpose |
|-------|---------|
| `lang` | Language identifier; must match the registry key |
| `url` | Upstream parser repository URL |
| `semver` | Whether the parser uses semver tags (`true`) or HEAD commits (`false`) |
| `parser_version` | Exact git ref (tag or SHA) the queries are tested against. The installer uses this as the checkout target. `null` falls back to the latest tag or HEAD. |
| `location` | Subdirectory within the parser repo (monorepos only) |
| `queries_only` | `true` for inheritance-only virtual languages (no parser binary) |
| `inherits` | Map of parent language name → `{ url, parser_version }` — pins the exact parent query repo ref used when these queries were validated |

### Why `inherits` matters

When `typescript` inherits from `ecma`, the installer fetches the ecma query repo and merges its
content into the typescript queries. The `inherits` block pins the exact version of each parent
that was validated alongside these queries. The installer fetches that exact ref — not the latest
— so the installed query set is always the one that passed CI.

When a parent query repo releases a new version, the child's `inherits.<lang>.parser_version` is bumped
(manually or via the automated bump workflow) and CI re-validates the merged set before merging.

## Version Discovery

The query repo's `parser.json` is the source of truth for which parser version to install.
The installer reads `parser_version` and fetches that exact ref — it does not query upstream
APIs to find the "latest" version at install time.

The `semver` flag has no role in the installer itself. It exists to inform the automated bump
workflow (see below) about how to discover newer upstream releases:

- `semver: true` — the bump workflow queries the parser repo's releases/tags API for the latest
  `vX.Y.Z` tag and compares it to the current `parser_version`
- `semver: false` — the bump workflow fetches the latest HEAD commit SHA and compares

### Host adapters (`hosts.lua`)

The `hosts.lua` shim in this repo is used by the bump workflow (not the installer) to discover
new parser versions across different git forges:

| Host | Version check method |
|------|---------------------|
| `github.com` | GitHub REST API: releases endpoint, falling back to tags endpoint |
| `gitlab.com` | GitLab API v4: releases then tags |
| `codeberg.org` | Gitea v1 API: tags |
| anything else | `git ls-remote` (universal fallback, no API token needed) |

New forges can be added without changing the installer:

```lua
local hosts = require("treesitter-registry.hosts")
hosts.register("git.example.com", {
  latest_tag  = function(url, cb) ... end,
  latest_head = function(url, branch, cb) ... end,
  tarball_url = function(url, ref) return url .. "/archive/" .. ref .. ".tar.gz" end,
  raw_url     = function(url, ref, path) return url .. "/raw/" .. ref .. "/" .. path end,
})
```

When `tarball_url` or `raw_url` return `nil`, the installer falls back to `git clone --depth 1`
and `git archive --remote` respectively.

## Caching

One cache, stored in the installer's `install_dir`:

| File | Contents | TTL | Format |
|------|----------|-----|--------|
| `treesitter-registry.json` | Full registry.json | 7 days | JSON |
| `treesitter-registry-meta.lua` | `{ fetched_at = <unix_ts> }` | — | Lua |

The registry TTL is long because the catalogue changes rarely (new language added, URL changed).
On fetch failure the installer falls back to the stale cache with a warning rather than failing
hard, so offline use remains possible. `TSUpdate!` bypasses the cache.

## Query Inheritance

Tree-sitter queries support inheritance via a directive on the first line of a `.scm` file:

```scheme
; inherits: ecma
; inherits: (optionallang)   -- parentheses = optional; no error if not installed
```

When installing a language, the installer resolves this recursively:

1. Fetch the language's queries
2. Parse `; inherits:` directives from each `.scm` file
3. For each parent: ensure it is installed (installing if necessary), then recurse
4. Merge: parent content prepended, child content appended (child takes precedence via
   tree-sitter's later-match-wins rule)
5. Detect circular inheritance and error clearly

This means `typescript` transparently gets `ecma`'s queries without the user or the query
maintainer needing to manually copy them.
