# README-fork.md

Maintenance notes for **kendall's fork** of `code-review-graph`
(`github.com/kendall/code-review-graph`, `origin`), tracking upstream
`tirth8205/code-review-graph` (`upstream`).

This document records what this fork changes, how it's installed and wired
into the `wb` project, the helper tooling around it, and the gotchas that
will bite if forgotten. It is fork-local — **do not** expect it upstream.

---

## 1. What this fork adds over upstream

One feature commit on `main`:

```
7aae283  feat: fix Zig parsing (grammar drift) and add Gleam support
```

Two languages, both validated end-to-end on the 200k-line `wb` repo:

### Zig — fixed (was silently broken upstream)

Zig was wired into upstream's parser but extracted **almost nothing**: the
bundled `tree-sitter-zig` grammar had drifted to **PascalCase** node types
(`FnProto`, `ContainerDecl`, `VarDecl`, `Decl`, `TestDecl`) while the parser's
mappings still used the old snake_case names (`fn_proto`,
`container_declaration`, `call_expression`). Every mapping missed.

The fix is a dedicated `_extract_zig_constructs` handler in
`code_review_graph/parser.py` (mirroring the Elixir/Nix/Julia handlers),
because Zig's structure doesn't fit the generic walker — a function is
`Decl > [FnProto, Block]` where the body `Block` is a **sibling** of the
signature, not a child. The handler extracts:

- **Functions** — `FnProto` name + recursion into the sibling `Block` so body
  calls attribute to the function.
- **Containers** — struct / enum / union / `opaque`, modeled as `Class`,
  tagged via `extra["zig_kind"]`.
- **Struct methods** — `Decl > FnProto` inside a container, attached to their
  type (`compute_crc` → `WaxHeader`).
- **Imports** — `const x = @import("…")` → `IMPORTS_FROM`.
- **Tests** — `test "…" { }` → `Test` node (named from the string literal).
- **Calls** — anchored on `FnCallArguments` + `prev_named_sibling`. A real
  call's preceding sibling is an `IDENTIFIER`; `@import`/builtins are
  `BUILTINIDENTIFIER` and are filtered out, so no phantom edges. `union(enum)`
  payloads produce no stray call either (guarded by a test).

### Gleam — new (absent upstream)

Gleam fits the generic machinery (a `function` node *contains* its `block`
body), so support is the four node-type table entries plus small
**language-gated** branches:

- `EXTENSION_TO_LANGUAGE`: `.gleam` → `gleam`.
- `_CLASS_TYPES`: `type_definition`, `type_alias` → `Class`.
- `_FUNCTION_TYPES`: `function`.
- `_IMPORT_TYPES`: `import`.
- `_CALL_TYPES`: `function_call`.
- `_get_name`: type name lives in `type_name > type_identifier`.
- `_get_call_name`: qualified calls (`io.println`) are `field_access > label`.
- `_extract_import`: the `module` child holds the slash-path (plain,
  unqualified-list `.{map}`, and aliased `as str` all resolve to the path).
- `_get_params`: `function_parameters`.
- `*_test` functions are auto-classified as `Test` via the existing
  `_TEST_PATTERNS`.

### Supporting changes

- **Grammar pinned** to `tree-sitter-language-pack==0.13.0` in `pyproject.toml`
  (+ `uv.lock`). See §6 — this is the single most important maintenance item.
- **Fixtures**: `tests/fixtures/sample.zig`, `tests/fixtures/sample.gleam`.
- **Tests**: 19 new in `tests/test_multilang.py` (`TestZigParsing`,
  `TestGleamParsing`) that assert *specific* node/edge structure (counts,
  names, method attribution, phantom-edge guards) — so the next grammar drift
  fails loudly instead of silently degrading.
- **Docs**: Gleam added to `README.md`, `docs/FEATURES.md`, `docs/USAGE.md`,
  `docs/LLM-OPTIMIZED-REFERENCE.md`, and the four localized READMEs.
- **CHANGELOG.md**: an `[Unreleased]` entry.

### Quality gates (all green at commit time)

- `uv run pytest tests/` → **1293 passed**, 1 skipped, 2 xpassed
- `uv run --with ruff ruff check …` → clean
- `uv run --with mypy mypy code_review_graph/parser.py …` → clean

---

## 2. Local install (this fork's build, not PyPI)

The published PyPI package does **not** have the Gleam fix. You must run the
fork's code. It's installed as an isolated global tool:

```bash
uv tool install --force /home/k/pentad/code-review-graph
```

This produces two executables on PATH (`~/.local/bin`):

