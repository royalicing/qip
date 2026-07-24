# Counting A WARC Archive

`warc-counts.wasm` scans an uncompressed WARC 1.0 or 1.1 archive and emits
deterministic long-form CSV. It reports factual structure, byte, HTTP, status,
and MIME-family counts; it does not extract payloads or decide whether an
archive is good.

```sh
make -j qip components/application/warc/warc-counts.wasm

qip router warc ./site |
  qip run components/application/warc/warc-counts.wasm
```

Every row has a stable name and an integer value:

```csv
metric,value
archive_bytes,12177834
records,381
response_records,379
http_status_2xx,376
http_html_records,84
http_html_body_bytes,1928441
```

Zero-valued rows are retained. This makes two archives straightforward to
compare with `diff`, SQLite, or a spreadsheet.

## What It Counts

The report covers:

- WARC 1.0 and 1.1 records, split by standard `WARC-Type`
- bytes used by record headers, payloads, and record separators
- the largest complete record and payload
- records carrying target URIs, block digests, and payload digests
- embedded HTTP requests, responses, headers, and bodies
- HTTP response status families, plus redirects excluding `304 Not Modified`
- HTTP record and body bytes grouped into HTML, CSS, JavaScript, other text,
  JSON, XML, image, audio, video, font, Wasm, other, and
  missing-content-type buckets

MIME parameters are ignored when grouping. For example,
`text/html; charset=utf-8` counts as HTML. Structured suffixes such as
`application/manifest+json` and `image/svg+xml` are grouped as JSON and image
respectively; the top-level image type wins before the XML suffix is tested.

The byte rows describe stored bytes, not decoded or decompressed sizes.
`warc-counts.wasm` accepts raw WARC input up to 128 MiB and does not currently
decode `.warc.gz`.

Malformed WARC record framing traps. A structurally valid WARC record with a
malformed embedded HTTP message remains countable and increments
`http_malformed_messages`.

## When Not To Use It

Use a record inventory when you need individual target URIs, dates, headers,
or offsets. Use an extractor when you need payload contents. Aggregate counts
are suitable for comparisons and overview charts, but they cannot identify
which record caused a change.
