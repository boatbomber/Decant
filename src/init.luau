--!strict
--!native

--[[
	Decant's public API. The real work lives in the format submodules below, and
	this module gathers them into a single library alongside a decompress helper
	that reads the data's own header to pick the right stream submodule.
]]

local zip = require(script.zip)
local gz = require(script.gz)
local zlib = require(script.zlib)
local deflate = require(script.deflate)

export type FileMetadata = zip.FileMetadata

--[[
	Decompresses a gzip or zlib stream, telling the two apart by their header.
	Raw deflate carries no header, so use Decant.deflate.decompress for that.
]]
local function decompress(data: buffer): buffer
	if buffer.len(data) < 2 then
		error("unrecognized stream format")
	end
	local first = buffer.readu8(data, 0)
	local second = buffer.readu8(data, 1)
	if first == 31 and second == 139 then
		return gz.decompress(data)
	end
	if first % 16 == 8 and (first * 256 + second) % 31 == 0 then
		return zlib.decompress(data)
	end
	error("unrecognized stream format")
end

local Decant = {
	zip = zip,
	gz = gz,
	zlib = zlib,
	deflate = deflate,
	decompress = decompress,
}

return table.freeze(Decant)
