# Contributing

## Adding a new language to the registry

Edit `registry.json` and add an entry following the schema in `schemas/schema.json`.

Determine the source type:

- Does the upstream parser repo ship its own Neovim queries in a `queries/` subdirectory?
  Use `self_contained` and set `queries_path` or `queries_dir`.
- Does a separate `nvim-treesitter-queries-<lang>` repo exist (or will you create one)?
  Use `external_queries`.
- Is this a virtual language with no parser binary, only consumed via `; inherits:`?
  Use `queries_only`.

### Minimum viable entry (external_queries)

```json
"mylang": {
  "source": {
    "type": "external_queries",
    "parser_url": "https://github.com/author/tree-sitter-mylang",
    "parser_semver": true,
    "queries_url": "https://github.com/neovim-treesitter/nvim-treesitter-queries-mylang",
    "queries_semver": true
  },
  "filetypes": ["mylang"]
}
```

Set `parser_semver: false` if the upstream repo does not publish semver tags. This is an
explicit opt-out — consider opening an issue upstream requesting semver releases.

### Self-contained entry

When the parser repo ships its own Neovim queries, use `self_contained`. The installer
fetches queries directly from the parser repo — no separate query repo needed.

```json
"mylang": {
  "source": {
    "type": "self_contained",
    "url": "https://github.com/author/tree-sitter-mylang",
    "semver": true,
    "queries_dir": "nvim-queries"
  },
  "filetypes": ["mylang"]
}
```

Use exactly one of `queries_dir` or `queries_path`:

- **`queries_dir`** — parent directory whose `<lang>/` subdirectory contains `.scm` files.
  The installer appends `/<lang>` automatically. Example: `"queries_dir": "nvim-queries"`
  means queries are at `nvim-queries/mylang/*.scm`.

- **`queries_path`** — direct path to the directory containing `.scm` files, when the layout
  does not follow the `<dir>/<lang>/` pattern. Example: `"queries_path": "queries/nvim"`.

Additional optional fields for self-contained entries:

| Field | Default | Description |
|-------|---------|-------------|
| `location` | repo root | Subdirectory containing the parser source (monorepos) |
| `generate` | `false` | Set `true` if `tree-sitter generate` is needed before compilation |
| `generate_from_json` | `false` | When `generate` is true: `true` = use `src/grammar.json`, `false` = use `grammar.js` |

For a full walkthrough of migrating an existing language to self-contained, see the
[Self-Contained Migration Guide](self-contained-migration.md).

### Monorepo parsers

If the grammar lives in a subdirectory of the upstream repo, add `parser_location`:

```json
"typescript": {
  "source": {
    "type": "external_queries",
    "parser_url": "https://github.com/tree-sitter/tree-sitter-typescript",
    "parser_semver": false,
    "parser_location": "typescript",
    ...
  }
}
```

### Inherited queries

If this language's queries build on another language's (e.g. TypeScript on ECMAScript), add
`requires` listing the parent language names. The installer resolves these transitively:

```json
"typescript": {
  ...
  "requires": ["ecma"]
}
```

The `; inherits: ecma` directive must also appear as the first line of any `.scm` file that
extends the parent. The `requires` field in the registry entry is for documentation and
pre-flight validation; the actual merge is driven by the directives in the `.scm` files.

### Injection dependencies

If a language's injection queries reference other languages (e.g. HTML injects CSS and
JavaScript), declare those dependencies with `inject_deps` so that CI can build the
required parsers for validation:

In the **registry entry**:

```json
"html": {
  "source": { ... },
  "filetypes": ["html"],
  "inject_deps": ["css", "javascript"]
}
```

In a **query repo's `parser.json`**:

```json
{
  "lang": "html",
  "url": "https://github.com/tree-sitter/tree-sitter-html",
  "semver": true,
  "parser_version": "v0.23.2",
  "inject_deps": ["css", "javascript"]
}
```

For **self-contained** parsers using the reusable CI workflow, pass injection deps as a
comma-separated input:

