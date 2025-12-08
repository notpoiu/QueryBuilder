# QueryBuilder

A verbose query builder for `QueryDescendants`.

Wally Package: [QueryBuilder](https://wally.run/package/notpoiu/query-builder)

## Installation

Add `notpoiu/query-builder` to your `wally.toml`:

```toml
[dependencies]
QueryBuilder = "notpoiu/query-builder@0.1.1"
```

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
