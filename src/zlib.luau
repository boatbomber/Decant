--!strict

--[[
	Zlib stream decompression.
]]

local types = require(script.Parent.types)
local bitstream = require(script.Parent.bitstream)
local inflate = require(script.Parent.inflate)

local zlib = {}

--[[
	Computes the Adler-32 checksum of a buffer.
]]
local function adler32(data: buffer): number
	local s1 = 1
	local s2 = 0
	for i = 0, buffer.len(data) - 1 do
		local c = buffer.readu8(data, i)
		s1 = (s1 + c) % 65521
		s2 = (s2 + s1) % 65521
	end
	return s2 * 65536 + s1
end

--[[
	Parses the zlib header, inflates the payload, and verifies its Adler-32
	checksum. Returns the decompressed bytes as a buffer.
]]
local function inflate_zlib(bs: types.Bitstream): buffer
	local cmf = buffer.readu8(bs.buf, 0)
	local flg = buffer.readu8(bs.buf, 1)
	if (cmf * 256 + flg) % 31 ~= 0 then
		error("zlib header check bits are incorrect")
	end
	if inflate.band(cmf, 15) ~= 8 then
		error("only deflate format is supported")
	end
	-- The window field tops out at seven, a 32K window, and anything above that
	-- is out of spec. The decoder keeps the whole output rather than a bounded
	-- window, so a smaller declared size reads the same and is accepted.
	if inflate.rshift(cmf, 4) > 7 then
		error("unsupported window size")
	end
	if inflate.band(flg, 32) ~= 0 then
		error("preset dictionary not implemented")
	end
	bs.pos = 2
	local result = inflate.decode(bs)
	local adler = ((bs:getBits(8) * 256 + bs:getBits(8)) * 256 + bs:getBits(8)) * 256 + bs:getBits(8)
	if adler ~= adler32(result) then
		error("checksum verification failed")
	end
	return result
end

--[[
	Decompresses a zlib stream and returns the contents as a buffer.
]]
function zlib.decompress(data: buffer): buffer
	return inflate_zlib(bitstream.new(data))
end

return table.freeze(zlib)
