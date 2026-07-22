--!strict
--!native

--[[
	ZIP archive access. Reads the central directory to extract a file by path or
	from an entry's metadata, and to iterate an archive's contents or its metadata.
]]

local bitstream = require(script.Parent.bitstream)
local inflate = require(script.Parent.inflate)
local crc32 = require(script.Parent.crc32)

local zip = {}

--[[
	One entry from a ZIP central directory. The modification time is Unix epoch
	seconds, and on an archive made on a Unix system the file mode lives in the
	high sixteen bits of the attributes word.
]]
export type FileMetadata = {
	path: string,
	size: number,
	offset: number,
	packed: boolean,
	crc: number,
	method: number,
	compressedSize: number,
	modified: number,
	isDirectory: boolean,
	attributes: number,
	utf8: boolean,
}

--[[
	The state carried through a central directory walk. delta is how many bytes
	a self-extracting stub shifts every recorded offset by, zero for an ordinary
	archive.
]]
type CdState = { data: buffer, len: number, delta: number }

-- Stands in for the content slot once an iterator runs out of entries.
local EMPTY_BUFFER = buffer.create(0)

-- Stands in for the metadata slot once the entry walk runs out of entries.
local EMPTY_METADATA: FileMetadata = {
	path = "",
	size = 0,
	offset = 0,
	packed = false,
	crc = 0,
	method = 0,
	compressedSize = 0,
	modified = 0,
	isDirectory = false,
	attributes = 0,
	utf8 = false,
}

-- The most recent dosToUnix conversion, since an archiver typically stamps
-- every entry with the same time.
local lastDos = -1
local lastUnix = 0

--[[
	Converts an MS-DOS date and time pair into Unix epoch seconds with plain
	calendar arithmetic, treating the fields as UTC since DOS times carry no
	zone. DOS stores seconds halved, so they double back out.
]]
local function dosToUnix(dostime: number, dosdate: number): number
	local key = dosdate * 65536 + dostime
	if key == lastDos then
		return lastUnix
	end
	local year = 1980 + bit32.rshift(dosdate, 9)
	local month = bit32.band(bit32.rshift(dosdate, 5), 15)
	local day = bit32.band(dosdate, 31)
	local hour = bit32.rshift(dostime, 11)
	local minute = bit32.band(bit32.rshift(dostime, 5), 63)
	local second = bit32.band(dostime, 31) * 2
	-- The standard civil-from-date formula, with the year shifted to start in
	-- March so leap days land at the end.
	local y = if month <= 2 then year - 1 else year
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local doy = math.floor((153 * (month + (if month > 2 then -3 else 9)) + 2) / 5) + day - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	local days = era * 146097 + doe - 719468
	lastDos = key
	lastUnix = days * 86400 + hour * 3600 + minute * 60 + second
	return lastUnix
end

--[[
	Inflates a raw deflate stream starting at the given 0-based offset, passing
	the known uncompressed size along as an output sizing hint.
]]
local function inflateRaw(data: buffer, offset: number, size: number): buffer
	local bs = bitstream.new(data)
	bs.pos = offset
	return inflate.decode(bs, size)
end

--[[
	Copies a stored (uncompressed) entry of the given size out of the archive at
	the given 0-based offset.
]]
local function extractStored(data: buffer, offset: number, size: number): buffer
	if offset + size > buffer.len(data) then
		error("entry data extends past the archive")
	end
	local result = buffer.create(size)
	buffer.copy(result, 0, data, offset, size)
	return result
end

--[[
	Extracts one entry's bytes and verifies them against the expected CRC-32.
]]
local function extractEntry(data: buffer, metadata: FileMetadata): buffer
	local method = metadata.method
	local result: buffer
	if method == 8 then
		result = inflateRaw(data, metadata.offset, metadata.size)
	elseif method == 0 then
		result = extractStored(data, metadata.offset, metadata.size)
	else
		error("unsupported compression method " .. method)
	end
	if metadata.crc ~= crc32.compute(result) then
		error("checksum verification failed")
	end
	return result
end

--[[
	Scans backwards for the end of central directory record and returns its
	0-based offset. The record may be followed by a comment of up to 65535
	bytes, so the search walks back through that span.
]]
local function findEocd(data: buffer): number
	local minSize = 22
	local maxComment = 65535
	local len = buffer.len(data)
	local searchEnd = math.max(0, len - minSize - maxComment)
	for p = len - minSize, searchEnd, -1 do
		if buffer.readu32(data, p) == 0x06054b50 then
			local commentLen = buffer.readu16(data, p + 20)
			if p + minSize + commentLen == len then
				return p
			end
		end
	end
	error("end of central directory record not found")
end

