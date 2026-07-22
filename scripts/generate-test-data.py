#!/usr/bin/env python3
"""Generates tests/sample_data.luau for the Decant test suite.

Roblox has no compressor, so the tests decompress fixtures that were built ahead
of time. This script is where they come from. It defines a wide spread of
payloads, compresses each to gzip and zlib with Python's stdlib, assembles a set
of ZIP archives that cover the shapes real archives come in, verifies every
artifact by reading it back, and writes the whole lot out as a Luau data module.

Some fixtures exercise features Decant does not support yet. Those are here on purpose.
The tests mark them with it.failing so the suite records where the gaps are.

Run it from the repository root with `python scripts/generate-test-data.py`.
"""

import base64
import gzip
import io
import random
import subprocess
import zipfile
import zlib
from pathlib import Path

STORE = zipfile.ZIP_STORED
DEFLATE = zipfile.ZIP_DEFLATED
BZIP2 = zipfile.ZIP_BZIP2
LZMA = zipfile.ZIP_LZMA

# A fixed date keeps the archive bytes reproducible across runs. It is the
# earliest a ZIP timestamp can express.
DOS_EPOCH = (1980, 1, 1, 0, 0, 0)


def rep(unit: bytes, count: int):
    """A payload spec for a unit repeated count times, stored compactly."""
    return ("rep", unit, count)


def raw(data: bytes):
    """A payload spec for an exact byte string, stored as base64."""
    return ("raw", data)


def materialize(spec) -> bytes:
    """Turns a payload spec into the bytes it stands for."""
    kind = spec[0]
    if kind == "rep":
        return spec[1] * spec[2]
    if kind == "raw":
        return spec[1]
    raise ValueError(f"unknown spec kind {kind!r}")


# A seeded generator gives byte streams with no structure worth compressing,
# which forces the deflate encoder onto stored blocks, while staying identical
# from one run to the next.
_rng = random.Random(0xDECA0C0FFEE)


def noise(n: int) -> bytes:
    """Returns n deterministic pseudo-random bytes."""
    return bytes(_rng.randrange(256) for _ in range(n))


# The word pool the prose benchmark payload draws from. A small fixed vocabulary
# keeps the output deterministic while giving deflate a realistic literal spread
# to build a dynamic Huffman tree around, so the decode leans on the symbol
# decoding loop rather than on long repeated matches.
_PROSE_WORDS = (
    "the quick brown fox jumps over a lazy dog while decant reads every deflate "
    "block from the bitstream and writes each byte into its growing output buffer "
    "without leaning on any native compression library beneath the pure luau core "
    "that unpacks archives one member at a time across gzip zlib and raw streams"
).split()


def prose_bytes(target: int) -> bytes:
    """Builds at least target bytes of deterministic English-ish prose.

    Words come from a fixed pool through a generator seeded apart from the noise
    stream, so this never disturbs the pseudo-random bytes the other fixtures
    draw. The result is trimmed to exactly target bytes for a round figure, and
    the mix of letters, spaces, and sentence breaks gives deflate a fuller
    literal distribution than a single repeated unit would.
    """
    rng = random.Random(0x50DA)
    parts = []
    total = 0
    since_break = 0
    while total < target:
        word = rng.choice(_PROSE_WORDS)
        parts.append(word)
        total += len(word)
        since_break += 1
        if since_break >= 12:
            separator = ".\n"
            since_break = 0
        else:
            separator = " "
        parts.append(separator)
        total += len(separator)
    return "".join(parts).encode("ascii")[:target]


