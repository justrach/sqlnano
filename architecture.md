# sqlnano Architecture

## Purpose

This document defines the technical architecture for `sqlnano`, a lightweight embeddable SQL engine written in Zig 0.16.0.

The execution roadmap lives in `plan.md`. This document is the design contract that implementation work should refer to.

## Design principles

1. Lightweight first.
2. Useful before complete.
3. Embedded before networked.
4. Correct before fast.
5. Fast on honest workloads.
6. Zero-copy where lifetimes are obvious.
7. Dependency-free core.
8. SQLite `.db` read compatibility before native format cleverness.
9. Simple storage path before multiple engines.
10. Durable by design.
11. Benchmark everything in layers.

## SQLite compatibility stance

sqlnano should treat SQLite compatibility as a staged contract, not a marketing phrase.

The implementation has a code-backed parity tracker in `src/sqlite/parity.zig` and the CLI exposes it with:

```text
sqlnano parity
```

Update that tracker whenever a compatibility feature moves from missing to scaffold, partial, basic, experimental, or complete. The tracker is the living checklist for the "are we 1:1 yet?" question.

Compatibility tiers:

```text
Tier 0: identify SQLite `.db` files and validate headers safely.
Tier 1: read-only schema introspection for simple SQLite databases.
Tier 2: read-only scans of rowid tables with supported SQLite record types.
Tier 3: supported SQL subset returns SQLite-equivalent results.
Tier 4: SQLite-like C API subset.
Tier 5: SQLite-compatible writes.
```

First target: Tier 0, then Tier 1. SQLite-compatible writes must wait until page, freelist, overflow, journaling/WAL, schema-cookie, and corruption tests are mature.

## High-level architecture

```text
Application / CLI / C ABI / future bindings
                    |
                    v
              Public API layer
                    |
                    v
              SQL frontend
        tokenizer -> parser -> AST -> binder
                    |
                    v
                Code generator
                    |
                    v
              Register bytecode VM
                    |
                    v
             Storage interface
                    |
        +-----------+------------+
        |                        |
        v                        v
 In-memory backend       File-backed backend
                                  |
                                  v
                    pager + B+tree + WAL + mmap/file
```

## Core components

### Public API

Responsibilities:

- Own database connection state.
- Own prepared statements.
- Expose incremental stepping.
- Expose row/column accessors.
- Hide storage internals.
- Define result lifetimes.

Initial API shape:

```zig
open(path, allocator) -> Database
Database.prepare(sql) -> Statement
Statement.bind(index, value)
Statement.step() -> StepResult
Statement.column(index) -> ValueView
Statement.reset()
Statement.finalize()
Database.close()
```

C ABI shape:

```c
sqlnano_open(path_ptr, path_len, out_db)
sqlnano_close(db)
sqlnano_prepare(db, sql_ptr, sql_len, out_stmt)
sqlnano_bind_int(stmt, index, value)
sqlnano_bind_text(stmt, index, ptr, len)
sqlnano_step(stmt)
sqlnano_column_type(stmt, index)
sqlnano_column_int(stmt, index)
sqlnano_column_text(stmt, index, out_ptr, out_len)
sqlnano_reset(stmt)
sqlnano_finalize(stmt)
```

Ownership rules:

- Database owns schema cache and storage backend.
- Statement owns bytecode, registers, cursor handles, and result state.
- Storage owns persisted bytes.
- Returned text/blob slices are valid until the next `step`, `reset`, or `finalize` on the statement.
- C ABI uses opaque handles and explicit pointer lengths.

## SQL frontend

### Tokenizer

The tokenizer should be hand-written and allocation-light.

Tokens:

- identifiers,
- keywords,
- integer literals,
- real literals,
- string literals,
- blob literals later,
- punctuation,
- comparison operators,
- comments.

Initial keywords:

- `CREATE`
- `TABLE`
- `INSERT`
- `INTO`
- `VALUES`
- `SELECT`
- `FROM`
- `WHERE`
- `NULL`
- `INTEGER`
- `REAL`
- `TEXT`
- `BLOB`
- `PRIMARY`
- `KEY`
- `AND`
- `OR`
- `NOT`
- `IS`

