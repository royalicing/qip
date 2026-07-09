-- A WAL-mode database file; readers should refuse it because the main file
-- may be stale without its -wal sidecar.
PRAGMA journal_mode = WAL;

CREATE TABLE
    t (id INTEGER PRIMARY KEY, x TEXT);

INSERT INTO t (x) VALUES ('hello');