```yaml
  validate:
    uses: neovim-treesitter/.github/.github/workflows/self-contained-validate.yml@main
    with:
      lang: html
      queries-dir: nvim-queries
      inject-deps: css,javascript
```

Without `inject_deps`, CI cannot validate injection queries that reference parsers not
present in the test environment. The queries will still be syntactically checked, but
injection-specific assertions may be skipped.

---

## Creating a query repo

Each language in the registry with `type: external_queries` or `type: queries_only` needs a
corresponding `nvim-treesitter-queries-<lang>` repository under the `neovim-treesitter` org.

### Repository structure

```
nvim-treesitter-queries-<lang>/
├── parser.json
├── queries/
│   ├── highlights.scm    (required if the language has syntax highlighting)
│   ├── injections.scm    (optional)
│   ├── folds.scm         (optional)
│   ├── indents.scm       (optional)
│   └── locals.scm        (optional)
├── CODEOWNERS
├── README.md
└── .github/
    └── workflows/
        └── validate.yml
```

### parser.json

For a language with no inheritance:

```json
{
  "lang": "mylang",
  "url": "https://github.com/author/tree-sitter-mylang",
  "semver": true,
  "parser_version": "v1.0.0",
  "location": null
}
```

For a language that inherits from another (e.g. a TypeScript-like language inheriting `ecma`):

```json
{
  "lang": "mylang",
  "url": "https://github.com/author/tree-sitter-mylang",
  "semver": true,
  "parser_version": "v1.0.0",
  "location": null,
  "inherits": {
    "ecma": {
      "url": "https://github.com/neovim-treesitter/nvim-treesitter-queries-ecma",
      "parser_version": "v1.0.0"
    }
  }
}
```

The `inherits` map must list every language whose queries you `; inherits:` from in your `.scm`
files. The installer fetches each parent query repo at the exact `parser_version` declared here,
so your queries are always merged against the version you have tested against.

- Set `parser_version` to the exact tag or commit SHA these queries are tested against.
- When adding or updating an `inherits` entry, verify CI passes against the declared parent version.

### CODEOWNERS

Every query repo must have a `CODEOWNERS` file at the root identifying at least one maintainer.
This is how ownership is tracked across the ~330 individual repos:

```
# CODEOWNERS
* @github-username
```

Multiple maintainers are encouraged. The org will periodically audit repos with no active
CODEOWNERS and flag them for adoption or archival.

---

## CI/CD for query repos

Every query repo runs CI on push and pull request to `main`. The workflow is standardised via
the template at `scripts/templates/query-validate.yml` in the `nvim-treesitter` repo.

### What CI validates

1. **Parser manifest** — `parser.json` is read with `jq` and validated against the JSON Schema
2. **Parser build** — the parser source is fetched at `parser_version` and compiled with
   `tree-sitter build` to produce a `.so`
3. **Query correctness** — `ts_query_ls check` is run against the `queries/` directory using
   the compiled parser, catching invalid node names, malformed predicates, and type errors
4. **Inherited queries** — if `parser.json` declares an `inherits` block, CI fetches each parent
   query repo at the declared `parser_version` and validates the merged query set
5. **Injection deps** — if `parser.json` declares `inject_deps`, CI builds those parsers so
   injection queries can be validated

A PR cannot be merged if CI fails. This enforces that every merged query set is known to work
against the exact declared `parser_version`.

### Automated update checks

A scheduled workflow in each query repo (weekly) checks whether a new parser version has been
released that differs from the current `parser_version`:

1. Queries the parser repo's host API for the latest release (or HEAD for non-semver parsers)
2. If a newer version exists and the repo has tests, opens a PR bumping `parser_version` in `parser.json`
3. CI on that PR runs the full validation against the new version
4. If CI passes, the PR can be merged by a maintainer; if it fails, the maintainer knows
   queries need updating before bumping

This means maintainers are notified of upstream parser releases without polling manually.
The PR serves as both the notification and the validation harness.

### Releasing a new query version

Tag the repo with a semver tag:

```bash
git tag v1.2.3
git push --follow-tags
```

Installers discover the new tag via the host API on next update check. No registry change
needed. The tag should reflect the significance of the change:

