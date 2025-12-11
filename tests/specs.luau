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
                 return child:GetAttribute("Active") == define(true) and child.ClassName == define("Part")
             end):ToQuery()
             -- :has(Part#DescendantName[$Active = true])
             expect(q).ToContain(":has(Part#DescendantName")
             expect(q).ToContain("[$Active = true]")
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
             
             
             -- Expected: :has(> Model.Red#Target)
             expect(q).ToContain(":has(> Model")
             expect(q).ToContain(".Red") 
             expect(q).ToContain("#Target")
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
                return l3.Transparency == define(1)
            end):ToQuery()
            
            -- :has(> #L1:has(> #L2:has(> #L3[Transparency = 1])))
            expect(q).ToContain("#L1")
            expect(q).ToContain("#L2")
            expect(q).ToContain("#L3")
            expect(q).ToContain("Transparency = 1")
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
        
        -- 6. Scoped Attribute Existence
        it("should handle scoped attribute existence with control flow", function()
             -- Case from issue report: 8282 if Sigma=nil, 67777 if broo!=nil
             local q = QueryBuilder.fromOperation(function(descendant)
                local BodyMover = descendant:FindFirstChildOfClass("BodyMover")
                if BodyMover then
                    if BodyMover:GetAttribute("Sigma") == define(nil) then
                        return descendant.Name == define("8282")
                    elseif BodyMover:GetAttribute("broo") ~= define(nil) then
                        return descendant.Name == define("67777")
                    end
                end
                return false
            end):ToQuery()
            
            -- Expect 67777 to have [$broo] and (likely) [$Sigma] (implied by elseif)
            expect(q).ToContain("#67777")
            expect(q).ToContain(":has(> BodyMover")
            expect(q).ToContain("[$broo]")
        end)

        -- 7. Very Deep Nesting (4+ levels)
        it("should handle very deep nesting (4+ levels)", function()
            local q = QueryBuilder.fromOperation(function(x)
                local a = x:FindFirstChild("LevelA")
                local b = a:FindFirstChild("LevelB")
                local c = b:FindFirstChild("LevelC")
                local d = c:FindFirstChild("LevelD")
                return d.ClassName == define("Part")
            end):ToQuery()
            
            expect(q).ToContain("#LevelA")
            expect(q).ToContain("#LevelB")
            expect(q).ToContain("#LevelC")
            expect(q).ToContain("#LevelD")
            expect(q).ToContain("Part")
        end)

        -- 8. Multiple :has selectors at same level
        it("should handle multiple :has selectors at same level", function()
            local q = QueryBuilder.fromOperation(function(x)
                local child1 = x:FindFirstChild("ChildA")
                local child2 = x:FindFirstChild("ChildB")
                return child1 and child2
            end):ToQuery()
            
            expect(q).ToContain(":has(> #ChildA)")
            expect(q).ToContain(":has(> #ChildB)")
        end)

        -- 9. Mixed recursive and non-recursive child queries
        it("should handle mixed recursive and non-recursive child queries", function()
            local q = QueryBuilder.fromOperation(function(x)
                local directChild = x:FindFirstChild("DirectChild")
                local deepChild = x:FindFirstChild("DeepChild", true)
                return directChild and deepChild
            end):ToQuery()
            
            expect(q).ToContain(":has(> #DirectChild)")
            expect(q).ToContain(":has(#DeepChild)")
        end)

        -- 10. Complex property + attribute + tag combination
        it("should handle complex property + attribute + tag combination", function()
            local q = QueryBuilder.fromOperation(function(x)
                return x.ClassName == define("Model")
                    and x.Name == define("Vehicle")
                    and table.find(x.Tags, "Driveable")
                    and x:GetAttribute("Speed") == define(100)
                    and x.Transparency == define(0)
            end):ToQuery()
            
            expect(q).ToContain("Model")
            expect(q).ToContain("#Vehicle")
            expect(q).ToContain(".Driveable")
            expect(q).ToContain("[$Speed = 100]")
            expect(q).ToContain("[Transparency = 0]")
        end)

        -- 11. Nested :has with properties on nested child
        it("should handle nested :has with multiple properties on nested child", function()
            local q = QueryBuilder.fromOperation(function(x)
                local container = x:FindFirstChild("Container")
                local item = container:FindFirstChild("Item")
                return item.Transparency == define(0.5)
                    and item:GetAttribute("Active") == define(true)
                    and table.find(item.Tags, "Interactable")
            end):ToQuery()
            
            expect(q).ToContain("#Container")
            expect(q).ToContain("#Item")
            expect(q).ToContain("[Transparency = 0.5]")
            expect(q).ToContain("[$Active = true]")
            expect(q).ToContain(".Interactable")
        end)

        -- 12. :not with multiple conditions
        it("should handle :not with multiple conditions", function()
            local q = QueryBuilder.fromOperation(function(x)
                return x.Name ~= define("Ignored")
                    and x.ClassName ~= define("Script")
            end):ToQuery()
            
            expect(q).ToContain(":not(#Ignored)")
            expect(q).ToContain(":not(Script)")
        end)

        -- 13. Deeply nested with negation at leaf
        it("should handle deeply nested with negation at leaf", function()
            local q = QueryBuilder.fromOperation(function(x)
                local a = x:FindFirstChild("Parent")
                local b = a:FindFirstChild("Child")
                return b.Name ~= define("Excluded")
            end):ToQuery()
            
            expect(q).ToContain("#Parent")
            expect(q).ToContain("#Child")
            expect(q).ToContain(":not")
            expect(q).ToContain("Excluded")
        end)

        -- 14. Multiple OR branches with different :has requirements
        it("should handle multiple OR branches with different :has requirements", function()
            local q = QueryBuilder.fromOperation(function(x)
                local tool = x:FindFirstChildWhichIsA("Tool")
                if tool then
                    return x.Name == define("ToolHolder")
                end
                
                local humanoid = x:FindFirstChildWhichIsA("Humanoid")
                if humanoid then
                    return x.Name == define("Character")
                end
                
                return x.Name == define("Default")
            end):ToQuery()
            
            expect(q).ToContain("#ToolHolder")
            expect(q).ToContain("#Character")
            expect(q).ToContain("#Default")
        end)

        -- 15. Attribute existence check combined with value check
        it("should handle attribute existence combined with value checks", function()
            local q = QueryBuilder.fromOperation(function(x)
                return x:GetAttribute("Level") ~= define(nil)
                    and x:GetAttribute("Score") == define(100)
            end):ToQuery()
            
            expect(q).ToContain("[$Level]")
            expect(q).ToContain("[$Score = 100]")
        end)

        -- 16. FindFirstChildOfClass with nested property checks
        it("should handle FindFirstChildOfClass with nested property checks", function()
            local q = QueryBuilder.fromOperation(function(x)
                local light = x:FindFirstChildOfClass("SpotLight")
                return light.Brightness == define(5) and light.Enabled == define(true)
            end):ToQuery()
            
            expect(q).ToContain(":has(> SpotLight")
            expect(q).ToContain("[Brightness = 5]")
            expect(q).ToContain("[Enabled = true]")
        end)

        -- 17. Triple-nested :has with class constraints
        it("should handle triple-nested :has with class constraints", function()
            local q = QueryBuilder.fromOperation(function(x)
                local model = x:FindFirstChildWhichIsA("Model")
                local part = model:FindFirstChildWhichIsA("Part")
                local attachment = part:FindFirstChildWhichIsA("Attachment")
                return attachment.Name == define("Center")
            end):ToQuery()
            
            expect(q).ToContain("Model")
            expect(q).ToContain("Part")
            expect(q).ToContain("Attachment")
            expect(q).ToContain("#Center")
        end)

        -- 18. Complex branching with nested attribute checks
        it("should handle complex branching with nested attribute checks", function()
            local q = QueryBuilder.fromOperation(function(x)
                local config = x:FindFirstChild("Config")
                if config then
                    if config:GetAttribute("Enabled") == define(true) then
                        return x.Name == define("ActiveItem")
                    else
                        return x.Name == define("DisabledItem")
                    end
                end
                return false
            end):ToQuery()
            
            expect(q).ToContain("#ActiveItem")
            expect(q).ToContain("#DisabledItem")
            expect(q).ToContain("#Config")
        end)

        -- 19. Multiple tags check
        it("should handle multiple tags check", function()
            local q = QueryBuilder.fromOperation(function(x)
                return table.find(x.Tags, "TagA")
                    and table.find(x.Tags, "TagB")
                    and table.find(x.Tags, "TagC")
            end):ToQuery()
            
            expect(q).ToContain(".TagA")
            expect(q).ToContain(".TagB")
            expect(q).ToContain(".TagC")
        end)

        -- 20. Negated tag with positive attributes
        it("should handle negated conditions mixed with positive ones", function()
            local q = QueryBuilder.fromOperation(function(x)
                return x.ClassName == define("BasePart")
                    and x.Name ~= define("Baseplate")
                    and x.Transparency ~= define(1)
            end):ToQuery()
            
            expect(q).ToContain("BasePart")
            expect(q).ToContain(":not(#Baseplate)")
            expect(q).ToContain(":not([Transparency = 1])")
        end)

        -- 21. Boolean property values
        it("should handle boolean property values correctly", function()
            local q = QueryBuilder.fromOperation(function(x)
                return x.CanCollide == define(false)
                    and x.Anchored == define(true)
                    and x.CastShadow == define(false)
            end):ToQuery()
            
            expect(q).ToContain("[CanCollide = false]")
            expect(q).ToContain("[Anchored = true]")
            expect(q).ToContain("[CastShadow = false]")
        end)

        -- 22. String with spaces in attribute value
        it("should handle string with spaces in attribute value", function()
            local q = QueryBuilder.fromOperation(function(x)
                return x:GetAttribute("DisplayName") == define("Hello World")
            end):ToQuery()
            
            expect(q).ToContain("[$DisplayName = \"Hello World\"]")
        end)

        -- 23. Deeply nested with mixed FindFirst methods
        it("should handle deeply nested with mixed FindFirst methods", function()
            local q = QueryBuilder.fromOperation(function(x)
                local folder = x:FindFirstChild("Data")
                local model = folder:FindFirstChildWhichIsA("Model")
                local config = model:FindFirstChild("Settings", true)
                return config:GetAttribute("Version") == define(2)
            end):ToQuery()
            
            expect(q).ToContain("#Data")
            expect(q).ToContain("Model")
            expect(q).ToContain("#Settings")
            expect(q).ToContain("[$Version = 2]")
        end)

        -- 24. Extremely deep nesting (5 levels)
        it("should handle extremely deep nesting (5 levels)", function()
            local q = QueryBuilder.fromOperation(function(x)
                local l1 = x:FindFirstChild("L1")
                local l2 = l1:FindFirstChild("L2")
                local l3 = l2:FindFirstChild("L3")
                local l4 = l3:FindFirstChild("L4")
                local l5 = l4:FindFirstChild("L5")
                return l5:GetAttribute("Found") == define(true)
            end):ToQuery()
            
            expect(q).ToContain("#L1")
            expect(q).ToContain("#L2")
            expect(q).ToContain("#L3")
            expect(q).ToContain("#L4")
            expect(q).ToContain("#L5")
            expect(q).ToContain("[$Found = true]")
        end)

        -- 25. Parallel children with different constraints
        it("should handle parallel children with different constraints", function()
            local q = QueryBuilder.fromOperation(function(x)
                local partA = x:FindFirstChild("PartA")
                local partB = x:FindFirstChild("PartB")
                return partA.Transparency == define(0) and partB.Transparency == define(1)
            end):ToQuery()
            
            expect(q).ToContain("#PartA")
            expect(q).ToContain("#PartB")
            expect(q).ToContain("[Transparency = 0]")
            expect(q).ToContain("[Transparency = 1]")
        end)

        -- 26. Yielding inside callback
        it("should disallow yielding inside callback", function()
             local success, err = pcall(function()
                 QueryBuilder.fromOperation(function(x)
                     coroutine.yield()
                     return true
                 end):ToQuery()
             end)
             
             expect(success).ToEqual(false)
             expect(err).ToContain("Unsatisfiable")
             expect(err).ToContain("Yielding (coroutine.yield or task.wait/wait) is not allowed")
        end)

        -- 27. IsA check
        it("should handle IsA check", function()
             local q = QueryBuilder.fromOperation(function(x)
                 return x:IsA("Part")
             end):ToQuery()
             expect(q).ToEqual("Part")
        end)
    end)
end
