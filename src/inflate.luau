--!strict
--!native

--[[
	The deflate decoder every Decant format builds on. It reads its input
	through a bitstream and is the performance sensitive hot path.
]]

local types = require(script.Parent.types)
local expandablebuffer = require(script.Parent.expandablebuffer)

local inflate = {}

--[[
	Builds a Huffman lookup table from the given code depths and returns it with
	the longest code length. Entries are two bytes so a decode is one plain read,
	and a zero entry is a gap the decoder rejects.
]]
local function buildHufftable(depths: { number }): (types.HuffTable, number)
	local nvalues = #depths
	local nbits = 1
	local used = 0
	local blCount: { [number]: number } = {}
	local nextCode: { [number]: number } = {}
	for i = 1, nvalues do
		local d = depths[i]
		if d > nbits then
			nbits = d
		end
		if d > 0 then
			used = used + 1
		end
		blCount[d] = (blCount[d] or 0) + 1
	end
	-- A sound code claims every bit pattern of its longest length exactly once.
	-- Claiming too many is corrupt, and leaving gaps would let a decode land on
	-- a missing entry, with a lone code being the one legal incomplete shape.
	local unclaimed = 1
	for i = 1, nbits do
		unclaimed = unclaimed * 2 - (blCount[i] or 0)
		if unclaimed < 0 then
			error("over-subscribed Huffman code")
		end
	end
	if unclaimed > 0 and used > 1 then
		error("incomplete Huffman code")
	end
	local lookup: types.HuffTable = buffer.create(bit32.lshift(2, nbits))
	local code = 0
	blCount[0] = 0
	for i = 1, nbits do
		code = (code + (blCount[i - 1] or 0)) * 2
		nextCode[i] = code
	end
	for i = 1, nvalues do
		local len = depths[i] or 0
		if len > 0 then
			local e = (i - 1) * 16 + len
			local symcode = nextCode[len]
			local rcode = 0
			for j = 1, len do
				rcode = rcode + bit32.lshift(bit32.band(1, bit32.rshift(symcode, j - 1)), len - j)
			end
			for j = 0, 2 ^ nbits - 1, 2 ^ len do
				buffer.writeu16(lookup, (j + rcode) * 2, e)
			end
			nextCode[len] = nextCode[len] + 1
		end
	end
	return lookup, nbits
end

-- Length codes 257 through 285 and distance codes 0 through 29 map to fixed
-- base values and extra bit counts, precomputed here with the base packed above
-- the bit count. An out-of-range code fails the lookup's bounds check.
local lengthEntries = buffer.create(58)
for lit = 257, 285 do
	local nbits = 0
	local size = 3
	if lit < 265 then
		size = size + lit - 257
	elseif lit < 285 then
		nbits = bit32.rshift(lit - 261, 2)
		size = size + bit32.lshift(bit32.band(lit - 261, 3) + 4, nbits)
	else
		size = 258
	end
	buffer.writeu16(lengthEntries, (lit - 257) * 2, size * 16 + nbits)
end
local distEntries = buffer.create(120)
for v = 0, 29 do
	local nbits = 0
	local dist = 1
	if v < 4 then
		dist = dist + v
	else
		nbits = bit32.rshift(v - 2, 1)
		dist = dist + bit32.lshift(bit32.band(v, 1) + 2, nbits)
	end
	buffer.writeu32(distEntries, v * 4, dist * 16 + nbits)
end