# The payloads each fixture must decompress back into. The mix spans empty and
# single byte edges, the 4096 byte output buffer growth boundary, highly
# compressible repetition, the full byte range, multibyte UTF-8, and
# incompressible noise.
PAYLOADS = {
    "empty": raw(b""),
    "tiny": raw(b"a"),
    "short": raw(b"hello world"),
    "text": rep(b"The quick brown fox jumps over the lazy dog. ", 300),
    "repetitive": rep(b"abcdefgh", 5000),
    "allBytes": rep(bytes(range(256)), 20),
    "newlines": rep(b"line of text\n", 500),
    "json": raw(
        b'{"name":"decant","values":[1,2,3,4,5],"nested":{"ok":true,"tags":["a","b","c"]}}'
    ),
    "unicode": rep("café ☕ 日本語 ".encode("utf-8"), 50),
    "atGrowth": rep(b"x", 4096),
    "pastGrowth": rep(b"y", 4097),
    "incompressible": raw(noise(512)),
    "binary": raw(noise(2048)),
}


def entry(path, payload=None, method=DEFLATE, comment=None, extra=None, zip64=False):
    """Describes one archive entry along with the header options it carries."""
    return {
        "path": path,
        "payload": payload if payload is not None else raw(b""),
        "method": method,
        "comment": comment,
        "extra": extra,
        "zip64": zip64,
    }


# A well formed extended timestamp extra field (header id 0x5455), the kind
# InfoZIP writes. Decant reads only its length and steps over the body.
TIMESTAMP_EXTRA = b"\x55\x54\x05\x00\x01\x00\x00\x00\x00"


