# SimViz Helper Library & User Scripting Reference Manual (`SimCore.SimViz`)

> **Module:** `SimCore.SimViz` ([`packages/SimCore/src/simviz_helpers.jl`](../packages/SimCore/src/simviz_helpers.jl))  
> **Auto-imported into all hooks:** `on_entry`, `on_exit`, `on_service_start`, `on_service_complete`, `on_pull`, `on_event`, `on_blocked`, `on_down`, `on_up`  
> **Last updated:** September 30, 2026 (`M-1`)

---

## 1. Core Mental Model: `ctx`, `self()`, `item()`, and Zero-Argument Calls

When a simulation hook runs, **two simulation entities** are naturally involved:

| Helper | Alias | What It Refers To | Example |
|---|---|---|---|
| **`self()`** | `self_handle()` | The **owner entity** onto which you attached the hook (e.g. `Server_1`, `Conveyor_1`, `Queue_A`, `Cell_1`). | Inside `Server_1`'s `on_entry` hook, `self()` is `Server_1`. |
| **`item()`** | `item_handle()` | The **flowing entity** (product, part, pallet, vehicle, order) that triggered the hook right now. | When `Product #42` enters `Server_1`, `item()` is `Product #42`. |
| **`ctx`** | `current_ctx()` | The lightweight `HookContext` packet carrying the simulation world, Future Event List (FEL), current clock `ctx.t`, `self()`, and `item()`. | Passed automatically as the first argument to every hook. |

### Why Zero-Argument Calls Work Inside Hooks
Before invoking your hook, the engine binds the active `HookContext` to a task-local pointer (`SimCore.with_hook_context(ctx)`). Therefore, **passing `ctx` is completely optional inside any hook**:

1. **Zero-argument station/structural queries default to `self()`:**
   - `queue_length()` $\equiv$ `queue_length(self())` $\equiv$ `queue_length(ctx, self())`
   - `utilization()` $\equiv$ `utilization(self())` $\equiv$ `utilization(ctx, self())`
   - `container_entity()` $\equiv$ `container_entity(self())` $\equiv$ `container_entity(ctx, self())`
   - `contained_entities()` $\equiv$ `contained_entities(self())` $\equiv$ `contained_entities(ctx, self())`
   - `set_speed!(2.0)` $\equiv$ `set_speed!(self(), 2.0)` $\equiv$ `set_speed!(ctx, self(), 2.0)`
2. **Zero-argument item/visual/attribute mutations default to `item()` (falling back to `self()` if no item is present):**
   - `set_color!(:red)` $\equiv$ `set_color!(item(), :red)`
   - `set_priority!(10)` $\equiv$ `set_priority!(item(), 10)`
   - `attr("lot_id")` $\equiv$ `attr(item(), "lot_id")`
   - `set_attr!("inspected", true)` $\equiv$ `set_attr!(item(), "inspected", true)`
   - `wait_time()` $\equiv$ `wait_time(item())`
   - `distance()` / `progress()` $\equiv$ `distance(item())` / `progress(item())`

---

## 2. High-Scale Performance: Unboxed `EntityHandle` & Batch Vectorization

Looking up entities by `String` name inside inner loops across thousands of entities incurs hash/string overhead. `SimCore.SimViz` uses a **64-bit unboxed `EntityHandle`** (`isbits`, zero heap allocation):

```julia
struct EntityHandle
    id   :: Int32  # 1-based dense index or runtime entity ID
    kind :: UInt8  # 1 = station/conveyor/queue, 2 = flowing item, 3 = container/subgraph
end
```

### Composable Selectors & Batch Mutations
Every mutator (`set_speed!`, `pause!`, `resume!`, `set_capacity!`, `set_servers!`, `set_attr!`, `set_color!`, `set_priority!`, `set_conveyor_mode!`) accepts either a **single `EntityHandle`** or a **`Vector{EntityHandle}`**:

```julia
# 1. Set speed of ALL conveyors in the entire model in O(N) with zero string lookups:
set_speed!(entities_of_kind(:conveyor), 2.0)

# 2. Set speed of all conveyors in a named group:
set_speed!(entities_in_group(:Packaging_Line), 2.5)

# 3. Set speed of all conveyors matching a predicate:
set_speed!(entities_where(e -> length(contained_entities(e)) > 3; kind=:conveyor), 3.0)

# 4. Pause all upstream entities connected to this block's :in_flow port:
pause!(connected_entities(:in_flow))
```

---

## 3. Strictly Directional Ports (`:in` / `:out`) & Particular Connected-Entity Selectors

Every port on an entity has a strict direction (`:in` or `:out`), a domain (`:flow`, `:signal`, `:event`, `:metric`), and an ordered **1-based slot list `[1..N]`** matching the `[▲][▼]` priority order in the GUI **Channel Manager Popup**.

```
                   ┌────────────────────┐
  Queue_1 ──[1]───►│                    │──[1]──► Server_Fast (Main Line)
  Queue_2 ──[2]───►│ in_flow   out_flow │──[2]──► Server_Rework (Rework Line)
  Queue_3 ──[3]───►│     (Inspector)    │──[3]──► Sink_Scrap (Scrap Bin)
                   └────────────────────┘
```

### Referring to a Particular Connected Entity on a Multi-Wire Port

| Selection Pattern | Example Call | Meaning |
|---|---|---|
| **By 1-Based Slot Index** | `connected_entity(:out_flow, 2)` | The entity wired to **Slot #2** of `self()`'s `:out_flow` port (`Server_Rework`). |
| **By Predicate (`_where`)** | `connected_entity_where(:out_flow, e -> !is_full(e) && !is_down(e))` | First connected entity on `:out_flow` (in slot order `1..N`) that is neither full nor down. |
| **All Matching (`_entities_where`)** | `connected_entities_where(:out_flow, e -> !is_down(e))` | Vector of all operational connected entities on `:out_flow`. |
| **By Minimum Score (`_argmin`)** | `connected_entity_argmin(:out_flow, e -> queue_length(e))` | Connected entity on `:out_flow` with the **shortest queue**. |
| **By Maximum Score (`_argmax`)** | `connected_entity_argmax(:out_flow, e -> free_capacity(e))` | Connected entity on `:out_flow` with the **most free capacity**. |

---

## 4. Symmetric Containment Hierarchy (`container_entity` & `contained_entities`)

Containment in SimViz is **100% uniform** across three physical scales:
1. **Subgraph / Zone / Cell $\to$ Stations & Conveyors** (`Welding_Cell_A` contains `Welder_1`, `Welder_2`).
2. **Station / Queue / Conveyor $\to$ Flowing Items** (`Welder_1` contains the items currently in service or queued inside it).
3. **Composite Carrier / Pallet / Batch $\to$ Sub-Items** (`Pallet_10` contains `Box_1`, `Box_2` placed inside it via `put_inside!`).

### A. Upward Navigation ("Who Contains Me?") — Shortest to Longest Flavors

| Flavor | Call | Meaning |
|---|---|---|
| **1. Shortest (Zero-Arg)** | `c = container_entity()` | Container of **`self()`** (e.g., `Welding_Cell_A` containing `Welder_1`). |
| **2. Flowing Item's Container** | `c = container_entity(item())` | Station/conveyor/pallet currently holding **`item()`**. |
| **3. Explicit Handle** | `c = container_entity(target_h)` | Immediate container of `target_h`. |
| **4. Chained Grandparent** | `g = container_entity(container_entity(item()))` | Two levels up (e.g., `Item -> Welder_1 -> Welding_Cell_A`). |
| **5. Outermost Root** | `r = root_container(item())` | Outermost container (e.g., `Plant_North`). |
| **6. Full Ancestor Chain** | `chain = ancestors(item())` | `[Welder_1, Welding_Cell_A, Plant_North]` from innermost to outermost. |
| **7. Longest (Explicit `ctx`)** | `c = container_entity(ctx, entity_handle(ctx, "Welder_1"))` | Fully explicit form usable inside standalone Julia functions outside hooks. |

