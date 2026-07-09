-- Exercises rowid aliasing declared via a table-level PRIMARY KEY constraint,
-- the style used by Chinook and many schema generators.
CREATE TABLE
    albums (
        "AlbumId" INTEGER NOT NULL,
        "Title" TEXT,
        CONSTRAINT "PK_Album" PRIMARY KEY ("AlbumId")
    );

INSERT INTO albums (AlbumId, Title) VALUES (1, 'First');

INSERT INTO albums (AlbumId, Title) VALUES (2, 'Second');
