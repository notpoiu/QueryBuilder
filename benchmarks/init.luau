--!strict
local stdio = require("@lune/stdio")
local process = require("@lune/process")

local function Color(code: string, text: string)
	return stdio.color(code :: any) .. text .. stdio.color("reset")
end

local function Green(text: string) return Color("green", text) end
local function Cyan(text: string) return Color("cyan", text) end
local function Red(text: string) return Color("red", text) end
local function Yellow(text: string) return Color("yellow", text) end

local DEFAULT_TIME = 1 -- seconds to run each benchmark

local function formatNumber(n: number): string
    local s = string.format("%.2f", n)
    -- Add commas
    local i, j, minus, int, frac = string.find(s, "([-]?)(%d+)([.]?%d*)")
    int = string.gsub(int, "(%d)(%d%d%d)$", "%1,%2")
    return minus .. int .. frac
end

local function runBenchmark(name: string, fn: () -> ())
    print(Cyan("\nRunning benchmark: " .. name))
    
    -- Warmup
    -- Run for at least 100ms or 100 iterations
    local warmupStart = os.clock()
    local warmupCount = 0
    while os.clock() - warmupStart < 0.1 do
        fn()
        warmupCount += 1
    end
    
    -- Force GC before actual run to reduce noise
    for _ = 1, 3 do
        local a = {}
        for i = 1, 1000 do a[i] = i end
    end
    collectgarbage("collect")
    
    local startTime = os.clock()
    local count = 0
    local elapsed = 0
    
    -- Main loop
    while elapsed < DEFAULT_TIME do
        -- Unroll slightly
        fn(); fn(); fn(); fn(); fn()
        fn(); fn(); fn(); fn(); fn()
        
        count += 10
        elapsed = os.clock() - startTime
    end
    
    local opsPerSec = count / elapsed
    local avgTimeUs = (elapsed / count) * 1_000_000
    
    print(string.format("  Iterations: %d", count))
    print(string.format("  Total Time: %.4fs", elapsed))
    print(Green(string.format("  Ops/Sec:    %s", formatNumber(opsPerSec))))
    print(Yellow(string.format("  Avg Time:   %.4f μs", avgTimeUs)))
end

-- Load cases
local cases = require("./cases")

print(string.format("Starting benchmarks... (Target time: %ds per case)", DEFAULT_TIME))

for name, fn in pairs(cases) do
    local success, err = pcall(function()
        runBenchmark(name, fn)
    end)
    
    if not success then
        print(Red("  FAILED: " .. tostring(err)))
    end
end