### B. Downward Navigation ("What Do I Contain?") — Shortest to Longest Flavors

| Flavor | Call | Meaning |
|---|---|---|
| **1. Shortest (All Children)** | ` list = contained_entities()` | All entities currently inside **`self()`** (in-service first, queued second). |
| **2. Count & Membership** | `n = contained_count()` / `contains_entity(item())` | Number of entities inside `self()` / check if `item()` is inside `self()`. |
| **3. Filtered by State** | `contained_entities(filter=:queued)` / `contained_entities(filter=:in_service)` | Only waiting items or only active in-service items inside `self()`. |
| **4. Positional (`1..K`)** | `first_contained()` / `last_contained()` / `contained_entity(2)` | First, last, or $k$-th entity inside `self()`. |
| **5. Predicate Search** | `contained_entity_where(e -> priority(e) > 5)` | First entity inside `self()` matching predicate. |
| **6. Argmin / Argmax** | `contained_entity_argmin(e -> due_date(e))` | Entity inside `self()` with earliest due date. |
| **7. Dynamic Palletizing** | `put_inside!(pallet, box)` / `take_out!(pallet, box)` | Dynamically load or unload child entities into/from a container entity. |

---

## 5. Multi-Queue Intake / Pull Selection (`:in_flow` Bus `[1..N]`)

When a **Server** has multiple **Queues** wired into its `:in_flow` bus (`Slot 1..N`), you can select the intake policy via the GUI dropdown (`intake_mode`: `slot_order`, `round_robin`, `longest_queue`, `highest_fill`, `custom`) or script custom pull logic inside the **`on_pull`** hook:

```julia
# 1. Built-in one-liner pulls inside on_pull:
pull_from_port!(:in_flow, 1)              # Pull specifically from Slot #1
pull_from_port_slot_order!(:in_flow)      # Pull from highest-priority non-empty slot [1..N]
pull_from_port_round_robin!(:in_flow)     # Cyclic fair turn-taking across slots
pull_from_port_longest!(:in_flow)         # Pull from upstream queue with most waiting items
pull_from_port_highest_fill!(:in_flow)    # Pull from upstream queue closest to full capacity

# 2. Custom predicate / scoring pulls across all connected upstream queues:
pull_from_port_where!(:in_flow, c -> attr(c, :grade) == "VIP")
pull_from_port_argmin!(:in_flow, c -> due_date(c.item))
pull_from_port_argmax!(:in_flow, c -> c.priority * 100.0 + c.wait_time)
```

Each candidate `c::PortCandidate` passed to your closure exposes:
- `c.slot::Int` — 1-based slot index on `:in_flow`
- `c.queue::EntityHandle` — upstream queue handle
- `c.item::EntityHandle` — candidate waiting item handle
- `c.priority::Int` — item priority
- `c.wait_time::Float64` — seconds waited in that upstream queue
- `c.queue_length::Int` & `c.fill_ratio::Float64` — upstream queue congestion metrics

---

## 6. Complete 13-Category API Reference (`>110` Primitives)

> **Tip:** At runtime or in the Julia REPL, call `list_simviz_helpers()` (or `list_simviz_helpers(category=:ports)`) to inspect `SimCore.SimViz.HELPER_CATALOG`, or type `?func_name` to read the docstring.

