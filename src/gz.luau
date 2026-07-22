--!strict

--[[
	Gzip stream decompression.
]]

local types = require(script.Parent.types)
local bitstream = require(script.Parent.bitstream)
local inflate = require(script.Parent.inflate)

local gz = {}

--[[
	Advances past a zero-terminated field in the buffer and returns the offset
	of the byte right after the terminator.
]]
local function skip_zero_terminated(data: buffer, pos: number): number
	while buffer.readu8(data, pos) ~= 0 do
		pos = pos + 1
	end
	return pos + 1
end

--[[
	Decodes one gzip member starting at the bitstream's current position. Parses
	the header and checks its CRC16 when the header carries one, inflates the
	payload, and verifies the trailing CRC-32 checksum and the input size the
	trailer records. Leaves the position at the byte after the member's trailer
	and returns the decompressed bytes as a buffer.
]]
local function inflate_member(bs: types.Bitstream): buffer
	local start = bs.pos
	local id1 = buffer.readu8(bs.buf, start)
	local id2 = buffer.readu8(bs.buf, start + 1)
	local cm = buffer.readu8(bs.buf, start + 2)
	local flg = buffer.readu8(bs.buf, start + 3)
	if id1 ~= 31 or id2 ~= 139 then
		error("invalid gzip header")
	end
	if cm ~= 8 then
		error("only deflate format is supported")
	end
	bs.pos = start + 10
	if inflate.band(flg, 4) ~= 0 then
		local xlen = buffer.readu16(bs.buf, bs.pos)
		bs.pos = bs.pos + xlen + 2
	end
	if inflate.band(flg, 8) ~= 0 then
		bs.pos = skip_zero_terminated(bs.buf, bs.pos)
	end
	if inflate.band(flg, 16) ~= 0 then
		bs.pos = skip_zero_terminated(bs.buf, bs.pos)
	end
	if inflate.band(flg, 2) ~= 0 then
		-- The header carries a CRC16 over every header byte read so far, so a copy
		-- of that span checks against the two bytes that follow it. A mismatch
		-- means the header was damaged before the payload even begins.
		local header_len = bs.pos - start
		local header = buffer.create(header_len)
		buffer.copy(header, 0, bs.buf, start, header_len)
		if inflate.crc32(header) % 65536 ~= buffer.readu16(bs.buf, bs.pos) then
			error("header checksum verification failed")
		end
		bs.pos = bs.pos + 2
	end
	local result = inflate.decode(bs)
	local crc = bs:getBits(8) + 256 * (bs:getBits(8) + 256 * (bs:getBits(8) + 256 * bs:getBits(8)))
	if crc ~= inflate.crc32(result) then
		error("checksum verification failed")
	end
	-- The last four bytes carry the uncompressed size modulo 2^32, a second
	-- integrity check that catches a payload swapped for one of a different
	-- length even when its CRC happens to line up.
	local isize = bs:getBits(8) + 256 * (bs:getBits(8) + 256 * (bs:getBits(8) + 256 * bs:getBits(8)))
	if isize ~= buffer.len(result) % 4294967296 then
		error("size verification failed")
	end
	return result
end

--[[
	Reports whether another gzip member begins at the current position. A
	concatenated stream packs its members back to back, so a matching pair of
	magic bytes still in bounds means there's more to read. Trailing bytes that
	aren't a header, like the zero padding some tools leave, end the run.
]]
local function member_follows(bs: types.Bitstream): boolean
	local pos = bs.pos
	return pos + 1 < buffer.len(bs.buf) and buffer.readu8(bs.buf, pos) == 31 and buffer.readu8(bs.buf, pos + 1) == 139
end

--[[
	Decompresses a gzip stream and returns the contents as a buffer. A stream may
	carry several members one after another, and every one is decoded and joined
	in order, the way the gzip tools read a concatenated file.
]]
function gz.decompress(data: buffer): buffer
	local bs = bitstream.new(data)
	local first = inflate_member(bs)
	if not member_follows(bs) then
		-- A single member is the common case, so it comes back without a copy.
		return first
	end
	local members = { first }
	local total = buffer.len(first)
	repeat
		local member = inflate_member(bs)
		table.insert(members, member)
		total = total + buffer.len(member)
	until not member_follows(bs)
	local combined = buffer.create(total)
	local at = 0
	for _, member in members do
		local size = buffer.len(member)
		buffer.copy(combined, at, member, 0, size)
		at = at + size
	end
	return combined
end

return table.freeze(gz)