--[[
	Iterator step over the central directory. Returns the offset of the next
	entry along with the current entry's FileMetadata, whose offset field points
	at the entry's data rather than its local header, with a nil offset at the
	end of the list.
]]
local function nextFile(state: CdState, p: number): (number?, FileMetadata)
	local data = state.data
	local len = state.len
	if p + 4 > len or buffer.readu32(data, p) ~= 0x02014b50 then
		-- The metadata slot carries filler to keep the return a fixed shape.
		return nil, EMPTY_METADATA
	end
	if p + 46 > len then
		error("truncated central directory")
	end
	local flags = buffer.readu16(data, p + 8)
	local method = buffer.readu16(data, p + 10)
	local dostime = buffer.readu16(data, p + 12)
	local dosdate = buffer.readu16(data, p + 14)
	local crc = buffer.readu32(data, p + 16)
	local compressedSize = buffer.readu32(data, p + 20)
	local size = buffer.readu32(data, p + 24)
	local namelen = buffer.readu16(data, p + 28)
	local extralen = buffer.readu16(data, p + 30)
	local commentlen = buffer.readu16(data, p + 32)
	local attributes = buffer.readu32(data, p + 38)
	if p + 46 + namelen + extralen + commentlen > len then
		error("truncated central directory")
	end
	local path = buffer.readstring(data, p + 46, namelen)
	-- The recorded offset is relative to the archive's own start, so the delta
	-- re-anchors it past any self-extracting stub.
	local offset = buffer.readu32(data, p + 42) + state.delta
	p = p + 46 + namelen + extralen + commentlen
	if offset < 0 or offset + 30 > len then
		error("entry data extends past the archive")
	end
	if buffer.readu32(data, offset) ~= 0x04034b50 then
		error("invalid local header signature")
	end
	-- The local header's name and extra lengths can differ from the central
	-- directory copy, so the data offset steps over the local fields.
	local localnamelen = buffer.readu16(data, offset + 26)
	local extlen = buffer.readu16(data, offset + 28)
	offset = offset + 30 + localnamelen + extlen
	if offset + compressedSize > len then
		error("entry data extends past the archive")
	end
	return p,
		{
			path = path,
			size = size,
			offset = offset,
			packed = method ~= 0,
			crc = crc,
			method = method,
			compressedSize = compressedSize,
			modified = dosToUnix(dostime, dosdate),
			-- A directory names itself with a trailing slash, or raises the DOS
			-- directory bit in the external attributes.
			isDirectory = string.sub(path, -1) == "/" or bit32.band(attributes, 16) == 16,
			attributes = attributes,
			utf8 = bit32.band(flags, 2048) ~= 0,
		}
end

--[[
	Returns a stateless iterator triple over the central directory. The
	directory ends where the end of central directory record begins, and any gap
	between there and the offset the record claims is a self-extracting stub's
	prefix, so correcting every offset by that gap handles both shapes.
]]
local function entries(data: buffer): (typeof(nextFile), CdState, number)
	local eocd = findEocd(data)
	local cdsize = buffer.readu32(data, eocd + 12)
	local cdoffset = buffer.readu32(data, eocd + 16)
	if cdsize > eocd then
		error("central directory extends past the archive")
	end
	local delta = (eocd - cdsize) - cdoffset
	return nextFile, { data = data, len = buffer.len(data), delta = delta }, cdoffset + delta
end

--[[
	Extracts a file from a ZIP archive by path and returns its contents as a
	buffer, or nil if the archive has no file at that path.
]]
function zip.extractFile(data: buffer, path: string): buffer?
	for _, metadata in entries(data) do
		if metadata.path == path then
			return extractEntry(data, metadata)
		end
	end
	return nil
end

--[[
	Extracts a single entry from the FileMetadata that iterateFileMetadata
	reported for it, without a second walk of the central directory.
]]
function zip.extractAt(data: buffer, metadata: FileMetadata): buffer
	return extractEntry(data, metadata)
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
		-- Copied to a local because the new Luau solver drops refinements on an
		-- upvalue used inside a loop.
		local accept = filter
		while true do
			local nextp, metadata = iter(state, p)
			if nextp == nil then
				return nil, EMPTY_BUFFER
			end
			p = nextp
			if accept == nil or accept(metadata.path, metadata.size) then
				return metadata.path, extractEntry(data, metadata)
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
		local nextp, metadata = iter(state, p)
		if nextp == nil then
			return nil
		end
		p = nextp
		return metadata
	end
end

--[[
	Returns the archive's comment, or an empty string when there isn't one.
]]
function zip.readComment(data: buffer): string
	local eocd = findEocd(data)
	local commentlen = buffer.readu16(data, eocd + 20)
	return buffer.readstring(data, eocd + 22, commentlen)
end

--[[
	Reports whether an entry path is safe to use as a relative path on a real
	filesystem, rejecting null bytes, absolute paths, drive letters, and parent
	traversals that escape the extraction root. Both slash flavors count as
	separators. Decant never touches a filesystem, so this serves callers who do.
]]
function zip.isPathSafe(path: string): boolean
	if string.find(path, "\0", 1, true) ~= nil then
		return false
	end
	local first = string.sub(path, 1, 1)
	if first == "/" or first == "\\" then
		return false
	end
	if string.match(path, "^%a:") ~= nil then
		return false
	end
	local depth = 0
	for component in string.gmatch(path, "[^/\\]+") do
		if component == ".." then
			depth = depth - 1
			if depth < 0 then
				return false
			end
		elseif component ~= "." then
			depth = depth + 1
		end
	end
	return true
end

return table.freeze(zip)
