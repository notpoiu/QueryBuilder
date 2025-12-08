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
    
    local valA = da.Type == "Val" and da.Val or da.SimulatedVal
    local valB = db.Type == "Val" and db.Val or db.SimulatedVal
    
    return valA == valB
end

-- Exposed Value Wrapper
function Reflector.Define(val: any)
    return CreateToken({ Type = "Val", Val = val })
end

-- Helper to canonicalize Child Key
local function ChildKey(mode, val, rec)
    return string.format("Child_%s_%s_%s", mode, tostring(val), tostring(rec))
end

local function ScopedKey(scope, type, key)
    return scope .. "::" .. type .. "_" .. key
end

local function DeepCopy(t)
    local n = {}
    for k,v in next, t do n[k] = v end
    return n
end

function Reflector.Parse(callback)
    local allResults = {}
    
    local queue = { {} } -- list of forcedNil sets
    local processedContexts = {} -- set of context strings to avoid loops
    
    -- Limit iterations to prevent explosion
    local iterations = 0
    local MAX_ITERATIONS = 20

    while #queue > 0 and iterations < MAX_ITERATIONS do
        iterations = iterations + 1
        local forcedNil = table.remove(queue, 1) or {}
        
        -- Context Signature
        local ctxKeys = {}
        for k in next, forcedNil do table.insert(ctxKeys, k) end
        table.sort(ctxKeys)
        local ctxSig = table.concat(ctxKeys, "|")
        if processedContexts[ctxSig] then continue end
        processedContexts[ctxSig] = true
        
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
            
            if prop and val and val.Type == "Val" then
                -- Record Constraint
                if prop.Type == "ScopedProp" or prop.Type == "ScopedAttribute" then
                    table.insert(constraints, { Type = prop.Type, ScopeKey = prop.ScopeKey, Key = prop.Key, Val = val.Val })
                else
                    table.insert(constraints, { Type = prop.Type, Key = prop.Key, Val = val.Val })
                end
    
                return true -- Assume match for tracing flow
            end
            return false -- logic fallthrough
        end
        
        local function TraceChildInterceptor(mode)
            return function(_, target, recursive)
                local actualTarget = (type(target) == "userdata" and TokenData[target]) and TokenData[target].Val or target
                local rec = recursive == true
                local ck = ChildKey(mode, actualTarget, rec)
                
                -- Check Forced Nil
                if forcedNil[ck] then
                    table.insert(constraints, { Type = "Child", Mode = mode, Target = actualTarget, Recursive = rec, ForcedNil = true })
                    return nil
                end
                
                discoveredChildren[ck] = true
                
                table.insert(constraints, { Type = "Child", Mode = mode, Target = actualTarget, Recursive = rec })
                return CreateToken({ Type = "ChildScope", ScopeKey = ck })
            end
        end
    
        local traceDescendant = CreateToken({ 
            Type = "Descendant", 
            Methods = {
                FindFirstChild = TraceChildInterceptor("Name"),
                FindFirstChildWhichIsA = TraceChildInterceptor("Class"),
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
                               
                               table.insert(constraints, { Type = "Tag", Val = actualVal })
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
        pcall(function() callback(traceDescendant) end)
        
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
                for _, v in next, domain[key] do if v == c.Val then exists = true break end end
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
                for _, v in next, domain[key] do if v == c.Val then exists = true break end end
                if not exists then table.insert(domain[key], c.Val) end
            elseif c.Type == "ScopedProp" then
                local key = ScopedKey(c.ScopeKey, "Prop", c.Key)
                domain[key] = domain[key] or {}
                local exists = false
                for _, v in next, domain[key] do if v == c.Val then exists = true break end end
                if not exists then table.insert(domain[key], c.Val) end
            elseif c.Type == "ScopedAttribute" then
                local key = ScopedKey(c.ScopeKey, "Attr", c.Key)
                domain[key] = domain[key] or {}
                local exists = false
                for _, v in next, domain[key] do if v == c.Val then exists = true break end end
                if not exists then table.insert(domain[key], c.Val) end
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
                mt.__index = function(_, k)
                    if k == "GetAttribute" then
                         return function(_, attrKey)
                             local key = ScopedKey(scopeKey, "Attr", attrKey)
                             local val = state[key]
                             if val == nil then val = "__REFLECT_RANDOM__" end
                             return CreateToken({ Type="Val", Val=val })
                         end
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
    
            methods.GetAttribute = function(_, key)
                 local val = state["Attr_"..key]
                 if val == nil then val = "__REFLECT_RANDOM__" end
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
                                    local key = "Tag_" .. tagName
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
            
            local s, r = pcall(callback, testDescendant)
            return s and r
        end
    
        -- 3. BACKTRACKING SOLVER
        
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
                local nextState = {}
                for k,v in next, currentState do nextState[k] = v end
                nextState[key] = val
                Solve(index+1, nextState)
                if goldenState then return end
            end
            
            -- Try random for props
            local isTag = key:sub(1,4) == "Tag_"
            local isChild = key:sub(1,6) == "Child_"
            local isScoped = key:find("::") ~= nil
            
            if (not isTag and not isChild) or isScoped then
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
                Children = {},
                Not = {},
                Has = {},
                NotHas = {}
            }
            
            for key, validVal in next, goldenState do
                local sep = key:find("::")
                local isScoped = sep ~= nil
                local isTag = key:sub(1,4) == "Tag_"
                local isChild = key:sub(1,6) == "Child_" and not isScoped
                
                -- Create a "Bad" state
                local badState = {}
                for k,v in next, goldenState do badState[k] = v end
                
                if isTag or isChild then
                    badState[key] = not validVal
                else
                    if validVal == "__REFLECT_RANDOM__" then
                        -- Check negative constraints
                        for _, badVal in next, domain[key] do
                             local specificBad = {}
                             for k,v in next, goldenState do specificBad[k] = v end
                             specificBad[key] = badVal
                             local success = RunTest(specificBad)
                             
                             if not success then
                                 -- It is required that Key ~= BadVal
                                 if isScoped then
                                     local scopeKey = key:sub(1, sep-1)
                                     local remainder = key:sub(sep+2)
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
                        badState[key] = "__REFLECT_RANDOM__"
                    end
                end
                
                if not RunTest(badState) then
                    -- It is required!
                    if isTag then
                        local tagName = key:sub(5)
                        if validVal then table.insert(result.Tags, tagName)
                        else table.insert(result.Not, {Type="Tag", Val=tagName}) end
                    elseif isScoped then
                        local scopeKey = key:sub(1, sep-1)
                        local remainder = key:sub(sep+2)
                        local meta = childChecks[scopeKey]
                        
                        if meta then
                            -- Parse Type_Key e.g. Prop_Name or Attr_Test
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
                    elseif isChild then
                        local meta = childChecks[key]
                        if validVal then
                            table.insert(result.Has, meta)
                        else
                            table.insert(result.NotHas, meta) -- :Not(:Has(...))
                        end
                    else
                        if key == "ClassName" then result.Class = validVal
                        elseif key == "Name" then result.Name = validVal
                        elseif key:sub(1,5) == "Attr_" then result.Attributes[key:sub(6)] = validVal
                        else result.Props[key] = validVal end
                    end
                end
            end
            
            -- Simple deduplication check
            -- Not robust but better than nothing
            table.insert(allResults, result)
        end
        
        -- Branch Exploration
        for childKey, _ in next, discoveredChildren do
             local newCtx = DeepCopy(forcedNil)
             if not newCtx[childKey] then
                 newCtx[childKey] = true
                 table.insert(queue, newCtx)
             end
        end
    end
    
    if #allResults == 0 then
        return nil, "Unsatisfiable"
    end
    
    return allResults
end

return Reflector