# QueryBuilder

A verbose query builder for `QueryDescendants`.

## Installation

Add `upio/query-builder` to your `wally.toml`:

```toml
[dependencies]
QueryBuilder = "upio/query-builder@0.1.0"
```

## Usage

```lua
local QueryBuilder = require(path.to.QueryBuilder)

local Query = QueryBuilder.new()
    :SetClass("Model")
    :SetName("Car")
    :Child(
        QueryBuilder.new()
            :SetClass("VehicleSeat")
            :SetProperty("Disabled", false)
            :Not(QueryBuilder.new():AddTag("Broken"))
    )
    :ToQuery()

print(#game:QueryDescendants(Query))
```
