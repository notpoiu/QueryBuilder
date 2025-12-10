# QueryBuilder

A verbose query builder for `QueryDescendants`.

Devforum Post: [QueryBuilder](https://devforum.roblox.com/t/querybuilder-querydescendants-query-builder/4137223)

Wally Package: [QueryBuilder](https://wally.run/package/notpoiu/query-builder)

## Installation

Add `notpoiu/query-builder` to your `wally.toml`:

```toml
[dependencies]
query-builder = "notpoiu/query-builder@0.2.2"
```

## Documentation

### Selectors

| Method                      | Description                      | Syntax Match     |
| :-------------------------- | :------------------------------- | :--------------- |
| `:SetClass(className)`      | Matches by ClassName             | `ClassName`      |
| `:SetName(name)`            | Matches by instance Name         | `#Name`          |
| `:AddTag(tag)`              | Matches by CollectionService Tag | `.Tag`           |
| `:SetProperty(key, value)`  | Matches by property value        | `[Key = Value]`  |
| `:SetAttribute(key, value)` | Matches by attribute value       | `[$Key = Value]` |
| `:HasAttribute(key)`        | Matches if attribute exists      | `[$Key]`         |

### Combinators & Modifiers

| Method                           | Description                              | Logic            |
| :------------------------------- | :--------------------------------------- | :--------------- |
| `:Child(query)`                  | Matches direct children                  | `:has(> query)`  |
| `:Descendant(query)`             | Matches descendants                      | `:has(>> query)` |
| `:Not(query)`                    | Negates the query                        | `:not(query)`    |
| `:Or(query)` <br> `:Also(query)` | Adds an alternative path                 | `query1, query2` |
| `:Has(query)`                    | Checks for existence of descendant/child | `:has(...)`      |

### Output

| Method       | Description                        |
| :----------- | :--------------------------------- |
| `:ToQuery()` | Returns the generated query string |

## Usage

```lua
local QueryBuilder = require(path.to.QueryBuilder)

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
```

## Function-Based Queries

Instead of manually building strings or objects, you can also write a function that describes the object you want to find. `QueryBuilder` will reflect on your function to generate the correct query string.

### Supported Operations

The instance passed to your function is a **proxy**, not a real Instance. Only the following members are supported for reflection:

| Member                                           | Description                                                       |
| :----------------------------------------------- | :---------------------------------------------------------------- |
| `.Property`                                      | ANY property access (e.g. `Part.Transparency`).                   |
| `.Tags`                                          | Special table for `table.find(part.Tags, "Tag")` checks.          |
| `:GetAttribute(name)`                            | Reads an attribute value.                                         |
| `:FindFirstChild(name, recursive?)`              | Checks for a direct child with the given name.                    |
| `:FindFirstChildOfClass(className, recursive?)`  | Checks for a direct child with the given ClassName.               |
| `:FindFirstChildWhichIsA(className, recursive?)` | Checks for a direct child that inherits from the given ClassName. |

> [!CAUTION]
> Calling any other methods (like `:IsA()`, `:Clone()`, `:GetChildren()`) will result in an error or undefined behavior.

### Basic Queries

Match based on properties, attributes, and tags.

```lua
local QueryBuilder = require(path.to.QueryBuilder)
local v = QueryBuilder.value

local Query = QueryBuilder.fromOperation(function(part)
    -- Properties
    return part.Name == v("Coin")
       and part.Transparency == v(0)
       -- Attribute Value
       and part:GetAttribute("IsCollectable") == v(true)
       -- Attribute Existence (Value doesn't matter, just needs to exist)
       and part:GetAttribute("SpawnId") ~= v(nil) -- or ~= v()
       -- CollectionService Tags
       and table.find(part.Tags, "Interactive")
end):ToQuery()

-- Output: "#Coin.Interactive[Transparency = 0][$IsCollectable = true][$SpawnId]"
```

> [!IMPORTANT]
> When comparing against literal values, use `QueryBuilder.define(value)`/`QueryBuilder.value(value)`/`QueryBuilder.defineValue(value)` to ensure proper reflection. Simple comparisons can often work, but if you encounter issues, use the defined functions.

### Hierarchy & Negation

Check for children (`Recursive=false`), descendants (`Recursive=true`)

```lua
local QueryBuilder = require(path.to.QueryBuilder)
local v = QueryBuilder.value

local Query = QueryBuilder.fromOperation(function(model)
    -- Must have a specific child
    local head = model:FindFirstChild("Head")

    -- Must have a Humanoid descendant
    local humanoid = model:FindFirstChildOfClass("Humanoid", true)

    -- Must NOT be "DestroyedModel"
    return head ~= nil
       and humanoid ~= nil
       and model.Name ~= v("DestroyedModel")
end):ToQuery()

-- Output: ":not(#DestroyedModel):has(> #Head):has(Humanoid)"
```

### Complex Queries (Alternatives)

You can use standard control flow (`if/else`) to describe alternative valid states. The builder will generate an `Or` query (comma-separated alternatives).

```lua
local QueryBuilder = require(path.to.QueryBuilder)
local v = QueryBuilder.value

local Query = QueryBuilder.fromOperation(function(part)
    local prompt = part:FindFirstChildOfClass("ProximityPrompt")

    if prompt then
        -- Path 1: If it has a prompt, it must be the "Interact" prompt
        return prompt.Name == v("Interact")
    else
        -- Path 2: If no prompt, it must be named "StaticPart"
        return part.Name == v("StaticPart")
    end
end):ToQuery()

-- Output: ":has(> ProximityPrompt[Name = "Interact"]), #StaticPart:not(:has(> ProximityPrompt))"
```

This allows you to express "A OR B" logic naturally.
