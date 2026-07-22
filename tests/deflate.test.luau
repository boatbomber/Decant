--[[
	Tests for Decant.deflate, the raw deflate stream decompressor. It wraps the
	inflate core with no header or checksum around it, so the coverage is round
	tripping every payload and rejecting a stream the decoder cannot make sense
	of.
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

describe("Decant.deflate", function()
	it("Round trips every payload as raw deflate", function()
		-- The fixture strips the two byte zlib header off each stream, leaving the
		-- bare deflate data that Decant.deflate reads without any wrapper.
		for key, expected in fixtures.payloads do
			local result = buffer.tostring(Decant.deflate.decompress(buffer.fromstring(fixtures.deflateStream(key))))
			if result ~= expected then
				error(`deflate.decompress {key} produced {#result} bytes, expected {#expected}`)
			end
		end
	end)

	it("Rejects a stream with an invalid block type", function()
		-- A block header of a final bit followed by type three is reserved, so the
		-- decoder has nothing to do but reject it. The byte 0x07 is the final bit
		-- set with the two type bits both set.
		expect(function()
			Decant.deflate.decompress(buffer.fromstring("\7"))
		end).toThrow()
	end)
end)
