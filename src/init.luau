--[[

	QueryBuilder
	Made by upio

	Provides a way to build queries for `QueryDescendants` in a verbose manner.

	Example:
		local Query = QueryBuilder.new()
			:SetClass("Model")
			:SetName("Car")
			:Child(
				QueryBuilder
					:SetClass("VehicleSeat")
					:SetProperty("Disabled", false)
					:Not(QueryBuilder:AddTag("Broken"))
			)
			:ToQuery()

		print(#game:QueryDescendants(Query))
]]

--!strict

local QueryBuilder = {}
QueryBuilder.__index = QueryBuilder

export type QueryBuilder = {
	_ClassName: string?,
	_Name: string?,
	_Tags: { string },
	_Properties: { [string]: any },
	_Attributes: { [string]: any },
	_Pseudos: { string },
	_Combinator: { Type: string, Query: QueryBuilder }?,
	_Alternatives: { QueryBuilder },
	
	SetClass: (self: QueryBuilder, className: string) -> QueryBuilder,
	SetName: (self: QueryBuilder, name: string) -> QueryBuilder,
	AddTag: (self: QueryBuilder, tag: string) -> QueryBuilder,
	
	SetProperties: (self: QueryBuilder, props: { [string]: any }) -> QueryBuilder,
	SetAttributes: (self: QueryBuilder, attrs: { [string]: any }) -> QueryBuilder,
	SetProperty: (self: QueryBuilder, key: string, value: any) -> QueryBuilder,
	SetAttribute: (self: QueryBuilder, key: string, value: any) -> QueryBuilder,
	
	Child: (self: QueryBuilder, subQuery: QueryBuilder) -> QueryBuilder,
	Descendant: (self: QueryBuilder, subQuery: QueryBuilder) -> QueryBuilder,
	
	Not: (self: QueryBuilder, ...QueryBuilder) -> QueryBuilder,
	Has: (self: QueryBuilder, ...QueryBuilder) -> QueryBuilder,
	
	Or: (self: QueryBuilder, ...QueryBuilder) -> QueryBuilder,
	Also: (self: QueryBuilder, ...QueryBuilder) -> QueryBuilder,
	
	-- Define aliases
	define: (val: any) -> QueryBuilder,
	defineValue: (val: any) -> QueryBuilder,
	dv: (val: any) -> QueryBuilder,
	v: (val: any) -> QueryBuilder,
	value: (val: any) -> QueryBuilder,
	
	fromOperation: (callback: (any) -> boolean) -> QueryBuilder,
	ToQuery: (self: QueryBuilder) -> string,
}


local Reflector
if script and script:FindFirstChild("Reflector") then
	Reflector = require(script:FindFirstChild("Reflector"))
else
	Reflector = require("./Reflector")
end

function QueryBuilder.new(): QueryBuilder
	local self = setmetatable({
		_ClassName = nil,
		_Name = nil,
		_Tags = {},
		_Properties = {},
		_Attributes = {},
		_Pseudos = {},
		_Combinator = nil,
		_Alternatives = {},
	}, QueryBuilder)
	return (self :: any) :: QueryBuilder
end

local function BuildQueryFromData(data)
	local qb = QueryBuilder.new()
	if data.Class then qb:SetClass(data.Class) end
	if data.Name then qb:SetName(data.Name) end
	
	for _, tag in next, data.Tags do
		qb:AddTag(tag)
	end
	
	qb:SetProperties(data.Props)
	
	if data.Attributes then
		for k, v in next, data.Attributes do
			qb:SetAttribute(k, v)
		end
	end
	
	-- Handle Not (Negations)
	for _, note in next, data.Not do
		local negation = QueryBuilder.new()
		if note.Type == "Prop" then -- Inequality
			if note.Key == "ClassName" then negation:SetClass(note.Val)
			elseif note.Key == "Name" then negation:SetName(note.Val)
			else negation:SetProperty(note.Key, note.Val) end
		elseif note.Type == "Tag" then
			negation:AddTag(note.Val)
		end
		
		qb:Not(negation)
	end
	
	-- Handle Has/NotHas (Children)
	local function ProcessHas(list, negate)
		for _, check in next, list do
			local target = QueryBuilder.new()
			if check.Mode == "Name" then
				target:SetName(check.Target)
			elseif check.Mode == "Class" then
				target:SetClass(check.Target)
			end
			
			if check.Props then
				for k,v in next, check.Props do target:SetProperty(k, v) end
			end
			if check.Attributes then
				for k,v in next, check.Attributes do target:SetAttribute(k, v) end
			end
			
			if check.NotProps or check.NotAttributes then
			    local negation = QueryBuilder.new()
			    if check.NotProps then
			        for _, p in next, check.NotProps do negation:SetProperty(p.Key, p.Val) end
		        end
		        if check.NotAttributes then
		            for _, a in next, check.NotAttributes do negation:SetAttribute(a.Key, a.Val) end
	            end
	            target:Not(negation)
			end
			
			-- Recursive = true (Descendant) -> :has(target)
			-- Recursive = false (Child) -> :has(> target)
			
			local hasQuery 
			if check.Recursive then
				-- If recursive, we just look for dynamic existence.
				-- By default :has(#Name) checks descendants.
				hasQuery = target
			else
				-- If non-recursive, we need direct child combinator
				hasQuery = QueryBuilder.new():Child(target)
			end
			
			if negate then
				qb:Not(QueryBuilder.new():Has(hasQuery))
			else
				qb:Has(hasQuery)
			end
		end
	end
	
	if data.Has then ProcessHas(data.Has, false) end
	if data.NotHas then ProcessHas(data.NotHas, true) end
	
	return qb
end

for _, key in next, { "define", "defineValue", "dv", "v", "value" } do
	QueryBuilder[key] = Reflector.Define
end

function QueryBuilder.fromOperation(callback: (any) -> boolean): QueryBuilder
	local dataList, err = Reflector.Parse(callback)
	assert(dataList, "Failed to parse operation: " .. tostring(err))
	
	local mainQB = nil
	
	for _, data in next, dataList do
	    local q = BuildQueryFromData(data)
	    if not mainQB then
	        mainQB = q
        else
            mainQB:Or(q)
        end
	end
	
	return mainQB :: QueryBuilder
end

local function EnsureInstance(self: any): QueryBuilder
	if self == QueryBuilder then
		return QueryBuilder.new()
	end
	return self
end

function QueryBuilder:SetClass(className: string): QueryBuilder
	local instance = EnsureInstance(self)
	instance._ClassName = className
	return instance
end

function QueryBuilder:SetName(name: string): QueryBuilder
	local instance = EnsureInstance(self)
	instance._Name = name
	return instance
end

function QueryBuilder:AddTag(tag: string): QueryBuilder
	local instance = EnsureInstance(self)
	table.insert(instance._Tags, tag)
	return instance
end

function QueryBuilder:SetProperties(props: { [string]: any }): QueryBuilder
	local instance = EnsureInstance(self)
	for k, v in next, props do
		instance._Properties[k] = v
	end
	return instance
end

function QueryBuilder:SetAttributes(attrs: { [string]: any }): QueryBuilder
	local instance = EnsureInstance(self)
	for k, v in next, attrs do
		instance._Attributes[k] = v
	end
	return instance
end

function QueryBuilder:SetProperty(key: string, value: any): QueryBuilder
	local instance = EnsureInstance(self)
	instance._Properties[key] = value
	return instance
end

function QueryBuilder:SetAttribute(key: string, value: any): QueryBuilder
	local instance = EnsureInstance(self)
	instance._Attributes[key] = value
	return instance
end

function QueryBuilder:Child(subQuery: QueryBuilder): QueryBuilder
	local instance = EnsureInstance(self)
	instance._Combinator = { Type = ">", Query = subQuery }
	return instance
end

function QueryBuilder:Descendant(subQuery: QueryBuilder): QueryBuilder
	local instance = EnsureInstance(self)
	instance._Combinator = { Type = ">>", Query = subQuery }
	return instance
end

function QueryBuilder:Or(...: QueryBuilder): QueryBuilder
	local instance = EnsureInstance(self)
	for i = 1, select("#", ...) do
		local altQuery = select(i, ...)
		table.insert(instance._Alternatives, altQuery :: QueryBuilder)
	end
	return instance
end

function QueryBuilder:Also(...: QueryBuilder): QueryBuilder
	return self:Or(...)
end

local function BuildSelectorList(...: QueryBuilder): string
	local parts: {string} = {}
	for i = 1, select("#", ...) do
		local builder = select(i, ...)
		table.insert(parts, builder:ToQuery() :: string)
	end
	return table.concat(parts, ", ") :: string
end

function QueryBuilder:Not(...: QueryBuilder): QueryBuilder
	local instance = EnsureInstance(self)
	table.insert(instance._Pseudos, string.format(":not(%s)", BuildSelectorList(...)))
	return instance
end

function QueryBuilder:Has(...: QueryBuilder): QueryBuilder
	local instance = EnsureInstance(self)
	table.insert(instance._Pseudos, string.format(":has(%s)", BuildSelectorList(...)))
	return instance
end

local function FormatValue(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	else
		return tostring(value)
	end
end

function QueryBuilder:ToQuery(): string
	local parts: {string} = {}

	-- 1. Class
	local className = self._ClassName
	if className then
		table.insert(parts, className :: string)
	end
	
	-- 2. Name (#Name)
	local name = self._Name
	if name then
		table.insert(parts, "#" .. name :: string)
	end

	-- 3. Tags (.Tag)
	table.sort(self._Tags)
	for _, tag in next, self._Tags do
		table.insert(parts, "." .. tag :: string)
	end
	
	-- 4. Properties ([Prop = Val])
	local propKeys: {string} = {}
	for k in next, self._Properties do
		table.insert(propKeys, k :: string)
	end

	table.sort(propKeys)
	
	for _, k in next, propKeys do
		local v = self._Properties[k]
		table.insert(parts, string.format("[%s = %s]", k, FormatValue(v)))
	end
	
	-- 5. Attributes ([$Attr = Val])
	local attrKeys: {string} = {}
	for k in next, self._Attributes do
		table.insert(attrKeys, k :: string)
	end

	table.sort(attrKeys)
	
	for _, k in next, attrKeys do
		local v = self._Attributes[k]
		table.insert(parts, string.format("[$%s = %s]", k, FormatValue(v)))
	end

	-- 6. Pseudos (:not(), :has())
	for _, pseudo in next, self._Pseudos :: any do
		table.insert(parts, pseudo :: string)
	end

	-- Combine compound selector
	local compound = table.concat(parts, "")

	-- 7. Combinator
	local combinator = self._Combinator
	if combinator then
		assert(combinator.Query ~= self, "Recursive combinator detected")
		
		local query = combinator.Query:ToQuery() :: string
		if compound == "" then
			compound = (combinator.Type :: string) .. " " .. query
		else
			compound = compound .. " " .. (combinator.Type :: string) .. " " .. query
		end
	end

	-- 8. Alternatives
	if #(self._Alternatives :: any) > 0 then
		for _, alt in next, self._Alternatives :: any do
            if alt == self then continue end
			
			local altStr = (alt :: any):ToQuery() :: string
			if compound == "" then
				compound = altStr
			else
				compound = compound .. ", " .. altStr
			end
		end
	end
	
	return compound :: string
end

return QueryBuilder