### Category 1: Identity & Topology Selectors (`:identity`)
| Function | Signature | Description |
|---|---|---|
| `self` / `self_handle` | `self([ctx]) -> EntityHandle` | Handle of the entity owning the hook. |
| `self_id` | `self_id([ctx]) -> String` | String ID of the entity owning the hook. |
| `item` / `item_handle` | `item([ctx]) -> EntityHandle` | Handle of the flowing entity that triggered the hook. |
| `item_id` | `item_id([ctx]) -> Int` | Numeric ID of the flowing entity (`0` if none). |
| `entity_handle` / `entity` | `entity_handle([ctx,] name_or_id) -> EntityHandle` | Resolve `EntityHandle` from name (`String`/`Symbol`) or ID. |
| `entity_name` | `entity_name([ctx,] [handle=self()]) -> String` | String name of an `EntityHandle`. |
| `entity_kind` | `entity_kind([ctx,] [handle=self()]) -> Symbol` | Kind symbol (`:server`, `:conveyor`, `:queue`, `:source`, `:sink`, `:item`). |
| `entities_of_kind` | `entities_of_kind([ctx,] kind::Symbol) -> Vector{EntityHandle}` | All entities of a kind (`:conveyor`, `:server`, `:queue`, `:item`). |
| `entities_where` | `entities_where([ctx,] pred::Function; kind=nothing) -> Vector{EntityHandle}` | All entities satisfying `pred(e)`. |
| `entities_in_group` | `entities_in_group([ctx,] group_tag) -> Vector{EntityHandle}` | All entities belonging to a named group. |
| `all_entities` | `all_entities([ctx]) -> Vector{EntityHandle}` | All registered scene entities. |

### Category 2: Ports & Connected-Entity Selectors (`:ports`)
| Function | Signature | Description |
|---|---|---|
| `ports` | `ports([ctx,] [owner=self()]; dir=:all, domain=:all) -> Vector{Symbol}` | List port names on `owner`. |
| `input_ports` / `output_ports` | `input_ports([ctx,] [owner=self()]; domain=:all) -> Vector{Symbol}` | List `:in` or `:out` ports on `owner`. |
| `has_port` | `has_port([ctx,] [owner=self(),] port_name) -> Bool` | True if `owner` has `port_name`. |
| `port_direction` / `port_domain` | `port_direction([ctx,] [owner=self(),] port_name) -> Symbol` | Direction (`:in`/`:out`) or domain (`:flow`/`:signal`/`:event`/`:metric`). |
| `port_cardinality` | `port_cardinality([ctx,] [owner=self(),] port_name) -> Int` | Maximum wires allowed on port. |
| `is_connected` / `connection_count` | `connection_count([ctx,] [owner=self(),] port_name) -> Int` | Check connectivity or number of active wires on port. |
| `connected_ports` | `connected_ports([ctx,] [owner=self(),] port_name) -> Vector{PortWireLink}` | Ordered wire descriptors in slot order `[1..N]`. |
| `connected_entities` | `connected_entities([ctx,] [owner=self(),] port_name) -> Vector{EntityHandle}` | All peer entities wired to `port_name` in slot order `[1..N]`. |
| `connected_entity` | `connected_entity([ctx,] [owner=self(),] port_name, slot=1) -> EntityHandle` | Peer entity wired to specific 1-based `slot`. |
| `connected_entity_where` | `connected_entity_where([ctx,] [owner,] port_name, pred) -> EntityHandle` | First connected entity on `port_name` satisfying `pred(e)`. |
| `connected_entities_where` | `connected_entities_where([ctx,] [owner,] port_name, pred) -> Vector{EntityHandle}` | All connected entities on `port_name` satisfying `pred(e)`. |
| `connected_entity_argmin` | `connected_entity_argmin([ctx,] [owner,] port_name, score_fn) -> EntityHandle` | Connected entity minimizing `score_fn(e)`. |
| `connected_entity_argmax` | `connected_entity_argmax([ctx,] [owner,] port_name, score_fn) -> EntityHandle` | Connected entity maximizing `score_fn(e)`. |
| `upstream_entities` / `downstream_entities` | `upstream_entities([ctx,] [owner=self()]) -> Vector{EntityHandle}` | Shorthand for `connected_entities(owner, :in_flow)` / `:out_flow`. |
| `send_signal!` / `read_signal` | `send_signal!([ctx,] [owner,] out_port, value)` | Propagate or read scalar/Dict value across a signal port. |
| `emit_port_event!` | `emit_port_event!([ctx,] [owner,] out_event_port, payload=nothing)` | Trigger an immediate event on all peers wired to `out_event_port`. |

