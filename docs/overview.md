# Overview: Why This Exists

## The Problem with nvim-treesitter

[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) historically bundled three
distinct concerns into a single repository:

1. **Parser registry** — a catalogue of known tree-sitter grammars with pinned revision hashes
2. **Query maintenance** — ~330 sets of `.scm` query files for syntax highlighting, indentation, folds, etc.
3. **Installation machinery** — the Neovim plugin that downloads, compiles, and installs parsers

This created a bottleneck: any change to an upstream grammar — even a patch release — required a
pull request to nvim-treesitter before users could get it. Query authors, parser authors, and
plugin authors were all serialised through the same review queue. The "tiers" system (stable /
unstable / unmaintained) further conflated curation with availability.

## Goals of This Redesign

**Separate concerns so each can evolve independently.**

| Concern | Owner | Repo |
|---------|-------|------|
| Parser discovery registry | `neovim-treesitter` org | `treesitter-parser-registry` (this repo) |
| Neovim queries per language | Per-language maintainers | `nvim-treesitter-queries-<lang>` |
| Installation / update UX | Individual installers | `nvim-treesitter`, `ts-install.nvim`, others |

**Stop blessing parser revisions.** The registry records *where* a parser lives and *how* to
track new versions (semver tags vs. HEAD commits). It does not pin a specific revision. Users
get updates as upstream publishes them; the installer discovers the latest via host APIs.

**Make the registry editor-agnostic.** The data in `registry.json` is plain JSON with a published
schema. Any editor integration, CLI tool, or language server can consume it without depending on
Neovim or Lua. The Lua shim (`lua/treesitter-registry.lua`) is a reference implementation for
Lua-based installers, not a requirement. A Python-based installer, a Rust CLI, or a VS Code
extension can fetch and parse `registry.json` directly.

**Support a variety of installers.** The registry is designed to be consumed by multiple
independent installers simultaneously. [nvim-treesitter](https://github.com/neovim-treesitter/nvim-treesitter)
and [ts-install.nvim](https://github.com/lewis6991/ts-install.nvim) are both Neovim installers
that can share this registry and the same `nvim-treesitter-queries-<lang>` repos without
duplicating query maintenance. Future installers for other editors are welcome — the registry
makes no assumptions about the consuming environment beyond HTTP access and the ability to parse
JSON.

**Distribute query ownership.** Each language's queries live in their own repo
(`nvim-treesitter-queries-<lang>`). That repo's maintainers own the queries and declare which
parser versions they are compatible with via a `parser.json` manifest. No central bottleneck.

## Governance Intent

The `neovim-treesitter` org acts as a neutral home for the registry and query repos, not as a
gating authority. The goal is maximum delegation:

- The registry is a data file. PRs to add or update entries are low-friction.
- Each query repo is intended to be owned by its community of language users, not by a central
  committee. Anyone can claim maintainership of a language by adding themselves to `CODEOWNERS`.
- The org maintainers are a fallback, not a bottleneck. They handle repos with no active
  maintainer and make infrastructure decisions (CI templates, schema updates), but language-specific
  query work belongs with people who use the language.
- Unmaintained repos are flagged and made available for adoption rather than blocked or removed.

See [`docs/contributing.md`](contributing.md) for the detailed governance mechanics.

## What Changes for Users

- `TSUpdate` fetches latest available versions from upstream APIs rather than applying pre-blessed
  revision bumps. You always get the newest compatible release.
- Parser updates and query updates are independent — a parser can release without waiting for
  query review, and queries can be patched without a parser change.
- The "tiers" concept is gone. If a language is in the registry, it is available. Maintenance
  status is the query repo's concern, communicated via its own README and CI health.

## What Does Not Change

- The install UX (`TSInstall`, `TSUpdate`, `:checkhealth`) remains the same from the user's
  perspective.
- Query inheritance (e.g. TypeScript inheriting from the shared `ecma` queries) continues to
  work; the installer resolves it recursively across repos.
- Local parser overrides for development continue to work via the `local` source type.