| Binary | Path |
|---|---|
| `code-review-graph` | `/home/k/.local/bin/code-review-graph` |
| `crg-daemon` | `/home/k/.local/bin/crg-daemon` |

> **Not editable.** `uv tool install` copies/builds — it does **not** link to
> the checkout. After any further parser change (and commit), re-run
> `uv tool install --force /home/k/pentad/code-review-graph` to pick it up.

Verify it's the fork build (parses Gleam):

```bash
cd /home/k/pentad/wb && code-review-graph status | grep Languages
# → Languages: bash, zig, elixir, javascript, gleam, python, sql, objc, go
```

---

## 3. wb wiring

### Graph build

```bash
cd /home/k/pentad/wb
code-review-graph build      # → wb/.code-review-graph/graph.db
```

Headline on wb: **1084 files, 14,171 nodes, 104,808 edges in ~4s**.
Node counts: Gleam 8,292 · Zig 4,564 (+ elixir/python/bash/go/sql/js/objc).
Zig containers: 349 struct · 49 enum · 4 union · 1 `opaque`.

### DB is git-ignored locally (no tracked-file change)

The 100 MB `graph.db` is excluded via `wb/.git/info/exclude` — a **local-only**
ignore that touches no tracked file and is never committed:

```
# in /home/k/pentad/wb/.git/info/exclude
.code-review-graph/
```

### MCP server (user scope → fork binary → wb)

```bash
claude mcp add code-review-graph -s user -- \
  /home/k/.local/bin/code-review-graph serve --repo /home/k/pentad/wb
```

Stored in `~/.claude.json` (user scope), so opening Claude Code **in wb** gets
the fork's graph tools automatically. The explicit `--repo` makes it target wb
regardless of launch cwd.

---

## 4. Helper script: `wb-agents`

`/home/k/.local/bin/wb-agents` (executable, on PATH). Ensures the watch daemon
is keeping wb's graph fresh, then launches `claude agents` in wb:

```bash
wb-agents          # ensure daemon up, then `claude agents` in wb
wb-agents <args>   # extra args forwarded to `claude agents`
```

What it does:
1. `crg-daemon add /home/k/pentad/wb` — idempotent (dedupes by path).
2. Starts `crg-daemon` **only if not already running** (`start` hard-exits
   non-zero when up; the guard greps `status` for `running (PID …)`).
3. `cd /home/k/pentad/wb && exec claude agents "$@"`.

Edit the `REPO=` line to repoint it. Fish convenience: `abbr -a wba wb-agents`.

---

## 5. The watch daemon (freshness)

The graph is a snapshot; the daemon keeps it current.

```bash
crg-daemon status               # daemon + per-repo watcher state
crg-daemon add /home/k/pentad/wb
crg-daemon start                # daemonizes (backgrounds itself)
crg-daemon stop
crg-daemon logs --repo wb -f
```

- Config: `~/.code-review-graph/watch.toml` (wb is registered, alias `wb`).
- **Persists across sessions** until `crg-daemon stop`.
- **Freshness split:** the *daemon writes* `graph.db` on file changes; the
  *MCP server reads* it (`serve --repo wb`, no `--auto-watch`). SQLite WAL
  handles the concurrent read/write cleanly.
- First start after idle may take a few seconds (incremental catch-up), then
  near-instant on saves.

Manual alternative if you skip the daemon: `code-review-graph update` from
inside wb (incremental, ~seconds).

---

## 6. ⚠️ Warnings / gotchas

1. **The `uvx` / PyPI trap.** The installer's command auto-detector
   (`skills._detect_serve_command`) will write `uvx code-review-graph serve`
   into MCP config when run outside a uv project — which pulls the **old PyPI
   build with no Gleam**. The crg repo's *own* `.mcp.json` does exactly this,
   so the `code-review-graph` server you see connected *inside the crg repo* is
   the PyPI build. Always wire wb (and any consumer) with the **absolute path**
   to `/home/k/.local/bin/code-review-graph` as in §3.

2. **MCP name collision warning.** `claude mcp list` warns that
   `code-review-graph` is defined in two scopes: user (fork binary → wb) and
   the crg repo's project `.mcp.json` (uvx → PyPI). **Harmless** — they apply
   to different projects (project scope overrides only when you're in the crg
   repo; wb has no project config, so it uses the user-scope fork binary). Live
   with it, or rename one.

3. **Grammar drift is the recurring threat.** Zig broke upstream precisely
   because `tree-sitter-language-pack` was unpinned and the grammar's node-type
   names changed under it. The pin (`==0.13.0`) + the structure-asserting
   fixture tests are the defense. **Before bumping the pin**, re-dump the node
   types and re-run the suite (procedure in §7).

