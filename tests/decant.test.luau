--[[
	Tests for the public Decant table assembled by init. Covers that the format
	namespaces are present and are the real submodules, that the table is
	frozen, and that a file round trips through the assembled API end to end.
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

describe("Decant", function()
	it("Exposes the format namespaces and the decompress helper", function()
		expect(type(Decant.zip.extractFile)).toBe("function")
		expect(type(Decant.zip.extractAt)).toBe("function")
		expect(type(Decant.zip.iterateFiles)).toBe("function")
		expect(type(Decant.zip.iterateFileMetadata)).toBe("function")
		expect(type(Decant.gz.decompress)).toBe("function")
		expect(type(Decant.zlib.decompress)).toBe("function")
		expect(type(Decant.deflate.decompress)).toBe("function")
		expect(type(Decant.decompress)).toBe("function")
	end)

	it("Wires the namespaces to the format submodules", function()
		local DecantInstance = Packages:WaitForChild("Decant")
		expect(Decant.zip).toBe(require(DecantInstance:WaitForChild("zip")))
		expect(Decant.gz).toBe(require(DecantInstance:WaitForChild("gz")))
		expect(Decant.zlib).toBe(require(DecantInstance:WaitForChild("zlib")))
		expect(Decant.deflate).toBe(require(DecantInstance:WaitForChild("deflate")))
	end)

	it("Decompresses a gzip or zlib stream by detecting its header", function()
		-- The top level decompress reads the header to pick the stream submodule,
		-- so a gzip stream and a zlib stream of the same payload both come back
		-- through the one call without the caller naming a format.
		expect(buffer.tostring(Decant.decompress(buffer.fromstring(fixtures.gzip.short)))).toBe(fixtures.payloads.short)
		expect(buffer.tostring(Decant.decompress(buffer.fromstring(fixtures.zlib.short)))).toBe(fixtures.payloads.short)
	end)

	it("Rejects a stream whose format it cannot detect", function()
		-- A header that is neither the gzip magic nor a valid zlib method word has
		-- no submodule to route to, and a buffer too short to hold a header cannot
		-- be recognized either.
		expect(function()
			Decant.decompress(buffer.fromstring("no"))
		end).toThrow()
		expect(function()
			Decant.decompress(buffer.fromstring("x"))
		end).toThrow()
	end)

	it("Freezes the public table", function()
		expect(table.isfrozen(Decant)).toBe(true)
	end)

	it("Round trips a file through the assembled API", function()
		-- A gzip stream and a ZIP entry both reach their submodule through the
		-- public table, which is the wiring these tests exist to prove.
		expect(buffer.tostring(Decant.gz.decompress(buffer.fromstring(fixtures.gzip.short)))).toBe(
			fixtures.payloads.short
		)

		local archive = fixtures.archives.mixed
		local first = archive.files[1]
		local extracted = Decant.zip.extractFile(buffer.fromstring(archive.bytes), first.path)
		expect(extracted).toBeDefined()
		expect(buffer.tostring(extracted)).toBe(first.body)
	end)
end)