### Category 3: Containment Hierarchy (`:containment`)
| Function | Signature | Description |
|---|---|---|
| `container_entity` | `container_entity([ctx,] [target=self()]) -> EntityHandle` | Immediate parent container of `target` (or `INVALID_HANDLE`). |
| `root_container` | `root_container([ctx,] [target=self()]) -> EntityHandle` | Outermost container of `target`. |
| `ancestors` | `ancestors([ctx,] [target=self()]) -> Vector{EntityHandle}` | Chain of enclosing containers `[parent, grandparent, ...]`. |
| `has_container` | `has_container([ctx,] [target=self()]) -> Bool` | True if `target` has an enclosing container. |
| `contained_entities` | `contained_entities([ctx,] [holder=self()]; filter=:all) -> Vector{EntityHandle}` | Entities inside `holder` (`:all`, `:in_service`, `:queued`). |
| `contained_count` | `contained_count([ctx,] [holder=self()]; filter=:all) -> Int` | Number of entities currently inside `holder`. |
| `contains_entity` | `contains_entity([ctx,] [holder=self(),] child; recursive=false) -> Bool` | True if `child` is inside `holder`. |
| `contained_entity` | `contained_entity([ctx,] [holder=self(),] index=1; filter=:all) -> EntityHandle` | $k$-th entity inside `holder`. |
| `first_contained` / `last_contained` | `first_contained([ctx,] [holder=self()]; filter=:all) -> EntityHandle` | First or last entity inside `holder`. |
| `contained_entity_where` | `contained_entity_where([ctx,] [holder,] pred; filter=:all) -> EntityHandle` | First entity inside `holder` satisfying `pred(e)`. |
| `contained_entities_where` | `contained_entities_where([ctx,] [holder,] pred; filter=:all) -> Vector{EntityHandle}` | All entities inside `holder` satisfying `pred(e)`. |
| `contained_entity_argmin` / `argmax` | `contained_entity_argmin([ctx,] [holder,] score_fn; filter=:all) -> EntityHandle` | Entity inside `holder` minimizing/maximizing `score_fn(e)`. |
| `put_inside!` / `take_out!` | `put_inside!([ctx,] container, child)` | Dynamically attach/detach `child` inside `container`. |

### Category 4: Multi-Queue Pull / Intake (`:intake`)
| Function | Signature | Description |
|---|---|---|
| `port_head_items` / `port_all_items` | `port_head_items([ctx,] [owner=self(),] in_port=:in_flow) -> Vector{PortCandidate}` | Inspect head waiting items or all waiting items across `:in_flow` slots. |
| `pull_from_port!` | `pull_from_port!([ctx,] in_port=:in_flow, slot=1) -> EntityHandle` | Pull head item from specific 1-based `slot`. |
| `pull_from_port_slot_order!` | `pull_from_port_slot_order!([ctx,] in_port=:in_flow) -> EntityHandle` | Pull from highest-priority non-empty slot `[1..N]`. |
| `pull_from_port_round_robin!` | `pull_from_port_round_robin!([ctx,] in_port=:in_flow) -> EntityHandle` | Cyclic fair pull across connected queues. |
| `pull_from_port_longest!` | `pull_from_port_longest!([ctx,] in_port=:in_flow) -> EntityHandle` | Pull from upstream queue with largest `queue_length`. |
| `pull_from_port_highest_fill!` | `pull_from_port_highest_fill!([ctx,] in_port=:in_flow) -> EntityHandle` | Pull from upstream queue with highest `fill_ratio`. |
| `pull_from_port_where!` | `pull_from_port_where!([ctx,] in_port, pred; scope=:heads) -> EntityHandle` | Pull first candidate satisfying `pred(c::PortCandidate)`. |
| `pull_from_port_argmin!` / `argmax!` | `pull_from_port_argmax!([ctx,] in_port, score_fn; scope=:heads) -> EntityHandle` | Pull candidate minimizing/maximizing `score_fn(c::PortCandidate)`. |
| `set_intake_mode!` | `set_intake_mode!([ctx,] [target=self(),] mode::Symbol)` | Switch intake policy at runtime (`:slot_order`, `:round_robin`, `:longest_queue`, `:highest_fill`, `:custom`). |

