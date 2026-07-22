# Changelog

## V1.1.0

### Added

- `FileMetadata` now carries the raw compression method id, the compressed byte count, the modification time as Unix epoch seconds, a directory flag, the raw external attributes word, and whether the writer flagged the path as UTF-8, alongside the existing extraction fields.
- `zip.readComment` returns the archive comment from the end of central directory record.
- `zip.isPathSafe` reports whether an entry path is safe to use as a relative path on a real filesystem, rejecting null bytes, absolute paths, drive letters, and `..` traversals that escape the extraction root.

### Changed

- Extracting an entry whose compression method Decant doesn't support now fails with `unsupported compression method <id>` instead of producing corrupt output. Metadata iteration over such archives still works.
- Truncated or hostile archives now fail with clear messages (`truncated central directory`, `entry data extends past the archive`, `central directory extends past the archive`, `invalid local header signature`).
- A deflate stream that runs out of bytes mid-symbol now fails with `unexpected end of stream`, and a corrupt code that lands in a gap of an incomplete Huffman table fails with `invalid Huffman code`, where both previously surfaced as raw buffer access errors.

### Performance

V1.1.0 is 3-4x faster than V1.0.0!

- The inflate block loop keeps its bitstream and output state in locals for a whole block, refills its bit buffer sixteen bits at a time, and writes literals and non-overlapping match copies straight into the output's backing store. Literal-heavy decoding runs about 3.7x faster.
- Huffman lookup tables, along with the fixed length and distance code mappings, live in buffers instead of Lua tables, so a symbol decode is one plain read.
- The fixed Huffman tables for static blocks are built once and cached, which with the other overhead cuts takes the fixed cost of decoding a small stream from roughly 55 microseconds to about 3. Iterating a ZIP archive of many small entries runs about 17x faster.
- Back-references copy through `buffer.copy` and `buffer.fill` instead of a byte loop, taking the widest step the overlap allows.
- Decodes with a known output size start the output at that size instead of growing to it. ZIP entries pass the central directory's uncompressed size, and gzip passes the trailer's size field when it is plausible for the input. An output whose backing store an accurate hint filled exactly is handed back without a final copy.
- CRC-32 is a slice-by-thirty-two over staggered tables held in a single buffer, about 5x faster.
- Adler-32 defers its modulo reduction to once per four megabyte block, takes sixteen bytes per pass through the weighted form of the update so the reads and products compute independently, and runs under native codegen, which together take zlib decompression of large payloads from 52 MB/s to over 500 MB/s.

## v1.0.0

- Initial release
