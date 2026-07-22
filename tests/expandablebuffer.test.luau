--[[
	Tests for the expandable buffer. Covers starting empty, appending bytes in
	order, finalizing to an exactly-sized buffer, growing past the starting
	capacity, copying a run out of a source buffer, and repeating a back-reference
	that overlaps the bytes it is producing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local expandablebuffer = require(Packages:WaitForChild("Decant"):WaitForChild("expandablebuffer"))

describe("expandablebuffer", function()
	it("Starts empty", function()
		local out = expandablebuffer.new()
		expect(out.len).toBe(0)
		expect(buffer.len(out:finalize())).toBe(0)
	end)

	it("Appends bytes in order", function()
		local out = expandablebuffer.new()
		out:writeByte(1)
		out:writeByte(2)
		out:writeByte(3)
		expect(out.len).toBe(3)
		expect(buffer.tostring(out:finalize())).toBe(string.char(1, 2, 3))
	end)

	it("Finalizes to an exactly-sized buffer", function()
		-- The backing store starts larger than a few bytes, so finalizing has to
		-- trim it down to just the bytes that were written.
		local out = expandablebuffer.new()
		out:writeByte(0x2A)
		local result = out:finalize()
		expect(buffer.len(result)).toBe(1)
		expect(buffer.readu8(result, 0)).toBe(0x2A)
	end)

	it("Grows past its starting capacity", function()
		-- The backing store doubles as needed, so a write well past the starting
		-- size still lands every byte at the right offset.
		local out = expandablebuffer.new()
		for i = 0, 4999 do
			out:writeByte(i % 256)
		end
		local result = out:finalize()
		expect(buffer.len(result)).toBe(5000)
		expect(buffer.readu8(result, 0)).toBe(0)
		expect(buffer.readu8(result, 4096)).toBe(4096 % 256)
		expect(buffer.readu8(result, 4999)).toBe(4999 % 256)
	end)

	it("Copies a run out of a source buffer", function()
		-- A stored block lands its bytes with a copy from the compressed stream,
		-- starting partway in when the caller passes an offset.
		local out = expandablebuffer.new()
		out:writeByte(0xAA)
		out:copyFrom(buffer.fromstring("hello world"), 6, 5)
		local result = out:finalize()
		expect(buffer.len(result)).toBe(6)
		expect(buffer.readu8(result, 0)).toBe(0xAA)
		expect(string.sub(buffer.tostring(result), 2)).toBe("world")
	end)

	it("Grows to fit a copied run past its starting capacity", function()
		-- A copy larger than the room left over still grows the backing store to
		-- hold it.
		local out = expandablebuffer.new()
		local source = buffer.fromstring(string.rep("Q", 5000))
		out:copyFrom(source, 0, 5000)
		local result = out:finalize()
		expect(buffer.len(result)).toBe(5000)
		expect(buffer.readu8(result, 0)).toBe(string.byte("Q"))
		expect(buffer.readu8(result, 4999)).toBe(string.byte("Q"))
	end)

	it("Repeats an overlapping back-reference", function()
		-- A distance of one reads the byte it just wrote on every step, so a length
		-- of five turns one A into a run of six.
		local out = expandablebuffer.new()
		out:writeByte(string.byte("A"))
		out:copyMatch(1, 5)
		expect(buffer.tostring(out:finalize())).toBe("AAAAAA")
	end)

	it("Copies a back-reference that does not overlap", function()
		local out = expandablebuffer.new()
		out:copyFrom(buffer.fromstring("abc"), 0, 3)
		out:copyMatch(3, 3)
		expect(buffer.tostring(out:finalize())).toBe("abcabc")
	end)

	it("Copies a back-reference that partially overlaps", function()
		-- A distance of two over a length of four reads into the bytes it is
		-- producing, so the two starting bytes tile across the run.
		local out = expandablebuffer.new()
		out:copyFrom(buffer.fromstring("ab"), 0, 2)
		out:copyMatch(2, 4)
		expect(buffer.tostring(out:finalize())).toBe("ababab")
	end)
end)
