--[[

    Reflector

    Shared Metatable Logic for "Tokens" (Proxies/Wrappers).

]]

--!nonstrict
local Reflector = {}

local TokenMeta = {}
local TraceRecorder = nil -- Temporarily holds the current recorder function during trace

function TokenMeta.__eq(a, b)
    if TraceRecorder then
        return TraceRecorder(a, b)
    end
    
    return Reflector.Compare(a, b)
end

-- Map Proxy -> Data
local TokenData = setmetatable({}, {__mode = "k"})

local function CreateToken(data)
    local proxy = newproxy(true)
    local mt = getmetatable(proxy)
    mt.__index = function(_, k)
        -- Handle nested access if necessary (e.g. Tags)
        if k == "Tags" then
            return CreateToken({ Type = "Tags", Source = data })
        end
        
        -- Proxy method support
        if data.Methods and data.Methods[k] then
            return data.Methods[k]
        end
        
        -- If accessing a property on a "Descendant" token
        if data.Type == "Descendant" then
            return CreateToken({ Type = "Prop", Key = k })
        end
        
        -- If accessing a property on a "ChildScope" token
        if data.Type == "ChildScope" then
            if k == "GetAttribute" then
                return function(_, attrKey)
                     return CreateToken({ Type = "ScopedAttribute", ScopeKey = data.ScopeKey, Key = attrKey })
                end
            end
            return CreateToken({ Type = "ScopedProp", ScopeKey = data.ScopeKey, Key = k })
        end
        
        return nil
    end
    
    mt.__eq = TokenMeta.__eq
    mt.__tostring = function() return "Token(" .. tostring(data.Type) .. ":" .. tostring(data.Key or data.Val) .. ")" end
    
    TokenData[proxy] = data
    return proxy
end

function Reflector.Compare(a, b)
    local da = TokenData[a]
    local db = TokenData[b]
    
    if not da or not db then return a == b end
    
    -- Simple equality check for Value types
    if da.Type == "Val" and db.Type == "Val" then
        return da.Val == db.Val
    end
    
    local valA
    if da.Type == "Val" then valA = da.Val else valA = da.SimulatedVal end
    
    local valB
    if db.Type == "Val" then valB = db.Val else valB = db.SimulatedVal end

    if valA == Reflector.NIL_SENTINEL then valA = nil end
    if valB == Reflector.NIL_SENTINEL then valB = nil end
    
    -- Existence Sentinel Wildcard Logic
    if (da.Origin == "Define" and da.Val == Reflector.EXISTENCE_SENTINEL) or
       (db.Origin == "Define" and db.Val == Reflector.EXISTENCE_SENTINEL) then
       return true
    end
    
    return valA == valB
end



-- Exposed Value Wrapper
Reflector.EXISTENCE_SENTINEL = newproxy(true)
getmetatable(Reflector.EXISTENCE_SENTINEL).__tostring = function() return "EXISTENCE_SENTINEL" end

Reflector.NIL_SENTINEL = newproxy(true)
getmetatable(Reflector.NIL_SENTINEL).__tostring = function() return "NIL_SENTINEL" end

-- Exposed Value Wrapper
function Reflector.Define(...)
    local n = select('#', ...)
    if n == 0 then
        return CreateToken({ Type = "Val", Val = Reflector.EXISTENCE_SENTINEL, Origin = "Define" })
    end
    local val = ...
    return CreateToken({ Type = "Val", Val = val, Origin = "Define" })
end

-- Helper to canonicalize Child Key
local function ChildKey(mode, val, rec)
    return string.format("Child_%s_%s_%s", mode, tostring(val), tostring(rec))
end

local function ScopedKey(scope, type, key)
    return scope .. "::" .. type .. "_" .. key
end



