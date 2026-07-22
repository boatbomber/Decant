--!strict

--[[
	Shared type definitions used across the Decant submodules.
]]

--[[
	A Huffman lookup table, a buffer of two-byte entries indexed by peeked bits.
	Each entry packs the symbol above the code length in the low four bits, and
	a zero entry is a gap in an incomplete code the decoder rejects.
]]
export type HuffTable = buffer

--[[
	A bitstream reader over a buffer of compressed data. All offsets are 0-based
	to match the buffer library.
]]
export type Bitstream = {
	buf: buffer, -- Buffer holding the compressed data.
	len: number, -- Total byte length of the buffer.
	pos: number, -- Offset of the next byte to be read.
	b: number, -- Bit buffer.
	n: number, -- Number of bits currently held in the bit buffer.
	flushBits: (Bitstream, n: number) -> (),
	nextByte: (Bitstream) -> number,
	peekBits: (Bitstream, n: number) -> number,
	getBits: (Bitstream, n: number) -> number,
	getSymbol: (Bitstream, hufftable: HuffTable, n: number) -> number,
}

--[[
	A growable byte buffer the deflate decoder writes its output into. The backing
	store grows on demand as it fills, and len tracks how many bytes have been
	written so far.
]]
export type ExpandableBuffer = {
	buf: buffer, -- Backing store, resized as it fills.
	len: number, -- Number of bytes written so far.
	reserve: (ExpandableBuffer, n: number) -> (),
	copyFrom: (ExpandableBuffer, source: buffer, offset: number, count: number) -> (),
	copyMatch: (ExpandableBuffer, distance: number, length: number) -> (),
	finalize: (ExpandableBuffer) -> buffer,
}

return nil
