-- Exercises INTEGER PRIMARY KEY rowid aliasing, NULL, REAL, and BLOB values.
CREATE TABLE
    products (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        price REAL,
        stock INTEGER,
        icon BLOB
    );

INSERT INTO products (name, price, stock, icon) VALUES ('Widget', 9.99, 3, x'C0FFEE');

INSERT INTO products (name, price, stock, icon) VALUES ('Gadget', 19.5, NULL, NULL);

INSERT INTO products (id, name, price, stock, icon) VALUES (100, 'Sprocket', 3.25, 0, x'00');
