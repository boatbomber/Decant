--[[
	Tests for Decant.zip, the ZIP archive reader. Covers walking the central
	directory, extracting files by name or offset, the iterateFiles filter, and
	the ways a lookup can miss or an archive can be malformed. The archives come
	in a range of shapes so each behavior is exercised on the structure that shows
	it best. Real-world features Decant does not support yet are marked it.failing
	so the suite records the gaps and flags the moment one closes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")
local TestProject = ReplicatedStorage:WaitForChild("TestProject")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Decant = require(Packages:WaitForChild("Decant"))
local fixtures = require(TestProject:WaitForChild("fixtures"))

local archives = fixtures.archives

--[[
	Walks an archive with iterateFiles and confirms it yields exactly the entries
	the fixture expects, in central directory order, with their bytes intact.
]]
local function expectArchiveExtracts(archive)
	local seen = {}
	for path, content in Decant.zip.iterateFiles(buffer.fromstring(archive.bytes)) do
		table.insert(seen, { path = path, content = buffer.tostring(content) })
	end

	expect(#seen).toBe(#archive.files)
	for i = 1, #archive.files do
		local expected = archive.files[i]
		local got = seen[i]
		expect(got).toBeDefined()
		expect(got.path).toBe(expected.path)
		if got.content ~= expected.body then
			error(`{expected.path} came back as {#got.content} bytes, expected {#expected.body}`)
		end
	end
end

describe("Decant.zip", function()
	it("Walks the central directory", function()
		local expectedFiles = archives.mixed.files
		local seen = {}
		for meta in Decant.zip.iterateFileMetadata(buffer.fromstring(archives.mixed.bytes)) do
			table.insert(seen, meta)
		end

		expect(#seen).toBe(#expectedFiles)
		for i = 1, #expectedFiles do
			local expected = expectedFiles[i]
			local got = seen[i]
			expect(got).toBeDefined()
			expect(got.path).toBe(expected.path)
			expect(got.size).toBe(#expected.body)
			expect(got.packed).toBe(expected.packed)
			-- The data offset points past the local header, so it clears the
			-- signature at the very start of the archive.
			expect(got.offset > 0).toBe(true)
			expect(type(got.crc)).toBe("number")
		end
	end)

	it("Extracts every file across archive shapes", function()
		local shapes = {
			"mixed",
			"stored",
			"nested",
			"many",
			"binary",
			"comment",
			"comments",
			"extraFields",
			"directories",
			"paths",
			"duplicates",
			"dataDescriptor",
			"zip64Extra",
		}
		for _, key in shapes do
			expectArchiveExtracts(archives[key])
		end
	end)

	it("Offers every entry to the iterateFiles filter and drops the rejects", function()
		local offered = {}
		local kept = {}
		-- Keeping only the modest entries is the shape this filter exists for,
		-- since it lets a caller skip a huge file without paying to inflate it.
		local keepModest = function(name: string, size: number): boolean
			table.insert(offered, `{name}:{size}`)
			return size > 0 and size < 5000
		end

		for path in Decant.zip.iterateFiles(buffer.fromstring(archives.mixed.bytes), keepModest) do
			table.insert(kept, path)
		end

		-- The filter runs against the central directory, so it sees the real
		-- uncompressed size of an entry it may well be about to skip.
		expect(#offered).toBe(#archives.mixed.files)
		expect(table.find(offered, "big.txt:40000")).toBeDefined()
		expect(table.find(offered, "empty.txt:0")).toBeDefined()

		expect(#kept).toBe(3)
		expect(table.find(kept, "big.txt")).never.toBeDefined()
		expect(table.find(kept, "empty.txt")).never.toBeDefined()
		expect(table.find(kept, "readme.txt")).toBeDefined()
		expect(table.find(kept, "data/nested.txt")).toBeDefined()
		expect(table.find(kept, "stored.txt")).toBeDefined()
	end)

	it("Yields nothing when the filter rejects everything", function()
		local rejectAll = function(): boolean
			return false
		end

		local count = 0
		for _path in Decant.zip.iterateFiles(buffer.fromstring(archives.mixed.bytes), rejectAll) do
			count += 1
		end
		expect(count).toBe(0)
	end)

	it("Extracts a single entry by name across archives", function()
		for _, key in { "mixed", "stored", "nested", "many", "binary" } do
			local archive = archives[key]
			local zip = buffer.fromstring(archive.bytes)
			for i = 1, #archive.files do
				local expected = archive.files[i]
				local got = Decant.zip.extractFile(zip, expected.path)
				expect(got).toBeDefined()
				local gotStr = buffer.tostring(got)
				if gotStr ~= expected.body then
					error(`{expected.path} came back as {#gotStr} bytes, expected {#expected.body}`)
				end
			end
			expect(Decant.zip.extractFile(zip, "no-such-file.txt")).never.toBeDefined()
		end
	end)

	it("Iterates an empty archive", function()
		local zip = buffer.fromstring(archives.empty.bytes)
		local count = 0
		for _meta in Decant.zip.iterateFileMetadata(zip) do
			count += 1
		end
		expect(count).toBe(0)
		expect(Decant.zip.extractFile(zip, "anything.txt")).never.toBeDefined()
	end)

	it("Yields directory entries as empty files", function()
		local contents = {}
		for path, content in Decant.zip.iterateFiles(buffer.fromstring(archives.directories.bytes)) do
			contents[path] = buffer.tostring(content)
		end
		-- A trailing slash entry is how a folder gets recorded, and Decant
		-- surfaces it as a zero length file rather than treating it as special.
		expect(contents["docs/"]).toBe("")
		expect(contents["docs/img/"]).toBe("")
		expect(contents["docs/guide.txt"]).toBe("read me first")
	end)

	it("Returns unusual paths verbatim", function()
		local archive = archives.paths
		local zip = buffer.fromstring(archive.bytes)
		-- Decant hands back whatever bytes the archive stored, including a
		-- backslash separator and a parent directory escape, and leaves the
		-- question of whether a path is safe to write to the caller.
		for i = 1, #archive.files do
			local expected = archive.files[i]
			local got = Decant.zip.extractFile(zip, expected.path)
			expect(got).toBeDefined()
			expect(buffer.tostring(got)).toBe(expected.body)
		end
	end)

	it("Returns the first of duplicate names and iterates both", function()
		local zip = buffer.fromstring(archives.duplicates.bytes)
		-- A lookup stops at the first match.
		expect(buffer.tostring(Decant.zip.extractFile(zip, "dup.txt"))).toBe(archives.duplicates.files[1].body)
		-- Iteration still visits every entry, duplicates included.
		local seen = 0
		for path in Decant.zip.iterateFiles(zip) do
			if path == "dup.txt" then
				seen += 1
			end
		end
		expect(seen).toBe(2)
	end)

	it("Reads an archive written with data descriptors", function()
		-- Streaming writers zero the local header sizes and set the streaming
		-- flag, leaving the real sizes in the central directory Decant reads.
		expectArchiveExtracts(archives.dataDescriptor)
	end)

	it("Steps over a zip64 extra field when the sizes still fit", function()
		-- A small entry written in the zip64 format keeps real 32-bit sizes and
		-- only adds an extra field, which Decant walks past like any other.
		expectArchiveExtracts(archives.zip64Extra)
	end)

	it("Throws when a deflated entry's checksum does not match", function()
		local bytes = archives.mixed.bytes
		local offset
		for meta in Decant.zip.iterateFileMetadata(buffer.fromstring(bytes)) do
			if meta.packed then
				offset = meta.offset
				break
			end
		end
		expect(offset).toBeDefined()

		-- Flip the first byte of the compressed payload so its CRC-32 check fails
		-- on extraction.
		local pos = offset + 1
		local corrupted = string.sub(bytes, 1, pos - 1)
			.. string.char((string.byte(bytes, pos) + 1) % 256)
			.. string.sub(bytes, pos + 1)

		local firstPacked = archives.mixed.files[1]
		expect(function()
			Decant.zip.extractFile(buffer.fromstring(corrupted), firstPacked.path)
		end).toThrow()
	end)

	it("Extracts an entry from its metadata across stored and deflated shapes", function()
		local archive = archives.mixed
		local zip = buffer.fromstring(archive.bytes)
		local index = 0
		local packed = 0
		local stored = 0
		for meta in Decant.zip.iterateFileMetadata(zip) do
			index += 1
			-- extractAt reads whichever way the entry was stored straight from its
			-- metadata, so a deflated entry and a stored one both come back through
			-- the one call.
			local content = buffer.tostring(Decant.zip.extractAt(zip, meta))
			expect(content).toBe(archive.files[index].body)
			if meta.packed then
				packed += 1
			else
				stored += 1
			end
		end
		expect(packed).toBe(3)
		expect(stored).toBe(2)
	end)

	it("Finds the end of central directory behind an archive comment", function()
		-- The comment archive carries a decoy end of central directory signature,
		-- so only the length check keeps the backward scan from stopping on it.
		expectArchiveExtracts(archives.comment)
	end)

	it("Throws on an archive with no end of central directory record", function()
		-- A missing path returns nil, but a buffer that is not an archive at all
		-- has no central directory to search, so the lookup itself fails.
		expect(function()
			Decant.zip.extractFile(buffer.fromstring("this is not a zip archive"), "readme.txt")
		end).toThrow()
	end)

	it("Verifies a stored entry's CRC", function()
		local bytes = archives.stored.bytes
		local target
		for meta in Decant.zip.iterateFileMetadata(buffer.fromstring(bytes)) do
			if not meta.packed and meta.size > 0 then
				target = meta
				break
			end
		end
		expect(target).toBeDefined()

		-- A stored entry records a CRC-32 the same as a deflated one, so flipping a
		-- byte of its body has to fail the check even though nothing was inflated.
		local pos = target.offset + 1
		local corrupted = string.sub(bytes, 1, pos - 1)
			.. string.char((string.byte(bytes, pos) + 1) % 256)
			.. string.sub(bytes, pos + 1)

		expect(function()
			Decant.zip.extractFile(buffer.fromstring(corrupted), target.path)
		end).toThrow()

		-- The untouched archive still extracts that entry, so the failure is the
		-- corruption and not the entry itself. The scan stops on the first stored
		-- entry, which is the first file in the archive.
		local intact = Decant.zip.extractFile(buffer.fromstring(bytes), target.path)
		expect(buffer.tostring(intact)).toBe(archives.stored.files[1].body)
	end)

	it.skip("Reads a zip64 overflow entry", function()
		-- A zip64 overflow entry parks the 0xFFFFFFFF sentinel in its 32-bit size
		-- field because the real size, carried in a zip64 extra, is at least four
		-- gigabytes. A Roblox buffer tops out near a gigabyte, so an archive that
		-- large cannot be held in memory and the entry cannot be materialized.
		-- Decant does not parse the zip64 extra to recover the size, since there is
		-- nothing it could hand back, so this stays unsupported rather than pending.
	end)

	it.failing("Extracts a bzip2 compressed entry", function()
		-- Method 12 is bzip2. Decant treats every nonzero method as deflate and
		-- cannot read it.
		local expected = archives.bzip2.files[1]
		local got = Decant.zip.extractFile(buffer.fromstring(archives.bzip2.bytes), expected.path)
		expect(got).toBeDefined()
		expect(buffer.tostring(got)).toBe(expected.body)
	end)

	it.failing("Extracts an lzma compressed entry", function()
		-- Method 14 is lzma, in the same boat as bzip2.
		local expected = archives.lzma.files[1]
		local got = Decant.zip.extractFile(buffer.fromstring(archives.lzma.bytes), expected.path)
		expect(got).toBeDefined()
		expect(buffer.tostring(got)).toBe(expected.body)
	end)

	it("Reads a self-extracting archive with a prepended stub", function()
		-- The archive sits behind an executable stub, so its stored central
		-- directory offset no longer points where the data lands in the file.
		-- Decant measures the stub from where the central directory actually sits
		-- and corrects every offset by it, so both entries come back.
		expectArchiveExtracts(archives.prefixed)
	end)

	it.skip("Decrypts a password protected entry", function()
		-- Traditional and AES ZIP encryption set general purpose bit zero and
		-- scramble the entry data. Decant has no decryption, and Python's stdlib
		-- cannot write an encrypted archive, so there is nothing to run here yet.
	end)

	it.skip("Reads a multi-disk spanned archive", function()
		-- A spanned archive splits across several files, each with its own disk
		-- number. Decant assumes a single file and does not resolve disk
		-- boundaries.
	end)
end)