### Category 5: Attributes & Scheduling Metadata (`:attributes`)
| Function | Signature | Description |
|---|---|---|
| `attr` / `get_attr` / `get_attribute` | `attr([ctx,] [target,] key, default=nothing)` | Read dynamic attribute from `target` (defaults to `item()` then `self()`). |
| `num_attr` / `str_attr` / `bool_attr` | `num_attr([ctx,] [target,] key, default=0.0) -> Float64` | Typed attribute getters. |
| `has_attr` / `has_attribute` | `has_attr([ctx,] [target,] key) -> Bool` | True if attribute `key` exists on `target`. |
| `set_attr!` / `set_attribute!` | `set_attr!([ctx,] [target,] key, value)` | Set attribute on single entity or `Vector{EntityHandle}` batch. |
| `inc_attr!` / `increment_attribute!` | `inc_attr!([ctx,] [target,] key, delta=1)` | Increment numeric attribute by `delta`. |
| `delete_attr!` / `clear_attrs!` | `delete_attr!([ctx,] [target,] key)` | Remove one or all attributes from `target`. |
| `priority` / `set_priority!` | `set_priority!([ctx,] [target=item(),] new_priority::Int)` | Read or update scheduling priority (and re-sort queue if waiting). |
| `arrival_time` / `wait_time` | `wait_time([ctx,] [target=item()]) -> Float64` | Arrival timestamp or elapsed waiting time at current station. |
| `due_date` / `slack` / `critical_ratio` | `slack([ctx,] [target=item()]) -> Float64` | EDD due date, remaining slack `due_date - t`, or critical ratio. |

### Category 6: State & Capacity Queries (`:state`)
| Function | Signature | Description |
|---|---|---|
| `queue_length` / `in_service` | `queue_length([ctx,] [target=self()]) -> Int` | Waiting queue count or active in-service count. |
| `num_servers` / `capacity` / `free_capacity` | `free_capacity([ctx,] [target=self()]) -> Int` | Parallel servers, max buffer capacity, or remaining free slots. |
| `utilization` / `fill_ratio` | `utilization([ctx,] [target=self()]) -> Float64` | Busy server ratio `[0, 1]` or buffer occupancy ratio `[0, 1]`. |
| `is_full` / `is_empty` / `is_busy` / `is_down` | `is_full([ctx,] [target=self()]) -> Bool` | Boolean state predicates on any station/queue/conveyor. |
| `queued_entities` / `head_entity` / `tail_entity` | `head_entity([ctx,] [target=self()]) -> EntityHandle` | Inspect waiting items in queue order. |
| `shortest_entity` / `least_utilized_entity` | `shortest_entity([ctx,] candidates) -> EntityHandle` | Pick candidate with smallest `queue_length` or `utilization`. |

### Category 7: Station Control & Actuation (`:control`)
| Function | Signature | Description |
|---|---|---|
| `set_capacity!` / `set_servers!` | `set_capacity!([ctx,] [target=self(),] new_cap::Int)` | Dynamically resize buffer capacity or server count (single or batch). |
| `pause!` / `resume!` | `pause!([ctx,] [target=self()])` | Pause or resume station/conveyor/source (single or batch). |
| `trigger_failure!` / `trigger_repair!` | `trigger_failure!([ctx,] [target=self(),] repair_duration=0.0)` | Force station breakdown or immediate repair. |
| `flush_queue!` | `flush_queue!([ctx,] [target=self()]; dest=:exit)` | Flush all queued items to `dest` or `:exit`. |