# The archives, each a list of entries in the order they land in the central
# directory. The shapes differ on purpose so the ZIP tests can lean on whichever
# one exercises the behavior in question, and the unsupported ones give the
# it.failing tests something concrete to point at.
ARCHIVES = {
    # A bit of everything: deflated, stored, empty, a nested path, and an entry
    # large enough to push the inflate output buffer past its starting size.
    "mixed": {
        "entries": [
            entry("readme.txt", rep(b"Hello from the Decant fixture. ", 40), DEFLATE),
            entry("data/nested.txt", raw(b"nested file contents"), DEFLATE),
            entry("stored.txt", raw(b"This file is stored, not deflated."), STORE),
            entry("empty.txt", raw(b""), STORE),
            entry("big.txt", rep(b"abcdefgh", 5000), DEFLATE),
        ],
    },
    # Every entry stored without compression, so the reader never inflates.
    "stored": {
        "entries": [
            entry("first.txt", raw(b"the first stored entry"), STORE),
            entry(
                "second.txt",
                raw(b"a second stored entry, a little longer than the first"),
                STORE,
            ),
            entry("blank.txt", raw(b""), STORE),
            entry("third.bin", raw(noise(256)), STORE),
        ],
    },
    # Deep directory nesting with forward slash separators.
    "nested": {
        "entries": [
            entry("a/b/c/d/e/deep.txt", raw(b"buried five levels down"), DEFLATE),
            entry("a/b/readme.txt", rep(b"shallow. ", 20), DEFLATE),
            entry("a/notes.txt", raw(b"one level down"), STORE),
            entry("root.txt", raw(b"at the top"), DEFLATE),
        ],
    },
    # Many small entries, to walk a longer central directory.
    "many": {
        "entries": [
            entry(
                f"file_{i:02d}.txt",
                raw(f"entry number {i}".encode("ascii")),
                DEFLATE if i % 2 == 0 else STORE,
            )
            for i in range(24)
        ],
    },
    # A real archive comment that carries a decoy end of central directory
    # signature, so the backward scan has to reject it on the length check.
    "comment": {
        "entries": [
            entry("alpha.txt", rep(b"alpha ", 30), DEFLATE),
            entry("beta.txt", raw(b"beta contents"), STORE),
        ],
        "comment": b"PK\x05\x06" + b"!" * 20,
    },
    # Incompressible bodies, some stored and some deflated, so the deflated ones
    # fall back on stored blocks inside an otherwise deflated entry.
    "binary": {
        "entries": [
            entry("noise_a.bin", raw(noise(300)), DEFLATE),
            entry("noise_b.bin", raw(noise(300)), STORE),
            entry("mixed.dat", raw(noise(64) + b"readable tail"), DEFLATE),
        ],
    },
    # No entries at all, just an end of central directory record.
    "empty": {
        "entries": [],
    },
    # Per entry comments in the central directory, which Decant steps over.
    "comments": {
        "entries": [
            entry(
                "noted.txt",
                raw(b"has a comment"),
                DEFLATE,
                comment=b"the central directory comment for this entry",
            ),
            entry("plain.txt", raw(b"no comment"), STORE),
            entry(
                "also-noted.txt",
                rep(b"commented. ", 10),
                DEFLATE,
                comment=b"another entry comment",
            ),
        ],
    },
    # Extra fields in both the local and central headers, which Decant steps
    # over by their length.
    "extraFields": {
        "entries": [
            entry(
                "timestamped.txt",
                raw(b"carries a timestamp extra"),
                DEFLATE,
                extra=TIMESTAMP_EXTRA,
            ),
            entry("also.txt", rep(b"padded. ", 12), STORE, extra=TIMESTAMP_EXTRA),
        ],
    },
    # Explicit directory entries alongside the files inside them, the way most
    # archivers record folders.
    "directories": {
        "entries": [
            entry("docs/", raw(b""), STORE),
            entry("docs/guide.txt", raw(b"read me first"), DEFLATE),
            entry("docs/img/", raw(b""), STORE),
            entry("docs/img/logo.dat", raw(noise(48)), STORE),
            entry("empty-dir/", raw(b""), STORE),
        ],
    },
    # Path formats a reader runs into in the wild, including ones a caller has to
    # treat with suspicion. Decant returns every path verbatim and leaves that
    # judgement to the caller.
    "paths": {
        "entries": [
            entry("with spaces and (parens).txt", raw(b"spaces are fine"), DEFLATE),
            entry("UPPER/lower/MiXeD.TxT", raw(b"case is preserved"), DEFLATE),
            entry("trailing.dots...", raw(b"dots at the end"), STORE),
            entry("..\\backslash\\path.txt", raw(b"backslash separators"), STORE),
            entry("../relative/escape.txt", raw(b"a zip slip path"), DEFLATE),
            entry("/leading/slash.txt", raw(b"an absolute looking path"), STORE),
            entry("café/naïve/résumé.txt", raw(b"accented utf-8 path"), DEFLATE),
            entry("日本語/ファイル.txt", raw(b"cjk utf-8 path"), DEFLATE),
            entry("deep/" * 20 + "bottom.txt", raw(b"a very long nested path"), STORE),
        ],
    },
    # Two entries sharing a name, each with different contents. A reader has to
    # decide which one wins a lookup.
    "duplicates": {
        "entries": [
            entry("dup.txt", raw(b"the first copy"), DEFLATE),
            entry("unique.txt", raw(b"only one of these"), STORE),
            entry("dup.txt", raw(b"the second copy, which came later"), DEFLATE),
        ],
    },
    # Written to an unseekable sink so every entry carries a data descriptor and
    # the streaming general purpose flag, the way a zip built on the fly does.
    "dataDescriptor": {
        "entries": [
            entry("streamed.txt", rep(b"streamed out. ", 20), DEFLATE),
            entry("stored-stream.txt", raw(b"stored while streaming"), STORE),
        ],
        "stream": True,
    },
    # Written in the zip64 format even though it is tiny. The 32-bit size fields
    # hold real values because they still fit, so the only zip64 footprint is an
    # extra field, which Decant steps over like any other. This one it reads.
    "zip64Extra": {
        "entries": [
            entry(
                "big-in-theory.txt",
                rep(b"pretend this is huge. ", 30),
                DEFLATE,
                zip64=True,
            ),
            entry("ordinary.txt", raw(b"a normal neighbor"), DEFLATE),
        ],
    },
    # A bzip2 compressed entry, method 12, which Decant feeds to its deflate
    # decoder and cannot read.
    "bzip2": {
        "entries": [
            entry("compressed.txt", rep(b"bzip2 compresses this. ", 40), BZIP2),
        ],
    },
    # An lzma compressed entry, method 14, in the same boat.
    "lzma": {
        "entries": [
            entry("compressed.txt", rep(b"lzma compresses this. ", 40), LZMA),
        ],
    },
    # A self-extracting archive, an executable stub with a normal archive glued
    # to its end. The stored central directory offset stays relative to the
    # archive start, so a reader has to correct for the stub. Decant measures the
    # gap from where the central directory actually sits and reads both entries.
    "prefixed": {
        "entries": [
            entry("payload.txt", rep(b"inside a self-extractor. ", 12), DEFLATE),
            entry("notes.txt", raw(b"another entry after the stub"), STORE),
        ],
        "prefix": b"MZ self-extracting stub, please ignore. " * 4,
    },
}