--[[
	Decodes literal/length and distance codes into the output accumulator until
	the end-of-block code. The bitstream and output state live in locals for the
	whole block and sync back to their tables at the end. Refills take sixteen
	bits at a time, which from at most fifteen held bits stays inside bit32's
	range while always covering the fifteen bit maximum read. A stream that runs
	out of bytes mid-symbol drives the held bit count negative, which is caught
	and reported rather than read past.
]]
local function blockLoop(
	out: types.ExpandableBuffer,
	bs: types.Bitstream,
	nlit: number,
	ndist: number,
	littable: types.HuffTable,
	disttable: types.HuffTable
)
	local sbuf = bs.buf
	local slen = bs.len
	local pos = bs.pos
	local b = bs.b
	local n = bs.n
	local litmask = bit32.lshift(1, nlit) - 1
	local distmask = bit32.lshift(1, ndist) - 1

	local obuf = out.buf
	local olen = out.len
	local ocap = buffer.len(obuf)

	while true do
		if n < 16 then
			if pos + 2 <= slen then
				b = b + bit32.lshift(buffer.readu16(sbuf, pos), n)
				pos = pos + 2
				n = n + 16
			elseif pos < slen then
				b = b + bit32.lshift(buffer.readu8(sbuf, pos), n)
				pos = pos + 1
				n = n + 8
			end
		end
		local e = buffer.readu16(littable, bit32.band(b, litmask) * 2)
		if e == 0 then
			error("invalid Huffman code")
		end
		local elen = bit32.band(e, 15)
		b = bit32.rshift(b, elen)
		n = n - elen
		if n < 0 then
			error("unexpected end of stream")
		end
		local lit = bit32.rshift(e, 4)
		if lit < 256 then
			if olen >= ocap then
				out.len = olen
				out:reserve(1)
				obuf = out.buf
				ocap = buffer.len(obuf)
			end
			buffer.writeu8(obuf, olen, lit)
			olen = olen + 1
		elseif lit == 256 then
			break
		else
			local le = buffer.readu16(lengthEntries, (lit - 257) * 2)
			local size = bit32.rshift(le, 4)
			local nbits = bit32.band(le, 15)
			if nbits > 0 then
				if n < 16 then
					if pos + 2 <= slen then
						b = b + bit32.lshift(buffer.readu16(sbuf, pos), n)
						pos = pos + 2
						n = n + 16
					elseif pos < slen then
						b = b + bit32.lshift(buffer.readu8(sbuf, pos), n)
						pos = pos + 1
						n = n + 8
					end
				end
				size = size + bit32.band(b, bit32.lshift(1, nbits) - 1)
				b = bit32.rshift(b, nbits)
				n = n - nbits
			end
			if n < 16 then
				if pos + 2 <= slen then
					b = b + bit32.lshift(buffer.readu16(sbuf, pos), n)
					pos = pos + 2
					n = n + 16
				elseif pos < slen then
					b = b + bit32.lshift(buffer.readu8(sbuf, pos), n)
					pos = pos + 1
					n = n + 8
				end
			end
			local de = buffer.readu16(disttable, bit32.band(b, distmask) * 2)
			if de == 0 then
				error("invalid Huffman code")
			end
			local delen = bit32.band(de, 15)
			b = bit32.rshift(b, delen)
			n = n - delen
			local ve = buffer.readu32(distEntries, bit32.rshift(de, 4) * 4)
			local dist = bit32.rshift(ve, 4)
			nbits = bit32.band(ve, 15)
			if nbits > 0 then
				if n < 16 then
					if pos + 2 <= slen then
						b = b + bit32.lshift(buffer.readu16(sbuf, pos), n)
						pos = pos + 2
						n = n + 16
					elseif pos < slen then
						b = b + bit32.lshift(buffer.readu8(sbuf, pos), n)
						pos = pos + 1
						n = n + 8
					end
				end
				dist = dist + bit32.band(b, bit32.lshift(1, nbits) - 1)
				b = bit32.rshift(b, nbits)
				n = n - nbits
			end
			if n < 0 then
				error("unexpected end of stream")
			end
			if olen + size > ocap then
				out.len = olen
				out:reserve(size)
				obuf = out.buf
				ocap = buffer.len(obuf)
			end
			if dist >= size then
				-- A match no longer than its distance never overlaps, so it lands
				-- as one plain copy. Overlaps go through copyMatch, which cannot
				-- grow the store out from under the hoisted locals because
				-- capacity is already reserved.
				buffer.copy(obuf, olen, obuf, olen - dist, size)
			else
				out.len = olen
				out:copyMatch(dist, size)
			end
			olen = olen + size
		end
	end

	bs.pos = pos
	bs.b = b
	bs.n = n
	out.len = olen
end

-- The code length alphabet's storage order and the extra bit widths of its
-- three repeat codes, both fixed by the format.
local order = { 17, 18, 19, 1, 9, 8, 10, 7, 11, 6, 12, 5, 13, 4, 14, 3, 15, 2, 16 }
local extrabits = { 2, 3, 7 }

