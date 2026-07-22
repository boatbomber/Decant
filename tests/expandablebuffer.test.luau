--[[
	Tests for the expandable buffer. Covers starting empty, finalizing to an
	exactly-sized buffer, growing past the starting capacity, writing through
	the direct buf and len contract the deflate core's block loop uses, copying
	a run out of a source buffer, and repeating a back-reference that overlaps
	the bytes it is producing.
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

	it("Accepts direct writes through the buf and len contract", function()
		-- The deflate core's block loop writes straight into the backing store
		-- and bumps len itself, reserving room first, so that usage has to hold
		-- up as a supported way in.
		local out = expandablebuffer.new()
		for i = 1, 3 do
			out:reserve(1)
			buffer.writeu8(out.buf, out.len, i)
			out.len += 1
		end
		expect(out.len).toBe(3)
		expect(buffer.tostring(out:finalize())).toBe(string.char(1, 2, 3))
	end)

	it("Finalizes to an exactly-sized buffer", function()
		-- The backing store starts larger than a few bytes, so finalizing has to
		-- trim it down to just the bytes that were written.
		local out = expandablebuffer.new()
		out:copyFrom(buffer.fromstring(string.char(0x2A)), 0, 1)
		local result = out:finalize()
		expect(buffer.len(result)).toBe(1)
		expect(buffer.readu8(result, 0)).toBe(0x2A)
	end)

	it("Grows past its starting capacity", function()
		-- The backing store doubles as needed, so writes well past the starting
		-- size still land every byte at the right offset.
		local out = expandablebuffer.new()
		for i = 0, 4999 do
			out:reserve(1)
			buffer.writeu8(out.buf, out.len, i % 256)
			out.len += 1
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
		out:copyFrom(buffer.fromstring(string.char(0xAA)), 0, 1)
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
		out:copyFrom(buffer.fromstring("A"), 0, 1)
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

	it("Repeats a single byte across a long run", function()
		-- A distance of one over a long length is the run fill branch, so the one
		-- byte has to stamp across the whole span.
		local out = expandablebuffer.new()
		out:copyFrom(buffer.fromstring("z"), 0, 1)
		out:copyMatch(1, 300)
		expect(buffer.tostring(out:finalize())).toBe(string.rep("z", 301))
	end)

	it("Tiles a window across an exact multiple of its length", function()
		-- A length that divides evenly by the distance exercises the chunked copy
		-- with no remainder left over.
		local out = expandablebuffer.new()
		out:copyFrom(buffer.fromstring("abc"), 0, 3)
		out:copyMatch(3, 9)
		expect(buffer.tostring(out:finalize())).toBe(string.rep("abc", 4))
	end)

	it("Tiles a window and finishes with a partial chunk", function()
		-- A length that does not divide evenly leaves a remainder shorter than the
		-- window, which lands through the final short copy.
		local out = expandablebuffer.new()
		out:copyFrom(buffer.fromstring("abcde"), 0, 5)
		out:copyMatch(5, 13)
		expect(buffer.tostring(out:finalize())).toBe(string.sub(string.rep("abcde", 4), 1, 18))
	end)

	it("Grows while repeating an overlapping back-reference", function()
		-- A match long enough to outgrow the starting capacity has to keep the
		-- overlap semantics intact across the reallocation.
		local out = expandablebuffer.new()
		out:copyFrom(buffer.fromstring("0123456789"), 0, 10)
		out:copyMatch(10, 8190)
		local result = buffer.tostring(out:finalize())
		expect(#result).toBe(8200)
		expect(string.sub(result, 1, 20)).toBe("01234567890123456789")
		expect(string.sub(result, 8191)).toBe("0123456789")
	end)

	it("Starts at a hinted size without changing what it holds", function()
		-- A size hint front-loads the backing store, and writes past the hint still
		-- grow it the usual way.
		local out = expandablebuffer.new(8)
		for i = 1, 5000 do
			out:reserve(1)
			buffer.writeu8(out.buf, out.len, i % 256)
			out.len += 1
		end
		local result = out:finalize()
		expect(buffer.len(result)).toBe(5000)
		expect(buffer.readu8(result, 4999)).toBe(5000 % 256)

		local hinted = expandablebuffer.new(10000)
		hinted:copyFrom(buffer.fromstring(string.rep("h", 10000)), 0, 10000)
		expect(buffer.len(hinted:finalize())).toBe(10000)
	end)
end)
