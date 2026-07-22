--[[
	Tests for inflate, the deflate core the format modules build on. Covers the
	CRC-32 check vectors and its continuation parameter, and decoding a bare
	deflate stream across every block type.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")
local TestProject = ReplicatedStorage:WaitForChild("TestProject")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local bitstream = require(Packages:WaitForChild("Decant"):WaitForChild("bitstream"))
local inflate = require(Packages:WaitForChild("Decant"):WaitForChild("inflate"))
local fixtures = require(TestProject:WaitForChild("fixtures"))

describe("inflate", function()
	it("Computes CRC-32 check vectors", function()
		-- The standard check value for this input is 0xCBF43926.
		expect(inflate.crc32(buffer.fromstring("123456789"))).toBe(0xCBF43926)
		expect(inflate.crc32(buffer.fromstring(""))).toBe(0)
	end)

	it("Continues a CRC-32 across chunks", function()
		-- Feeding the running checksum back in has to match hashing the whole
		-- input in one pass, which is what lets a caller stream the data.
		local whole = inflate.crc32(buffer.fromstring("123456789"))
		local first = inflate.crc32(buffer.fromstring("12345"))
		local both = inflate.crc32(buffer.fromstring("6789"), first)
		expect(both).toBe(whole)
	end)

	it("Inflates a bare deflate stream across block types", function()
		-- Every payload exercises the decoder a little differently. The
		-- incompressible ones fall back on stored blocks, the text ones lean on
		-- static and dynamic Huffman tables, and the growth pair straddles the
		-- point where the output buffer has to double.
		for key, expected in fixtures.payloads do
			local bs = bitstream.new(buffer.fromstring(fixtures.deflateStream(key)))
			local result = buffer.tostring(inflate.decode(bs))
			if result ~= expected then
				error(`inflate.decode {key} produced {#result} bytes, expected {#expected}`)
			end
		end
	end)

	it("Rejects an unknown deflate block type", function()
		-- A block header of a final bit followed by type three is reserved, so the
		-- decoder has nothing to do but reject it. The byte 0x07 is the final bit
		-- set with the two type bits both set.
		expect(function()
			inflate.decode(bitstream.new(buffer.fromstring("\7")))
		end).toThrow()
	end)

	it("Rejects a stored block with a mismatched length check", function()
		-- A stored block follows its 16-bit length with the length's ones
		-- complement. Here the length is one but the complement is zero, so the
		-- two do not agree and the block is invalid. The leading byte is a final
		-- stored block header, then the length and its bad complement.
		local block = string.char(1, 1, 0, 0, 0)
		expect(function()
			inflate.decode(bitstream.new(buffer.fromstring(block)))
		end).toThrow()
	end)
end)
