# Migrating to Self-Contained Queries

This guide is for **parser maintainers** who want to ship Neovim queries
directly in their `tree-sitter-<lang>` repository instead of relying on
a separate `nvim-treesitter-queries-<lang>` repo.

When a parser is self-contained, the registry points directly at the
upstream repo and the installer fetches queries from there. This gives
parser authors full control over query quality and lets query changes
land alongside grammar changes in the same PR.

---

## Overview

| Step | What | Where |
|------|------|-------|
| 1 | Add nvim query files to your parser repo | `tree-sitter-<lang>` |
| 2 | Add the reusable CI workflow | `tree-sitter-<lang>` |
| 3 | Update the registry entry to `self_contained` | `treesitter-parser-registry` |
| 4 | (Optional) Archive the old query repo | `neovim-treesitter` org |

---

## Step 1 — Add Neovim query files

Create a directory in your parser repo to hold the Neovim-specific queries.
The recommended layout uses a parent directory with a `<lang>/` subdirectory:

```
tree-sitter-mylang/
├── grammar.js
├── src/
├── queries/              # generic tree-sitter queries (highlights.scm etc.)
├── nvim-queries/         # Neovim-specific queries
│   └── mylang/
│       ├── highlights.scm
│       ├── injections.scm    (optional)
│       ├── folds.scm         (optional)
│       ├── indents.scm       (optional)
│       └── locals.scm        (optional)
└── ...
```

The `nvim-queries/<lang>/` layout is recommended because it maps cleanly to
the registry's `queries_dir` field. However, you can also place queries
directly in a flat directory (e.g. `queries/nvim/`) and use `queries_path`
instead.

### If migrating from an existing query repo

Copy the `.scm` files from the `nvim-treesitter-queries-<lang>` repo's
`queries/` directory into your new `nvim-queries/<lang>/` directory:

```bash
# Clone the existing query repo
git clone https://github.com/neovim-treesitter/nvim-treesitter-queries-mylang /tmp/queries-mylang

# Copy queries into your parser repo
mkdir -p nvim-queries/mylang
cp /tmp/queries-mylang/queries/*.scm nvim-queries/mylang/
```

Verify the queries still work against your current grammar — if you have
recently changed node names or structure, the queries may need updating.

### `.tsqueryrc.json`

Add a `.tsqueryrc.json` at your repo root so `ts_query_ls` can find queries
during local development:

```json
{
  "$schema": "https://raw.githubusercontent.com/ribru17/ts_query_ls/refs/heads/master/schemas/config.json",
  "parser_install_directories": ["."],
  "language_retrieval_patterns": [
    "nvim-queries/([^/]+)/[^/]+\\.scm$"
  ]
}
```

Adjust the pattern if you use a different directory layout.

---

## Step 2 — Add CI

Add a workflow file that calls the reusable validation workflow from the
`neovim-treesitter` org. This validates your nvim queries on every push
and PR, just like the query repos do.

### Minimal example

Create `.github/workflows/nvim-queries.yml` (or add a job to your existing
CI workflow):

```yaml
name: Validate Queries (Self-Contained)

on:
  push:
    branches: [main]
    paths:
      - "nvim-queries/mylang/**"
  pull_request:
    branches: [main]
    paths:
      - "nvim-queries/mylang/**"
  workflow_dispatch:

jobs:
  validate:
    uses: neovim-treesitter/.github/.github/workflows/self-contained-validate.yml@main
    with:
      lang: mylang
      queries-dir: nvim-queries
```

### Adding to an existing CI workflow

If your parser already has a CI workflow (most do via the standard
`tree-sitter/parser-test-action`), add the query validation as an
additional job and extend the path triggers:

```yaml
on:
  push:
    branches: [main]
    paths:
      - grammar.js
      - src/**
      - test/**
      - nvim-queries/**      # <-- add this
  pull_request:
    paths:
      - grammar.js
      - src/**
      - test/**
      - nvim-queries/**      # <-- add this

jobs:
  test:
    # ... existing parser test job ...

  query:
    name: Validate queries
    uses: neovim-treesitter/.github/.github/workflows/self-contained-validate.yml@main
    with:
      lang: mylang
      queries-dir: nvim-queries
```

### Workflow inputs reference

| Input | Required | Description |
|-------|----------|-------------|
| `lang` | Yes | Language name (must match subdirectory name under `queries-dir`) |
| `queries-dir` | One of these | Parent directory containing `<lang>/` with `.scm` files |
| `queries-path` | required | Direct path to directory containing `.scm` files |
| `parser-location` | No | Subdirectory containing parser source (for monorepos) |
| `inject-deps` | No | Comma-separated injection dependency languages |
| `inherits` | No | Comma-separated inherited languages |

`queries-dir` and `queries-path` are mutually exclusive. Use `queries-dir`
when your layout is `<dir>/<lang>/*.scm` (recommended). Use `queries-path`
when queries are in a flat directory without the `<lang>/` nesting.