4. **Vendor code is excluded by design — and not overridable today.**
   `vendor/**` is in `DEFAULT_IGNORE_PATTERNS` (`incremental.py`), along with
   `node_modules/`, `target/`, etc. This keeps the graph a map of *your* code
   (token efficiency, review-focused). There is **no flag, env var, or
   `!vendor/**` negation** to re-include it without a code change. Measured
   cost on wb if you ever do (it rarely vendors, so this was left as-is):

   | | files | zig files | nodes | CALLS | resolved |
   |---|---|---|---|---|---|
   | no-vendor (default) | 1084 | 273 | 13,946 | 70,358 | 16,636 (23%) |
   | with-vendor | 1315 | 323 | 15,321 | 82,827 | 18,439 (22%) |

   ~+10% nodes for ~+1,800 resolved calls into deps. If wanted, the clean
   design is *parse-but-tag* (resolve edges into vendor, but mark the nodes so
   review/search/communities de-weight them) — not flipping the default.

5. **Install is a snapshot, not a link.** See §2 — re-`uv tool install --force`
   after every change you want live.

---

## 7. Maintenance

### Re-run the suite

```bash
cd /home/k/pentad/code-review-graph
uv run pytest tests/ -q
uv run pytest tests/test_multilang.py -k "Zig or Gleam"   # the fork's tests
```

### Bump the grammar pin safely

The pin exists because node-type names are version-specific. To raise it:

1. Edit `pyproject.toml` (`tree-sitter-language-pack==<new>`), `uv lock`.
2. Re-dump the node types the parser depends on:

   ```bash
   uv run python - <<'PY'
   import tree_sitter_language_pack as tslp
   for lang, src in [("zig", b'fn add(a:i32)i32{return a;}\n'),
                     ("gleam", b'pub fn add(a:Int)->Int{a}\n')]:
       t = tslp.get_parser(lang).parse(src)
       def w(n,d=0):
           if n.is_named: print("  "*d, n.type)
           for c in n.children: w(c,d+1)
       print("==", lang); w(t.root_node)
   PY
   ```

   If `FnProto`/`ContainerDecl`/`FnCallArguments` (Zig) or
   `function`/`type_definition`/`function_call`/`field_access` (Gleam) changed,
   update the mappings/handlers in `parser.py`.
3. `uv run pytest tests/test_multilang.py -k "Zig or Gleam"`. The
   structure-asserting tests fail loudly if anything drifted — that's the
   signal to fix mappings, not to loosen the tests.
4. Re-install: `uv tool install --force /home/k/pentad/code-review-graph`.

### Adding another language (the discipline that kept this safe)

Gate every language-specific branch by `if language == "…"` in the shared
helpers (`_get_name`, `_get_call_name`, `_get_params`, `_extract_import`).
**Never widen a shared node-type tuple** (e.g. don't add `field_access` to the
generic `member_types` — Java emits it too). Add a fixture + count-and-name
assertions. Run the *full* suite, since those helpers are shared.

### Sync with upstream

```bash
git fetch upstream
git merge upstream/main        # or rebase; resolve parser.py / docs conflicts
uv run pytest tests/ -q
uv tool install --force /home/k/pentad/code-review-graph
git push origin main
```

---

## 8. Quick reference

```bash
# rebuild fork binary after a change
uv tool install --force /home/k/pentad/code-review-graph

# work in wb with a fresh graph + agents
wb-agents

# manual graph refresh / status (in wb)
code-review-graph update
code-review-graph status

# daemon control
crg-daemon status | start | stop | logs --repo wb -f

# undo everything
claude mcp remove code-review-graph -s user
crg-daemon stop && crg-daemon remove /home/k/pentad/wb
uv tool uninstall code-review-graph
rm -rf /home/k/pentad/wb/.code-review-graph
rm /home/k/.local/bin/wb-agents
```

| Thing | Location |
|---|---|
| Fork CLI | `/home/k/.local/bin/code-review-graph` |
| Daemon | `/home/k/.local/bin/crg-daemon` |
| Launcher | `/home/k/.local/bin/wb-agents` |
| Daemon config | `~/.code-review-graph/watch.toml` |
| MCP config (user) | `~/.claude.json` |
| wb graph DB | `/home/k/pentad/wb/.code-review-graph/graph.db` |
| wb local ignore | `/home/k/pentad/wb/.git/info/exclude` |
| Feature commit | `7aae283` on `main` |
