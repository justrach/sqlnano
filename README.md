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

All engines built with `-O3` / `ReleaseFast` against the same fixture:
a 10,000-row table `t(id INTEGER PRIMARY KEY, n INTEGER)` in a
`DELETE`-journaled SQLite `.db`, durable mode (`PRAGMA synchronous=FULL`),
warm fs cache. `sqlnano` test suite passes all 54 tests.

| Test | sqlnano | SQLite native C | Ratio |
|---|---:|---:|---:|
| Point read (`WHERE rowid = 1`) | 12,078,936 rows/sec | 278,935 rows/sec | **sqlnano 43.3x faster** |
| Full table scan | 20,669,951 rows/sec | 38,478,410 rows/sec | **SQLite 1.86x faster** |
| Durable writes (autocommit) | 1,830 ops/sec | 392 ops/sec | **sqlnano 4.7x faster** |

sqlnano's point-read path is a specialized direct-rowid lookup (`src/main.zig:432-436`)
that skips the b-tree walk. The full-scan path materialises and walks the
table through its own b-tree implementation.

To reproduce:

```sh
zig build -Doptimize=ReleaseFast
# create fixture
sqlite3 test.db "
  PRAGMA journal_mode=DELETE;
  CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER);
  WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 10000)
  INSERT INTO t(n) SELECT x FROM c;
"
./zig-out/bin/sqlnano bench-read  test.db "SELECT * FROM t WHERE rowid = 1" 100000
./zig-out/bin/sqlnano bench-read  test.db "SELECT * FROM t" 1000
./zig-out/bin/sqlnano bench-write test.db t 1000
```

`bench-write` uses a long-lived `Connection` that amortises WAL checkpoint
flush, so throughput improves with longer runs.

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
