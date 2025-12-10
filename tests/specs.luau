--!strict
local Runner = require("test_runner")
local QueryBuilder = require("../src/init")
local define = QueryBuilder.define

local d: any = Runner.Describe
local it: any = Runner.Test
local expect: any = Runner.Expect

return function()
	d("QueryBuilder Properties", function()
		it("should handle basic property equality", function()
			local q = QueryBuilder.fromOperation(function(x)
				return x.ClassName == define("Model")
			end):ToQuery()
			expect(q).ToEqual("Model")
		end)

		it("should handle define() wrapper", function()
			local q = QueryBuilder.fromOperation(function(x)
				return x.Name == define("Part")
			end):ToQuery()
			expect(q).ToEqual("#Part")
		end)

        it("should handle numeric properties", function()
            -- Numeric prop isn't mapped to Class/Name/Id helper, but standard [Prop=Val]
            local q = QueryBuilder.fromOperation(function(x)
                return x.Transparency == define(1)
            end):ToQuery()
            expect(q).ToContain("[Transparency = 1]")
        end)
	end)

    d("QueryBuilder Attributes", function()
        it("should handle GetAttribute", function()
             local q = QueryBuilder.fromOperation(function(x)
                 return x:GetAttribute("MyKey") == define("MyVal")
             end):ToQuery()
             expect(q).ToEqual("[$MyKey = \"MyVal\"]")
        end)

        it("should handle GetAttribute with define", function()
             local q = QueryBuilder.fromOperation(function(x)
                 return x:GetAttribute("Level") == define(5)
             end):ToQuery()
             expect(q).ToEqual("[$Level = 5]")
        end)
        
        it("should handle HasAttribute (Explicit builder syntax)", function()
            local q = QueryBuilder.new()
                :HasAttribute("MyCheck")
                :ToQuery()
            expect(q).ToEqual("[$MyCheck]")
        end)
        
        it("should handle HasAttribute via define()", function()
             local q = QueryBuilder.fromOperation(function(x)
                 return x:GetAttribute("Exists") ~= define(nil)
             end):ToQuery()
             expect(q).ToEqual("[$Exists]")
        end)
    end)

    d("QueryBuilder Children", function()
        it("should handle FindFirstChild (Recursive=false)", function()
            local q = QueryBuilder.fromOperation(function(x)
                return x:FindFirstChild("ChildName")
            end):ToQuery()
            -- :has(> #ChildName)
            expect(q).ToContain(":has(> #ChildName)")
        end)

        it("should handle FindFirstChild (Recursive=true)", function()
             local q = QueryBuilder.fromOperation(function(x)
                return x:FindFirstChild("DescendantName", true)
            end):ToQuery()
            -- :has(>> #DescendantName)
            expect(q).ToContain(":has(#DescendantName)")
        end)

         it("should handle FindFirstChildWhichIsA", function()
             local q = QueryBuilder.fromOperation(function(x)
                return x:FindFirstChildWhichIsA("Part")
            end):ToQuery()
            -- :has(> Part)
            expect(q).ToContain(":has(> Part)")
        end)
        
        it("should handle nested attributes", function()
            local q = QueryBuilder.fromOperation(function(x)
                local child = x:FindFirstChild("ChildName")
                return child:GetAttribute("Test") == define(true)
            end):ToQuery()
            -- :has(> #ChildName[$Test = true])
            expect(q).ToContain(":has(> #ChildName[$Test = true])")
        end)

        it("should handle nested properties", function()
             local q = QueryBuilder.fromOperation(function(x)
                 local child = x:FindFirstChild("ChildName")
                 return child.Transparency == define(0.5)
             end):ToQuery()
             -- :has(> #ChildName[Transparency = 0.5])
             expect(q).ToContain(":has(> #ChildName[Transparency = 0.5])")
        end)
        
        it("should handle recursive nested checks", function()
             local q = QueryBuilder.fromOperation(function(x)
                 local child = x:FindFirstChild("DescendantName", true)
                 return child:GetAttribute("Active") == define(true) and child.Name == define("Target")
             end):ToQuery()
             -- :has(#DescendantName[Name = "Target"][$Active = true])
             expect(q).ToContain(":has(#DescendantName[Name = \"Target\"][$Active = true])")
        end)

        it("should handle nested negation", function()
             local q = QueryBuilder.fromOperation(function(x)
                 local child = x:FindFirstChild("ChildName")
                 return child.Transparency ~= define(1)
             end):ToQuery()
             -- :has(> #ChildName:not([Transparency = 1]))
             expect(q).ToContain(":has(> #ChildName:not([Transparency = 1]))")
        end)
    end)

    d("QueryBuilder Tags", function()
        it("should handle table.find(Tags)", function()
            local q = QueryBuilder.fromOperation(function(x)
                return table.find(x.Tags, "MyTag")
            end):ToQuery()
            expect(q).ToContain(".MyTag")
        end)
    end)
    
    d("QueryBuilder Negation", function()
         it("should handle negation", function()
            local q = QueryBuilder.fromOperation(function(x)
                return x.Name ~= define("Bad")
            end):ToQuery()
            -- :not(#Bad)
            expect(q).ToContain(":not(#Bad)")
         end)
    end)

    d("QueryBuilder Complex Queries", function()
        it("should handle complex queries", function()
            local q = QueryBuilder.fromOperation(function(x)
                local Prompt = x:FindFirstChildWhichIsA("ProximityPrompt", true)
                if Prompt and Prompt.Name == define("Interaction") then
                    return x.Name == define("InteractablePart")
                end

                return x.Name == define("Part")
            end):ToQuery()
            expect(q).ToContain("#Part")
            expect(q).ToContain("#InteractablePart")
        end)
    end)

    d("QueryBuilder Stress Tests", function()
        -- 1. Complex :has (Combinators inside has)
        it("should handle complex :has with nested properties", function()
             -- :has(> Method.Red[Enabled = true])
             local q = QueryBuilder.fromOperation(function(x)
                 local child = x:FindFirstChildWhichIsA("Model")
                 return table.find(child.Tags, "Red") and child.Name == define("Target")
             end):ToQuery()
             
             
             -- Expected: :has(> Model.Red[Name = "Target"])
             expect(q).ToContain(":has(> Model")
             expect(q).ToContain(".Red") 
             expect(q).ToContain("Name = \"Target\"")
        end)

        -- 2. Complex :not (Nested)
        it("should handle complex :not selectors", function()
             -- :not(:has(> #BadChild))
             local q = QueryBuilder.fromOperation(function(x)
                 return not x:FindFirstChild("BadChild")
             end):ToQuery()
             
             expect(q).ToContain(":not(:has(> #BadChild))")
        end)
        
        -- 3. Mixed Combinators (OR with paths)
        it("should handle mixed combinators and paths", function()
             -- #HumanoidRootPart:has(> BodyMover), #Torso:has(> BodyMover)
             -- This is the repro case, ensuring it stays fixed.
             local q = QueryBuilder.fromOperation(function(x)
                local BodyMover = x:FindFirstChildOfClass("BodyMover")
                if not BodyMover then return false end
                
                return x.Name == define("HumanoidRootPart") or x.Name == define("Torso")
             end):ToQuery()
             
             expect(q).ToContain("#HumanoidRootPart:has(> BodyMover)")
             expect(q).ToContain("#Torso:has(> BodyMover)")
        end)
        
        -- 4. Deep Nesting
        it("should handle deep nesting", function()
            local q = QueryBuilder.fromOperation(function(x)
                local l1 = x:FindFirstChild("L1")
                local l2 = l1:FindFirstChild("L2")
                local l3 = l2:FindFirstChild("L3")
                return l3.Name == define("Final")
            end):ToQuery()
            
            -- :has(> #L1:has(> #L2:has(> #L3[Name = "Final"])))
            expect(q).ToContain("#L1")
            expect(q).ToContain("#L2")
            expect(q).ToContain("#L3")
            expect(q).ToContain("Name = \"Final\"")
        end)

        -- 5. Control flow attributes
        it("should handle control flow with attribute checks", function()
            local q = QueryBuilder.fromOperation(function(x)
                if x:GetAttribute("MyAttribute") ~= define(nil) then
                    return x.Name == define("Target")
                end

                return x.Name == define("NotTarget")
            end):ToQuery()
            
            expect(q).ToContain("[$MyAttribute]")
            expect(q).ToContain("#Target")
            expect(q).ToContain("#NotTarget")
        end)
    end)
end