### Parser

Use recursive descent for statements and Pratt parsing for expressions.

Initial statements:

```sql
CREATE TABLE name (...);
INSERT INTO name VALUES (...);
SELECT projection FROM name;
SELECT projection FROM name WHERE expression;
DELETE FROM name WHERE expression;
```

Initial expression support:

- literals,
- column references,
- positional parameters `?`,
- `=`, `!=`, `<`, `<=`, `>`, `>=`,
- `AND`, `OR`, `NOT`,
- `IS NULL`,
- `IS NOT NULL`.

Unsupported syntax should produce explicit errors.

### AST

The AST should preserve enough source spans for diagnostics while avoiding over-modeling unsupported SQL.

Core AST nodes:

```text
Statement
  CreateTable
  Insert
  Select
  Delete

Expr
  Literal
  ColumnRef
  Parameter
  Binary
  Unary
  IsNull
```

### Binder

Responsibilities:

- Resolve table names.
- Resolve column names.
- Expand `*`.
- Validate insert arity.
- Assign column indexes.
- Assign parameter indexes.
- Reject unsupported constructs before codegen.

The binder receives AST plus schema cache and returns a bound statement.

## Value model

Runtime values:

```text
Value
  Null
  Integer(i64)
  Real(f64)
  Text([]const u8)
  Blob([]const u8)
```

Type affinity:

```text
Affinity
  Integer
  Real
  Text
  Blob
  Any
```

Initial rules:

- Declared types are stored as affinity metadata.
- Values are dynamically typed.
- First version enforces column count, not strict type constraints.
- `WHERE` treats null/unknown as false.
- `IS NULL` and `IS NOT NULL` are explicit.

## Record format

The row record format should be native to sqlnano and versioned from day one.

Goals:

- Compact.
- Easy to decode safely.
- Supports dynamic typing.
- Allows skipping columns.
- Avoids storing host pointers.
- Forward-compatible.

Record layout:

```text
Record
  version: u8
  flags: varint
  column_count: varint
  header_size: varint
  column_directory[column_count]
  payload_area

ColumnDirectoryEntry
  type_tag: u8
  offset: varint
  length: varint
```

Type tags:

```text
0x00 NULL
0x01 INTEGER_0
0x02 INTEGER_1
0x03 INTEGER_I8
0x04 INTEGER_I16
0x05 INTEGER_I32
0x06 INTEGER_I64
0x07 REAL_F64
0x08 TEXT_UTF8
0x09 BLOB
0x80..0xff reserved
```

Example row:

```sql
INSERT INTO users VALUES (1, 'alice', NULL);
```

Logical values:

```text
INTEGER_I8 1
TEXT_UTF8 "alice"
NULL
```

The decoder must reject:

- truncated varints,
- invalid type tags,
- directory offsets outside the payload,
- column count mismatches,
- unsupported record versions.

## Catalog and schema

Use a reserved internal table for catalog metadata.

Reserved IDs:

```text
table_id 0: sqlnano catalog
```

Catalog stores:

- database metadata,
- schema version,
- table definitions,
- column definitions,
- original SQL where useful.

Table schema:

```text
TableSchema
  table_id: u64
  name: []const u8
  columns: []ColumnSchema
  root_page_or_storage_id: u64
  schema_version: u64

ColumnSchema
  name: []const u8
  affinity: Affinity
  nullable: bool
  primary_key: bool
```

First version can keep catalog in memory for the memory backend, then persist it in the file backend.

## Bytecode VM

Use a register-based bytecode VM.

Why VM instead of direct AST execution:

- Incremental `step` execution is natural.
- Prepared statements can be reused.
- Programs can be disassembled for debugging.
- Codegen and execution are separated.
- Future optimizations can target bytecode.

### Instruction format

```text
Instruction
  op: Op
  p1: i32
  p2: i32
  p3: i32
  p4: u32 // constant index or metadata index
```

### VM state