--[[
	Decodes a block compressed with dynamic Huffman tables.
]]
local function blockDynamic(out: types.ExpandableBuffer, bs: types.Bitstream)
	local hlit = 257 + bs:getBits(5)
	local hdist = 1 + bs:getBits(5)
	local hclen = 4 + bs:getBits(4)
	local depths: { number } = {}
	for i = 1, hclen do
		local v = bs:getBits(3)
		depths[order[i]] = v
	end
	for i = hclen + 1, 19 do
		depths[order[i]] = 0
	end
	local lengthtable, nlen = buildHufftable(depths)
	local total = hlit + hdist
	local i = 1
	while i <= total do
		local v = bs:getSymbol(lengthtable, nlen)
		if v < 16 then
			depths[i] = v
			i = i + 1
		elseif v < 19 then
			local nb = extrabits[v - 15]
			local c = 0
			local n = 3 + bs:getBits(nb)
			if v == 16 then
				-- Code 16 repeats the previous length, so it cannot lead the list.
				if i == 1 then
					error("code length repeat with no previous length")
				end
				c = depths[i - 1]
			elseif v == 18 then
				n = n + 8
			end
			-- A repeat running past the combined lengths would corrupt the
			-- split into the two tables.
			if i + n - 1 > total then
				error("code length repeat runs past the table")
			end
			for _j = 1, n do
				depths[i] = c
				i = i + 1
			end
		else
			error("invalid code length symbol")
		end
	end
	local litdepths = table.move(depths, 1, hlit, 1, table.create(hlit, 0))
	local littable, nlit = buildHufftable(litdepths)
	local distdepths = table.move(depths, hlit + 1, total, 1, table.create(hdist, 0))
	local disttable, ndist = buildHufftable(distdepths)
	blockLoop(out, bs, nlit, ndist, littable, disttable)
end

-- The fixed Huffman tables are identical for every static block, so they are
-- built once and cached.
local staticLittable: types.HuffTable? = nil
local staticNlit = 0
local staticDisttable: types.HuffTable? = nil
local staticNdist = 0

--[[
	Returns the fixed Huffman tables and their widths, building them on first
	use.
]]
local function staticTables(): (types.HuffTable, number, types.HuffTable, number)
	local littable = staticLittable
	local disttable = staticDisttable
	if littable and disttable then
		return littable, staticNlit, disttable, staticNdist
	end
	local cnt = { 144, 112, 24, 8 }
	local dpt = { 8, 9, 7, 8 }
	local depths: { number } = {}
	for i = 1, 4 do
		local d = dpt[i]
		for _j = 1, cnt[i] do
			table.insert(depths, d)
		end
	end
	local builtLit, nlit = buildHufftable(depths)
	depths = {}
	for i = 1, 32 do
		depths[i] = 5
	end
	local builtDist, ndist = buildHufftable(depths)
	staticLittable = builtLit
	staticNlit = nlit
	staticDisttable = builtDist
	staticNdist = ndist
	return builtLit, nlit, builtDist, ndist
end

--[[
	Decodes a block compressed with the fixed Huffman tables.
]]
local function blockStatic(out: types.ExpandableBuffer, bs: types.Bitstream)
	local littable, nlit, disttable, ndist = staticTables()
	blockLoop(out, bs, nlit, ndist, littable, disttable)
end

--[[
	Copies a stored (uncompressed) block straight into the output accumulator.
]]
local function blockUncompressed(out: types.ExpandableBuffer, bs: types.Bitstream)
	bs:flushBits(bit32.band(bs.n, 7))
	local len = bs:getBits(16)
	local nlen = bs:getBits(16)
	if bit32.bxor(len, nlen) ~= 65535 then
		error("stored block length check failed")
	end
	out:copyFrom(bs.buf, bs.pos, len)
	bs.pos = bs.pos + len
end

--[[
	Inflates a whole deflate stream and returns the decompressed bytes as an
	exactly-sized buffer. A caller that knows the output size can pass it as a
	hint so the accumulator starts at that size.
]]
function inflate.decode(bs: types.Bitstream, sizeHint: number?): buffer
	local last: number, btype: number
	local out = expandablebuffer.new(sizeHint)
	repeat
		last = bs:getBits(1)
		btype = bs:getBits(2)
		if btype == 0 then
			blockUncompressed(out, bs)
		elseif btype == 1 then
			blockStatic(out, bs)
		elseif btype == 2 then
			blockDynamic(out, bs)
		else
			error("unsupported block type")
		end
	until last == 1
	bs:flushBits(bit32.band(bs.n, 7))
	return out:finalize()
end

return table.freeze(inflate)
