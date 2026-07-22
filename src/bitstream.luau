--!strict
--!native

--[[
	The bitstream reader the deflate decoder reads through. It wraps a buffer of
	compressed data and hands out bits, whole bytes, and Huffman-coded symbols on
	demand. All offsets are 0-based to match the buffer library.
]]

local types = require(script.Parent.types)

local bitstream = {}

-- The reader sits on the decoder's hot path, so localize bit32 once here to skip
-- a global lookup on every operation.
local bit = bit32

--[[
	Discards the first n bits from the bit buffer.
]]
local function flushBits(self: types.Bitstream, n: number)
	self.n = self.n - n
	self.b = bit.rshift(self.b, n)
end

--[[
	Reads the byte at the current byte position and advances past it.
]]
local function nextByte(self: types.Bitstream): number
	local pos = self.pos
	self.pos = pos + 1
	return buffer.readu8(self.buf, pos)
end

--[[
	Peeks n bits from the stream without consuming them.
]]
local function peekBits(self: types.Bitstream, n: number): number
	while self.n < n do
		self.b = self.b + bit.lshift(self:nextByte(), self.n)
		self.n = self.n + 8
	end
	return bit.band(self.b, bit.lshift(1, n) - 1)
end

--[[
	Consumes and returns n bits from the stream.
]]
local function getBits(self: types.Bitstream, n: number): number
	local ret = self:peekBits(n)
	self.n = self.n - n
	self.b = bit.rshift(self.b, n)
	return ret
end

--[[
	Consumes one Huffman-coded symbol from the stream and returns it, decoded
	through the given table. n is the table's longest code, the most bits a single
	symbol can take.
]]
local function getSymbol(self: types.Bitstream, hufftable: types.HuffTable, n: number): number
	local e = hufftable[self:peekBits(n)]
	local len = bit.band(e, 15)
	local ret = bit.rshift(e, 4)
	self.n = self.n - len
	self.b = bit.rshift(self.b, len)
	return ret
end

--[[
	Builds a bitstream reader over a buffer of compressed data. Accepts a string
	for convenience and converts it to a buffer once up front.
]]
function bitstream.new(data: buffer | string): types.Bitstream
	local buf = if type(data) == "string" then buffer.fromstring(data) else data
	return {
		buf = buf,
		len = buffer.len(buf),
		pos = 0,
		b = 0,
		n = 0,
		flushBits = flushBits,
		nextByte = nextByte,
		peekBits = peekBits,
		getBits = getBits,
		getSymbol = getSymbol,
	} :: types.Bitstream
end

return table.freeze(bitstream)