### Category 8: Routing & Flow Control (`:routing`)
| Function | Signature | Description |
|---|---|---|
| `route_to!` | `route_to!([ctx,] target)` | Redirect departing item to `target` (`EntityHandle`, name, or `:exit`). |
| `route_to_port!` | `route_to_port!([ctx,] out_port=:out_flow, slot=1)` | Route departing item via specific output port `slot`. |
| `route_to_shortest!` / `route_to_fastest!` | `route_to_shortest!([ctx,] [candidates])` | Route departing item to candidate with shortest queue or lowest utilization. |
| `exit_system!` | `exit_system!([ctx])` | Route departing item out of the system. |
| `hold_entity!` / `release_entity!` | `hold_entity!([ctx,] [target=item(),] duration)` | Hold or release an entity. |
| `preempt_server!` | `preempt_server!([ctx,] [station=self()])` | Preempt current item in service. |
| `clone_entity!` / `batch_entities!` / `unbatch_entity!` | `batch_entities!([ctx,] count::Int)` | Clone, batch waiting items into a parent, or unbatch children. |

### Category 9: Custom Server Construction (`:server`)
| Function | Signature | Description |
|---|---|---|
| `set_service_time!` | `set_service_time!([ctx,] duration::Real)` | Override service duration `[s]` for the current item. |
| `add_setup_time!` | `add_setup_time!([ctx,] extra_duration::Real)` | Add sequence-dependent setup/changeover time `[s]`. |
| `last_processed_attr` | `last_processed_attr([ctx,] [station=self(),] key, default=nothing)` | Read attribute of the previous item processed at `station`. |
| `start_service!` / `complete_service!` | `start_service!([ctx,] [target=item()]; duration=nothing)` | Explicitly start or finish service on an item. |
| `seize_capacity!` / `release_capacity!` | `seize_capacity!([ctx,] [station=self(),] units=1) -> Bool` | Manually acquire or release server capacity units. |
| `dequeue_where!` | `dequeue_where!([ctx,] [station=self(),] pred::Function) -> EntityHandle` | Dequeue and start service on the first waiting item matching `pred(e)`. |

### Category 10: Low-Level DEVS Event Scheduling (`:events`)
| Function | Signature | Description |
|---|---|---|
| `set_process_mode!` | `set_process_mode!([ctx,] [target=self(),] mode::Symbol)` | Set `:standard` or `:custom` FEL event control mode. |
| `schedule_event!` | `schedule_event!([ctx,] [owner=self(),] tag::Symbol, delay::Real; payload=nothing)` | Schedule a `CustomUserEvent` on the FEL after `delay` seconds (also accepts `(delay, tag)`). |
| `schedule_at!` | `schedule_at!([ctx,] [owner=self(),] tag::Symbol, abs_time::Real; payload=nothing)` | Schedule a `CustomUserEvent` at absolute simulation time `abs_time`. |
| `schedule_every!` | `schedule_every!([ctx,] [owner=self(),] tag::Symbol, interval::Real; payload=nothing)` | Schedule a periodic repeating `CustomUserEvent` every `interval` seconds. |
| `cancel_event!` / `cancel_all_events!` | `cancel_event!([ctx,] event_id::Integer)` | Cancel a scheduled FEL event by ID or all custom events on `owner`. |
| `event_tag` / `event_payload` | `event_tag([ctx]) -> Symbol` | Inspect the tag or payload of the currently firing `CustomUserEvent` inside `on_event`. |
| `after!` | `after!(fn::Function, [ctx,] delay::Real)` | Schedule a Julia closure `do c ... end` to run after `delay` seconds. |
| `forward_entity!` | `forward_entity!([ctx,] [target=item()]; to=nothing, port=:out_flow, slot=1)` | Immediately dispatch `target` to a downstream entity or port slot. |

