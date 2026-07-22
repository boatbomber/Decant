--!strict

--[[
	Raw deflate stream decompression.
]]

local bitstream = require(script.Parent.bitstream)
local inflate = require(script.Parent.inflate)

local deflate = {}

--[[
	Decompresses a raw deflate stream, one with no gzip or zlib wrapper around
	it, and returns the contents as a buffer. There's no header to parse or
	checksum to verify, so the bytes go straight to the deflate core.
]]
function deflate.decompress(data: buffer): buffer
	return inflate.decode(bitstream.new(data))
end

return table.freeze(deflate)