### What CI validates

1. **Parser build** — compiles the parser from your repo using `tree-sitter build`
2. **Query correctness** — `ts_query_ls check` verifies all `.scm` files against
   the compiled parser (invalid node names, malformed predicates, type errors)
3. **Inherited queries** — if your queries use `; inherits:` directives, CI fetches
   the parent query repos and validates the merged set
4. **Injection deps** — if specified, builds parsers for injected languages
5. **Highlight tests** — if `tests/highlights/` exists, runs highlight assertion tests

---

## Step 3 — Update the registry

Open a PR against
[`treesitter-parser-registry`](https://github.com/neovim-treesitter/treesitter-parser-registry)
to change your language's entry in `registry.json` from `external_queries`
to `self_contained`.

### Before (external_queries)

```json
"mylang": {
  "filetypes": ["mylang"],
  "source": {
    "type": "external_queries",
    "parser_url": "https://github.com/author/tree-sitter-mylang",
    "parser_semver": true,
    "queries_url": "https://github.com/neovim-treesitter/nvim-treesitter-queries-mylang",
    "queries_semver": true
  }
}
```

### After (self_contained)

```json
"mylang": {
  "filetypes": ["mylang"],
  "source": {
    "type": "self_contained",
    "url": "https://github.com/author/tree-sitter-mylang",
    "semver": true,
    "queries_dir": "nvim-queries"
  }
}
```

### Field reference

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | `"self_contained"` |
| `url` | Yes | Git URL of your parser repo |
| `semver` | Yes | `true` if you publish semver tags, `false` otherwise |
| `queries_dir` | One of | Parent dir whose `<lang>/` subdirectory has `.scm` files |
| `queries_path` | these | Direct path to directory containing `.scm` files |
| `location` | No | Subdirectory for monorepo parsers |
| `generate` | No | Set `true` if `tree-sitter generate` is needed before build |
| `generate_from_json` | No | `true` to generate from `src/grammar.json` |

### PR checklist

- [ ] Source type changed to `self_contained`
- [ ] `url` points at your parser repo
- [ ] `queries_dir` or `queries_path` matches your actual layout
- [ ] `semver` reflects whether you publish semver tags
- [ ] Your parser repo CI passes with the reusable workflow
- [ ] `filetypes` and `requires` fields preserved from old entry

---

## Step 4 — (Optional) Archive the old query repo

Once the registry PR is merged, the old `nvim-treesitter-queries-<lang>`
repo is no longer the source of truth. Notify the `neovim-treesitter` org
maintainers to archive it. The archive preserves history while clearly
signalling that queries now live upstream.

If you do not have access to archive the repo, mention it in your registry
PR and an org maintainer will handle it.

---

## Worked example: `tree-sitter-zsh`

The `tree-sitter-zsh` parser is the reference implementation for self-contained
queries. Here is exactly what was done:

### Query layout

```
tree-sitter-zsh/
├── nvim-queries/
│   └── zsh/
│       ├── highlights.scm
│       ├── injections.scm
│       ├── locals.scm
│       └── folds.scm
├── .tsqueryrc.json
└── ...
```

### CI workflow (in `.github/workflows/ci.yml`)

```yaml
  query:
    name: Validate queries
    uses: neovim-treesitter/.github/.github/workflows/self-contained-validate.yml@main
    with:
      lang: zsh
      queries-dir: nvim-queries
```

This is added alongside the existing `test` and `fuzz` jobs. The path
triggers include `nvim-queries/**` so query-only changes also run CI.

### Registry entry

```json
"zsh": {
  "filetypes": ["zsh"],
  "source": {
    "type": "self_contained",
    "url": "https://github.com/georgeharker/tree-sitter-zsh",
    "semver": false,
    "queries_dir": "nvim-queries"
  }
}
```

---

## FAQ

### Can I keep both the query repo and self-contained queries?

During migration, yes. The registry entry determines which source the
installer uses. While the entry says `external_queries`, the query repo
is canonical. Once you flip it to `self_contained`, the installer fetches
from your parser repo. The query repo can remain as a read-only archive.

### What if my queries use `; inherits:`?

The reusable workflow handles this automatically. It scans your `.scm`
files for `; inherits:` directives and fetches the parent query repos
via BFS. You can also pass explicit dependencies via the `inherits`
input if needed.

You should also keep `requires` in your registry entry so the installer
knows about the dependency chain.

### What if my parser is in a monorepo?

Set `parser-location` in the workflow call and `location` in the registry
entry to the subdirectory containing your parser source.

### Do I need to change how I release?

No. The installer discovers versions the same way — via semver tags
(if `semver: true`) or HEAD (if `semver: false`). The only difference
is that queries are now fetched from the same repo and ref as the parser.

### What about the `queries/` directory at the repo root?

The generic `queries/highlights.scm` (used by the tree-sitter CLI
playground and other non-Neovim tools) is separate from the
`nvim-queries/` directory. Keep both — they serve different audiences.