# The unit the bulk benchmark payload repeats. Repeating one readable block many
# times gives deflate long back-references at a fixed distance, so its decode
# leans on the match copy path and on growing the output buffer to a large size,
# the complement to the literal heavy prose payload.
BULK_UNIT = (
    b"Decant unpacks compressed archives in pure Luau, reading each deflate "
    b"block straight from the bitstream and writing the bytes into a growing "
    b"output buffer without any native compression library underneath it. "
)


# The large payloads the benchmark script decodes, kept apart from the test
# payloads so the correctness suite stays quick while the benchmarks still get
# inputs big enough to time without the scheduler's noise drowning them out. The
# prose payload stresses the literal decoding loop and the bulk payload stresses
# the match copy loop, the two halves of the inflate hot path.
BENCHMARK_PAYLOADS = {
    "prose": prose_bytes(48 * 1024),
    "bulk": BULK_UNIT * 2600,
}


class _Unseekable:
    """Wraps a writable buffer but hides tell and seek, so zipfile takes its
    streaming path and writes a data descriptor after each entry."""

    def __init__(self, sink):
        self._sink = sink

    def write(self, data):
        return self._sink.write(data)

    def flush(self):
        return self._sink.flush()


def _add_entries(archive, entries):
    """Writes each described entry into an open ZipFile."""
    for item in entries:
        info = zipfile.ZipInfo("placeholder", date_time=DOS_EPOCH)
        # Assigning the name after construction keeps the exact bytes, since the
        # constructor rewrites the platform separator and would turn a backslash
        # into a forward slash.
        info.filename = item["path"]
        info.compress_type = item["method"]
        if item["comment"] is not None:
            info.comment = item["comment"]
        if item["extra"] is not None:
            info.extra = item["extra"]
        data = materialize(item["payload"])
        if item["zip64"]:
            with archive.open(info, "w", force_zip64=True) as handle:
                handle.write(data)
        else:
            archive.writestr(info, data)


def build_zip(spec) -> bytes:
    """Assembles one ZIP archive from its entry list and options."""
    buffer = io.BytesIO()
    # zipfile only needs write and flush from its sink, and hiding tell and seek
    # is what pushes it onto the data descriptor path, so the sink is narrower
    # than the type stubs describe.
    sink = _Unseekable(buffer) if spec.get("stream") else buffer
    with zipfile.ZipFile(sink, "w") as archive:  # type: ignore[arg-type]
        comment = spec.get("comment")
        if comment:
            archive.comment = comment
        _add_entries(archive, spec["entries"])
    # A prefix stands in for a self-extractor's executable stub, glued on the
    # front without touching the offsets the archive stored.
    prefix = spec.get("prefix")
    return (prefix + buffer.getvalue()) if prefix else buffer.getvalue()


def verify_zip(zip_bytes: bytes, spec):
    """Reads an archive back and confirms its entries survived the round trip.

    Returns whether each entry ended up compressed, in central directory order,
    so the emitted expectations describe the bytes on disk. The read goes through
    the ZipInfo rather than the name so duplicate names each get their own body.
    """
    entries = spec["entries"]
    packed = []
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as archive:
        broken = archive.testzip()
        if broken is not None:
            raise ValueError(f"archive failed its own CRC check at {broken}")
        infos = archive.infolist()
        if len(infos) != len(entries):
            raise ValueError(
                "archive read back a different number of entries than it was given"
            )
        for info, item in zip(infos, entries):
            body = archive.read(info)
            if body != materialize(item["payload"]):
                raise ValueError(
                    f"{info.filename} read back differently than it was written"
                )
            packed.append(info.compress_type != STORE)
    return packed


