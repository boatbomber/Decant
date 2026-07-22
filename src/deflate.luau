--!strict
--!native

--[[
	Raw deflate stream decompression.
]]

local bitstream = require(script.Parent.bitstream)
local inflate = require(script.Parent.inflate)

local deflate = {}

--[[
	Decompresses a raw deflate stream, one with no gzip or zlib wrapper around
	it, and returns the contents as a buffer.
]]
function deflate.decompress(data: buffer): buffer
	return inflate.decode(bitstream.new(data))
end

return table.freeze(deflate)