- **patch** (`v1.0.x`) — query fixes, no grammar node changes required
- **minor** (`v1.x.0`) — new query coverage (new capture names, new injections, etc.)
- **major** (`vx.0.0`) — breaking change in capture name conventions or required parser bump
  that installers need to be aware of

---

## CI/CD for self-contained parser repos

Parser repos that ship their own Neovim queries use a separate reusable workflow
([`self-contained-validate.yml`](https://github.com/neovim-treesitter/.github/blob/main/.github/workflows/self-contained-validate.yml))
and a corresponding template at `scripts/templates/self-contained-validate.yml`.

### What it validates

1. **Parser build** — compiles the parser from the repo itself using `tree-sitter build`
2. **Query correctness** — `ts_query_ls check` against the query directory
3. **Inherited queries** — BFS resolution of `; inherits:` directives across query repos
4. **Injection deps** — builds dependency parsers if `inject-deps` is specified
5. **Highlight tests** — runs highlight assertion tests if `tests/highlights/` exists

### Adding to your parser repo

Add a job to your existing CI workflow (or create a standalone workflow):

```yaml
  nvim-query:
    name: Validate nvim queries
    uses: neovim-treesitter/.github/.github/workflows/self-contained-validate.yml@main
    with:
      lang: mylang
      queries-dir: nvim-queries
```

Available inputs:

| Input | Required | Description |
|-------|----------|-------------|
| `lang` | Yes | Language name (must match `<lang>/` subdirectory under `queries-dir`) |
| `queries-dir` | One of | Parent directory whose `<lang>/` subdirectory has `.scm` files |
| `queries-path` | these | Direct path to directory containing `.scm` files |
| `parser-location` | No | Parser source subdirectory (monorepos) |
| `inject-deps` | No | Comma-separated injection dependency languages |
| `inherits` | No | Comma-separated inherited languages (auto-detected from `.scm` files) |

For a full migration walkthrough, see the
[Self-Contained Migration Guide](self-contained-migration.md).

---

## Registry-level CI

The registry itself runs a
[validation workflow](https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/.github/workflows/validate.yml)
on push, PR, and weekly cron:

1. **Schema validation** — `registry.json` is validated against `schemas/schema.json`
2. **URL reachability** — all parser and query URLs are checked (warn-only, non-blocking)
3. **Query repo health** — polls the latest CI run status for every query repo and
   creates/updates a tracking issue listing failures

This provides a single dashboard view of ecosystem health across all languages.

---

## Maintaining an existing query repo

### When the parser releases a new version

The automated update check (above) will open a PR if tests exist. If you prefer to do this manually:

1. Create a branch, update `parser_version` in `parser.json` to the new tag or SHA
2. Run CI — if it passes, merge; `parser_version` has moved forward
3. If CI fails, fix the queries for the new grammar in the same branch before merging

### When an inherited query repo releases a new version

If `ecma` releases `v2.0.0` and your `typescript` queries declare `"inherits": { "ecma": { "parser_version": "v1.0.0" } }`:

1. The installer will continue using the pinned ecma `v1.0.0` — your users are unaffected immediately
2. Test against the new ecma version by bumping `inherits.ecma.parser_version` in a branch
3. If CI passes, update the pin; your users now get the improved ecma queries
4. If CI fails, the ecma change broke something in the merged set — fix your queries or wait
   for ecma to publish a fix, then update the pin

### When queries need a fix unrelated to the parser

Open a PR, fix the `.scm` files, ensure CI passes, merge. Tag a new patch release.
No registry change needed.

---

## Migration tooling

The migration from the monolithic `nvim-treesitter` repo to this distributed model is handled
by tooling in the `nvim-treesitter` repository.

### Intent

The migration has three phases:

**Phase 1 — Infrastructure** *(in progress)*
Set up this registry repo, define `parser.json` format and JSON Schema, establish CI templates,
create the `neovim-treesitter` org, create concrete query repos for a small set of well-understood
languages (python, rust, typescript, ecma, javascript) to validate the structure before bulk
creation.

**Phase 2 — Bulk repo creation**
Run `scripts/create-query-repos.sh` to generate all ~330 query repos from the existing
`runtime/queries/` directory. Each repo gets:
- Query `.scm` files copied verbatim from the current nvim-treesitter tree
- A `parser.json` generated by `scripts/gen-parser-manifest.lua` (infers semver from the
  current revision; sets `parser_version` if the revision is a tag, leaves it null otherwise)
- The standard CI workflow and README template
- An initial commit tagged `v0.1.0`

At this point all queries exist in standalone repos but nvim-treesitter still serves as the
canonical source during the transition.

**Phase 3 — Ownership and cutover**
- Announce the new repos to the community and solicit maintainers
- Each repo that gains a `CODEOWNERS` entry is considered adopted
- nvim-treesitter's installer is updated to fetch from the registry rather than from its own
  `runtime/queries/` directory
- The `runtime/queries/` directory in nvim-treesitter is removed once all installers can source
  queries from the distributed repos
- Unadopted repos remain under org maintainer ownership until claimed or archived

### Migration scripts

| Script | Location | Purpose |
|--------|----------|---------|
| `gen-parser-manifest.lua` | `nvim-treesitter/scripts/` | Reads `parsers.lua`, emits `parser.json` for one lang |
| `create-query-repos.sh` | `nvim-treesitter/scripts/` | Bulk creates GitHub repos, populates content, tags v0.1.0 |

Both scripts are designed to be idempotent — running `create-query-repos.sh` for a lang that
already has a repo skips it. The manifest script can be re-run at any time to regenerate
`parser.json` from the current state of `parsers.lua`.

### Post-migration state

Once migration is complete, nvim-treesitter no longer contains query files. It becomes a thin
installer that:
- Reads `registry.json` from this repo (cached locally)
- Fetches parser sources and query repos on demand
- Handles compilation, caching, and the `:TSInstall` / `:TSUpdate` UX

Other installers can adopt the same registry and query repos without duplicating the query
maintenance effort. The registry schema is open and documented — any installer that can
fetch and parse JSON can consume it.

---

## Governance and ownership

### Org structure

The `neovim-treesitter` GitHub org owns:
- This registry repo (`treesitter-parser-registry`)
- All `nvim-treesitter-queries-<lang>` repos
- The `nvim-treesitter` installer fork

Org-level maintainers have admin access across all repos. Per-language maintainers have write
access to their specific query repos via GitHub teams.

### Query repo ownership model

Each query repo is intended to be owned by its community of users, not by the org maintainers
centrally. The model:

- **Maintainer** — anyone listed in `CODEOWNERS`. Can merge PRs, cut releases, update
  `parser.json` bounds. Ideally someone who uses the language daily and tracks upstream grammar
  development.
- **Contributor** — anyone who opens a PR. No special access required. PRs must pass CI.
- **Org maintainer** — fallback owner for repos without active maintainers. Will merge
  community PRs but should not be the primary driver of language-specific query work.

### Claiming maintainership

To become a maintainer of a query repo:

1. Open a PR adding yourself to `CODEOWNERS`
2. Include a brief note in the PR description about your familiarity with the language and
   willingness to track upstream grammar releases
3. An org maintainer will approve and grant write access via a GitHub team

There is no vetting process beyond demonstrated interest. Maintainership can be shared — more
is better for active languages.

### Unmaintained repos

A query repo is considered unmaintained if:
- No `CODEOWNERS` entry exists, or all listed owners have been inactive for > 6 months
- CI has been failing for > 30 days with no open PR to fix it

Unmaintained repos are flagged in their README with a notice and listed in a tracking issue in
this repo. They remain installable but users are warned. Anyone can claim them by following the
process above.

Repos that cannot be revived (e.g. language is abandoned upstream) are archived rather than
deleted, preserving history for anyone who needs them.

### Relationship to upstream parser projects

This org does not own or control upstream tree-sitter grammar repositories. The registry
records where they live; it does not gate their releases. Parser authors who want to ship their
own Neovim queries (`self_contained` source type) are welcome to do so — the registry entry
just points at their repo and the installer fetches from there directly.