```text
VM
  program counter
  registers
  cursors
  bound parameters
  current result row
  halted state
  error state
```

### Initial opcodes

```text
Init
Halt
Null
Integer
Real
String
Blob
Param
Move
OpenRead
OpenWrite
Rewind
Next
Column
Rowid
SeekRowid
MakeRecord
Insert
Delete
Eq
Ne
Lt
Le
Gt
Ge
And
Or
Not
IsNull
NotNull
ResultRow
Transaction
Commit
Rollback
```

### Example: SELECT full scan

```text
Init
OpenRead cursor0, table(users)
Rewind cursor0, end
loop:
  Column cursor0, col0 -> r0
  Column cursor0, col1 -> r1
  ResultRow r0..r1
  Next cursor0, loop
end:
Halt
```

### Example: INSERT

```text
Init
Transaction
OpenWrite cursor0, table(users)
Integer 1 -> r0
String 'alice' -> r1
MakeRecord r0..r1 -> r2
Insert cursor0, rowid, r2
Commit
Halt
```

## Storage interface

The SQL layer must not depend directly on file pages or mmap.

Interface:

```text
Storage.open
Storage.close
Storage.createTable(table_id)
Storage.dropTable(table_id)
Storage.get(table_id, rowid) -> encoded row
Storage.put(table_id, rowid, encoded row)
Storage.delete(table_id, rowid)
Storage.scan(table_id) -> cursor
Storage.begin(mode)
Storage.commit
Storage.rollback
```

Cursor interface:

```text
Cursor.first
Cursor.next
Cursor.seekRowid(rowid)
Cursor.rowid
Cursor.value
Cursor.valid
Cursor.close
```

Backends:

1. `mem.zig`: deterministic in-memory backend for tests and frontend development.
2. `file.zig`: durable backend using pager, B+tree, and WAL.

## File-backed storage

### Layers

```text
file/mmap
  -> pager
    -> page allocator
      -> B+tree table/index storage
        -> storage interface
```

### Page model

Initial page size should be a named constant and benchmarked. Start with 16 KiB or 64 KiB only if intentional; avoid docs/code drift.

Page header:

```text
PageHeader
  magic/version
  page_no
  page_type
  flags
  used_bytes
  cell_count
  free_start
  free_end
  next_page
```

Page types:

```text
free
table_leaf
table_internal
index_leaf
index_internal
overflow
catalog
```

### Table storage

First implementation:

```text
rowid -> encoded record
```

Use B+tree table pages keyed by signed rowid.

Secondary indexes come later:

```text
encoded_index_key -> rowid
```

### WAL

WAL should exist before public durability claims.

WAL entry:

```text
WalHeader
  magic/version
  lsn
  txn_id
  op
  table_id
  rowid
  payload_len
  crc32
payload
```

Operations:

```text
begin
commit
rollback_marker optional
create_table
drop_table
put_row
delete_row
checkpoint
```

Recovery:

1. Scan WAL from start or last checkpoint.
2. Validate CRC and entry lengths.
3. Stop at first partial/corrupt tail entry.
4. Collect committed transactions.
5. Replay committed changes.
6. Ignore uncommitted changes.
7. Truncate invalid tail.

## Transactions and concurrency

Initial model:

- Single connection writer.
- Implicit transaction per mutating statement.
- Read statements do not mutate state.
- Storage interface includes begin/commit/rollback from day one.

Next model:

- Explicit `BEGIN`, `COMMIT`, `ROLLBACK`.
- Single writer, multiple readers.
- Snapshot reads via epoch/MVCC later.

Do not start with distributed or multi-writer complexity.

## Error handling

Use a compact engine error set plus structured diagnostics.

Error categories:

```text
ParseError
BindError
RuntimeError
StorageError
CorruptionError
ConstraintError
UnsupportedError
OutOfMemory
IoError
```

Diagnostics should include:

- category,
- message,
- optional source span,
- optional underlying error.

C ABI should expose stable numeric codes and a way to get the last error message.

## Testing strategy

### Unit tests

