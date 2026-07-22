--[[
	Coverage notes for the compression formats outside Decant's reach. Every one
	needs a decoder from a different family than deflate and has no fixture to
	run against, so these stay it.skip as documentation rather than pending work.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it

describe("Decant format coverage", function()
	it.skip("Decompresses a Brotli stream", function()
		-- Brotli backs the br content encoding on the web, and its window and
		-- static dictionary model needs a decoder Decant does not have.
	end)

	it.skip("Decompresses a Zstandard stream", function()
		-- Zstandard is a separate algorithm from deflate, so Decant cannot
		-- read it.
	end)

	it.skip("Decompresses a standalone xz or lzma stream", function()
		-- The xz and lzma formats wrap the LZMA algorithm the way gzip wraps
		-- deflate. The lzma ZIP entry in zip.test points at the same decoder
		-- inside an archive.
	end)

	it.skip("Decompresses a standalone bzip2 stream", function()
		-- Bzip2 is a Burrows Wheeler transform that shares nothing with deflate.
		-- The bzip2 ZIP entry in zip.test points at the same decoder inside an
		-- archive.
	end)

	it.skip("Extracts a member from a tar archive", function()
		-- Decant can gunzip the wrapper around a tar.gz but has no tar reader
		-- to pull the individual members out of the result.
	end)
end)
