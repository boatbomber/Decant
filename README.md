# Decant

Decompression in pure Luau.

## Installation

### Wally

```toml
[dependencies]
Decant = "boatbomber/decant@1.1.0"
```

### Roblox model

You can download a model file from the [Releases](https://github.com/boatbomber/Decant/releases) page.

## Simple Example

```Luau
local Decant = require(script.Decant)
local HttpService = game:GetService("HttpService")

local source_zip = buffer.fromstring(HttpService:RequestAsync({
    Method = "GET",
    Url = "https://github.com/boatbomber/Decant/archive/refs/tags/v1.1.0.zip",
}).Body)

for path, content in Decant.zip.iterateFiles(source_zip) do
    print(string.format("%4.1f KB  %s", buffer.len(content) / 1024, path))
end
```

## API

### Decant.zip

```Lua
Decant.zip.extractFile(data: buffer, path: string): buffer?
```

Finds a file by path in a ZIP archive and returns its decompressed contents, or `nil` if the archive has no file at that path. Throws if the archive is malformed, an entry uses a compression method Decant can't decode, or a decompressed entry's checksum doesn't match its central directory record.

```Lua
Decant.zip.extractAt(data: buffer, metadata: FileMetadata): buffer
```

Extracts a single entry you already found through `iterateFileMetadata`, reading its bytes straight from the offset the `FileMetadata` records without walking the central directory a second time. It handles stored and deflated entries alike and verifies the entry's CRC-32.

```Lua
Decant.zip.iterateFiles(data: buffer, filter: ((path: string, size: number) -> boolean)?): () -> (string?, buffer)
```

Returns an iterator over every file in the archive, yielding each file's path and decompressed contents. The optional filter runs on each file's path and uncompressed size before anything is decompressed, so returning `false` skips that entry without ever inflating it.

```Lua
Decant.zip.iterateFileMetadata(data: buffer): () -> FileMetadata?
```

Returns an iterator over the archive's central directory, yielding one `FileMetadata` per entry without decompressing anything. It's a cheap way to list an archive's contents, or to hold onto an entry's metadata for a later `extractAt` call.

```Lua
Decant.zip.readComment(data: buffer): string
```

Returns the archive's comment or an empty string when there isn't one.

```Lua
Decant.zip.isPathSafe(path: string): boolean
```

Reports whether an entry path is safe to use as a relative path on a real filesystem. A hostile archive can name entries with absolute paths, drive letters, or enough `..` traversals to climb out of the extraction root, and this rejects all of those along with embedded null bytes. Decant itself never touches a filesystem, so this is a helper for callers who do.

```Lua
export type FileMetadata = {
    path: string,
    size: number,
    offset: number,
    packed: boolean,
    crc: number,
    method: number,
    compressedSize: number,
    modified: number,
    isDirectory: boolean,
    attributes: number,
    utf8: boolean,
}
```

The first five fields drive extraction: the entry's path as the archive stored it, its uncompressed size, the 0-based offset of its data, whether it's compressed rather than stored, and its expected CRC-32. The rest describe the entry: `method` is the raw compression method id, `compressedSize` is how many bytes the entry occupies in the archive, `modified` is the recorded modification time as Unix epoch seconds, `isDirectory` marks folder entries, `attributes` is the raw external attributes word (an archive made on Unix keeps the file mode in its high sixteen bits), and `utf8` reports whether the writer flagged the path as UTF-8 encoded.

### Decant.gz

```Lua
Decant.gz.decompress(data: buffer): buffer
```

Decompresses a gzip stream and verifies its CRC-32 checksum.

### Decant.zlib

```Lua
Decant.zlib.decompress(data: buffer): buffer
```

Decompresses a zlib stream and verifies its Adler-32 checksum.

### Decant.deflate

```Lua
Decant.deflate.decompress(data: buffer): buffer
```

Decompresses a raw deflate stream, one with no gzip or zlib wrapper around it. A raw stream has no header or checksum, so there's nothing to parse or verify around the deflate data.

### Decant.decompress

```Lua
Decant.decompress(data: buffer): buffer
```

Decompresses a gzip or zlib stream, telling the two apart by their header. Raw deflate has no header to detect, so use `Decant.deflate.decompress` for that instead. Throws if the header matches neither format.

## Reference

This library draws a lot of inspiration from [zzlib](https://codeberg.org/zerkman/zzlib) and [luau-unzip](https://github.com/0x5eal/luau-unzip).
