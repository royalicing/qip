-- A UTF-16le database; readers only support UTF-8 and should trap clearly.
PRAGMA encoding = 'UTF-16le';

CREATE TABLE
    t (id INTEGER PRIMARY KEY, x TEXT);

INSERT INTO t (x) VALUES ('hello');
