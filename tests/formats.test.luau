--[[
	Coverage notes for the compression formats outside Decant's reach. Python,
	Node, and .NET each decode formats Decant does not, and these skipped tests
	write down which ones and why, so the gap is recorded rather than assumed.
	Every one needs a decoder from a different family than deflate, and there is
	no fixture to run against, so they stay it.skip as documentation rather than
	pending work. The bzip2 and lzma ZIP entries have their own it.failing tests
	in zip.test, so what these note is the standalone streams and the tar
	container those same decoders would also unlock.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it

describe("Decant format coverage", function()
	it.skip("Decompresses a Brotli stream", function()
		-- Brotli backs the br content encoding on the web. Node decodes it through
		-- zlib.brotliDecompress and .NET through BrotliStream. Its window and
		-- static dictionary model comes from a different family than deflate, so
		-- reading it needs a decoder Decant does not have.
	end)

	it.skip("Decompresses a Zstandard stream", function()
		-- Zstandard is what package managers and tar.zst reach for now. Node 22
		-- decodes it through zlib.zstdDecompress and Python 3.14 through
		-- compression.zstd. It is a separate algorithm from deflate, so Decant
		-- cannot read it.
	end)

	it.skip("Decompresses a standalone xz or lzma stream", function()
		-- The xz and lzma stream formats wrap the LZMA algorithm the way gzip
		-- wraps deflate, and Python reads both through its lzma module. Decant
		-- covers the gzip family alone, so a standalone .xz file is out of reach.
		-- The lzma ZIP entry in zip.test points at the same decoder inside an
		-- archive.
	end)

	it.skip("Decompresses a standalone bzip2 stream", function()
		-- A .bz2 file carries the bzip2 algorithm, a Burrows Wheeler transform
		-- that shares nothing with deflate, and Python reads it through its bz2
		-- module. Decant has no bzip2 decoder. The bzip2 ZIP entry in zip.test
		-- points at the same decoder inside an archive.
	end)

	it.skip("Extracts a member from a tar archive", function()
		-- A tar archive, and the tar.gz, tar.bz2, and tar.xz built on top of it,
		-- is the Unix counterpart to a ZIP. Python's tarfile and .NET's
		-- System.Formats.Tar read it. Decant can gunzip the wrapper around a
		-- tar.gz but has no tar reader to pull the individual members out of the
		-- result.
	end)
end)
