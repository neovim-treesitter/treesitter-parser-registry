# treesitter-parser-registry

An editor-agnostic catalogue of [tree-sitter](https://tree-sitter.github.io/tree-sitter/) parsers
and their associated Neovim query repositories.

Part of the [neovim-treesitter](https://github.com/neovim-treesitter) organisation's effort to
separate parser discovery, query maintenance, and editor integration into independent concerns.

## Contents

| Path | Purpose |
|------|---------|
| [`registry.json`](registry.json) | Catalogue of all known parsers and query sources |
| [`schemas/schema.json`](schemas/schema.json) | JSON Schema validating `registry.json` and per-repo `parser.json` manifests |
| [`lua/treesitter-registry.lua`](lua/treesitter-registry.lua) | Lua shim: fetch, cache, and decode the registry for Neovim-based installers |
| [`lua/treesitter-registry/hosts.lua`](lua/treesitter-registry/hosts.lua) | Git host adapters (GitHub, GitLab, Codeberg, generic fallback) |
| [`docs/overview.md`](docs/overview.md) | Motivation and goals |
| [`docs/architecture.md`](docs/architecture.md) | System design reference |
| [`docs/contributing.md`](docs/contributing.md) | How to add languages and maintain query repos |

## Quick start

### For Neovim plugin authors

Vendor `lua/treesitter-registry.lua` and `lua/treesitter-registry/hosts.lua` into your plugin.
Call `M.load(cache_dir, opts, callback)` to get a decoded registry table:

```lua
local registry = require("treesitter-registry")
registry.load(vim.fn.stdpath("cache"), {}, function(reg, err)
  if err then return vim.notify(err, vim.log.levels.ERROR) end
  local python = reg.python
  -- python.source.parser_url, python.source.queries_url, etc.
end)
```

The `hosts.lua` module handles version discovery across GitHub, GitLab, Codeberg, and arbitrary
git hosts. New hosts can be registered at runtime without modifying the library.

### For other installer authors

The registry is a plain JSON file — no Lua runtime required. Fetch it directly:

```
https://raw.githubusercontent.com/neovim-treesitter/treesitter-parser-registry/main/registry.json
```

Each entry carries everything needed to locate the parser source, discover new versions, and find
the associated query repository. Validate entries against `schemas/schema.json`, which also covers
the `parser.json` manifests found at the root of each `nvim-treesitter-queries-<lang>` repo.

Version discovery is intentionally left to the installer: use the host API most appropriate for
your runtime (GitHub REST, GitLab API, `git ls-remote`, etc.). The `hosts.lua` shim is a reference
implementation for Lua/Neovim environments, not a required dependency.

### For parser/query maintainers

See [`docs/contributing.md`](docs/contributing.md).

## Registry entry shape

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

Source types: `self_contained` · `external_queries` · `queries_only` · `local`.
See [`docs/architecture.md`](docs/architecture.md) for full field documentation.

## Design

This registry intentionally **does not pin parser revisions**. It records where parsers and
queries live and how to discover new versions (semver tags or HEAD). Installers query upstream
host APIs to find the latest compatible release and cache results locally.

See [`docs/overview.md`](docs/overview.md) for the rationale.

## Related repositories

- [nvim-treesitter](https://github.com/neovim-treesitter/nvim-treesitter) — Neovim installer and query integration (this org's fork)
- [ts-install.nvim](https://github.com/lewis6991/ts-install.nvim) — alternative Neovim tree-sitter installer
- [nvim-treesitter-queries-\*](https://github.com/orgs/neovim-treesitter/repositories?q=nvim-treesitter-queries) — per-language query repositories

## License

MIT
