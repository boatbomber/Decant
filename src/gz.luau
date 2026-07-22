--!strict
--!native

--[[
	Gzip stream decompression.
]]

local types = require(script.Parent.types)
local bitstream = require(script.Parent.bitstream)
local inflate = require(script.Parent.inflate)
local crc32 = require(script.Parent.crc32)

local gz = {}

--[[
	Advances past a zero-terminated field in the buffer and returns the offset
	of the byte right after the terminator.
]]
local function skipZeroTerminated(data: buffer, pos: number): number
	while buffer.readu8(data, pos) ~= 0 do
		pos = pos + 1
	end
	return pos + 1
end

--[[
	Decodes one gzip member starting at the bitstream's current position,
	leaving it at the byte after the trailer. The optional size hint sizes the
	inflate output up front.
]]
local function inflateMember(bs: types.Bitstream, sizeHint: number?): buffer
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
	if bit32.band(flg, 4) ~= 0 then
		local xlen = buffer.readu16(bs.buf, bs.pos)
		bs.pos = bs.pos + xlen + 2
	end
	if bit32.band(flg, 8) ~= 0 then
		bs.pos = skipZeroTerminated(bs.buf, bs.pos)
	end
	if bit32.band(flg, 16) ~= 0 then
		bs.pos = skipZeroTerminated(bs.buf, bs.pos)
	end
	if bit32.band(flg, 2) ~= 0 then
		-- The optional header CRC16 covers every header byte read so far.
		local headerLen = bs.pos - start
		local header = buffer.create(headerLen)
		buffer.copy(header, 0, bs.buf, start, headerLen)
		if crc32.compute(header) % 65536 ~= buffer.readu16(bs.buf, bs.pos) then
			error("header checksum verification failed")
		end
		bs.pos = bs.pos + 2
	end
	local result = inflate.decode(bs, sizeHint)
	local crc = bs:getBits(8) + 256 * (bs:getBits(8) + 256 * (bs:getBits(8) + 256 * bs:getBits(8)))
	if crc ~= crc32.compute(result) then
		error("checksum verification failed")
	end
	-- The trailer's size field, the uncompressed length modulo 2^32, catches a
	-- payload of the wrong length even when its CRC lines up.
	local isize = bs:getBits(8) + 256 * (bs:getBits(8) + 256 * (bs:getBits(8) + 256 * bs:getBits(8)))
	if isize ~= buffer.len(result) % 4294967296 then
		error("size verification failed")
	end
	return result
end

--[[
	Reports whether another gzip member begins at the current position, which is
	how a concatenated stream continues. Trailing bytes that aren't a header,
	like zero padding, end the run.
]]
local function memberFollows(bs: types.Bitstream): boolean
	local pos = bs.pos
	return pos + 1 < buffer.len(bs.buf) and buffer.readu8(bs.buf, pos) == 31 and buffer.readu8(bs.buf, pos + 1) == 139
end

--[[
	Decompresses a gzip stream and returns the contents as a buffer, decoding
	and joining every member of a concatenated stream in order.
]]
function gz.decompress(data: buffer): buffer
	local bs = bitstream.new(data)
	-- The stream's last four bytes record the final member's uncompressed size,
	-- which for the common single member stream sizes the whole output, so it
	-- serves as a hint for the first member. A wrong hint costs memory rather
	-- than correctness, and an implausibly large one is ignored so a damaged
	-- trailer can't force a huge allocation.
	local len = buffer.len(data)
	local hint: number? = nil
	if len >= 18 then
		local isize = buffer.readu32(data, len - 4)
		if isize <= len * 1032 and isize <= 268435456 then
			hint = isize
		end
	end
	local first = inflateMember(bs, hint)
	if not memberFollows(bs) then
		-- A single member is the common case, so it comes back without a copy.
		return first
	end
	local members = { first }
	local total = buffer.len(first)
	repeat
		local member = inflateMember(bs)
		table.insert(members, member)
		total = total + buffer.len(member)
	until not memberFollows(bs)
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
