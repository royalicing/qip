# TAR to ZIP

`tar-to-zip.wasm` converts one `application/x-tar` archive into an
`application/zip` archive. Each regular file and symbolic link uses raw
DEFLATE when that makes its payload smaller; otherwise it uses ZIP's stored
method. Directories are stored as empty entries.

```sh
qip run \
  -i site.tar \
  -o site.zip \
  components/application/x-tar/tar-to-zip.wasm
```

The converter accepts POSIX ustar archives, PAX `path`, `linkpath`, `size`, and
`mtime` records, and GNU long-name and long-link records. It preserves entry
order, Unix permissions, symbolic links, and modification times representable
by ZIP's 32-bit extended timestamp.

The component deliberately emits classic ZIP rather than ZIP64. Inputs are
limited to 128 MiB, outputs to 160 MiB, and archives to 65,535 entries. Entries
are compressed in independent 512 KiB batches, so the token scratch buffer is
bounded at 2 MiB regardless of entry size. A small match sample sends
incompressible batches directly to stored DEFLATE blocks; compressible batches
choose fixed or dynamic Huffman codes from their exact bit costs. The complete
entry falls back to ZIP's stored method when the resulting DEFLATE stream is
not smaller.

The 512 KiB batch size and 32-candidate match-chain limit are constants in
`tar-to-zip.zig`; they can be retuned without changing the component protocol.
Resetting match history at each batch boundary gives up some cross-boundary
matches in exchange for bounded scratch memory and predictable work. The
component traps on malformed TAR data, unsupported entry types, unsafe
extraction paths, capacity overflow, and classic-ZIP limit violations.

Use this component when ZIP compatibility at a system boundary is useful.
Keep TAR between components when sequential parsing or richer Unix archive
semantics are more important.
