# SQLite Fixtures

Test fixtures and example databases for the `application/vnd.sqlite3` QIP
components. All files use UTF-8 encoding and rowid tables unless noted.

## Generated fixtures

Built from the `.sql` file of the same name via `make sqlite-fixtures`
(see `sqlite.mk`):

- `countries.sqlite` — 14 countries with ISO codes and currencies; TEXT primary key.
- `products.sqlite` — exercises INTEGER PRIMARY KEY rowid aliasing, NULL, REAL, and BLOB values.
- `albums-tablepk.sqlite` — rowid aliasing via a table-level `PRIMARY KEY` constraint (Chinook style).
- `kv-without-rowid.sqlite` — a `WITHOUT ROWID` table; readers should trap clearly.
- `wal-mode.sqlite` — WAL journal mode; readers should refuse it (serve `VACUUM INTO` output instead).
- `utf16.sqlite` — UTF-16le encoding; readers should trap clearly.

## Open datasets

Downloaded copies of public teaching datasets, kept small enough to commit:

From [PADJO SQLite starter packs](http://2016.padjo.org/tutorials/sqlite-data-starterpacks/)
(Stanford Public Affairs Data Journalism course, public records data):

- `simplefolks.sqlite` (9 KB) — five tiny tables (`people`, `homes`, `pets`, `inmates`, `politicians`) designed for practicing joins.
- `florida-deathrow.sqlite` (115 KB) — Florida death row roster; real-world messy data with 1 KB pages and a large freelist.

From [SQLite databases for learning data science](https://github.com/davidjamesknight/SQLite_databases_for_learning_data_science)
(the classic seaborn sample datasets as normalized SQLite):

- `iris.sqlite` (20 KB) — 150 flower observations, FLOAT columns.
- `flights.sqlite` (12 KB) — monthly airline passengers 1949–1960.
- `titanic.sqlite` (68 KB) — 891 passengers, 8 tables, mixed types with NULLs.

## Larger datasets (not committed)

Useful for benchmarking; download on demand:

- SSA baby names 2015 (11 MB): http://2016.padjo.org/files/data/starterpack/ssa-babynames/ssa-babynames-for-2015.sqlite
- USGS earthquakes, lower US (5 MB): http://2016.padjo.org/files/data/starterpack/usgs/usgs-lower-us.sqlite
- California schools (14 MB): http://2016.padjo.org/files/data/starterpack/cde-schools/cdeschools.sqlite
- seaborn diamonds, 53,940 rows (3.2 MB): https://raw.githubusercontent.com/davidjamesknight/SQLite_databases_for_learning_data_science/main/diamonds.db
