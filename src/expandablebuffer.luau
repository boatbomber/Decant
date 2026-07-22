--!strict
--!native

--[[
	The growable byte buffer the deflate decoder accumulates its output into.
	The decoder's block loop writes literals and non-overlapping copies on the
	buf and len fields directly, growing the store through reserve, so those
	fields are part of the contract rather than hidden state, while overlapping
	back-references come through copyMatch. All offsets are 0-based to match
	the buffer library.
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
	Copies count bytes out of source starting at offset onto the end of the
	buffer.
]]
local function copyFrom(self: types.ExpandableBuffer, source: buffer, offset: number, count: number)
	reserve(self, count)
	buffer.copy(self.buf, self.len, source, offset, count)
	self.len = self.len + count
end

--[[
	Copies length bytes from distance bytes back in the buffer onto its end,
	taking the widest step the overlap allows. A match no longer than its
	distance lands in a single copy, a distance of one is a run buffer.fill
	stamps out, and anything else repeats the distance-wide window in whole
	chunks with one shorter copy for the tail, which cannot overlap since the
	write position is a full window past the read by then.
]]
local function copyMatch(self: types.ExpandableBuffer, distance: number, length: number)
	reserve(self, length)
	local buf = self.buf
	local read = self.len - distance
	local write = self.len
	self.len = self.len + length
	if distance >= length then
		buffer.copy(buf, write, buf, read, length)
	elseif distance == 1 then
		buffer.fill(buf, write, buffer.readu8(buf, read), length)
	else
		local remaining = length
		repeat
			buffer.copy(buf, write, buf, read, distance)
			write = write + distance
			remaining = remaining - distance
		until remaining < distance
		if remaining > 0 then
			buffer.copy(buf, write, buf, read, remaining)
		end
	end
end

--[[
	Returns the written bytes as an exactly-sized buffer. A backing store that
	is exactly full is handed back without a copy, and nothing writes to the
	store after it escapes.
]]
local function finalize(self: types.ExpandableBuffer): buffer
	local len = self.len
	local buf = self.buf
	if buffer.len(buf) == len then
		return buf
	end
	local result = buffer.create(len)
	buffer.copy(result, 0, buf, 0, len)
	return result
end

--[[
	Builds an empty buffer whose backing store grows on demand. A caller that
	knows how many bytes are coming can pass that as a hint so the doubling
	copies never happen, and a wrong hint only costs memory, never correctness.
]]
function expandablebuffer.new(sizeHint: number?): types.ExpandableBuffer
	return {
		buf = buffer.create(math.max(sizeHint or 0, 4096)),
		len = 0,
		reserve = reserve,
		copyFrom = copyFrom,
		copyMatch = copyMatch,
		finalize = finalize,
	} :: types.ExpandableBuffer
end

return table.freeze(expandablebuffer)
