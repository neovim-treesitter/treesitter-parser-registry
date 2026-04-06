# Testing

Each language's query repository (`nvim-treesitter-queries-<lang>`) ships a standardised CI workflow (`query-validate.yml`) that runs two types of validation:

1. **Query validation** — `ts_query_ls check queries/` verifies structural correctness of every `.scm` file
2. **Corpus tests** — `tree-sitter test` runs parse tree snapshot tests from `test/corpus/*.txt` when present

Both must pass for a PR to merge.

---

## Query validation with `ts_query_ls`

`ts_query_ls` is an LSP server that understands tree-sitter query syntax. Its `check` subcommand runs a static analysis pass over every `.scm` file in the target directory and exits non-zero on any error.

### What it checks

- **Node type validity** — every node name (e.g. `(function_definition)`) must exist in the language's grammar
- **Field validity** — field names (e.g. `name:`) must be declared for that node type
- **Predicate syntax** — predicates like `(#eq? @a @b)` and `(#match? @cap "pattern")` are validated for correct arity and capture reference
- **Capture names** — captures referenced in predicates must be defined in the same pattern
- **Inherits resolution** — queries from inherited languages must be resolvable (see [Dependency query resolution](#dependency-query-resolution))

### Running locally

```sh
ts_query_ls check queries/
```

`ts_query_ls` reads `.tsqueryrc.json` from the working directory to locate grammars and dependency queries. A minimal config:

```json
{
  "parser_install_directories": ["~/.local/share/nvim/lazy/nvim-treesitter/parser"],
  "language_retrieval_patterns": [
    "queries/([^/]+)/[^/]+\\.scm$"
  ]
}
```

When dependency queries are present locally (see below), add the `query-deps/` path:

```json
{
  "parser_install_directories": ["~/.local/share/nvim/lazy/nvim-treesitter/parser"],
  "language_retrieval_patterns": [
    "queries/([^/]+)/[^/]+\\.scm$",
    "query-deps/([^/]+)/[^/]+\\.scm$"
  ]
}
```

### Interpreting errors

Output follows LSP diagnostic format:

```
queries/highlights.scm:14:3: error: Unknown node type `expresion`
queries/injections.scm:8:1: error: Predicate `#match?` expects 2 arguments, got 1
```

Each line is `file:line:col: severity: message`. Errors are fatal; warnings are informational.

---

## Corpus tests

Corpus tests verify that the tree-sitter parser produces the expected parse tree for a given input. They are parse tree snapshots: if the grammar changes in a way that alters the tree, the test fails.

CI runs corpus tests only when the `test/corpus/` directory exists in the repository. If you add corpus tests, CI picks them up automatically.

### Corpus file format

Tests live in `test/corpus/*.txt`. Each file can contain multiple test cases separated by `================================================================================` (80 `=` characters).

```
================================================================================
Function definition
================================================================================

def greet(name):
    return name

--------------------------------------------------------------------------------

(module
  (function_definition
    name: (identifier)
    parameters: (parameters
      (identifier))
    body: (block
      (return_statement
        (identifier)))))

================================================================================
Empty function
================================================================================

def noop():
    pass

--------------------------------------------------------------------------------

(module
  (function_definition
    name: (identifier)
    parameters: (parameters)
    body: (block
      (pass_statement))))
```

Structure of each test case:

- **Header** — `===` line, test name on its own line, `===` line
- **Input** — the source code to parse (blank line before and after)
- **Separator** — `---` line (80 `-` characters)
- **Expected tree** — S-expression matching `tree-sitter parse` output (blank line before and after)

### Writing good tests

- Name tests after the construct being tested, not the file it came from (`Function with default argument`, not `test1`)
- Cover error recovery: include a test with deliberate syntax errors to document how the parser handles them; wrap the error node explicitly: `(ERROR)`
- Keep inputs minimal — one construct per test case makes failures easy to diagnose
- Test edge cases: empty bodies, Unicode identifiers, deeply nested structures, trailing commas
- Avoid testing constructs that belong to an inherited language; those are covered by the parent language's own corpus

### Running locally

Run all corpus tests:

```sh
tree-sitter test
```

Run a single test case by name (substring match):

```sh
tree-sitter test -f "Function definition"
```

This requires a compiled parser. If `tree-sitter build` hasn't been run yet:

```sh
tree-sitter build
tree-sitter test
```

### Updating snapshots

When the grammar changes intentionally and the new parse tree is correct, update snapshots in bulk:

```sh
tree-sitter test --update
```

This rewrites the expected tree sections in-place. Review the diff before committing — every changed snapshot is a semantic change to the parser's output contract.

---

## Dependency query resolution

Some query files inherit queries from another language using a directive on the first line:

```scheme
; inherits: javascript
```

This means the query consumer (Neovim) prepends the inherited language's queries before evaluating the file. `ts_query_ls` must also be able to find those queries to validate predicates and captures that reference inherited node types.

### How CI resolves dependencies

The `query-validate.yml` workflow performs a BFS traversal of the `; inherits:` graph before running `ts_query_ls`. For each dependency language `<dep>`:

1. The workflow fetches query files from `nvim-treesitter-queries-<dep>` (the corresponding repo for that language)
2. Files are written to `query-deps/<dep>/` inside the workspace
3. A `.tsqueryrc.json` is written dynamically that includes `query-deps/([^/]+)/[^/]+\.scm$` in `language_retrieval_patterns`

`ts_query_ls` then resolves `; inherits: <dep>` by matching the pattern against files under `query-deps/<dep>/`.

### Replicating dependency resolution locally

To run `ts_query_ls check queries/` locally with inherited queries:

1. Create the `query-deps/<dep>/` directory:

   ```sh
   mkdir -p query-deps/javascript
   ```

2. Copy (or symlink) the parent language's query files into it:

   ```sh
   cp /path/to/nvim-treesitter-queries-javascript/queries/*.scm query-deps/javascript/
   ```

   Or clone the dep repo:

   ```sh
   git clone https://github.com/nvim-treesitter/nvim-treesitter-queries-javascript /tmp/ts-queries-js
   cp /tmp/ts-queries-js/queries/*.scm query-deps/javascript/
   ```

3. Write a `.tsqueryrc.json` that includes the `query-deps/` retrieval pattern:

   ```json
   {
     "parser_install_directories": ["~/.local/share/nvim/lazy/nvim-treesitter/parser"],
     "language_retrieval_patterns": [
       "queries/([^/]+)/[^/]+\\.scm$",
       "query-deps/([^/]+)/[^/]+\\.scm$"
     ]
   }
   ```

4. Run the check:

   ```sh
   ts_query_ls check queries/
   ```

For a language with transitive dependencies (e.g. `typescript` inherits `javascript` which inherits nothing), repeat step 2 for each dependency in the inheritance chain.

---

## Running CI locally

The `query-validate.yml` workflow does the following in order. To replicate it on a local checkout:

```sh
# 1. Resolve dependency queries (repeat for each ; inherits: <dep>)
mkdir -p query-deps/<dep>
cp /path/to/nvim-treesitter-queries-<dep>/queries/*.scm query-deps/<dep>/

# 2. Write .tsqueryrc.json
cat > .tsqueryrc.json <<'EOF'
{
  "parser_install_directories": ["~/.local/share/nvim/lazy/nvim-treesitter/parser"],
  "language_retrieval_patterns": [
    "queries/([^/]+)/[^/]+\\.scm$",
    "query-deps/([^/]+)/[^/]+\\.scm$"
  ]
}
EOF

# 3. Run query validation
ts_query_ls check queries/

# 4. Run corpus tests (if test/corpus/ exists)
if [ -d test/corpus ]; then
  tree-sitter build
  tree-sitter test
fi
```

Both steps must exit 0 for CI to pass. Query validation failures are reported as LSP diagnostics (see [Interpreting errors](#interpreting-errors)); corpus test failures print the input, the expected tree, and the actual tree side-by-side.