def lua_string(data: bytes) -> str:
    """Renders bytes as a double-quoted Luau string literal.

    Printable ASCII passes through, and everything else becomes a three digit
    decimal escape so a following digit can never extend it.
    """
    out = ['"']
    for byte in data:
        if byte == 0x22:
            out.append('\\"')
        elif byte == 0x5C:
            out.append("\\\\")
        elif 0x20 <= byte <= 0x7E:
            out.append(chr(byte))
        else:
            out.append(f"\\{byte:03d}")
    out.append('"')
    return "".join(out)


def b64(data: bytes) -> str:
    """Base64 encodes bytes into an ASCII string."""
    return base64.b64encode(data).decode("ascii")


def emit_spec(spec) -> str:
    """Renders a payload spec as the Luau table fixtures.luau materializes."""
    if spec[0] == "rep":
        return f"{{ rep = {{ unit = {lua_string(spec[1])}, count = {spec[2]} }} }}"
    return f'{{ b64 = "{b64(materialize(spec))}" }}'


def gzip_bytes(data: bytes) -> bytes:
    """Compresses data to a gzip stream with a zeroed timestamp for stability."""
    stream = gzip.compress(data, compresslevel=9, mtime=0)
    if gzip.decompress(stream) != data:
        raise ValueError("gzip round trip did not reproduce the payload")
    return stream


def gzip_with_header_crc(data: bytes) -> bytes:
    """Builds a gzip stream that sets the FNAME and FHCRC flags with a valid
    header CRC16, the bytes gzip.compress never writes. The CRC covers every
    header byte, the fixed ten plus the stored filename, up to but not including
    itself, so a reader that checks it catches a tampered header and a reader that
    stops at the fixed ten bytes gets the span wrong. The deflate payload and
    trailer come straight from an ordinary gzip of the same data."""
    name = b"header.txt\x00"
    header = bytes([0x1F, 0x8B, 0x08, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF]) + name
    crc16 = zlib.crc32(header) & 0xFFFF
    header += bytes([crc16 & 0xFF, (crc16 >> 8) & 0xFF])
    stream = header + gzip.compress(data, compresslevel=9, mtime=0)[10:]
    if gzip.decompress(stream) != data:
        raise ValueError("header CRC gzip did not decompress to the payload")
    return stream


def zlib_bytes(data: bytes) -> bytes:
    """Compresses data to a zlib stream and confirms it round trips."""
    stream = zlib.compress(data, 9)
    if zlib.decompress(stream) != data:
        raise ValueError("zlib round trip did not reproduce the payload")
    return stream


def render_payloads(lines):
    """Appends the payloads table to the growing output."""
    lines.append("\tpayloads = {")
    for key, spec in PAYLOADS.items():
        data = materialize(spec)
        lines.append(f"\t\t{key} = {{")
        lines.append(f"\t\t\texpected = {emit_spec(spec)},")
        lines.append(f'\t\t\tgzip = "{b64(gzip_bytes(data))}",')
        lines.append(f'\t\t\tzlib = "{b64(zlib_bytes(data))}",')
        lines.append("\t\t},")
    lines.append("\t},")


def render_archives(lines):
    """Appends the archives table to the growing output."""
    lines.append("\tarchives = {")
    for key, spec in ARCHIVES.items():
        # A decoy end of central directory signature in the comment is meant to
        # fool a naive backward scan, and Python's own reader is one, so the
        # entries are verified against a comment-free build and the commented
        # bytes are what gets emitted.
        verify_spec = {
            "entries": spec["entries"],
            "stream": spec.get("stream"),
            "prefix": spec.get("prefix"),
        }
        packed = verify_zip(build_zip(verify_spec), verify_spec)
        zip_bytes = build_zip(spec)
        lines.append(f"\t\t{key} = {{")
        lines.append(f'\t\t\tzip = "{b64(zip_bytes)}",')
        lines.append("\t\t\tfiles = {")
        for item, is_packed in zip(spec["entries"], packed):
            path = lua_string(item["path"].encode("utf-8"))
            body = emit_spec(item["payload"])
            flag = "true" if is_packed else "false"
            lines.append(
                f"\t\t\t\t{{ path = {path}, body = {body}, packed = {flag} }},"
            )
        lines.append("\t\t\t},")
        lines.append("\t\t},")
    lines.append("\t},")


