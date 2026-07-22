--# selene: allow(unused_variable)
--[[
	Performance benchmarks for Decant, run through run-in-roblox by
	scripts/bench.sh against the same place the tests build. Each benchmark
	times a whole operation with os.clock across several runs and prints the
	best and mean, since the best run is the one least disturbed by the
	garbage collector and the scheduler.

	The suite walks every public surface. It times the inflate core and the
	CRC-32 helper on their own, since those are the hot path the formats build
	on, then times the gzip, zlib, raw deflate, and auto-detecting entry points,
	and finishes on the ZIP reader's walk and extract paths. The large inputs
	come from the benchmark streams in the fixtures, big enough that a decode
	runs long enough to time cleanly, and the format entry points also sweep the
	whole small payload corpus so the timing reflects real variety rather than
	one shape.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local TestProject = ReplicatedStorage:WaitForChild("TestProject")

local DecantModule = Packages:WaitForChild("Decant")
local Decant = require(DecantModule)
local bitstream = require(DecantModule:WaitForChild("bitstream"))
local inflate = require(DecantModule:WaitForChild("inflate"))
local fixtures = require(TestProject:WaitForChild("fixtures"))

local RUNS = 10

-- Every decoded byte flows into this accumulator so the compiler cannot treat a
-- benchmark's work as dead and drop it. Its final value is printed at the end
-- purely to keep it live.
local sink = 0

--[[
	Runs work RUNS times after two untimed warmups and returns the elapsed
	seconds of each run, sorted fastest first. The setup callback runs before
	every attempt outside the timed window, and whatever it returns is handed
	to work, which is how a benchmark that needs fresh state each run can build
	it without paying for it inside the measurement.
]]
local function measure(setup: () -> any, work: (any) -> ()): { number }
	for _ = 1, 2 do
		work(setup())
	end
	local times = table.create(RUNS)
	for runIndex = 1, RUNS do
		local state = setup()
		local startTime = os.clock()
		work(state)
		times[runIndex] = os.clock() - startTime
	end
	table.sort(times)
	return times
end

--[[
	Prints one benchmark's timings and returns the best run in seconds so
	callers can derive throughput and speedup figures from it.
]]
local function summarize(label: string, times: { number }): number
	local total = 0
	for _, elapsed in times do
		total += elapsed
	end
	local best = times[1]
	print(
		string.format(
			"%s: best %.2f ms, mean %.2f ms over %d runs",
			label,
			best * 1000,
			(total / #times) * 1000,
			#times
		)
	)
	return best
end

--[[
	Stands in for a benchmark that needs nothing built before each run.
]]
local function noSetup(): any
	return nil
end

--[[
	Runs one named benchmark end to end. It measures the work, prints the
	timing, and when a byte count is given also prints the throughput that best
	run sustained, which is the figure worth watching on the decode paths. It
	yields afterward so a long line of benchmarks never holds the scheduler long
	enough for Roblox to fault the script for running away.
]]
local function bench(label: string, bytes: number?, setup: () -> any, work: (any) -> ())
	local best = summarize(label, measure(setup, work))
	if bytes then
		print(string.format("    %.1f MB/s at best", (bytes / 1048576) / best))
	end
	task.wait()
end

--[[
	Prints a blank line and a heading so the output reads as grouped sections
	rather than one flat list.
]]
local function section(title: string)
	print("")
	print("== " .. title .. " ==")
end

-- The small payload corpus, each fixture pre-decoded from base64 into the
-- compressed buffers the format entry points read, kept in three parallel
-- arrays so a benchmark can sweep the whole spread in one pass. The variety
-- spans empty and single byte edges, the output buffer growth boundary, highly
-- compressible repetition, multibyte UTF-8, and incompressible noise.
local gzipCorpus = {}
local zlibCorpus = {}
local deflateCorpus = {}
for key in fixtures.payloads do
	table.insert(gzipCorpus, buffer.fromstring(fixtures.gzip[key]))
	table.insert(zlibCorpus, buffer.fromstring(fixtures.zlib[key]))
	table.insert(deflateCorpus, buffer.fromstring(fixtures.deflateStream(key)))
end

-- The large benchmark streams in their gzip, zlib, and raw deflate forms. The
-- prose payload leans on the literal decoding loop and the bulk payload on the
-- match copy loop, so together they cover both halves of the inflate hot path.
local proseGzip = buffer.fromstring(fixtures.benchmarks.prose.gzip)
local proseZlib = buffer.fromstring(fixtures.benchmarks.prose.zlib)
local proseDeflate = buffer.fromstring(fixtures.benchmarkDeflate("prose"))
local proseSize = fixtures.benchmarks.prose.size

local bulkGzip = buffer.fromstring(fixtures.benchmarks.bulk.gzip)
local bulkZlib = buffer.fromstring(fixtures.benchmarks.bulk.zlib)
local bulkDeflate = buffer.fromstring(fixtures.benchmarkDeflate("bulk"))
local bulkSize = fixtures.benchmarks.bulk.size

-- The decoded outputs of the two large streams, held so the CRC-32 benchmark
-- can checksum a real buffer of each size without folding the decode into the
-- timing.
local proseOutput = Decant.deflate.decompress(proseDeflate)
local bulkOutput = Decant.deflate.decompress(bulkDeflate)

-- A couple of archives and the metadata of a packed entry inside one of them, so
-- the ZIP benchmarks can walk a central directory and extract both by path and
-- from metadata.
local mixedArchive = buffer.fromstring(fixtures.archives.mixed.bytes)
local manyArchive = buffer.fromstring(fixtures.archives.many.bytes)

local bigMeta = Decant.zip.iterateFileMetadata(mixedArchive)()
for meta in Decant.zip.iterateFileMetadata(mixedArchive) do
	if meta.path == "big.txt" then
		bigMeta = meta
	end
end

section("inflate core")

bench("inflate.decode bulk (match copy path)", bulkSize, noSetup, function()
	sink += buffer.len(inflate.decode(bitstream.new(bulkDeflate)))
end)

bench("inflate.decode prose (literal decode path)", proseSize, noSetup, function()
	sink += buffer.len(inflate.decode(bitstream.new(proseDeflate)))
end)

section("CRC-32 core")

bench("inflate.crc32 bulk", bulkSize, noSetup, function()
	sink += inflate.crc32(bulkOutput)
end)

bench("inflate.crc32 prose", proseSize, noSetup, function()
	sink += inflate.crc32(proseOutput)
end)

section("gzip")

bench("gz.decompress bulk", bulkSize, noSetup, function()
	sink += buffer.len(Decant.gz.decompress(bulkGzip))
end)

bench("gz.decompress prose", proseSize, noSetup, function()
	sink += buffer.len(Decant.gz.decompress(proseGzip))
end)

bench("gz.decompress corpus (13 payloads)", nil, noSetup, function()
	for _, compressed in gzipCorpus do
		sink += buffer.len(Decant.gz.decompress(compressed))
	end
end)

section("zlib")

bench("zlib.decompress bulk", bulkSize, noSetup, function()
	sink += buffer.len(Decant.zlib.decompress(bulkZlib))
end)

bench("zlib.decompress prose", proseSize, noSetup, function()
	sink += buffer.len(Decant.zlib.decompress(proseZlib))
end)

bench("zlib.decompress corpus (13 payloads)", nil, noSetup, function()
	for _, compressed in zlibCorpus do
		sink += buffer.len(Decant.zlib.decompress(compressed))
	end
end)

section("raw deflate")

bench("deflate.decompress bulk", bulkSize, noSetup, function()
	sink += buffer.len(Decant.deflate.decompress(bulkDeflate))
end)

bench("deflate.decompress prose", proseSize, noSetup, function()
	sink += buffer.len(Decant.deflate.decompress(proseDeflate))
end)

bench("deflate.decompress corpus (13 payloads)", nil, noSetup, function()
	for _, compressed in deflateCorpus do
		sink += buffer.len(Decant.deflate.decompress(compressed))
	end
end)

section("auto-detect dispatch")

bench("decompress gzip corpus (13 payloads)", nil, noSetup, function()
	for _, compressed in gzipCorpus do
		sink += buffer.len(Decant.decompress(compressed))
	end
end)

bench("decompress zlib corpus (13 payloads)", nil, noSetup, function()
	for _, compressed in zlibCorpus do
		sink += buffer.len(Decant.decompress(compressed))
	end
end)

section("ZIP archive")

-- The central directory walk touches no payload, so one pass is too quick to
-- time on its own and the benchmark repeats it to land in a readable range.
bench("zip.iterateFileMetadata many (100 walks of 24 entries)", nil, noSetup, function()
	for _ = 1, 100 do
		for meta in Decant.zip.iterateFileMetadata(manyArchive) do
			sink += meta.size
		end
	end
end)

bench("zip.iterateFiles mixed (5 entries, one large)", nil, noSetup, function()
	for _, content in Decant.zip.iterateFiles(mixedArchive) do
		sink += buffer.len(content)
	end
end)

-- The many archive holds two dozen tiny entries, so like the metadata walk it
-- repeats to be worth timing.
bench("zip.iterateFiles many (20 passes of 24 entries)", nil, noSetup, function()
	for _ = 1, 20 do
		for _, content in Decant.zip.iterateFiles(manyArchive) do
			sink += buffer.len(content)
		end
	end
end)

bench("zip.extractFile mixed big.txt (walk then inflate)", nil, noSetup, function()
	local content = Decant.zip.extractFile(mixedArchive, "big.txt")
	if content then
		sink += buffer.len(content)
	end
end)

bench("zip.extractAt mixed big.txt (inflate from metadata)", nil, noSetup, function()
	sink += buffer.len(Decant.zip.extractAt(mixedArchive, bigMeta))
end)

print("")
print("checksum sink: " .. sink)

-- run-in-roblox can drop log output that is still queued when the place
-- closes, so give it a moment to drain before returning.
task.wait(2)

return nil
