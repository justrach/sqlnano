# sqlnano Plan

## Purpose

`sqlnano` is a tiny embeddable SQL engine in Zig 0.16.0. It should carry forward what worked in TurboDB: a fast native core, compact storage, zero-copy reads, simple APIs, and benchmarks from day one.

This plan is the execution roadmap. The technical contracts live in `architecture.md`. If the two documents disagree, treat `architecture.md` as authoritative for design contracts and this file as authoritative for sequencing.

## Product thesis

Build a lightweight SQL database that is useful before it is huge.

The first public story should be:

> sqlnano is a small embeddable Zig SQL engine with a lightweight core, a SQLite `.db` compatibility track, an incremental prepared-statement API, and honest benchmarks against SQLite and Turso. The first compatibility milestone is safe SQLite database identification and read-only header parsing, followed by read-only table scanning before any SQLite-compatible writes.

## Compatibility-first direction

The first implementation should stay lite while making SQLite `.db` compatibility a first-class track. Compatibility progress is tracked in code by `src/sqlite/parity.zig`; run `sqlnano parity` after meaningful feature work and update the table when a feature's status changes.

1. Detect SQLite database files safely.
2. Parse and validate the 100-byte SQLite database header.
3. Open SQLite `.db` files in read-only mode first.
4. Read `sqlite_schema` from compatible files.
5. Decode SQLite table b-tree pages for simple rowid tables.
6. Execute a small SQL subset against SQLite files.
7. Add sqlnano-native writes separately until SQLite-compatible writes are proven safe.

This means we can be backward-compatible with existing `.db` files for reads before promising write compatibility. Write compatibility is much riskier because a bad writer can corrupt user data.

## Non-goals for the first version

- SQLite-compatible writes to existing `.db` files.
- Full SQLite SQL compatibility.
- Distributed replication.
- Sharding.
- Vector search.
- HTTP server.
- Authentication.
- Cloud control plane.
- Multi-language drivers beyond the initial C ABI.
- Query optimizer sophistication beyond simple rowid scans and table scans.

These can come later, but the first version should stay small and credible.

## What we learned from TurboDB

TurboDB was effective because it separated a fast core from thin access layers. The lessons to carry into sqlnano are:

1. Keep the storage core dependency-light.
2. Make the happy path obvious: open, execute, query, close.
3. Use compact record formats.
4. Prefer zero-copy reads where lifetimes are clear.
5. Add WAL early, not as an afterthought.
6. Measure subsystem speed separately from binding/protocol speed.
7. Expose useful APIs before adding distributed features.
8. Avoid feature sprawl until the core is boring.

## Workstreams

### Workstream A: Core SQL vertical slice

Goal: `CREATE TABLE`, `INSERT`, and `SELECT` working through a prepared-statement API using in-memory storage first.

Deliverables:

- SQL tokenizer.
- Minimal AST.
- Parser for the first SQL subset.
- Binder/name resolver.
- SQL value model.
- Row encoder/decoder.
- Register VM.
- In-memory storage backend.
- Prepared statement API.
- End-to-end tests.

### Workstream B: Durable storage

Goal: replace the in-memory backend with a native file-backed storage layer inspired by TurboDB.

Deliverables:

- mmap/file abstraction.
- Pager.
- Page allocator.
- Table B+tree.
- WAL.
- Recovery.
- Catalog persistence.
- Crash/reopen tests.

### Workstream C: Useful embedded API

Goal: make sqlnano easy to use from Zig and C.

Deliverables:

- Zig API.
- C ABI with opaque handles.
- `prepare`, `step`, `column`, `reset`, `finalize`.
- Basic CLI shell.
- Error codes.
- Example commands.

### Workstream D: Benchmarks and validation

Goal: prove correctness first, then publish scoped performance claims.

Deliverables:

- SQL behavior tests against SQLite for supported subset.
- Microbenchmarks.
- Startup latency benchmark.
- Point read benchmark.
- Full scan benchmark.
- Batched insert benchmark.
- Durable and non-durable write modes reported separately.
- Raw benchmark output.

## Milestones

### Milestone 0: Project skeleton

Status: not started.

