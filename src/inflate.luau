--!strict
--!native

--[[
	The deflate decoder every Decant format builds on, along with the CRC-32
	helper the wrapper formats verify their payloads against. It reads its input
	through a bitstream and is the performance sensitive hot path.
]]

local types = require(script.Parent.types)
local expandablebuffer = require(script.Parent.expandablebuffer)

local inflate = {}

-- The decoder leans on bit32 in its innermost loops, so localize it once here to
-- skip a global lookup on every operation.
local bit = bit32

-- The wrapper formats need a few bit operations of their own, so re-export the
-- two they reach for rather than have each of them require bit32 directly.
inflate.band = bit.band
inflate.rshift = bit.rshift

--[[
	Builds a Huffman lookup table from the given code depths. Returns the
	table and the maximum bit length used by any code.
]]
local function hufftable_create(depths: { number }): (types.HuffTable, number)
	local nvalues = #depths
	local nbits = 1
	local used = 0
	local bl_count: { [number]: number } = {}
	local next_code: { [number]: number } = {}
	for i = 1, nvalues do
		local d = depths[i]
		if d > nbits then
			nbits = d
		end
		if d > 0 then
			used = used + 1
		end
		bl_count[d] = (bl_count[d] or 0) + 1
	end
	-- A sound code hands each bit pattern of its longest length to one symbol.
	-- Handing out more than there is room for is corrupt, and leaving some
	-- unclaimed opens gaps a decode could land in and read as a missing entry.
	-- A single code is the one legal gap, the shape a lone distance entry takes,
	-- so anything else is caught here rather than surfacing as a bad table read
	-- partway through a block.
	local unclaimed = 1
	for i = 1, nbits do
		unclaimed = unclaimed * 2 - (bl_count[i] or 0)
		if unclaimed < 0 then
			error("over-subscribed Huffman code")
		end
	end
	if unclaimed > 0 and used > 1 then
		error("incomplete Huffman code")
	end
	local lookup: types.HuffTable = {}
	local code = 0
	bl_count[0] = 0
	for i = 1, nbits do
		code = (code + (bl_count[i - 1] or 0)) * 2
		next_code[i] = code
	end
	for i = 1, nvalues do
		local len = depths[i] or 0
		if len > 0 then
			local e = (i - 1) * 16 + len
			local symcode = next_code[len]
			local rcode = 0
			for j = 1, len do
				rcode = rcode + bit.lshift(bit.band(1, bit.rshift(symcode, j - 1)), len - j)
			end
			for j = 0, 2 ^ nbits - 1, 2 ^ len do
				lookup[j + rcode] = e
			end
			next_code[len] = next_code[len] + 1
		end
	end
	return lookup, nbits
end

--[[
	Decodes literal/length and distance codes into the output accumulator
	until the end-of-block code is reached. Back-references are copied byte by
	byte because a match is allowed to overlap the bytes it produces.
]]
local function block_loop(
	out: types.ExpandableBuffer,
	bs: types.Bitstream,
	nlit: number,
	ndist: number,
	littable: types.HuffTable,
	disttable: types.HuffTable
)
	local lit: number
	repeat
		lit = bs:getSymbol(littable, nlit)
		if lit < 256 then
			out:writeByte(lit)
		elseif lit > 256 then
			local nbits = 0
			local size = 3
			local dist = 1
			if lit < 265 then
				size = size + lit - 257
			elseif lit < 285 then
				nbits = bit.rshift(lit - 261, 2)
				size = size + bit.lshift(bit.band(lit - 261, 3) + 4, nbits)
			else
				size = 258
			end
			if nbits > 0 then
				size = size + bs:getBits(nbits)
			end
			local v = bs:getSymbol(disttable, ndist)
			if v < 4 then
				dist = dist + v
			else
				nbits = bit.rshift(v - 2, 1)
				dist = dist + bit.lshift(bit.band(v, 1) + 2, nbits)
				dist = dist + bs:getBits(nbits)
			end
			out:copyMatch(dist, size)
		end
	until lit == 256
