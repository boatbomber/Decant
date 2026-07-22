--[[
	Tests for Decant.gz, the gzip stream decompressor. Covers round tripping
	every gzip fixture, stepping over the optional header fields, decoding a
	stream of several members back to back, and rejecting a stream whose
	checksum, size trailer, or header is wrong.
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

--[[
	Rebuilds a gzip stream with a different flag byte and a block of optional
	header fields spliced in between the fixed header and the deflate data.
]]
local function withGzipHeaderFields(gz: string, extraFlags: number, fields: string): string
	local flg = bit32.bor(string.byte(gz, 4), extraFlags)
	return string.sub(gz, 1, 3) .. string.char(flg) .. string.sub(gz, 5, 10) .. fields .. string.sub(gz, 11)
end

describe("Decant.gz", function()
	it("Round trips every gzip fixture", function()
		for key, expected in fixtures.payloads do
			local result = buffer.tostring(Decant.gz.decompress(buffer.fromstring(fixtures.gzip[key])))
			if result ~= expected then
				error(`gz.decompress {key} produced {#result} bytes, expected {#expected}`)
			end
		end
	end)

	it("Skips optional gzip header fields", function()
		local gz = fixtures.gzip.short

		-- A filename is what a gzip of a real file most often carries.
		local named = withGzipHeaderFields(gz, 8, "original.txt\0")
		expect(buffer.tostring(Decant.gz.decompress(buffer.fromstring(named)))).toBe(fixtures.payloads.short)

		-- An extra field is length prefixed rather than zero terminated.
		local extra = withGzipHeaderFields(gz, 4, "\4\0ABCD")
		expect(buffer.tostring(Decant.gz.decompress(buffer.fromstring(extra)))).toBe(fixtures.payloads.short)

		-- The extra field, filename, and comment at once, in the order the format
		-- defines. Decant steps over all three by their length or terminator
		-- without reading their contents. The header CRC has its own test, since
		-- verifying it needs a real checksum rather than a stand-in.
		local everything = withGzipHeaderFields(gz, 4 + 8 + 16, "\4\0ABCD" .. "original.txt\0" .. "a comment\0")
		expect(buffer.tostring(Decant.gz.decompress(buffer.fromstring(everything)))).toBe(fixtures.payloads.short)
	end)

	it("Rejects a corrupted gzip checksum", function()
		local gz = fixtures.gzip.text
		-- The trailer holds a CRC-32 followed by the input size, so the
		-- checksum starts eight bytes from the end.
		local corrupted = string.sub(gz, 1, #gz - 8)
			.. string.char((string.byte(gz, #gz - 7) + 1) % 256)
			.. string.sub(gz, #gz - 6)

		expect(function()
			Decant.gz.decompress(buffer.fromstring(corrupted))
		end).toThrow()

		-- The same stream untouched still has to work, otherwise the test
		-- above proves nothing about the checksum in particular.
		expect(buffer.tostring(Decant.gz.decompress(buffer.fromstring(gz)))).toBe(fixtures.payloads.text)
	end)

	it("Rejects malformed gzip headers", function()
		expect(function()
			Decant.gz.decompress(buffer.fromstring("not a gzip stream at all"))
		end).toThrow()

		local gz = fixtures.gzip.short
		-- Compression method nine is not deflate, so the header parse rejects it.
		local badMethod = string.sub(gz, 1, 2) .. string.char(9) .. string.sub(gz, 4)
		expect(function()
			Decant.gz.decompress(buffer.fromstring(badMethod))
		end).toThrow()
	end)

	it("Rejects a truncated gzip stream", function()
		-- Cutting the stream off inside the deflate data leaves the reader running
		-- past the end while it decodes.
		local truncated = string.sub(fixtures.gzip.text, 1, 20)
		expect(function()
			Decant.gz.decompress(buffer.fromstring(truncated))
		end).toThrow()
	end)

	it("Decompresses every member of a concatenated gzip stream", function()
		-- gzip lets members sit back to back in one stream, and a reader returns
		-- the whole run. Decant decodes each member and joins them in order.
		local members = fixtures.gzipMembers
		local result = buffer.tostring(Decant.gz.decompress(buffer.fromstring(members.stream)))
		expect(result).toBe(members.full)
		-- The first member is a prefix of the result, which pins down that the
		-- members are joined in order rather than merely summing to the right size.
		expect(string.sub(result, 1, #members.first)).toBe(members.first)
	end)

	it("Verifies the gzip ISIZE trailer", function()
		-- The last four bytes carry the input size modulo 2^32, a second integrity
		-- check past the CRC-32. Flipping the high byte leaves a size that no longer
		-- matches the output length, so the read has to reject it.
		local gz = fixtures.gzip.text
		local corrupted = string.sub(gz, 1, #gz - 1) .. string.char((string.byte(gz, #gz) + 1) % 256)
		expect(function()
			Decant.gz.decompress(buffer.fromstring(corrupted))
		end).toThrow()

		-- The untouched stream still round trips, so the rejection is about the
		-- size in particular and not the stream as a whole.
		expect(buffer.tostring(Decant.gz.decompress(buffer.fromstring(gz)))).toBe(fixtures.payloads.text)
	end)

	it("Verifies the gzip header CRC16", function()
		-- A gzip header can carry a CRC16 over its own bytes, guarded by flag bit
		-- two, and Decant checks it the way zlib based readers do. This fixture
		-- sets the field along with a stored filename the CRC also covers, so a
		-- clean read proves the check spans the whole header and not just its
		-- fixed ten bytes.
		local hc = fixtures.gzipHeaderCrc

		-- The intact stream decodes, since its header CRC is correct to begin with.
		expect(buffer.tostring(Decant.gz.decompress(buffer.fromstring(hc.stream)))).toBe(hc.expected)

		-- The modification time sits inside the span the CRC covers but has no
		-- other effect on the read, so flipping one of its bytes leaves a header
		-- that fails its CRC check while the payload past it stays intact.
		local corrupted = string.sub(hc.stream, 1, 4)
			.. string.char((string.byte(hc.stream, 5) + 1) % 256)
			.. string.sub(hc.stream, 6)
		expect(function()
			Decant.gz.decompress(buffer.fromstring(corrupted))
		end).toThrow()
	end)
end)