def render_gzip_members(lines):
    """Appends a concatenated gzip fixture, two members in one stream."""
    first = b"first member. " * 20
    second = b"second member. " * 20
    stream = gzip_bytes(first) + gzip_bytes(second)
    if gzip.decompress(stream) != first + second:
        raise ValueError("concatenated gzip did not decompress to both members")
    lines.append("\tgzipMembers = {")
    lines.append(f'\t\tstream = "{b64(stream)}",')
    lines.append(f"\t\tfirst = {emit_spec(raw(first))},")
    lines.append(f"\t\tfull = {emit_spec(raw(first + second))},")
    lines.append("\t},")


def render_gzip_header_crc(lines):
    """Appends a gzip fixture whose header carries a valid CRC16, the optional
    check Decant steps over without verifying."""
    payload = b"header crc guarded gzip payload. " * 8
    lines.append("\tgzipHeaderCrc = {")
    lines.append(f'\t\tstream = "{b64(gzip_with_header_crc(payload))}",')
    lines.append(f"\t\texpected = {emit_spec(raw(payload))},")
    lines.append("\t},")


def render_benchmarks(lines):
    """Appends the large benchmark payloads, stored as their gzip and zlib
    streams alongside the decoded size the benchmark script checks its output
    against."""
    lines.append("\tbenchmarks = {")
    for key, data in BENCHMARK_PAYLOADS.items():
        lines.append(f"\t\t{key} = {{")
        lines.append(f"\t\t\tsize = {len(data)},")
        lines.append(f'\t\t\tgzip = "{b64(gzip_bytes(data))}",')
        lines.append(f'\t\t\tzlib = "{b64(zlib_bytes(data))}",')
        lines.append("\t\t},")
    lines.append("\t},")


def render() -> str:
    """Builds the full text of the sample_data.luau module."""
    lines = [
        "--[[",
        "\tGenerated by scripts/generate-test-data.py. Do not edit by hand.",
        "",
        "\tHolds the compression fixtures and ZIP archives the test suite reads",
        "\tthrough tests/fixtures.luau, along with the larger benchmark streams the",
        "\tbenchmark script decodes. Each payload and archive body is stored either",
        "\tas a base64 blob or as a repeated unit, and the gzip, zlib, and archive",
        "\tbytes are base64. Some archives use features Decant does not support,",
        "\twhich the tests reach for with it.failing. Regenerate with",
        "\t`python scripts/generate-test-data.py`.",
        "]]",
        "",
        "return table.freeze({",
    ]
    render_payloads(lines)
    render_archives(lines)
    render_gzip_members(lines)
    render_gzip_header_crc(lines)
    render_benchmarks(lines)
    lines.append("})")
    lines.append("")
    return "\n".join(lines)


def main():
    root = Path(__file__).resolve().parent.parent
    out_path = root / "tests" / "sample_data.luau"
    out_path.write_text(render(), encoding="utf-8", newline="\n")
    print(
        f"wrote {out_path.relative_to(root)} with {len(PAYLOADS)} payloads, "
        f"{len(ARCHIVES)} archives, and {len(BENCHMARK_PAYLOADS)} benchmark streams"
    )

    try:
        subprocess.run(["stylua", str(out_path)], check=True)
        print("formatted with stylua")
    except FileNotFoundError:
        print("stylua not found on PATH, run it yourself before committing")
    except subprocess.CalledProcessError as error:
        print(f"stylua exited with {error.returncode}, format the file yourself")


if __name__ == "__main__":
    main()