Tasks:

- Create `build.zig` and `build.zig.zon`.
- Create `src/` layout matching `architecture.md`.
- Add `zig build test` target.
- Add a tiny smoke test.
- Add formatting/check target if useful.

Acceptance criteria:

- `zig build test` succeeds.
- Project builds with Zig 0.16.0.
- No external dependencies.

### Milestone 1: Values and records

Status: not started.

Tasks:

- Implement `Value` union: null, integer, real, text, blob.
- Implement varint helpers.
- Implement record encoder.
- Implement record decoder.
- Add malformed-record tests.
- Add round-trip tests for all supported value types.

Acceptance criteria:

- Records round-trip without allocation for decoded text/blob slices.
- Decoder rejects truncated records and invalid type tags.
- Record format includes a version byte.

### Milestone 2: In-memory storage contract

Status: not started.

Tasks:

- Define storage interface.
- Implement memory backend.
- Implement table create/drop in memory.
- Implement rowid put/get/delete.
- Implement table scan cursor.
- Add tests for deterministic scan order.

Acceptance criteria:

- Storage supports rowid tables.
- Storage supports full scan and point lookup.
- Storage can be used without SQL frontend.

### Milestone 3: Tokenizer and parser

Status: not started.

Initial SQL subset:

```sql
CREATE TABLE users (id INTEGER, name TEXT);
INSERT INTO users VALUES (1, 'alice');
SELECT * FROM users;
SELECT name FROM users WHERE id = 1;
```

Tasks:

- Tokenize identifiers, keywords, strings, integers, punctuation, and operators.
- Parse `CREATE TABLE`.
- Parse `INSERT INTO ... VALUES`.
- Parse `SELECT ... FROM ... WHERE`.
- Parse simple expressions.
- Reject unsupported syntax with clear diagnostics.

Acceptance criteria:

- Parser tests cover valid and invalid SQL.
- Unsupported SQL fails explicitly, not silently.

### Milestone 4: Binder and catalog

Status: not started.

Tasks:

- Implement schema structs.
- Implement catalog interface.
- Resolve table names.
- Resolve column names.
- Expand `*`.
- Validate insert arity.
- Validate basic column references in `WHERE`.

Acceptance criteria:

- `SELECT missing FROM users` errors cleanly.
- `INSERT` with wrong number of values errors cleanly.
- Schema cache is connection-owned.

### Milestone 5: Register VM

Status: not started.

Tasks:

- Define opcodes.
- Implement instruction format.
- Implement program builder.
- Implement disassembler.
- Implement VM registers.
- Implement `ResultRow` pause/resume.
- Implement cursor abstraction.

Minimum opcodes:

- `Init`
- `Halt`
- `Null`
- `Integer`
- `Real`
- `String`
- `Blob`
- `Param`
- `OpenRead`
- `OpenWrite`
- `Rewind`
- `Next`
- `Column`
- `Rowid`
- `SeekRowid`
- `MakeRecord`
- `Insert`
- `Delete`
- `Eq`
- `Ne`
- `Lt`
- `Le`
- `Gt`
- `Ge`
- `And`
- `Or`
- `Not`
- `ResultRow`
- `Transaction`
- `Commit`
- `Rollback`

Acceptance criteria:

- VM can run hand-built bytecode programs.
- VM returns rows incrementally.
- VM disassembly is stable and useful in tests.

### Milestone 6: End-to-end SQL on memory backend

Status: not started.

Tasks:

- Codegen for `CREATE TABLE`.
- Codegen for `INSERT`.
- Codegen for `SELECT` full scan.
- Codegen for simple `WHERE` filters.
- Add public API around prepare/step/finalize.
- Add end-to-end tests.

Acceptance criteria:

- End-to-end create/insert/select works.
- Prepared statements can be reused after reset.
- Result values are valid until the next step/reset/finalize.

### Milestone 7: File-backed storage MVP

Status: not started.

Tasks:

- Implement file/mmap layer.
- Implement page format.
- Implement page allocator.
- Implement table leaf pages.
- Implement rowid table scan.
- Implement rowid point lookup.
- Persist catalog.

Acceptance criteria:

