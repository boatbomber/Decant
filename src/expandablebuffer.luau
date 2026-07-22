--!strict
--!native

--[[
	A growable byte buffer that grows its backing store on demand, which the
	deflate decoder uses to accumulate its output. Its new builds an empty buffer,
	and the only way in is through the write methods. A caller appends a single
	byte, copies a run straight out of a source buffer, or repeats a back-reference
	from earlier in the buffer, then finalizes into an exactly-sized buffer once it
	is done. All offsets are 0-based to match the buffer library.
]]

local types = require(script.Parent.types)

local expandablebuffer = {}

--[[
	Ensures the buffer has room for n more bytes, doubling the backing store as
	needed.
]]
local function reserve(self: types.ExpandableBuffer, n: number)
	local needed = self.len + n
	local size = buffer.len(self.buf)
	if needed <= size then
		return
	end
	repeat
		size = size * 2
	until size >= needed
	local grown = buffer.create(size)
	buffer.copy(grown, 0, self.buf, 0, self.len)
	self.buf = grown
end

--[[
	Appends a single byte to the buffer, growing it first if it is full.
]]
local function writeByte(self: types.ExpandableBuffer, byte: number)
	reserve(self, 1)
	buffer.writeu8(self.buf, self.len, byte)
	self.len = self.len + 1
end

--[[
	Copies count bytes out of source starting at offset onto the end of the
	buffer. This lands a stored block's literal bytes straight from the compressed
	stream.
]]
local function copyFrom(self: types.ExpandableBuffer, source: buffer, offset: number, count: number)
	reserve(self, count)
	buffer.copy(self.buf, self.len, source, offset, count)
	self.len = self.len + count
end

--[[
	Copies length bytes from distance bytes back in the buffer onto its end, one
	byte at a time so a back-reference is free to overlap the bytes it is in the
	middle of producing.
]]
local function copyMatch(self: types.ExpandableBuffer, distance: number, length: number)
	reserve(self, length)
	local buf = self.buf
	local read = self.len - distance
	local write = self.len
	self.len = self.len + length
	while length > 0 do
		buffer.writeu8(buf, write, buffer.readu8(buf, read))
		read = read + 1
		write = write + 1
		length = length - 1
	end
end

--[[
	Copies the written bytes into an exactly-sized buffer.
]]
local function finalize(self: types.ExpandableBuffer): buffer
	local result = buffer.create(self.len)
	buffer.copy(result, 0, self.buf, 0, self.len)
	return result
end

--[[
	Builds an empty buffer over a starting backing store that grows on demand.
]]
function expandablebuffer.new(): types.ExpandableBuffer
	return {
		buf = buffer.create(4096),
		len = 0,
		writeByte = writeByte,
		copyFrom = copyFrom,
		copyMatch = copyMatch,
		finalize = finalize,
	} :: types.ExpandableBuffer
end

return table.freeze(expandablebuffer)
