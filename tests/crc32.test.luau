--[[
	Tests for the CRC-32 module the gzip and ZIP formats verify their payloads
	against. Covers the standard check vectors and the continuation parameter.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local crc32 = require(Packages:WaitForChild("Decant"):WaitForChild("crc32"))

describe("crc32", function()
	it("Computes CRC-32 check vectors", function()
		-- The standard check value for this input is 0xCBF43926.
		expect(crc32.compute(buffer.fromstring("123456789"))).toBe(0xCBF43926)
		expect(crc32.compute(buffer.fromstring(""))).toBe(0)
	end)

	it("Continues a CRC-32 across chunks", function()
		-- Feeding the running checksum back in has to match hashing the whole
		-- input in one pass, which is what lets a caller stream the data.
		local whole = crc32.compute(buffer.fromstring("123456789"))
		local first = crc32.compute(buffer.fromstring("12345"))
		local both = crc32.compute(buffer.fromstring("6789"), first)
		expect(both).toBe(whole)
	end)

	it("Agrees with the byte loop across the slicing boundary", function()
		-- Inputs on either side of the thirty-two byte step land in different
		-- mixes of the sliced loop and the byte tail, and continuing byte by byte
		-- has to reach the same value as one whole pass at every length.
		local bytes = table.create(100)
		for i = 1, 100 do
			bytes[i] = string.char((i * 37) % 256)
		end
		local input = table.concat(bytes)
		for len = 30, 70 do
			local whole = crc32.compute(buffer.fromstring(string.sub(input, 1, len)))
			local running = 0
			for i = 1, len do
				running = crc32.compute(buffer.fromstring(string.sub(input, i, i)), running)
			end
			expect(running).toBe(whole)
		end
	end)
end)
