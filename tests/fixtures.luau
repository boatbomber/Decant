--[[
	Shared fixtures for the Decant test suite. Roblox has no compressor, so every
	input is decoded from tests/sample_data.luau, which scripts/generate-test-data.py
	produces with Python's stdlib and verifies before writing out. This module
	turns that base64 data into the ready to use payloads, compressed streams, and
	ZIP archives the tests reach for.

	Expected outputs are reconstructed from the same spec the generator compressed,
	either a base64 blob or a repeated unit, so they stand on their own rather than
	on anything Decant does.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestProject = ReplicatedStorage:WaitForChild("TestProject")

local sampleData = require(TestProject:WaitForChild("sample_data"))

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local b64lookup = {}
for i = 1, 64 do
	b64lookup[string.byte(B64_ALPHABET, i)] = i - 1
end

--[[
	Decodes a base64 string into the raw bytes it stands for. Padding and any
	other character outside the alphabet is ignored.
]]
local function b64decode(text: string): string
	local out = {}
	local acc, bits = 0, 0
	for i = 1, #text do
		local v = b64lookup[string.byte(text, i)]
		if v then
			-- Only the low fourteen bits ever matter, so masking to sixteen
			-- keeps the accumulator from growing without bound as it shifts.
			acc = bit32.band(bit32.bor(bit32.lshift(acc, 6), v), 0xFFFF)
			bits += 6
			if bits >= 8 then
				bits -= 8
				table.insert(out, string.char(bit32.band(bit32.rshift(acc, bits), 0xFF)))
			end
		end
	end
	return table.concat(out)
end

--[[
	Reconstructs the bytes behind a payload or body spec, which is either a
	repeated unit or a base64 blob.
]]
local function materialize(spec): string
	local rep = spec.rep
	if rep then
		return string.rep(rep.unit, rep.count)
	end
	return b64decode(spec.b64)
end

local payloads = {}
local gzip = {}
local zlib = {}
for key, entry in sampleData.payloads do
	payloads[key] = materialize(entry.expected)
	gzip[key] = b64decode(entry.gzip)
	zlib[key] = b64decode(entry.zlib)
end

local archives = {}
for key, entry in sampleData.archives do
	local files = {}
	for i = 1, #entry.files do
		local file = entry.files[i]
		files[i] = {
			path = file.path,
			body = materialize(file.body),
			packed = file.packed,
			method = file.method,
			compressedSize = file.compressedSize,
			modified = file.modified,
			isDirectory = file.isDirectory,
			attributes = file.attributes,
			utf8 = file.utf8,
		}
	end
	archives[key] = {
		bytes = b64decode(entry.zip),
		comment = entry.comment,
		files = files,
	}
end

--[[
	Returns the deflate stream behind a payload's zlib fixture by stripping the
	fixed two byte header. The Adler-32 trailer stays on the end because
	inflate.decode peeks a couple bytes past the final code.
]]
local function deflateStream(key: string): string
	return string.sub(zlib[key], 3)
end

-- A gzip stream of two members back to back, along with the first member's bytes
-- and the full concatenation. gzip readers are meant to return every member.
local gzipMembers = {
	stream = b64decode(sampleData.gzipMembers.stream),
	first = materialize(sampleData.gzipMembers.first),
	full = materialize(sampleData.gzipMembers.full),
}

-- The one fixture whose gzip header carries the optional CRC16, paired with
-- the payload it decodes to.
local gzipHeaderCrc = {
	stream = b64decode(sampleData.gzipHeaderCrc.stream),
	expected = materialize(sampleData.gzipHeaderCrc.expected),
}

-- The large streams the benchmark script decodes. They live apart from
-- payloads so the correctness suite never pays to decode them.
local benchmarks = {}
for key, entry in sampleData.benchmarks do
	benchmarks[key] = {
		size = entry.size,
		gzip = b64decode(entry.gzip),
		zlib = b64decode(entry.zlib),
	}
end

--[[
	Returns the raw deflate stream behind a benchmark payload, the same way
	deflateStream does for the test payloads.
]]
local function benchmarkDeflate(key: string): string
	return string.sub(benchmarks[key].zlib, 3)
end

return table.freeze({
	payloads = payloads,
	gzip = gzip,
	zlib = zlib,
	deflateStream = deflateStream,
	archives = archives,
	gzipMembers = gzipMembers,
	gzipHeaderCrc = gzipHeaderCrc,
	benchmarks = benchmarks,
	benchmarkDeflate = benchmarkDeflate,
})
