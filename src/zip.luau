--!strict

--[[
	ZIP archive access. Reads the central directory to extract a file by path or
	from an entry's metadata, and to iterate an archive's contents or its metadata.
]]

local bitstream = require(script.Parent.bitstream)
local inflate = require(script.Parent.inflate)

local zip = {}

--[[
	One entry from a ZIP central directory, holding its path, uncompressed size,
	the 0-based offset of its data, whether it is deflate-packed rather than
	stored, and its expected CRC-32.
]]
export type FileMetadata = {
	path: string,
	size: number,
	offset: number,
	packed: boolean,
	crc: number,
}

--[[
	The state carried through each step of a central directory walk. It holds the
	archive bytes and the prefix delta, which is how many bytes a self-extracting
	stub shifts every recorded offset by. That delta is zero for an ordinary
	archive.
]]
type CdState = { data: buffer, delta: number }

-- Stands in for the content slot once an iterator runs out of entries.
local EMPTY_BUFFER = buffer.create(0)

--[[
	Inflates a raw deflate stream starting at the given 0-based offset,
	optionally verifying the result against an expected CRC-32.
]]
local function inflate_raw(data: buffer, offset: number, crc: number?): buffer
	local bs = bitstream.new(data)
	bs.pos = offset
	local result = inflate.decode(bs)
	if crc and crc ~= inflate.crc32(result) then
		error("checksum verification failed")
	end
	return result
end

--[[
	Copies a stored (uncompressed) entry of the given size out of the archive at
	the given 0-based offset and verifies it against its expected CRC-32.
]]
local function extract_stored(data: buffer, offset: number, size: number, crc: number): buffer
	local result = buffer.create(size)
	buffer.copy(result, 0, data, offset, size)
	if crc ~= inflate.crc32(result) then
		error("checksum verification failed")
	end
	return result
end

--[[
	Extracts one entry's bytes from its central directory fields, inflating a
	deflated entry or copying a stored one, and verifies the result against the
	entry's expected CRC-32.
]]
local function extract_entry(data: buffer, offset: number, size: number, packed: boolean, crc: number): buffer
	if packed then
		return inflate_raw(data, offset, crc)
	end
	return extract_stored(data, offset, size, crc)
end

--[[
	Scans backwards for the end of central directory record and returns its
	0-based offset. The record may be followed by a comment of up to 65535
	bytes, so the search walks back through that span.
]]
local function find_eocd(data: buffer): number
	local min_size = 22
	local max_comment = 65535
	local len = buffer.len(data)
	local search_end = math.max(0, len - min_size - max_comment)
	for p = len - min_size, search_end, -1 do
		if buffer.readu32(data, p) == 0x06054b50 then
			local comment_len = buffer.readu16(data, p + 20)
			if p + min_size + comment_len == len then
				return p
			end
		end
	end
	error("end of central directory record not found")
end

--[[
	Iterator step over the central directory. Given the walk state and the
	offset of a central directory entry, returns the offset of the next entry
	along with the current file's path, 0-based data offset, uncompressed size,
	whether it is deflate-packed, and its expected CRC-32. The offset comes back
	nil once the end of the list is reached.
]]
local function nextfile(state: CdState, p: number): (number?, string, number, number, boolean, number)
	local data = state.data
	if buffer.readu32(data, p) ~= 0x02014b50 then
		-- The central directory list ends here, so the remaining values are
		-- unused filler that keeps the tuple a fixed shape.
		return nil, "", 0, 0, false, 0
	end
	local packed = buffer.readu16(data, p + 10) ~= 0
	local crc = buffer.readu32(data, p + 16)
	local size = buffer.readu32(data, p + 24)
	local namelen = buffer.readu16(data, p + 28)
	local path = buffer.readstring(data, p + 46, namelen)
	-- The recorded offset is relative to the archive's own start, so the prefix
	-- delta re-anchors it to where the local header actually lands in the file.
	local offset = buffer.readu32(data, p + 42) + state.delta
	p = p + 46 + namelen + buffer.readu16(data, p + 30) + buffer.readu16(data, p + 32)
	if buffer.readu32(data, offset) ~= 0x04034b50 then
		error("invalid local header signature")
	end
	-- The local header carries its own name and extra field lengths, which a
	-- writer is free to set apart from the central directory copy, so the data
	-- offset steps over the local header's own fields rather than reusing the
	-- central name length.
	local localnamelen = buffer.readu16(data, offset + 26)
	local extlen = buffer.readu16(data, offset + 28)
	offset = offset + 30 + localnamelen + extlen
	return p, path, offset, size, packed, crc
end

--[[
	Returns a stateless iterator triple over a ZIP archive's central directory
	entries, ready to drive a generic for loop. The central directory ends right
	where the end of central directory record begins, so subtracting its size
	tells us where it really starts. Any gap between that and the offset the
	record claims is the stub a self-extracting archive prepends, and correcting
	every entry offset by that gap keeps the walk working whether or not a stub
	is there.
]]
local function entries(data: buffer): (typeof(nextfile), CdState, number)
	local eocd = find_eocd(data)
	local cdsize = buffer.readu32(data, eocd + 12)
	local cdoffset = buffer.readu32(data, eocd + 16)
	local delta = (eocd - cdsize) - cdoffset
	return nextfile, { data = data, delta = delta }, cdoffset + delta
end

--[[
	Extracts a file from a ZIP archive by path and returns its contents as a
	buffer, or nil if the archive has no file at that path.
]]
function zip.extractFile(data: buffer, path: string): buffer?
	for _, name, offset, size, packed, crc in entries(data) do
		if name == path then
			return extract_entry(data, offset, size, packed, crc)
		end
	end
	return nil
end

--[[
	Extracts a single entry from the FileMetadata that iterateFileMetadata
	reported for it, reading straight from its recorded offset without a second
	walk of the central directory. It inflates a deflated entry or copies a
	stored one and verifies the result against the entry's CRC-32.
]]
function zip.extractAt(data: buffer, metadata: FileMetadata): buffer
	return extract_entry(data, metadata.offset, metadata.size, metadata.packed, metadata.crc)
end

--[[
	Returns an iterator over every file in a ZIP archive, yielding each file's
	path and contents as a buffer. The optional filter runs on each file's path
	and uncompressed size before anything is decompressed, and returning false
	skips that file without ever inflating it.
]]
function zip.iterateFiles(data: buffer, filter: ((path: string, size: number) -> boolean)?): () -> (string?, buffer)
	local iter, state, start = entries(data)
	local p = start
	return function(): (string?, buffer)
		-- The filter gets copied into a local because the new Luau solver drops
		-- refinements on an upvalue used inside a loop, so the nil check below
		-- only narrows when it reads from something local to this closure.
		local accept = filter
		while true do
			local nextp, name, offset, size, packed, crc = iter(state, p)
			if nextp == nil then
				return nil, EMPTY_BUFFER
			end
			p = nextp
			if accept == nil or accept(name, size) then
				return name, extract_entry(data, offset, size, packed, crc)
			end
		end
	end
end

--[[
	Returns an iterator over every file in a ZIP archive, yielding one
	FileMetadata per entry without decompressing anything.
]]
function zip.iterateFileMetadata(data: buffer): () -> FileMetadata?
	local iter, state, start = entries(data)
	local p = start
	return function(): FileMetadata?
		local nextp, name, offset, size, packed, crc = iter(state, p)
		if nextp == nil then
			return nil
		end
		p = nextp
		return {
			path = name,
			size = size,
			offset = offset,
			packed = packed,
			crc = crc,
		}
	end
end

return table.freeze(zip)