function Reflector.Parse(callback)
    local allResults = {}
    
    -- Queue of paths to explore.
    -- Each path is list of booleans representing decisions made at each choice point.
    -- { History = {true, false, ...}, Index = 1 }
    local executionQueue = { { History = {}, Index = 1 } }
    
    local seenResults = {}
    
    local iterations = 0
    local MAX_ITERATIONS = 50 -- Safety break

    while #executionQueue > 0 and iterations < MAX_ITERATIONS do
        iterations += 1
        local currentTrace = table.remove(executionQueue, 1)
        local traceIndex = 1

        
        local constraints = {}
        local discoveredChildren = {}
        
        -- 1. TRACE PHASE
        TraceRecorder = function(a, b)
            local da = TokenData[a]
            local db = TokenData[b]
            
            if not da then da = { Type = "Val", Val = a } end
            if not db then db = { Type = "Val", Val = b } end
            
            -- Identify which is the Prop and which is the Val
            local prop, val
            if da.Type == "Prop" or da.Type == "Attribute" or da.Type == "ScopedProp" or da.Type == "ScopedAttribute" then prop = da; val = db 
            elseif db.Type == "Prop" or db.Type == "Attribute" or db.Type == "ScopedProp" or db.Type == "ScopedAttribute" then prop = db; val = da end
            
            -- Only record decision for Prop/Val comparison
            if prop and val and val.Type == "Val" then
                -- Check history
                local decision = true
                
                if traceIndex <= #currentTrace.History then
                    -- Replay history
                    decision = currentTrace.History[traceIndex]
                    traceIndex += 1
                else
                    -- New frontier! Default true, but queue false branch
                    
                    decision = true
                    
                    -- Queue the "False" path
                    local newHistory = {table.unpack(currentTrace.History)}
                    table.insert(newHistory, false)
                    table.insert(executionQueue, { History = newHistory })
                    
                    -- Update the CURRENT history so subsequent calls in THIS execution know.
                     table.insert(currentTrace.History, true)
                     traceIndex += 1
                end

                if decision then
                    -- Record Constraint
                    if prop.Type == "ScopedProp" or prop.Type == "ScopedAttribute" then
                        table.insert(constraints, { Type = prop.Type, ScopeKey = prop.ScopeKey, Key = prop.Key, Val = val.Val })
                    else
                        table.insert(constraints, { Type = prop.Type, Key = prop.Key, Val = val.Val })
                    end
                    return true 
                else
                    -- If we chose false, we still record the constraint so the Solver knows this Property is relevant!
                    -- The User Code `~=` will enforce the logic.
                    if prop.Type == "ScopedProp" or prop.Type == "ScopedAttribute" then
                        table.insert(constraints, { Type = prop.Type, ScopeKey = prop.ScopeKey, Key = prop.Key, Val = val.Val, Negate = true })
                    else
                        table.insert(constraints, { Type = prop.Type, Key = prop.Key, Val = val.Val, Negate = true })
                    end
                    return false
                end
            end
            
            -- Non-traceable comparison (e.g. constant vs constant), just do it
            return Reflector.Compare(a, b)
        end
        
        local function GetChildInterceptor(parentScope)
            local function TraceChildInterceptor(mode)
                return function(_, target, recursive)
                    local actualTarget = (type(target) == "userdata" and TokenData[target]) and TokenData[target].Val or target
                    local rec = recursive == true
                    local ck = ChildKey(mode, actualTarget, rec)
                    
                    local key = ck
                    if parentScope then
                        -- Use ScopedKey component to match Solver/Verify expectations
                        -- ck is "Child_..."
                        key = ScopedKey(parentScope, "Child", ck)
                    end
                    
                    -- Decision: Does this child exist?
                    local decision = true
                    
                    if traceIndex <= #currentTrace.History then
                        decision = currentTrace.History[traceIndex]
                        traceIndex += 1
                    else
                         -- Frontier
                         decision = true
                         
                         -- Queue the "False" path (Child does NOT exist)
                        local newHistory = {table.unpack(currentTrace.History)}
                        table.insert(newHistory, false)
                        table.insert(executionQueue, { History = newHistory })
                        
                        table.insert(currentTrace.History, true)
                        traceIndex += 1
                    end
                    
                    if not decision then
                        -- Child doesn't exist
                        if parentScope then
                            table.insert(constraints, { Type = "ScopedChild", ScopeKey = parentScope, Key = ck, Mode = mode, Target = actualTarget, Recursive = rec, ForcedNil = true })
                        else
                            table.insert(constraints, { Type = "Child", Mode = mode, Target = actualTarget, Recursive = rec, ForcedNil = true })
                        end
                        return nil
                    end
                    
                    discoveredChildren[key] = true
                    
                    if parentScope then
                         table.insert(constraints, { Type = "ScopedChild", ScopeKey = parentScope, Key = ck, Mode = mode, Target = actualTarget, Recursive = rec })
                    else
                        table.insert(constraints, { Type = "Child", Mode = mode, Target = actualTarget, Recursive = rec })
                    end
                    
                    return CreateToken({ 
                        Type = "ChildScope", 
                        ScopeKey = key,
                        Methods = {
                             FindFirstChild = GetChildInterceptor(key)("Name"),
                             FindFirstChildWhichIsA = GetChildInterceptor(key)("Class"),
                             FindFirstChildOfClass = GetChildInterceptor(key)("Class"),
                             GetAttribute = function(_, attrKey)
                                 return CreateToken({ Type = "ScopedAttribute", ScopeKey = key, Key = attrKey })
                             end
                        }
                    })
                end
            end
            return TraceChildInterceptor
        end
    
        local traceDescendant = CreateToken({ 
            Type = "Descendant", 
            Methods = {
                FindFirstChild = GetChildInterceptor(nil)("Name"),
                FindFirstChildWhichIsA = GetChildInterceptor(nil)("Class"),
                FindFirstChildOfClass = GetChildInterceptor(nil)("Class"),
                GetAttribute = function(_, key)
                    -- Return a token representing the value of this attribute
                    return CreateToken({ Type = "Attribute", Key = key })
                end
            } 
        })
        
        -- Environment Injection
        local originalEnv = getfenv(callback)
        local traceEnv = setmetatable({}, {
            __index = function(_, k)
                if k == "table" then
                    return setmetatable({
                        find = function(t, v)
                            local d = TokenData[t]
                            if d and d.Type == "Tags" then
                               local actualVal = v
                               if type(v) == "userdata" and TokenData[v] then
                                   actualVal = TokenData[v].Val
                               end
                               
                               if d.Source and d.Source.Type == "ChildScope" then
                                     table.insert(constraints, { Type = "ScopedTag", ScopeKey = d.Source.ScopeKey, Val = actualVal })
                                else
                                    table.insert(constraints, { Type = "Tag", Val = actualVal })
                               end
                               return true
                            end
                            return table.find(t, v)
                        end
                    }, {__index = table})
                end
                return originalEnv[k]
            end
        })
        
        setfenv(callback, traceEnv)
        local noYield = setmetatable({}, {
            __index = function()
                callback(traceDescendant)
                return true
            end
        })
        
        local success, err = pcall(function()
            return noYield.__TRIGGER
        end)

        if not success then
             local errStr = tostring(err)
             if string.find(errStr, "attempt to yield") or string.find(errStr, "thread is not yieldable") then
                 return nil, "Unsatisfiable: Yielding (coroutine.yield or task.wait/wait) is not allowed in query callbacks."
             end
        end
        
        TraceRecorder = nil
        
        -- 2. SOLVE PHASE
        -- Build Domain
        local domain = {}
        
        -- Register unique child checks
        local childChecks = {}
        
        for _, c in next, constraints do
            if c.Type == "Prop" then
                local key = c.Key
                domain[key] = domain[key] or {}
                local exists = false
                for _, v in next, domain[key] do 
                    if v == c.Val then 
                        exists = true 
                        break 
                    end 
                end
                if not exists then table.insert(domain[key], c.Val) end
            elseif c.Type == "Tag" then
                local key = "Tag_" .. c.Val
                domain[key] = {true, false}
            elseif c.Type == "Child" then
                local key = ChildKey(c.Mode, c.Target, c.Recursive)
                if c.ForcedNil then
                     -- If forced nil, it MUST be false
                     domain[key] = {false}
                else
                    domain[key] = {true, false}
                end
                childChecks[key] = c -- Store metadata

            elseif c.Type == "Attribute" then
                local key = "Attr_" .. c.Key
                domain[key] = domain[key] or {}
                local exists = false
                
                local storedVal = c.Val
                if storedVal == nil then storedVal = Reflector.NIL_SENTINEL end
                
                for _, v in next, domain[key] do 
                    if v == storedVal then 
                        exists = true 
                        break 
                    end 
                end
                if not exists then table.insert(domain[key], storedVal) end
            elseif c.Type == "ScopedChild" then
                -- ScopedKey::Key
                local key = ScopedKey(c.ScopeKey, "Child", c.Key)
                 if c.ForcedNil then
                     domain[key] = {false}
                else
                    domain[key] = {true, false}
                end
                childChecks[key] = c
            elseif c.Type == "ScopedTag" then
                local key = ScopedKey(c.ScopeKey, "Tag", c.Val)
                domain[key] = {true, false}
            elseif c.Type == "ScopedProp" then
                local key = ScopedKey(c.ScopeKey, "Prop", c.Key)
                domain[key] = domain[key] or {}
                local exists = false
                
                local storedVal = c.Val
                if storedVal == nil then storedVal = Reflector.NIL_SENTINEL end

                for _, v in next, domain[key] do 
                    if v == storedVal then 
                        exists = true 
                        break 
                    end 
                end
                if not exists then table.insert(domain[key], storedVal) end
            elseif c.Type == "ScopedAttribute" then
                local key = ScopedKey(c.ScopeKey, "Attr", c.Key)
                domain[key] = domain[key] or {}
                local exists = false
                
                local storedVal = c.Val
                if storedVal == nil then storedVal = Reflector.NIL_SENTINEL end
                
                for _, v in next, domain[key] do 
                    if v == storedVal then 
                        exists = true 
                        break 
                    end 
                end
                if not exists then table.insert(domain[key], storedVal) end
            end
            
            -- The original code had a duplicate 'elseif c.Type == "Tag" then' here,
            -- which was syntactically incorrect. The instruction implies closing the
            -- previous elseif block and then having the 'Tag' case.
            -- Assuming the intent was to have this as a separate case, not nested.
            if c.Type == "Tag" then -- This was likely intended as a separate 'elseif' or 'if'
                 local key = "Tag_" .. tostring(c.Val)
                 domain[key] = {true, false}
            end

        end
        
        local keys = {}
        for k in next, domain do table.insert(keys, k) end
        
    
        
        -- Verification execution
        local function RunTest(state)
            local testDescendant = newproxy(true)
            local mt = getmetatable(testDescendant)
            
            -- Method Mocking for RunTest
            local methods = {}
            local function CreateScopedMock(scopeKey)
                local proxy = newproxy(true)
                local mt = getmetatable(proxy)
                
                 local function GetMockMethods(sKey)
                    return {
                        FindFirstChild = function(_, name, rec)
                             local actualName = name
                             if type(name) == "userdata" and TokenData[name] then actualName = TokenData[name].Val end
                             local ck = ChildKey("Name", actualName, rec == true)
                             local childKey = ScopedKey(sKey, "Child", ck)
                             
                             if state[childKey] then
                                 return CreateScopedMock(childKey)
                             end
                             return nil
                        end,
                        FindFirstChildWhichIsA = function(_, cls, rec)
                             local actualCls = cls
                             if type(cls) == "userdata" and TokenData[cls] then actualCls = TokenData[cls].Val end
                             local ck = ChildKey("Class", actualCls, rec == true)
                             local childKey = ScopedKey(sKey, "Child", ck)
                             
                             if state[childKey] then
                                 return CreateScopedMock(childKey)
                             end
                             return nil
                        end,
                         FindFirstChildOfClass = function(_, cls, rec) -- same
                             local actualCls = cls
                             if type(cls) == "userdata" and TokenData[cls] then actualCls = TokenData[cls].Val end
                             local ck = ChildKey("Class", actualCls, rec == true)
                             local childKey = ScopedKey(sKey, "Child", ck)
                             
                             if state[childKey] then
                                 return CreateScopedMock(childKey)
                             end
                             return nil
                        end,
                        GetAttribute = function(_, attrKey)
                             local key = ScopedKey(sKey, "Attr", attrKey)
                             local val = state[key]
                             -- if val == nil then val = "__REFLECT_RANDOM__" end
                             return CreateToken({ Type="Val", Val=val })
                         end
                    }
                end
                
                local m = GetMockMethods(scopeKey)
                
                mt.__index = function(_, k)
                    if m[k] then return m[k] end
                    if k == "Tags" then
                        return CreateToken({ Type = "Tags", State = state, ScopeKey = scopeKey }) 
                    end
                    
                    local key = ScopedKey(scopeKey, "Prop", k)
                    local val = state[key]
                    if val == nil then val = "__REFLECT_RANDOM__" end
                    return CreateToken({ Type="Val", Val=val })
                end
                return proxy
            end
    
            methods.FindFirstChild = function(_, name, rec)
                 local actualName = name
                 if type(name) == "userdata" and TokenData[name] then actualName = TokenData[name].Val end
                 local ck = ChildKey("Name", actualName, rec == true)
                 if state[ck] then
                     return CreateScopedMock(ck)
                 else
                     return nil
                 end
            end
            methods.FindFirstChildWhichIsA = function(_, cls, rec)
                 local actualCls = cls
                 if type(cls) == "userdata" and TokenData[cls] then actualCls = TokenData[cls].Val end
                 local ck = ChildKey("Class", actualCls, rec == true)
                 if state[ck] then
                     return CreateScopedMock(ck)
                 else
                     return nil
                 end
            end
            
            methods.FindFirstChildOfClass = methods.FindFirstChildWhichIsA
    
            methods.GetAttribute = function(_, key)
                 local val = state["Attr_"..key]
                 -- if val == nil then val = "__REFLECT_RANDOM__" end -- Attributes can be nil
                 return CreateToken({ Type = "Val", Val = val }) -- Attributes return values directly
            end
    
            mt.__index = function(_, k)
                if methods[k] then return methods[k] end
                
                if k == "Tags" then
                    return CreateToken({ Type = "Tags", State = state }) 
                end
                
                local val = state[k]
                if val == nil then val = "__REFLECT_RANDOM__" end
                
                return CreateToken({ Type = "Prop", Key = k, SimulatedVal = val })
            end
            
            local verifyEnv = setmetatable({}, {
                __index = function(_, k)
                    if k == "table" then
                        return setmetatable({
                            find = function(t, v)
                                local d = TokenData[t]
                                if d and d.Type == "Tags" and d.State then
                                    local tagName = (type(v) == "userdata" and TokenData[v]) and TokenData[v].Val or v
                                    local key
                                    if d.ScopeKey then
                                        key = ScopedKey(d.ScopeKey, "Tag", tagName)
                                    else
                                        key = "Tag_" .. tagName
                                    end
                                    return d.State[key] == true
                                end
                                return table.find(t, v)
                            end
                        }, {__index = table})
                    end
                    return originalEnv[k]
                end
            })
            
            setfenv(callback, verifyEnv)
            
            local noYield = setmetatable({}, { 
                __index = function()
                    return callback(testDescendant)
                end
            })

            local s, r = pcall(function()
                return noYield.__TRIGGER
            end)
            
            if not s then
                local errStr = tostring(r)
                if string.find(errStr, "attempt to yield") or string.find(errStr, "thread is not yieldable") then
                    error("Unsatisfiable: Yielding (coroutine.yield or task.wait/wait) is not allowed in query callbacks.")
                end
            end
            
            return s and r
        end
        
        -- Build Forbidden Map
        local forbidden = {}
        local requiredExistence = {} 
        
        for _, c in next, constraints do
             if c.Negate then
                 local key
                 if c.Type == "Prop" then key = c.Key
                 elseif c.Type == "Attribute" then key = "Attr_" .. c.Key
                 elseif c.Type == "ScopedProp" then key = ScopedKey(c.ScopeKey, "Prop", c.Key)
                 elseif c.Type == "ScopedAttribute" then key = ScopedKey(c.ScopeKey, "Attr", c.Key)
                 end
                 
                 if key then
                     if c.Val == nil then
                         -- Constraint: Key != nil (Must Exist)
                         requiredExistence[key] = true
                     else
                         forbidden[key] = forbidden[key] or {}
                         forbidden[key][c.Val] = true
                     end
                 end
             end
        end
        
        -- Ensure required existence keys have a domain
        for key, _ in next, requiredExistence do
            domain[key] = domain[key] or {}
            
            local hasNonNil = false
            for _, v in next, domain[key] do
                if v ~= Reflector.NIL_SENTINEL then hasNonNil = true; break end
            end
            
            if not hasNonNil then
                -- Inject placeholder 'true' to satisfy existence
                table.insert(domain[key], Reflector.EXISTENCE_SENTINEL)
            end
        end
        
        local goldenState = nil
        
        local function Solve(index, currentState)
            if goldenState then return end
            if index > #keys then
                if RunTest(currentState) then
                    goldenState = currentState
                end
                return
            end
            
            local key = keys[index]
            local options = domain[key]
            
            for _, val in next, options do
                -- Check negative constraints from Trace
                local actualVal = val
                if val == Reflector.NIL_SENTINEL then actualVal = nil end

                if forbidden[key] and forbidden[key][actualVal] then
                    continue
                end
                
                -- Check existence constraint (redundant if we only added to domain, but good for safety)
                if requiredExistence[key] and actualVal == nil then
                     continue
                end
                
                local nextState = {}
                for k,v in next, currentState do nextState[k] = v end
                nextState[key] = actualVal
                Solve(index+1, nextState)
                if goldenState then return end
            end
            
            -- Try random for props
            local isScoped = key:find("::") ~= nil
            
            local scopeKey, remainder
            if isScoped then
                 -- Greedy match to find last ::
                 local s, r = key:match("^(.*)::(.*)$")
                 scopeKey = s
                 remainder = r
            end

            local isTag = key:sub(1,4) == "Tag_"
            local isChild = key:sub(1,6) == "Child_" and not isScoped
            local isScopedTag = isScoped and remainder:sub(1,4) == "Tag_"
            local isScopedChild = isScoped and remainder:sub(1,6) == "Child_"
            
            if (not isTag and not isChild) and (not isScopedTag and not isScopedChild) then
                 local nextState = {}
                 for k,v in next, currentState do nextState[k] = v end
                 nextState[key] = "__REFLECT_RANDOM__"
                 Solve(index+1, nextState)
            end
        end
        
        Solve(1, {})
        
        -- SENSITIVITY ANALYSIS
        if goldenState then
            local result = {
                Class = nil,
                Name = nil,
                Tags = {},
                Props = {},
                Attributes = {},
                AttributeExistence = {},
                Children = {},
                Not = {},
                Has = {},
                NotHas = {},
                NotAttributes = {}
            }
            
            for _, key in ipairs(keys) do
                local validVal = goldenState[key]
                if validVal == nil then validVal = Reflector.NIL_SENTINEL end
            
                local sep = key:find("::")
                local isScoped = sep ~= nil
                local isTag = key:sub(1,4) == "Tag_"
                local isChild = key:sub(1,6) == "Child_" and not isScoped
                
                -- Create a "Bad" state
                local badState = {}
                for k,v in next, goldenState do badState[k] = v end
                
                -- Greedy match to find last ::
                local scopeKey, remainder
                if isScoped then
                     local s, r = key:match("^(.*)::(.*)$")
                     scopeKey = s
                     remainder = r
                end
                
                if isTag or isChild or (isScoped and type(validVal) == "boolean") then
                    badState[key] = not validVal
                    local success = RunTest(badState)
                    
                    if not success then
                        if isTag then
                            local tagName = key:sub(5)
                            if validVal then table.insert(result.Tags, tagName)
                            else table.insert(result.Not, {Type="Tag", Val=tagName}) end
                        elseif isScoped then
                            local meta = childChecks[scopeKey]
                            if meta then
                                local typeSep = remainder:find("_")
                                if typeSep then
                                     local sType = remainder:sub(1, typeSep-1)
                                     local sKey = remainder:sub(typeSep+1)
                                     
                                     if sType == "Attr" then
                                         meta.Attributes = meta.Attributes or {}
                                         meta.Attributes[sKey] = validVal
                                     elseif sType == "Prop" then
                                         meta.Props = meta.Props or {}
                                         meta.Props[sKey] = validVal
                                     elseif sType == "Tag" then
                                         meta.Tags = meta.Tags or {}
                                         table.insert(meta.Tags, sKey)
                                     elseif sType == "Child" then
                                         local childMeta = childChecks[key] 
                                         if validVal then
                                             meta.Has = meta.Has or {}
                                             table.insert(meta.Has, childMeta)
                                         else
                                             meta.NotHas = meta.NotHas or {}
                                             table.insert(meta.NotHas, childMeta)
                                         end
                                     end
                                end
                            end
                        elseif isChild then
                            local meta = childChecks[key]
                            if validVal then
                                table.insert(result.Has, meta)
                            else
                                table.insert(result.NotHas, meta)
                            end
                        end
                    end
                else
                    if validVal == "__REFLECT_RANDOM__" then
                        -- Check negative constraints
                        for _, badVal in next, domain[key] do
                             local specificBad = {}
                             for k,v in next, goldenState do specificBad[k] = v end
                             specificBad[key] = badVal
                             local success = RunTest(specificBad)

                             if not success then
                                 if isScoped then
                                     local meta = childChecks[scopeKey]
                                     if meta then
                                         local typeSep = remainder:find("_")
                                         if typeSep then
                                              local sType = remainder:sub(1, typeSep-1)
                                              local sKey = remainder:sub(typeSep+1)
                                              
                                              if sType == "Attr" then
                                                  meta.NotAttributes = meta.NotAttributes or {}
                                                  table.insert(meta.NotAttributes, {Key=sKey, Val=badVal})
                                              elseif sType == "Prop" then
                                                  meta.NotProps = meta.NotProps or {}
                                                  table.insert(meta.NotProps, {Key=sKey, Val=badVal})
                                              end
                                         end
                                     end
                                 else
                                     table.insert(result.Not, {Type="Prop", Key=key, Val=badVal})
                                 end
                             end
                        end
                        continue 
                    else
                        -- Check 1: Is it required at all? (Existence Check)
                        badState[key] = nil
                        local existenceRequired = not RunTest(badState)
                        
                        -- Check 2: Is the specific value required?
                        badState[key] = "__REFLECT_RANDOM__"
                        local valueRequired = not RunTest(badState)
                        
                        if existenceRequired then
                            if not valueRequired then
                                -- Existence Only!
                                if key:sub(1,5) == "Attr_" then
                                    table.insert(result.AttributeExistence, key:sub(6))
                                end
                                
                                if isScoped then
                                    local meta = childChecks[scopeKey]
                                    if meta then
                                        local typeSep = remainder:find("_")
                                        if typeSep then
                                            local sType = remainder:sub(1, typeSep-1)
                                            local sKey = remainder:sub(typeSep+1)
                                            
                                            if sType == "Attr" then
                                                meta.AttributeExistence = meta.AttributeExistence or {}
                                                table.insert(meta.AttributeExistence, sKey)
                                            end
                                        end
                                    end
                                end
                            else
                                -- Specific Value Required
                                if isScoped then
                                    local meta = childChecks[scopeKey]
                                    if meta then
                                        local typeSep = remainder:find("_")
                                        if typeSep then
                                            local sType = remainder:sub(1, typeSep-1)
                                            local sKey = remainder:sub(typeSep+1)
                                            
                                            if sType == "Attr" then
                                                meta.Attributes = meta.Attributes or {}
                                                meta.Attributes[sKey] = validVal
                                            elseif sType == "Prop" then
                                                meta.Props = meta.Props or {}
                                                meta.Props[sKey] = validVal
                                            end
                                        end
                                    end
                                else
                                    if key == "ClassName" then result.Class = validVal
                                    elseif key == "Name" then result.Name = validVal
                                    elseif key:sub(1,5) == "Attr_" then 
                                        if validVal == Reflector.EXISTENCE_SENTINEL then
                                            table.insert(result.AttributeExistence, key:sub(6))
                                        else
                                            result.Attributes[key:sub(6)] = validVal 
                                        end
                                    elseif key:sub(1,4) == "Tag_" then
                                        if validVal == true then 
                                            table.insert(result.Tags, key:sub(5))
                                        end
                                    else result.Props[key] = validVal end
                                end
                            end
                        -- DEBUG

                        
                        elseif valueRequired and validVal == Reflector.NIL_SENTINEL then
                             if isScoped then
                                 local meta = childChecks[scopeKey]
                                 if meta then
                                      local typeSep = remainder:find("_")
                                      if typeSep then
                                           local sType = remainder:sub(1, typeSep-1)
                                           local sKey = remainder:sub(typeSep+1)
                                           
                                           if sType == "Attr" then
                                               meta.NotAttributes = meta.NotAttributes or {}
                                               table.insert(meta.NotAttributes, {Key=sKey, Val=Reflector.EXISTENCE_SENTINEL})
                                           elseif sType == "Tag" then
                                               -- This block is for NIL_SENTINEL (Absence)
                                               -- If Tag is NIL_SENTINEL (or false/nil), it's a Negated Tag
                                                meta.Not = meta.Not or {}
                                                table.insert(meta.Not, {Type="Tag", Val=sKey})
                                           end
                                      end
                                 end
                             else
                                 -- Global Attribute Absence
                                 table.insert(result.Not, {Type="Attribute", Key=key:sub(6), Val=Reflector.EXISTENCE_SENTINEL})
                             end
                        end
                    end
                end
            end
            
            -- Robust deduplication based on goldenState
            local stateSigParts = {}
            for k, v in next, goldenState do
                table.insert(stateSigParts, tostring(k) .. "=" .. tostring(v))
            end
            table.sort(stateSigParts)
            local stateSig = table.concat(stateSigParts, "|")
            
            if not seenResults[stateSig] then
                seenResults[stateSig] = true
                table.insert(allResults, result)
            end
        end
        
        -- Branch Exploration handled inline
    end
    
    if #allResults == 0 then
        return nil, "Unsatisfiable"
    end
    
    return allResults
end

return Reflector