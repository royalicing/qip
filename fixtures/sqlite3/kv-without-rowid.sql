-- WITHOUT ROWID tables are stored as index b-trees; readers should trap
-- with a clear error rather than misread the pages.
CREATE TABLE
    kv (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;

INSERT INTO kv VALUES ('a', '1');
