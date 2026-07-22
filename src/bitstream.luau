--!strict
--!native

--[[
	The bitstream reader the deflate decoder reads through. It wraps a buffer of
	compressed data and hands out bits, whole bytes, and Huffman-coded symbols on
	demand. All offsets are 0-based to match the buffer library.
]]

local types = require(script.Parent.types)

local bitstream = {}

--[[
	Discards the first n bits from the bit buffer.
]]
local function flushBits(self: types.Bitstream, n: number)
	self.n = self.n - n
	self.b = bit32.rshift(self.b, n)
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
		self.b = self.b + bit32.lshift(self:nextByte(), self.n)
		self.n = self.n + 8
	end
	return bit32.band(self.b, bit32.lshift(1, n) - 1)
end

--[[
	Consumes and returns n bits from the stream.
]]
local function getBits(self: types.Bitstream, n: number): number
	local ret = self:peekBits(n)
	self.n = self.n - n
	self.b = bit32.rshift(self.b, n)
	return ret
end

--[[
	Consumes one Huffman-coded symbol from the stream and returns it, decoded
	through the given table. n is the table's longest code, the most bits a single
	symbol can take.
]]
local function getSymbol(self: types.Bitstream, hufftable: types.HuffTable, n: number): number
	local e = buffer.readu16(hufftable, self:peekBits(n) * 2)
	if e == 0 then
		error("invalid Huffman code")
	end
	local len = bit32.band(e, 15)
	local ret = bit32.rshift(e, 4)
	self.n = self.n - len
	self.b = bit32.rshift(self.b, len)
	return ret
end

--[[
	Builds a bitstream reader over a buffer of compressed data, accepting a
	string for convenience.
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