### Category 11: Spatial & Conveyor Kinematics (`:kinematics`)
| Function | Signature | Description |
|---|---|---|
| `set_conveyor_mode!` | `set_conveyor_mode!([ctx,] [conv=self(),] mode::Symbol; pitch=0.5, index_interval=1.0)` | Set `:free_flow`, `:accumulating` (with `pitch` `[m]`), or `:indexing` (with `pitch` and `index_interval` `[s]`). |
| `path_length` | `path_length([ctx,] [conv=self()]) -> Float64` | Physical arc-length `[m]` of conveyor. |
| `distance` / `progress` | `distance([ctx,] [target=item()]) -> Float64` | Traveled distance `[m]` or normalized progress `[0, 1]` along conveyor. |
| `speed` / `set_speed!` | `set_speed!([ctx,] [target=self(),] new_speed::Real)` | Query or update speed `[m/s]` of a conveyor, item, or `Vector{EntityHandle}` batch. |
| `set_distance!` / `set_progress!` / `step_distance!` | `step_distance!([ctx,] [target=self(),] delta_m::Real)` | Set or advance position along conveyor path. |
| `entities_along_path` | `entities_along_path([ctx,] [conv=self()]) -> Vector{EntityHandle}` | Items on `conv` sorted front-to-back (outlet to inlet). |
| `entity_ahead` / `entity_behind` / `gap_ahead` | `gap_ahead([ctx,] [target=item()]) -> Float64` | Inspect neighboring items on the belt and physical clearance `[m]` ahead. |
| `world_pos` / `set_world_pos!` / `distance_between` | `world_pos([ctx,] [target=item()]) -> NTuple{3, Float64}` | Read/override 3D world position `(x, y, z)` or compute 3D Euclidean distance. |

### Category 12: Dynamic Entity & Component Creation (`:creation`)
| Function | Signature | Description |
|---|---|---|
| `define_entity_type!` | `define_entity_type!([ctx,] type_name::Symbol; mesh=:box, color=:cyan, size=1.0, default_attrs=Dict())` | Register a reusable runtime entity template. |
| `create_entity!` | `create_entity!([ctx,] entity_type=:product; priority=0, attrs...) -> EntityHandle` | Dynamically create a new flowing entity in `SimWorld`. |
| `spawn_to_port!` | `spawn_to_port!([ctx,] entity_type=:product, out_port=:out_flow; slot=1, priority=0, attrs...) -> EntityHandle` | Create and inject a new entity out of `out_port` `slot`. |
| `destroy_entity!` | `destroy_entity!([ctx,] [target=item()])` | Remove a flowing entity from the simulation. |
| `combine_entities!` | `combine_entities!([ctx,] handles::Vector{EntityHandle}; new_type=:assembly) -> EntityHandle` | Combine multiple entities into a composite assembly. |
| `split_entity!` | `split_entity!([ctx,] [parent=item(),] count::Int; child_type=:subpart, out_port=:out_flow) -> Vector{EntityHandle}` | Split an entity into `count` child entities. |

### Category 13: Visuals, Seeded Randomness & Custom Telemetry (`:visuals`, `:random`, `:telemetry`)
| Function | Signature | Description |
|---|---|---|
| `set_color!` / `set_mesh!` / `set_size!` | `set_color!([ctx,] [target=item(),] color)` | Live 2D/3D visual overrides (`:red`, `:green`, `:gold`, `"#ff8800"`, or `(r,g,b)`). |
| `set_label!` / `highlight!` | `set_label!([ctx,] [target=item(),] text)` | Floating text badge override or timed visual highlight pulse. |
| `sim_time` / `rng` | `sim_time([ctx]) -> Float64` | Current simulation clock `[s]` or seeded RNG stream. |
| `rand_uniform` / `rand_exp` / `rand_normal` / `rand_triangular` | `rand_triangular([ctx,] min_v, mode_v, max_v) -> Float64` | Reproducible continuous random variates from the simulation's seeded RNG. |
| `rand_int` / `rand_choice` / `coin_flip` | `rand_choice([ctx,] items, [weights])` | Reproducible discrete random variates. |
| `record_metric!` / `increment_counter!` / `set_gauge!` | `record_metric!([ctx,] name, value)` | Record custom time-series metrics, counters, and scalar gauges streamed to the GUI. |
| `record_histogram!` / `record_tally!` / `log_event!` | `log_event!([ctx,] message)` | Record custom distributions, running averages, and timestamped log entries. |