end

--[[
	Decodes a block compressed with dynamic Huffman tables.
]]
local function block_dynamic(out: types.ExpandableBuffer, bs: types.Bitstream)
	local order = { 17, 18, 19, 1, 9, 8, 10, 7, 11, 6, 12, 5, 13, 4, 14, 3, 15, 2, 16 }
	local extrabits = { 2, 3, 7 }
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
	local lengthtable, nlen = hufftable_create(depths)
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
			-- A run that reaches past the literal and distance lengths would
			-- corrupt the split into the two tables, so it is rejected here.
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
	local litdepths: { number } = {}
	for j = 1, hlit do
		table.insert(litdepths, depths[j])
	end
	local littable, nlit = hufftable_create(litdepths)
	local distdepths: { number } = {}
	for j = hlit + 1, total do
		table.insert(distdepths, depths[j])
	end
	local disttable, ndist = hufftable_create(distdepths)
	block_loop(out, bs, nlit, ndist, littable, disttable)
end

--[[
	Decodes a block compressed with the fixed Huffman tables.
]]
local function block_static(out: types.ExpandableBuffer, bs: types.Bitstream)
	local cnt = { 144, 112, 24, 8 }
	local dpt = { 8, 9, 7, 8 }
	local depths: { number } = {}
	for i = 1, 4 do
		local d = dpt[i]
		for _j = 1, cnt[i] do
			table.insert(depths, d)
		end
	end
	local littable, nlit = hufftable_create(depths)
	depths = {}
	for i = 1, 32 do
		depths[i] = 5
	end
	local disttable, ndist = hufftable_create(depths)
	block_loop(out, bs, nlit, ndist, littable, disttable)
end

--[[
	Copies a stored (uncompressed) block straight into the output accumulator.
]]
local function block_uncompressed(out: types.ExpandableBuffer, bs: types.Bitstream)
	bs:flushBits(bit.band(bs.n, 7))
	local len = bs:getBits(16)
	local nlen = bs:getBits(16)
	if bit.bxor(len, nlen) ~= 65535 then
		error("stored block length check failed")
	end
	out:copyFrom(bs.buf, bs.pos, len)
	bs.pos = bs.pos + len
end

--[[
	Inflates the whole deflate stream from the bitstream and returns the
	decompressed bytes as an exactly-sized buffer.
]]
function inflate.decode(bs: types.Bitstream): buffer
	local last: number, btype: number
	local out = expandablebuffer.new()
	repeat
		last = bs:getBits(1)
		btype = bs:getBits(2)
		if btype == 0 then
			block_uncompressed(out, bs)
		elseif btype == 1 then
			block_static(out, bs)
		elseif btype == 2 then
			block_dynamic(out, bs)
		else
			error("unsupported block type")
		end
	until last == 1
	bs:flushBits(bit.band(bs.n, 7))
	return out:finalize()
end

local crc32_table: { [number]: number }? = nil

--[[
	Returns the CRC-32 lookup table, building it on the first call and reusing
	it from then on.
]]
local function crc32_lookup(): { [number]: number }
	local cached = crc32_table
	if cached then
		return cached
	end
	local built: { [number]: number } = {}
	for i = 0, 255 do
		local r = i
		for _j = 1, 8 do
			r = bit.bxor(bit.rshift(r, 1), bit.band(0xedb88320, bit.bnot(bit.band(r, 1) - 1)))
		end
		built[i] = r
	end
	crc32_table = built
	return built
end

--[[
	Computes the CRC-32 checksum of a buffer, optionally continuing from a
	previous checksum value.
]]
function inflate.crc32(buf: buffer, crc: number?): number
	local lookup = crc32_lookup()
	local acc = bit.bnot(crc or 0)
	for i = 0, buffer.len(buf) - 1 do
		local c = buffer.readu8(buf, i)
		acc = bit.bxor(lookup[bit.bxor(c, bit.band(acc, 0xff))], bit.rshift(acc, 8))
	end
	return bit.bnot(acc)
end

return inflate
