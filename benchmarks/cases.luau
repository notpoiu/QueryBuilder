--!strict
local QueryBuilder = require("../src/init")
local define = QueryBuilder.define

local cases = {}

-- 1. Direct API Creation
-- Measures the cost of creating a builder and chaining methods manually.
function cases.DirectAPI_Builder()
    QueryBuilder.new()
        :SetClass("Part")
        :SetName("MyPart")
        :SetProperty("Transparency", 0.5)
        :Child(
            QueryBuilder.new():SetClass("Decal"):SetAttribute("Active", true)
        )
        :ToQuery()
end

-- 2. Simple Reflection
-- Measures the overhead of the reflection proxy for basic properties.
function cases.Reflection_Simple()
    QueryBuilder.fromOperation(function(x)
        return x.ClassName == define("Part")
           and x.Name == define("MyPart")
           and x.Transparency == define(0.5)
    end):ToQuery()
end

-- 3. Complex Reflection: Deep Recursion
-- Measures handling of deep nesting
function cases.Reflection_DeepRecursion()
    QueryBuilder.fromOperation(function(x)
        local l1 = x:FindFirstChild("Level1")
        local l2 = l1:FindFirstChild("Level2")
        local l3 = l2:FindFirstChild("Level3")
        local l4 = l3:FindFirstChild("Level4")
        local l5 = l4:FindFirstChild("Level5")
        return l5.Name == define("Target")
    end):ToQuery()
end

-- 4. Complex Reflection: Branching Logic
-- Measures multiple execution paths (concolic execution overhead).
function cases.Reflection_ComplexBranching()
    QueryBuilder.fromOperation(function(x)
        local root = x:FindFirstChild("Root")
        if root then
            local typeAttr = root:GetAttribute("Type")
            if typeAttr == define("A") then
                return x.Name == define("TypeA_Container")
            elseif typeAttr == define("B") then
                return x.Name == define("TypeB_Container")
            else
                return x.Name == define("Generic_Container")
            end
        end
        return false
    end):ToQuery()
end

-- 5. Define Overhead
-- Measures just the cost of wrapped values.
function cases.Define_Overhead()
    define("string")
    define(123)
    define(true)
    define(nil)
end

return cases