- varint encoding,
- value conversion,
- record encoding/decoding,
- tokenizer,
- parser,
- binder,
- VM opcodes,
- storage cursor behavior,
- WAL parsing/recovery.

### Integration tests

- create/insert/select,
- prepared parameters,
- reopen persistence,
- malformed SQL,
- malformed records,
- transaction rollback,
- recovery after partial WAL.

### Differential tests

Use SQLite as the correctness reference for supported SQL subset.

Only compare features sqlnano claims to support.

## Benchmark architecture

Benchmarks must be layered:

1. Parser/prepare time.
2. VM step overhead.
3. Record encode/decode.
4. Storage point lookup.
5. Storage full scan.
6. WAL append/commit.
7. End-to-end SQL query.
8. CLI overhead.
9. C ABI overhead.

Benchmark modes:

```text
memory backend
file backend, non-durable
file backend, durable
cold cache
warm cache
```

Baselines:

- SQLite current stable release.
- Turso pinned version/commit.

No global speed claims. Claims must name workload, durability mode, API mode, versions, and hardware.

## Module map

```text
src/sqlnano.zig
  Public root module.

src/api.zig
  Database and Statement APIs.

src/error.zig
  Error set and diagnostics.

src/value.zig
  SQL values and affinity.

src/record.zig
  Row encoding and decoding.

src/schema.zig
  Table and column schema.

src/catalog.zig
  Catalog read/write/cache.

src/codegen.zig
  Bound AST to VM program.

src/sql/token.zig
  Token enum and keyword map.

src/sql/tokenizer.zig
  SQL tokenizer.

src/sql/ast.zig
  AST data structures.

src/sql/parser.zig
  Statement and expression parser.

src/sql/binder.zig
  Name resolution and semantic validation.

src/vm/op.zig
  Opcode enum and instruction definition.

src/vm/program.zig
  Program builder and disassembler.

src/vm/cursor.zig
  VM cursor abstraction.

src/vm/vm.zig
  Execution loop.

src/storage/mod.zig
  Storage interface.

src/storage/mem.zig
  In-memory backend.

src/storage/file.zig
  File backend composition root.

src/storage/pager.zig
  Page cache/allocation interface.

src/storage/btree.zig
  B+tree table/index implementation.

src/storage/wal.zig
  Write-ahead log and recovery.
```

## Compatibility stance

sqlnano is SQLite-inspired, not SQLite-compatible by default.

Compatibility tiers:

```text
Tier 0: SQLite-like API shape.
Tier 1: Supported SQL subset matches SQLite results.
Tier 2: Broader SQL behavior compatibility.
Tier 3: SQLite C API subset compatibility.
Tier 4: SQLite file-format compatibility.
```

First target: Tier 1 for a small SQL subset.

## First useful slice

The first useful vertical slice is:

```sql
CREATE TABLE users (id INTEGER, name TEXT, age INTEGER);
INSERT INTO users VALUES (1, 'alice', 30);
INSERT INTO users VALUES (2, 'bob', 31);
SELECT name FROM users WHERE id = 1;
```

It should run through:

```text
API -> tokenizer -> parser -> binder -> codegen -> VM -> memory storage
```

Then the same SQL should run through:

```text
API -> tokenizer -> parser -> binder -> codegen -> VM -> file storage
```

## Architecture risks

### SQL scope creep

Mitigation: reject unsupported SQL explicitly and keep a public capability matrix.

### Storage leaks into SQL frontend

Mitigation: keep all storage access behind `Storage` and `Cursor` interfaces.

### Row format churn

Mitigation: version records from day one and keep decoder boundaries strict.

### Benchmark credibility

Mitigation: publish raw results and include correctness status for every benchmark.

### Documentation drift

Mitigation: constants such as page size must be referenced from code in generated output or tested against docs before releases.

### Memory lifetime bugs

Mitigation: document value lifetimes and keep statement-owned result buffers.

## Final architecture rule

If a feature makes the core faster but harder to trust, delay it.

If a feature makes the database more useful without bloating the core, consider it.

If a feature requires distributed correctness, postpone it.
