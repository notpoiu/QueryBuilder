--!strict
local TestRunner = {}

local stdio = require("@lune/stdio")

local function Color(code: string, text: string)
	return stdio.color(code :: any) .. text .. stdio.color("reset")
end

local function Green(text: string) return Color("green", text) end
local function Red(text: string) return Color("red", text) end
local function Blue(text: string) return Color("blue", text) end

type Stats = {
	Passed: number,
	Failed: number,
}

local currentStats: Stats = { Passed = 0, Failed = 0 }

function TestRunner.Describe(name: string, callback: () -> ())
	print(Blue("\n" .. name))
	callback()
end

function TestRunner.Test(name: string, callback: () -> ())
	local success, err = pcall(callback)
	if success then
		currentStats.Passed += 1
		print(Green("  [PASS] ") .. name)
	else
		currentStats.Failed += 1
		print(Red("  [FAIL] ") .. name)
		print(Red("    " .. tostring(err)))
	end
end

function TestRunner.Expect(value: any)
	return {
		ToEqual = function(expected: any)
			assert(value == expected, string.format("Expected %q to equal %q", tostring(value), tostring(expected)))
		end,
		ToContain = function(substring: string)
			assert(string.find(tostring(value), substring, 1, true), string.format("Expected %q to contain %q", tostring(value), substring))
		end,
	}
end

function TestRunner.PrintSummary()
	print("\n" .. string.rep("-", 20))
	print(string.format("Passed: %d", currentStats.Passed))
	print(string.format("Failed: %d", currentStats.Failed))
	if currentStats.Failed > 0 then
		error("Tests failed!")
	end
end

return TestRunner
