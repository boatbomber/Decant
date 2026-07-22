--!strict
--!native

--[[
	Zlib stream decompression.
]]

local types = require(script.Parent.types)
local bitstream = require(script.Parent.bitstream)
local inflate = require(script.Parent.inflate)

local zlib = {}

--[[
	Computes the Adler-32 checksum of a buffer. The sums stay exact in doubles
	for millions of bytes, so the modulo runs once per four megabyte block. The
	inner loop takes sixteen bytes per pass through the weighted form of the
	update, which reaches the same totals as byte-at-a-time while letting the
	reads and products compute independently.
]]
local function adler32(data: buffer): number
	local s1 = 1
	local s2 = 0
	local len = buffer.len(data)
	local i = 0
	while i < len do
		local blockEnd = math.min(i + 4194304, len)
		while i + 16 <= blockEnd do
			local b0 = buffer.readu8(data, i)
			local b1 = buffer.readu8(data, i + 1)
			local b2 = buffer.readu8(data, i + 2)
			local b3 = buffer.readu8(data, i + 3)
			local b4 = buffer.readu8(data, i + 4)
			local b5 = buffer.readu8(data, i + 5)
			local b6 = buffer.readu8(data, i + 6)
			local b7 = buffer.readu8(data, i + 7)
			local b8 = buffer.readu8(data, i + 8)
			local b9 = buffer.readu8(data, i + 9)
			local b10 = buffer.readu8(data, i + 10)
			local b11 = buffer.readu8(data, i + 11)
			local b12 = buffer.readu8(data, i + 12)
			local b13 = buffer.readu8(data, i + 13)
			local b14 = buffer.readu8(data, i + 14)
			local b15 = buffer.readu8(data, i + 15)
			s2 = s2
				+ 16 * s1
				+ (16 * b0 + 15 * b1 + 14 * b2 + 13 * b3 + 12 * b4 + 11 * b5 + 10 * b6 + 9 * b7)
				+ (8 * b8 + 7 * b9 + 6 * b10 + 5 * b11 + 4 * b12 + 3 * b13 + 2 * b14 + b15)
			s1 = s1 + (b0 + b1 + b2 + b3 + b4 + b5 + b6 + b7) + (b8 + b9 + b10 + b11 + b12 + b13 + b14 + b15)
			i = i + 16
		end
		while i < blockEnd do
			s1 = s1 + buffer.readu8(data, i)
			s2 = s2 + s1
			i = i + 1
		end
		s1 = s1 % 65521
		s2 = s2 % 65521
	end
	return s2 * 65536 + s1
end

--[[
	Decodes one zlib stream and returns the decompressed bytes as a buffer.
]]
local function inflateZlib(bs: types.Bitstream): buffer
	local cmf = buffer.readu8(bs.buf, 0)
	local flg = buffer.readu8(bs.buf, 1)
	if (cmf * 256 + flg) % 31 ~= 0 then
		error("zlib header check bits are incorrect")
	end
	if bit32.band(cmf, 15) ~= 8 then
		error("only deflate format is supported")
	end
	-- Anything above seven, a 32K window, is out of spec. Smaller windows read
	-- the same since the decoder keeps the whole output.
	if bit32.rshift(cmf, 4) > 7 then
		error("unsupported window size")
	end
	if bit32.band(flg, 32) ~= 0 then
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
	return inflateZlib(bitstream.new(data))
end

return table.freeze(zlib)