- Database can be closed and reopened.
- Rows persist across reopen.
- Catalog persists across reopen.
- Memory backend and file backend pass the same SQL tests.

### Milestone 8: WAL and recovery

Status: not started.

Tasks:

- Implement WAL entry format.
- Write WAL records for catalog and row changes.
- Implement commit marker.
- Implement recovery scan.
- Truncate partial WAL tail.
- Add kill/reopen-style tests where possible.

Acceptance criteria:

- Committed changes survive reopen.
- Uncommitted changes are ignored on recovery.
- Truncated WAL does not corrupt the database.

### Milestone 9: C ABI and CLI

Status: not started.

Tasks:

- Add opaque C handles.
- Add length-based pointer APIs.
- Add stable error codes.
- Add CLI shell.
- Add simple `.open`, `.tables`, `.schema`, and SQL execution.

Acceptance criteria:

- C ABI does not expose Zig internals.
- CLI can run the first SQL subset.
- Errors are readable and structured.

### Milestone 10: Benchmark harness

Status: not started.

Tasks:

- Add benchmark runner.
- Add startup/first-query benchmark.
- Add prepare/step benchmark.
- Add point read benchmark.
- Add full scan benchmark.
- Add batched insert benchmark.
- Add SQLite baseline.
- Add Turso baseline.
- Store raw results.

Acceptance criteria:

- Benchmarks identify engine version, build flags, OS, CPU, and durability mode.
- Correctness tests run before benchmark reporting.
- Results distinguish in-memory, non-durable, and durable modes.

## Initial directory layout

```text
sqlnano/
├── build.zig
├── build.zig.zon
├── plan.md
├── architecture.md
├── src/
│   ├── sqlnano.zig
│   ├── api.zig
│   ├── error.zig
│   ├── value.zig
│   ├── record.zig
│   ├── schema.zig
│   ├── catalog.zig
│   ├── codegen.zig
│   ├── sql/
│   │   ├── token.zig
│   │   ├── tokenizer.zig
│   │   ├── ast.zig
│   │   ├── parser.zig
│   │   └── binder.zig
│   ├── vm/
│   │   ├── op.zig
│   │   ├── program.zig
│   │   ├── cursor.zig
│   │   └── vm.zig
│   └── storage/
│       ├── mod.zig
│       ├── mem.zig
│       ├── file.zig
│       ├── pager.zig
│       ├── btree.zig
│       └── wal.zig
├── bench/
└── test/
```

## Benchmark rules

Performance claims must follow these rules:

1. Correctness first.
2. Same schema and data where possible.
3. Same durability mode.
4. Same API mode.
5. Prepared statements unless parsing is the benchmark target.
6. Explicit transactions for write benchmarks.
7. Warm-cache and cold-cache results reported separately.
8. Median and p95/p99 reported, not only averages.
9. Raw results published.
10. Slower results are not hidden.

Safe claim shape:

> sqlnano version X is N times faster than SQLite/Turso version Y on workload Z, under durability mode D and API mode A, on hardware H, after passing correctness checks for the supported SQL subset.

Unsafe claims:

- sqlnano is faster than SQLite.
- sqlnano is faster than Turso.
- Fully SQLite-compatible.
- Drop-in SQLite replacement.
- Production-ready.
- Durable and faster, if durability was disabled.

## Immediate next steps

1. Create the Zig project skeleton.
2. Implement `Value` and record encoding.
3. Implement in-memory storage.
4. Implement tokenizer/parser for the first SQL subset.
5. Implement VM and end-to-end create/insert/select.
6. Only then add durable file-backed storage.

## Definition of done for the first public demo

The first demo is complete when this works:

```sql
CREATE TABLE users (id INTEGER, name TEXT, age INTEGER);
INSERT INTO users VALUES (1, 'alice', 30);
INSERT INTO users VALUES (2, 'bob', 31);
SELECT name FROM users WHERE id = 1;
```

And the project can show:

- passing tests,
- a CLI demo,
- a tiny C ABI demo,
- startup latency benchmark,
- point read benchmark,
- batched insert benchmark,
- SQLite/Turso comparison with clear caveats.
