--[[
	Tests for Decant.zlib, the zlib stream decompressor. Covers round tripping
	every zlib fixture, rejecting a corrupted Adler-32, and rejecting the header
	shapes the decoder refuses: bad check bits, a preset dictionary, an
	unsupported compression method, and an unsupported window size.
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
	Finds a flag byte that pairs with the given CMF to satisfy the zlib mod-31
	header check, so a test can reach a later validation with a header that only
	fails the way it means to. Returns nil when no flag works.
]]
local function flagFor(cmf: number): number?
	for flg = 0, 255 do
		if (cmf * 256 + flg) % 31 == 0 then
			return flg
		end
	end
	return nil
end

describe("Decant.zlib", function()
	it("Round trips every zlib fixture", function()
		for key, expected in fixtures.payloads do
			local result = buffer.tostring(Decant.zlib.decompress(buffer.fromstring(fixtures.zlib[key])))
			if result ~= expected then
				error(`zlib.decompress {key} produced {#result} bytes, expected {#expected}`)
			end
		end
	end)

	it("Rejects a corrupted zlib checksum", function()
		local zl = fixtures.zlib.text
		-- The Adler-32 occupies the last four bytes.
		local corrupted = string.sub(zl, 1, #zl - 1) .. string.char((string.byte(zl, #zl) + 1) % 256)

		expect(function()
			Decant.zlib.decompress(buffer.fromstring(corrupted))
		end).toThrow()

		expect(buffer.tostring(Decant.zlib.decompress(buffer.fromstring(zl)))).toBe(fixtures.payloads.text)
	end)

	it("Rejects bad zlib header check bits", function()
		expect(function()
			Decant.zlib.decompress(buffer.fromstring("\255\255not zlib"))
		end).toThrow()
	end)

	it("Rejects a preset dictionary", function()
		-- A preset dictionary is signalled by bit five of the flag byte, and the
		-- header check bits still have to come out to a multiple of 31.
		local zl = fixtures.zlib.short
		local cmf = string.byte(zl, 1)
		local dictFlag = nil
		for flg = 0, 255 do
			if (cmf * 256 + flg) % 31 == 0 and bit32.band(flg, 32) ~= 0 then
				dictFlag = flg
				break
			end
		end
		expect(dictFlag).toBeDefined()
		expect(function()
			Decant.zlib.decompress(buffer.fromstring(string.char(cmf, dictFlag :: number) .. string.sub(zl, 3)))
		end).toThrow()
	end)

	it("Rejects an unsupported compression method", function()
		-- The low nibble of the CMF is the method, and only deflate (eight) is
		-- supported, so a nine reaches the method check with valid check bits.
		local cmf = 0x79
		local flg = flagFor(cmf)
		expect(flg).toBeDefined()
		expect(function()
			Decant.zlib.decompress(buffer.fromstring(string.char(cmf, flg :: number)))
		end).toThrow()
	end)

	it("Rejects a window size above the maximum", function()
		-- The high nibble of the CMF is the window size, which cannot exceed seven.
		-- An eight is over the maximum and out of spec, so the window check rejects
		-- it while the method stays valid.
		local cmf = 0x88
		local flg = flagFor(cmf)
		expect(flg).toBeDefined()
		expect(function()
			Decant.zlib.decompress(buffer.fromstring(string.char(cmf, flg :: number)))
		end).toThrow()
	end)

	it("Accepts a window size below the maximum", function()
		-- A stream may declare any window up to 32K, and the decoder keeps the whole
		-- output rather than a bounded window, so a smaller declared size decodes the
		-- same. Rewriting the header to a 16K window (CINFO six) with matching check
		-- bits still reproduces the payload.
		local zl = fixtures.zlib.short
		local rewritten = string.char(0x68, 0x05) .. string.sub(zl, 3)
		expect(buffer.tostring(Decant.zlib.decompress(buffer.fromstring(rewritten)))).toBe(fixtures.payloads.short)
	end)

	it("Rejects a truncated zlib stream", function()
		-- Cutting the stream off inside the deflate data leaves the reader running
		-- past the end while it decodes.
		local truncated = string.sub(fixtures.zlib.text, 1, 12)
		expect(function()
			Decant.zlib.decompress(buffer.fromstring(truncated))
		end).toThrow()
	end)

	it.skip("Decompresses a zlib stream that uses a preset dictionary", function()
		-- A stream compressed against a preset dictionary needs that same
		-- dictionary to inflate. Decant has no way to accept one, so it rejects
		-- the stream rather than reading it.
	end)
end)
