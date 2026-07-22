--[[
	Tests for the bitstream reader. Covers reading bits least significant first,
	reaching across a byte boundary, peeking without consuming, flushing partial
	bits, stepping to the next whole byte, decoding a symbol through a Huffman
	table, and accepting a string as readily as a buffer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local bitstream = require(Packages:WaitForChild("Decant"):WaitForChild("bitstream"))

describe("bitstream", function()
	it("Reads bits least significant first", function()
		-- The byte 0x4D is 0b01001101. Reading the low bit first hands back 5 from
		-- the first three bits, then 1, then 4 from the last four.
		local bs = bitstream.new(string.char(0x4D))
		expect(bs:getBits(3)).toBe(5)
		expect(bs:getBits(1)).toBe(1)
		expect(bs:getBits(4)).toBe(4)
	end)

	it("Reads across a byte boundary", function()
		-- The low nibble of 0xFF is 0b1111, then a read of eight bits pulls the
		-- top nibble of 0xFF and the low nibble of 0x00 into one value.
		local bs = bitstream.new(string.char(0xFF, 0x00))
		expect(bs:getBits(4)).toBe(15)
		expect(bs:getBits(8)).toBe(15)
	end)

	it("Peeks without consuming", function()
		-- A peek leaves the bits in place, so a second peek sees the same value
		-- and the read that follows still gets them.
		local bs = bitstream.new(string.char(0x4D))
		expect(bs:peekBits(3)).toBe(5)
		expect(bs:peekBits(3)).toBe(5)
		expect(bs:getBits(3)).toBe(5)
	end)

	it("Flushes bits without reading them", function()
		-- After taking the low two bits, flushing three more skips ahead to the
		-- last three bits of the byte.
		local bs = bitstream.new(string.char(0x4D))
		expect(bs:getBits(2)).toBe(1)
		bs:flushBits(3)
		expect(bs:getBits(3)).toBe(2)
	end)

	it("Steps to the next whole byte", function()
		local bs = bitstream.new(string.char(0xAB, 0xCD))
		expect(bs:nextByte()).toBe(0xAB)
		expect(bs:nextByte()).toBe(0xCD)
	end)

	it("Decodes a symbol through a Huffman table", function()
		-- A Huffman table is a buffer of two-byte entries, each packing the decoded
		-- symbol in the high bits and the code length in the low four. A leading
		-- zero bit is a one-bit code for symbol 10, while 0b01 and 0b11 are two-bit
		-- codes for 20 and 30. The byte 0x1A lays those three codes out one after
		-- another.
		local hufftable = buffer.create(8)
		buffer.writeu16(hufftable, 0, 10 * 16 + 1)
		buffer.writeu16(hufftable, 2, 20 * 16 + 2)
		buffer.writeu16(hufftable, 4, 10 * 16 + 1)
		buffer.writeu16(hufftable, 6, 30 * 16 + 2)
		local bs = bitstream.new(string.char(0x1A))
		expect(bs:getSymbol(hufftable, 2)).toBe(10)
		expect(bs:getSymbol(hufftable, 2)).toBe(20)
		expect(bs:getSymbol(hufftable, 2)).toBe(30)
	end)

	it("Accepts a string as readily as a buffer", function()
		-- The same bytes given as a string or as a buffer produce identical reads.
		local bytes = string.char(0x4D, 0xB2)
		local fromString = bitstream.new(bytes)
		local fromBuffer = bitstream.new(buffer.fromstring(bytes))
		expect(fromString:getBits(8)).toBe(0x4D)
		expect(fromBuffer:getBits(8)).toBe(0x4D)
		expect(fromString:getBits(8)).toBe(fromBuffer:getBits(8))
	end)
end)
