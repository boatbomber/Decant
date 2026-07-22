--!strict
--!native

--[[
	The CRC-32 checksum the gzip and ZIP formats verify their payloads against,
	using the standard reflected polynomial 0xEDB88320.
]]

local crc32 = {}

local slicingTables: buffer? = nil

--[[
	Returns the slicing tables, building them on the first call. One buffer
	holds thirty-two staggered 256-entry tables where table k gives the CRC of
	a byte followed by k zero bytes, so thirty-two input bytes fold in one step.
]]
local function buildTables(): buffer
	local cached = slicingTables
	if cached then
		return cached
	end
	local built = buffer.create(32768)
	for i = 0, 255 do
		local r = i
		for _j = 1, 8 do
			r = bit32.bxor(bit32.rshift(r, 1), bit32.band(0xedb88320, bit32.bnot(bit32.band(r, 1) - 1)))
		end
		buffer.writeu32(built, i * 4, r)
	end
	for t = 1, 31 do
		for i = 0, 255 do
			local v = buffer.readu32(built, (t - 1) * 1024 + i * 4)
			local folded = bit32.bxor(buffer.readu32(built, bit32.band(v, 0xff) * 4), bit32.rshift(v, 8))
			buffer.writeu32(built, t * 1024 + i * 4, folded)
		end
	end
	slicingTables = built
	return built
end

--[[
	Computes the CRC-32 of a buffer, optionally continuing from a previous
	checksum. The main loop slices thirty-two bytes per step, gathering the
	lookups in four independent xor groups so they overlap instead of forming
	one long chain, and a byte loop picks up the tail.
]]
function crc32.compute(buf: buffer, crc: number?): number
	local t = buildTables()
	local acc = bit32.bnot(crc or 0)
	local len = buffer.len(buf)
	local i = 0
	while i + 32 <= len do
		local c1 = bit32.bxor(buffer.readu32(buf, i), acc)
		local c2 = buffer.readu32(buf, i + 4)
		local c3 = buffer.readu32(buf, i + 8)
		local c4 = buffer.readu32(buf, i + 12)
		local c5 = buffer.readu32(buf, i + 16)
		local c6 = buffer.readu32(buf, i + 20)
		local c7 = buffer.readu32(buf, i + 24)
		local c8 = buffer.readu32(buf, i + 28)
		local a1 = bit32.bxor(
			buffer.readu32(t, 31744 + bit32.band(c1, 0xff) * 4),
			buffer.readu32(t, 30720 + bit32.band(bit32.rshift(c1, 8), 0xff) * 4),
			buffer.readu32(t, 29696 + bit32.band(bit32.rshift(c1, 16), 0xff) * 4),
			buffer.readu32(t, 28672 + bit32.rshift(c1, 24) * 4),
			buffer.readu32(t, 27648 + bit32.band(c2, 0xff) * 4),
			buffer.readu32(t, 26624 + bit32.band(bit32.rshift(c2, 8), 0xff) * 4),
			buffer.readu32(t, 25600 + bit32.band(bit32.rshift(c2, 16), 0xff) * 4),
			buffer.readu32(t, 24576 + bit32.rshift(c2, 24) * 4)
		)
		local a2 = bit32.bxor(
			buffer.readu32(t, 23552 + bit32.band(c3, 0xff) * 4),
			buffer.readu32(t, 22528 + bit32.band(bit32.rshift(c3, 8), 0xff) * 4),
			buffer.readu32(t, 21504 + bit32.band(bit32.rshift(c3, 16), 0xff) * 4),
			buffer.readu32(t, 20480 + bit32.rshift(c3, 24) * 4),
			buffer.readu32(t, 19456 + bit32.band(c4, 0xff) * 4),
			buffer.readu32(t, 18432 + bit32.band(bit32.rshift(c4, 8), 0xff) * 4),
			buffer.readu32(t, 17408 + bit32.band(bit32.rshift(c4, 16), 0xff) * 4),
			buffer.readu32(t, 16384 + bit32.rshift(c4, 24) * 4)
		)
		local a3 = bit32.bxor(
			buffer.readu32(t, 15360 + bit32.band(c5, 0xff) * 4),
			buffer.readu32(t, 14336 + bit32.band(bit32.rshift(c5, 8), 0xff) * 4),
			buffer.readu32(t, 13312 + bit32.band(bit32.rshift(c5, 16), 0xff) * 4),
			buffer.readu32(t, 12288 + bit32.rshift(c5, 24) * 4),
			buffer.readu32(t, 11264 + bit32.band(c6, 0xff) * 4),
			buffer.readu32(t, 10240 + bit32.band(bit32.rshift(c6, 8), 0xff) * 4),
			buffer.readu32(t, 9216 + bit32.band(bit32.rshift(c6, 16), 0xff) * 4),
			buffer.readu32(t, 8192 + bit32.rshift(c6, 24) * 4)
		)
		local a4 = bit32.bxor(
			buffer.readu32(t, 7168 + bit32.band(c7, 0xff) * 4),
			buffer.readu32(t, 6144 + bit32.band(bit32.rshift(c7, 8), 0xff) * 4),
			buffer.readu32(t, 5120 + bit32.band(bit32.rshift(c7, 16), 0xff) * 4),
			buffer.readu32(t, 4096 + bit32.rshift(c7, 24) * 4),
			buffer.readu32(t, 3072 + bit32.band(c8, 0xff) * 4),
			buffer.readu32(t, 2048 + bit32.band(bit32.rshift(c8, 8), 0xff) * 4),
			buffer.readu32(t, 1024 + bit32.band(bit32.rshift(c8, 16), 0xff) * 4),
			buffer.readu32(t, bit32.rshift(c8, 24) * 4)
		)
		acc = bit32.bxor(a1, a2, a3, a4)
		i = i + 32
	end
	while i < len do
		local c = buffer.readu8(buf, i)
		acc = bit32.bxor(buffer.readu32(t, bit32.band(bit32.bxor(c, acc), 0xff) * 4), bit32.rshift(acc, 8))
		i = i + 1
	end
	return bit32.bnot(acc)
end

return table.freeze(crc32)
