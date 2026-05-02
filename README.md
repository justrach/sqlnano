# sqlnano

A small embeddable SQL engine in Zig 0.16 with a SQLite `.db` compatibility track.

The first public story:

> sqlnano is a small embeddable Zig SQL engine with a lightweight core, a
> SQLite `.db` compatibility track, an incremental prepared-statement API, and
> honest benchmarks against SQLite and Turso. The first compatibility milestone
> is safe SQLite database identification and read-only header parsing, followed
> by read-only table scanning before any SQLite-compatible writes.

## Status

See [`src/sqlite/parity.zig`](src/sqlite/parity.zig) for the live tracker. Run

```sh
zig build run -- parity
```

to print the current matrix.

Highlights:

- Reads SQLite `.db` files: header validation, `sqlite_schema`, table b-tree
  scans (rowid + interior), simple non-unique single-column indexes, payload
  overflow.
- Writes via a native WAL (`*-snwal` beside the data file): group commit, one
  fsync per op in steady state, deferred checkpoint + compact, crash recovery
  on reopen, and torn-WAL truncation. Verified by a fuzz test that walks every
  byte offset.
- Tables grow past one page via interior-root + multi-leaf splits, validated
  by `PRAGMA integrity_check`. Indexes still single-leaf for now.

## Build & test

```sh
zig build              # builds the static library and the `sqlnano` CLI
zig build test         # runs the test suite (Debug)
zig build test -Doptimize=ReleaseFast  # runs the heavier split tests
```

`sqlite3` on PATH is required for the integration tests; they `SkipZigTest`
when it is missing.

## CLI

```sh
sqlnano inspect path.db
sqlnano select  path.db 'SELECT name FROM users WHERE id = 1'
sqlnano exec    path.db "INSERT INTO users VALUES (NULL, 'alice', 30)"
sqlnano wal-checkpoint path.db
sqlnano bench-write    path.db users 1000
sqlnano parity
```

## Benchmarks

Both engines compiled `-O3`/`ReleaseFast`, same fixture
(`CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER)`), same SQL, same
prepared-statement autocommit loop, macOS APFS, warm fs cache. SQLite
is the release-build amalgamation 3.50.0.

**Inserts (matched durability — this is the only fair comparison):**

| N | config | sqlnano | SQLite | ratio |
|---:|---|---:|---:|---:|
| 1,000  | FULL   | 37,939  | 25,334  (WAL)  | **sqlnano 1.50x** |
| 1,000  | NORMAL | **399k** | 122k (WAL) | **sqlnano 3.3x** |
| 10,000 | FULL   | 38,275  | 33,374  (WAL)  | **sqlnano 1.15x** |
| 10,000 | NORMAL | **193k** | 158k (WAL) | **sqlnano 1.22x** |
| 50,000 | NORMAL | 53k  | 172k (WAL) | SQLite 3.2x |

At 50k rows SQLite pulls ahead because sqlnano's fast path
(O(1) rightmost-leaf append) falls back to a full tree rebuild when a
leaf fills. The next optimization is a proper in-place leaf split.

**Reads (same durability, same fixture):**

| Test | sqlnano | SQLite native C | ratio |
|---|---:|---:|---:|
| Point read by rowid | 9.96M ops/sec | 260K ops/sec | **sqlnano 38x** |
| Full table scan | 20.4M rows/sec | 40M rows/sec | SQLite 1.95x |

### Reproduce

```sh
zig build -Doptimize=ReleaseFast
rm -f /tmp/t.db /tmp/t.db-snwal
sqlite3 /tmp/t.db 'CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER);'
./zig-out/bin/sqlnano bench-write /tmp/t.db t 10000 normal   # synchronous=NORMAL
./zig-out/bin/sqlnano bench-write /tmp/t.db t 10000 full     # synchronous=FULL (default)
./zig-out/bin/sqlnano bench-write /tmp/t.db t 10000 off      # no durability
```

### What makes the fast path fast

1. **Native WAL** (`*-snwal`) — group-commit, one fsync per op in steady
   state, deferred checkpoint/compact, crash recovery on reopen. Fuzz
   tested against every byte offset.
2. **In-memory data-file image** — `Connection` loads the DB once, all
   ops mutate in RAM, `writeFile` only fires on flush/close.
3. **Per-table auto-rowid cache** — first `VALUES (NULL, ...)` triggers
   one `scanTable` to seed; subsequent inserts hit cache.
4. **Incremental rightmost-leaf append** — when no indexes and the
   rightmost leaf has room, we stamp one cell directly into the page
   (pointer-array + cell_count + content_start_abs) instead of
   rebuilding the b-tree.
5. **Per-op arena allocator** backed by the page allocator — schema
   view, `TableInfo`, WAL payload, cell envelope all allocate into the
   arena and come free on the next op's reset. Steady state is ~zero
   malloc/free pairs per op. (Hack borrowed from
   [justrach/codedb](https://github.com/justrach/codedb).)
6. **Stack buffer for small cells** — a 256-byte stack slice handles
   the cell envelope for typical rows; larger rows fall through to the
   arena.
7. **Configurable `synchronous`** — `full` (fsync per commit, power-loss
   safe, default), `normal` (fsync on checkpoint only, matches SQLite
   WAL+NORMAL), `off` (never fsync).

## License

[Server Side Public License v1, with an author exception for justrach](LICENSE).
The exception lets justrach (and software/services owned by justrach) offer
sqlnano as a service without the SSPL §13 obligations; everyone else is bound
by full unmodified SSPL.

## Layout

```
src/sqlnano.zig          public API surface
src/main.zig             CLI
src/sqlite/header.zig    SQLite database header parser
src/sqlite/page.zig      Page reader
src/sqlite/btree.zig     B-tree page header
src/sqlite/record.zig    Record decoder
src/sqlite/varint.zig    SQLite varint
src/sqlite/schema.zig    sqlite_schema reader
src/sqlite/catalog.zig   CREATE TABLE column resolver
src/sqlite/table.zig     Table b-tree walker
src/sqlite/index.zig     Index b-tree walker
src/sqlite/tokenizer.zig SQL tokenizer
src/sqlite/parser.zig    SQL parser (SELECT/INSERT/UPDATE/DELETE subset)
src/sqlite/ast.zig       Tiny AST
src/sqlite/sql.zig       Query executor
src/sqlite/wal.zig       Native sqlnano WAL (group commit + crash recovery)
src/sqlite/wal_codec.zig WAL payload codec
src/sqlite/write.zig     INSERT/UPDATE/DELETE + b-tree splits
src/sqlite/parity.zig    Compatibility tracker
```

## Plan

[`plan.md`](plan.md) is the execution roadmap. [`architecture.md`](architecture.md)
holds the technical contracts.
