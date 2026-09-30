# SimViz Simulation Customization — Architecture & Roadmap

> **Document scope:** Code design, user exposure, GUI interface, and phased roadmap
> for making SimViz a fully customizable simulation platform.
> Originally drafted: September 25, 2026 (Phase 7D-12C).
> **Last updated:** September 30, 2026 (post Phase 7E / 7F / 7G, Immediate Actions `I-1`–`I-4`, and `M-1` `SimViz` Helper Library implementation).
> **Companion Reference Manual:** [`2026-09-30_simviz_helper_library_reference.md`](./2026-09-30_simviz_helper_library_reference.md)

---

## The Core Problem

SimViz currently gives users two modes:

| Mode | Who it serves | Limitation |
|---|---|---|
| No-code canvas (drag + connect) | Business analysts, non-programmers | Can only express what the GUI exposes |
| Raw Julia scripts | Expert developers | Bypasses the GUI entirely |

**The gap:** A manufacturing engineer who knows their domain deeply but isn't a software developer can't express "send this pallet to rework if it's been waiting more than 30 minutes" in either mode. The no-code canvas doesn't support it, and raw Julia is too steep a climb.

The customization system's job is to **close this gap progressively** — no-code → low-code → full-code — without breaking the people at either end.

---

## Design Principles

1. **Layered access** — Every capability is reachable at multiple abstraction levels. A dropdown is always simpler than a hook, a hook is always simpler than a macro, a macro is always simpler than raw Julia.
2. **Progressive disclosure** — The GUI shows the simplest interface by default. Complexity reveals itself only when the user asks for it.
3. **Safe by default** — User code runs in a controlled context. It cannot corrupt the simulation engine. Exceptions are caught, logged, and isolated.
4. **Inspectable** — Every customization the user makes is visible, editable, and reversible from the GUI. Nothing is buried in a file somewhere.
5. **Composable** — User-defined behaviors can be combined. A hook can call a helper function that fires a signal that triggers a discipline change.
6. **Julia-native** — The customization language IS Julia, not a made-up subset. Users who grow into full Julia can use everything they learn.

---

## The Four Tiers

```
┌─────────────────────────────────────────────────────────────────────┐
│  Tier 4 — Full Julia                                                │
│  Raw SimDES / SimCore code. No constraints. Expert only.            │
├─────────────────────────────────────────────────────────────────────┤
│  Tier 3 — SimViz DSL                                                │
│  @zone, @on_entry, @routing macros. Julia syntax, domain vocab.     │
├─────────────────────────────────────────────────────────────────────┤
│  Tier 2 — Hooks + Helper Library                                    │
│  Event-driven Julia snippets. SimViz.* functions for safe mutation. │
├─────────────────────────────────────────────────────────────────────┤
│  Tier 1 — No-Code Canvas                                           │
│  Dropdowns, sliders, property panels. Zero code required.           │
└─────────────────────────────────────────────────────────────────────┘
```

Each tier builds on the one below. The DSL macros expand into helper function calls. The helper functions are wrappers around the raw Julia engine. The canvas generates scenes that compile to the same IR as hand-written DSL code.

---

## Current State (Updated September 30, 2026 — Post Phase 7G + `I-1`–`I-4` + `M-1`)

### 1. Core Simulation & Authoring Customization Matrix

| Feature | Tier | Status | Implementation Notes |
|---|---|---|---|
| Drag-and-drop block authoring | 1 | ✅ Done | 2D Canvas + 3D Viewport + Undo/Redo command stack |
| Queue discipline dropdown (FIFO/Priority HOL) | 1 | ✅ Done | Native `FIFO` and `PRIORITY_HOL` in `SimDES` |
| Routing rule dropdown (Fixed/Prob/ShortestQ/RR/Dynamic) | 1 | ✅ Done | `FixedRoute`, `ProbRoute`, `ShortestQueueRoute`, `RoundRobinRoute`, `DynamicPolicyRoute` in `SimDES` |
| Multi-stream priority arrivals & custom distributions | 1 | ✅ Done | `CustomArrivalProcess` & `CompositeArrivalProcess` (`des_compiler.jl`) |
| ProductDefinition (color, shape, size) | 1 | ✅ Done | `ProductDefinition` in `ExecutionGraphIR` + `telemetry_adapter.jl` |
| 3D Parametric Conveyor Geometry & Custom Splines | 1 | ✅ Done | Phase 7F: 6 shape presets (`straight`, `curve_90`, `curve_180`, `s_curve`, `incline`, `helix`), custom 3D splines, $C^1$ junction docking (`conveyor_curve.jl`, `conveyor_3d_builder.gd`) |
| Multi-Wire Bus Ports & Channel Manager Popup | 1 | ✅ Done | Phase 7G: Unlimited fan-in/fan-out flow ports, right-click `SimVizAuthoringChannelPopup` with `[▲][▼]` priority reordering, live flow rates, and `[✕]` disconnect |
| Custom Connection Wire Shapes & Interactive Waypoints | 1 | ✅ Done | Phase 7G: Port-normal aware `bezier`, `orthogonal`, `chamfer` (45°), and `straight` wires, scene-wide default wire shape dropdown, draggable `●` waypoints & `⊕` segment handles, and right-click `SimVizAuthoringWirePopup` (stroke style, width, curvature/radius, color override) |
| Live 2D Canvas Entity & Telemetry Visualization | 1 | ✅ Done | Phase 7G: Real-time entities inside queues (`+N` overflow pill), servers (progress arcs), and conveyors, plus compact pill badges & hover telemetry cards |
| Simulation-Based Optimization (`SimOptim` + Studio UI) | 1–2 | ✅ Done | Phase 7E: Parameter, policy threshold (`DynamicPolicyRoute`), and bilevel graph + 3D/2D spatial coordinate optimization via `SciMLBase.OptimizationProblem` + live Optimization Studio |
| Curated Examples Catalog & GUI Switcher | 1 | ✅ Done | Phase 7E: 3 flagship optimization/routing scenarios in `examples_catalog.jl` + top-bar Example Picker |
| `on_entry/exit/service_*` hooks + `HookContext` | 2 | ✅ Done | `ZoneHooks` + `HookContext` (`zone_hooks.jl`), supports both `(ctx::HookContext)` and legacy `(entity_id, zone_id, t)` |
| Hook code editor + Quick Presets in Floating Inspector | 2 | ✅ Done | `authoring_floating_inspector.gd` (with 1-click presets & `HookContext` reference) |
| Hook hot-swap without restart | 2 | ✅ Done | `set_hook` command in `live_simulation_server.jl` + SceneSpec `properties["hooks"]` compilation |
| Condition-Based Routing (no hook required) | 1–2 | ⚠️ Partial | `DynamicPolicyRoute` closure in `SimDES` + connection `SimVizAuthoringRuleBuilder` UI (`IF metric op threshold`) + `route_to!(ctx, zone)` in hooks (`I-2`); multi-branch inspector dropdown awaits `M-4` |
| EDD / SPT / LIFO discipline | 1 | ✅ Done | Native `LIFO`, `EDD`, `SPT` in `SimDES` (`zone.jl`, `dispatch.jl`), `logic_catalog.jl`, and GUI dropdowns (`I-4`) |
| Entity attributes (user metadata on entities) | 1–2 | ✅ Done | `world.entity_attributes` (`SimCore/src/world.jl`), Source `default_attributes` editor + presets, and Outliner live attribute sub-rows (`I-1`) |
| Hook mutation (`HookContext`: color, mesh, size, priority, routing, attributes) | 2 | ✅ Done | Queued atomic mutations (`set_color!`, `set_mesh!`, `set_size!`, `reset_visual!`, `set_attribute!`, `set_priority!`, `route_to!`) applied after hook return and propagated to 2D/3D telemetry (`I-2`, `I-3`) |
| Custom discipline as comparator closure | 2 | ✅ Done | `custom_discipline` comparator `(entity_a, entity_b) -> Bool` in `ZoneConfig` (`SimDES`), `parse_discipline_expr`, and Queue Inspector / Rule Panel editors (`I-4`) |
| `SimViz.*` helper library (`>100` primitives across 13 categories) | 2 | ✅ Done | Implemented in `SimCore/src/simviz_helpers.jl` (`SimCore.SimViz`), auto-imported into all hooks (`M-1`) |
| Inter-zone signaling (`send_signal!`, `read_signal`, `emit_port_event!`) | 2 | ✅ Done | Directional port signaling & event pulses implemented in `M-1` (`M-2` GUI wiring next) |
| Programmable live variable panel (`record_metric!`, `increment_counter!`, `set_gauge!`) | 2 | ⚠️ Partial | Backend `UserTelemetryStore` & snapshot export implemented in `M-1`; dedicated GUI Variable Panel in `M-3` |
| DSL macros (`@simulation`, `@zone`, `@routing`) | 3 | ❌ Missing | Planned in `F-1` / `F-2` |
| Full REPL/notebook integration | 4 | ❌ Missing | Planned in `F-3` |

---

## Immediate Actions (Completed September 29, 2026) — Status: ✅ Done

> **Audit Note (2026-09-29):** Items **I-1 through I-4** and **M-1** have been implemented end-to-end across `SimCore`, `SimDES`, `GodotBridge`, and the Godot Authoring GUI (Floating Inspector, Rule Panel, Outliner, and 2D/3D Telemetry).

### I-1 · Entity Attribute Bag (✅ Done)

**What:** Every simulation entity carries a `Dict{String, Any}` of user-defined metadata in `SimWorld.entity_attributes` (`SimCore/src/world.jl`), exposed via `EntityState` and `get_attribute` / `has_attribute`.

**Why first:** Every other feature depends on this. You can't route by "batch type" if entities don't have a "batch type" field. You can't implement EDD without a "due_date" attribute.

**Code design (Julia):**

```julia
# SimCore/src/world.jl:
struct EntityState
    id::Int
    arrival_time::Float64
    priority::Int
    service_start_time::Float64
    attributes::Dict{String, Any}
end
```

**GUI exposure (Implemented):**
- **Source Block Inspector (`authoring_floating_inspector.gd`):** Dedicated **"DEFAULT ENTITY ATTRIBUTES (METADATA BAG)"** section with 1-click preset buttons (`+ Batch ID`, `+ Due Date (EDD)`, `+ Est. Service (SPT)`, `+ Custom Key`), inline key/value editing, and support for `"auto_increment"`, `"due_date_offset"`, `"rand_uniform(a,b)"`, `"rand_int(a,b)"`, and literal values.
- **Model Outliner (`authoring_outliner.gd`):** Live entity rows display custom attribute summaries (`[batch_id=2, due_date=51.0]`) and expand to show individual `• key: value` child items.

**SceneSpec JSON:**
```json
{
  "id": "src1",
  "kind": "source",
  "properties": {
    "default_attributes": {
      "batch_id": "auto_increment",
      "priority": 1,
      "due_date_offset": 120.0
    }
  }
}
```

---

### I-2 · HookContext — Safe Mutation API (✅ Done)

**What:** Upgraded [`zone_hooks.jl`](../packages/GodotBridge/src/runtime/zone_hooks.jl) with a `HookContext` object that provides safe, validated, queued mutation methods applied atomically after the hook returns, while maintaining full backward compatibility with legacy `(entity_id, zone_id, t)` hooks.

**Code design (Julia):**

```julia
mutable struct HookContext
    entity_id::Int
    zone_id::String
    t::Float64
    _world_ref::Union{Nothing, SimCore.SimWorld}
    _pending_mutations::Vector{Tuple{Symbol, Any}}
end

# Safe mutation methods — queued during execution and applied atomically via apply_hook_mutations!
set_color!(ctx::HookContext, r::Real, g::Real, b::Real)
set_color!(ctx::HookContext, name::Union{Symbol, AbstractString}) # :red, :amber, :green, :blue, :purple, :cyan, :orange
set_mesh!(ctx::HookContext, shape::Union{Symbol, AbstractString}) # :box, :sphere, :cylinder, :capsule, :pallet, :crate
set_size!(ctx::HookContext, scale::Real)
reset_visual!(ctx::HookContext)
set_priority!(ctx::HookContext, p::Integer)
route_to!(ctx::HookContext, target_zone::Union{String, Symbol, Int})
set_attribute!(ctx::HookContext, key::Union{String, Symbol}, value)
get_attribute(ctx::HookContext, key::Union{String, Symbol}, default=nothing)
has_attribute(ctx::HookContext, key::Union{String, Symbol})::Bool
```

**GUI exposure (Implemented):**
- **Floating Inspector Tab 4 (`🔗 Hooks` in `authoring_floating_inspector.gd`):** Displays the `HookContext` API reference banner, 1-click **Quick Hook Presets** (`🎨 Color by Wait`, `⬆ Boost Priority`, `🏷 Stamp Attr`, `🔀 Reroute`), and persists hooks into both SceneSpec `properties["hooks"]` and live `set_hook` WebSocket commands.

---

### I-3 · Visual Mutation from Hooks (✅ Done)

**What:** `set_color!`, `set_mesh!`, `set_size!`, and `reset_visual!` in `HookContext` write to `world.entity_visuals` and propagate automatically through [`telemetry_adapter.jl`](../packages/GodotBridge/src/runtime/telemetry_adapter.jl) to both the 2D Canvas and 3D Viewport.

**Example (user writes or inserts via `🎨 Color by Wait` preset in Hook Editor):**
```julia
wait_s = t - get_attribute(ctx, "arrival_time", t)
if wait_s > 30.0
    set_color!(ctx, :red)
elseif wait_s > 10.0
    set_color!(ctx, :amber)
else
    set_color!(ctx, :green)
end
```

---

### I-4 · Custom Queue Discipline as Comparator & Native `LIFO` / `EDD` / `SPT` (✅ Done)

**What:** Native `LIFO`, `EDD` (`due_date`), and `SPT` (`estimated_service` / `service_time`) queue disciplines in `SimDES`, plus a user-authored Julia comparator closure `custom_discipline` `(entity_a::EntityState, entity_b::EntityState) -> Bool` in `ZoneConfig`.

**GUI exposure (Implemented):**
- **Queue Inspector (`authoring_floating_inspector.gd`) & Rule Panel (`authoring_rule_panel.gd`):** Queue Discipline dropdown includes `FIFO`, `LIFO`, `Priority`, `EDD`, `SPT`, and `Custom (Julia Comparator)`, with a dedicated **Custom Queue Discipline Comparator** code editor and 1-click presets (`Preset: EDD`, `Preset: SPT`, `Preset: VIP + Aging`).

---

## Mid-Term Actions (1–3 Months)

### M-1 · `SimViz` Helper Library & User Scripting Vocabulary (✅ Done — September 30, 2026)

**What:** A curated, zero-allocation Julia helper library (`SimCore.SimViz`, implemented in [`packages/SimCore/src/simviz_helpers.jl`](../packages/SimCore/src/simviz_helpers.jl)) providing **114 cataloged domain primitives across 13 functional groups**, automatically imported into every user hook (`on_entry`, `on_exit`, `on_service_start`, `on_service_complete`, `on_pull`, `on_event`, `on_blocked`, `on_down`, `on_up`).

- **Reference Manual:** [`docs/2026-09-30_simviz_helper_library_reference.md`](./2026-09-30_simviz_helper_library_reference.md)
- **Verification Suite:** [`packages/GodotBridge/test/test_simviz_helper_library.jl`](../packages/GodotBridge/test/test_simviz_helper_library.jl) (`118 / 118` tests passing)

**Key Architectural Highlights:**
1. **Unboxed 64-bit `EntityHandle` (`O(1)` Addressing) & Batch Vectorization:**
   - `self()` / `self_handle()` (the station/conveyor/queue owning the hook) and `item()` / `item_handle()` (the flowing item that triggered the hook), with implicit zero-argument `current_ctx()` resolution inside hooks.
   - Composable selectors: `entities_of_kind(:conveyor)`, `entities_where(...)`, `entities_in_group(:Zone_A)`, `connected_entities(:out_flow)`, `contained_entities()`.
   - Zero-overhead batch mutations: `set_speed!(entities_of_kind(:conveyor), 2.0)`, `pause!(connected_entities(:in_flow))`.
2. **Strictly Directional Port Topology (`:in` / `:out`, Slots `[1..N]`):**
   - `connected_entity(:out_flow, 2)`, `connected_entity_where`, `connected_entities_where`, `connected_entity_argmin`, `connected_entity_argmax`, `upstream_entities`, `downstream_entities`, `send_signal!`, `read_signal`, `emit_port_event!`.
3. **Symmetric Containment Hierarchy (Upward & Downward):**
   - Upward ("Who Contains Me?"): `container_entity()`, `container_entity(item())`, `root_container()`, `ancestors()`, `has_container()`.
   - Downward ("What Do I Contain?"): `contained_entities()`, `contained_count()`, `contains_entity()`, `contained_entity(k)`, `first_contained()`, `last_contained()`, `contained_entity_where`, `contained_entities_where`, `contained_entity_argmin`, `contained_entity_argmax`, `put_inside!`, `take_out!`.
4. **Multi-Queue Intake / Pull Selection (`:in_flow` Bus `[1..N]`):**
   - `port_head_items`, `port_all_items`, `pull_from_port!`, `pull_from_port_slot_order!`, `pull_from_port_round_robin!`, `pull_from_port_longest!`, `pull_from_port_highest_fill!`, `pull_from_port_where!`, `pull_from_port_argmin!`, `pull_from_port_argmax!`, `set_intake_mode!`.
5. **Custom Server Primitives, Low-Level DEVS Event Engine, Conveyor Kinematics & Dynamic Entity Creation:**
   - Server control: `set_service_time!`, `add_setup_time!`, `last_processed_attr`, `start_service!`, `complete_service!`, `seize_capacity!`, `release_capacity!`, `dequeue_where!`.
   - DEVS FEL scheduling (`CustomUserEvent`): `set_process_mode!(:custom)`, `schedule_event!`, `schedule_at!`, `schedule_every!`, `cancel_event!`, `cancel_all_events!`, `event_tag`, `event_payload`, `after!`, `forward_entity!`.
   - Conveyor kinematics (`EntityKinematics` piecewise-linear $O(1)$ progress): `set_conveyor_mode!(:free_flow | :accumulating | :indexing)`, `path_length`, `distance`, `progress`, `speed`, `set_distance!`, `set_progress!`, `step_distance!`, `set_speed!`, `entities_along_path`, `entity_ahead`, `entity_behind`, `gap_ahead`.
   - Dynamic lifecycle & telemetry: `define_entity_type!`, `create_entity!`, `spawn_to_port!`, `destroy_entity!`, `combine_entities!`, `split_entity!`, `record_metric!`, `increment_counter!`, `set_gauge!`, `record_histogram!`, `record_tally!`, `log_event!`.
6. **Docstrings & Runtime Introspection Catalog (`HELPER_CATALOG`):**
   - All 114 primitives have rich Julia docstrings (`@doc` bound at precompile time for REPL `?` and IDE hover), structured `HelperFunctionMeta` records via `list_simviz_helpers(; category=nothing)`, and Markdown generation via `helper_docs_markdown(; category=nothing)`.

**GUI Exposure (Implemented in [`authoring_catalog.gd`](../godot/scripts/authoring_catalog.gd) & [`authoring_floating_inspector.gd`](../godot/scripts/authoring_floating_inspector.gd)):**
- Conveyor Inspector exposes `conveyor_mode` (`free_flow`, `accumulating`, `indexing`), `accumulation_pitch`, and `index_interval`.
- Server Inspector exposes `intake_mode` (`slot_order`, `round_robin`, `longest_queue`, `highest_fill`, `custom`) and `process_mode` (`standard`, `custom`).
- Hooks Tab (`🔗 Hooks`) includes `on_pull` and `on_event` hooks plus the **📚 Insert SimViz Recipe...** dropdown with 10 ready-to-run recipes.

---

### M-2 · Inter-Zone Signaling & Event Wiring (⚠️ Partial — Backend Done in `M-1`; No-Code GUI Wiring Next)

**What:** A hook in Entity A can send continuous port signals or fire discrete event pulses that Entity B receives across `:out_signal -> :in_signal` and `:out_event -> :in_event` wires, or schedule timed events directly in the Future Event List (FEL).

**What is implemented so far (in `M-1`):**
- **Directional Port Signals & Events (`SimCore.SimViz`):**
  ```julia
  # Continuous signal propagation across :out_signal -> :in_signal wires:
  send_signal!(:out_signal, is_full() ? 1.0 : 0.0)
  if read_signal(:in_signal) > 0.5
      pause!()
  end

  # Discrete event pulse across :out_event -> :in_event wires (or directFEL scheduling):
  emit_port_event!(:out_event, :batch_ready, get_attr(:batch_id))
  schedule_event!(entity_handle("Inspection"), :prepare_jig, 0.0; payload=get_attr(:batch_id))
  ```
- **`CustomUserEvent` in `SimDES` FEL & `on_event` Hook:** `CustomUserEvent` dispatches at exact simulation timestamps and triggers the target entity's `on_event` hook (`event_tag()`, `event_payload()`).

**What remains for `M-2`:**
- Visual signal/event pulse animation along `:signal` and `:event` wires on the 2D canvas and a no-code Signal Trigger builder in the Floating Inspector.

---

### M-3 · Programmable Inspector & Live Variable Panel (⚠️ Partial — Backend & Snapshot Export Done in `M-1`; GUI Dock Next)

**What:** A dedicated panel in the GUI showing user-defined variables, counters, gauges, histograms, and structured event logs in real time.

**What is implemented so far (in `M-1`):**
- **`UserTelemetryStore` in `SimCore` & `SimViz` Primitives:**
  - `record_metric!(name, val)` — time-series `(t, value)` stream
  - `increment_counter!(name, delta=1)` — monotonic integer counter
  - `set_gauge!(name, val)` — instantaneous scalar gauge
  - `record_histogram!(name, val)` & `record_tally!(name, val)` — distribution samples and Welford running mean/variance/min/max
  - `log_event!(msg; level=:info)` — ring-buffered structured simulation log
- **Telemetry Frame Export ([`telemetry_adapter.jl`](../packages/GodotBridge/src/runtime/telemetry_adapter.jl)):** Automatically serializes `user_counters`, `user_gauges`, `user_metrics`, `user_tallies`, and `user_logs` into every live telemetry snapshot sent to Godot.

**What remains for `M-3`:**
- Adding a dedicated **"User Variables & Logs"** tab in the Godot Plot Studio dock and live counter badges in the Model Outliner.

---

### M-4 · Condition-Based Routing (⚠️ Partially Implemented)

**What:** Extend routing to support state-based and attribute-based conditions, expressible without writing code.

**What is implemented so far:**
1. **`DynamicPolicyRoute` in `SimDES` ([`zone.jl`](../packages/SimDES/src/zone.jl), [`dispatch.jl`](../packages/SimDES/src/dispatch.jl)) and [`des_compiler.jl`](../packages/GodotBridge/src/compiler/des_compiler.jl):** Supports state-dependent closure routing (`:dynamic_policy` / `:state_threshold` / `:vip_threshold`) based on `agent.priority`, downstream queue lengths, and server pool utilization.
2. **Connection Rule Builder UI ([`authoring_rule_builder.gd`](../godot/scripts/authoring_rule_builder.gd)):** Provides a no-code `IF <metric> <op> <threshold>` rule editor with live scene metric discovery for connections.
3. **Hook-Based Conditional Routing (`route_to!` in `I-2`):** Hooks can redirect entities by attribute or wait time (`if get_attribute(ctx, "defective", false); route_to!(ctx, "Rework"); end`).

**What remains:**
- Extending the station inspector routing dropdown with no-code multi-branch `IF attribute <op> <value> THEN route to <target> OTHERWISE <default>` rules (now unblocked since `I-1` Entity Attribute Bag is implemented):

```
Routing Rule: [ Conditional ▼ ]

┌─── Conditions ────────────────────────────────────┐
│ IF  attribute: [priority ▼]  >=  [5]              │
│ THEN route to: [FastTrack   ▼]                    │
│                                                    │
│ IF  attribute: [defective   ▼]  ==  [true]        │
│ THEN route to: [Rework      ▼]                    │
│                                                    │
│ OTHERWISE route to: [Standard  ▼]                 │
└───────────────────────────────────────────────────┘
```

---

## Far Future (3–12 Months)

### F-1 · SimViz DSL — `@zone`, `@routing`, `@on_entry` Macros (❌ Pending)

**What:** A full Julia macro system that makes simulation models look like domain specifications.

```julia
using SimVizDSL

@simulation "Warehouse Fulfillment" begin

  @product begin
    name = "Standard Pallet"
    color = :steel_blue
    shape = :pallet
    size  = (0.8, 0.6, 0.4)
    default_attributes = Dict("priority" => 1, "fragile" => false)
  end

  @source "Receiving Dock" begin
    arrival = Poisson(rate=2.5)   # per minute
    on_create = (ctx) -> begin
      set_attribute!(ctx, "arrival_time", ctx.t)
      rand() < 0.1 && set_attribute!(ctx, "priority", 10)  # 10% are rush
    end
  end

  @queue "Staging Buffer" begin
    capacity = 50
    discipline = custom do (a, b)
      get_attribute(a, "priority") > get_attribute(b, "priority")
    end
    on_entry = (ctx) -> begin
      wait = t - get_attribute(ctx, "arrival_time")
      wait > 30 && set_color!(ctx, :amber)
      wait > 60 && set_color!(ctx, :red)
    end
  end

  @server "Pick Station" begin
    servers = 3
    service_time = LogNormal(μ=2.0, σ=0.5)
    on_service_complete = (ctx) -> begin
      record!(ctx, "throughput", 1)
    end
  end

  @routing "Pick Station" do (entity, ctx)
    get_attribute(entity, "fragile") ? to("Careful Pack") : to("Standard Pack")
  end

  @sink "Dispatch" begin
    on_exit = (ctx) -> begin
      sojourn = ctx.t - get_attribute(ctx, "arrival_time")
      record!(ctx, "sojourn_time", sojourn)
      log!(ctx, "Dispatched entity $(ctx.entity_id) after $(round(sojourn, digits=1))s")
    end
  end

end
```

This entire spec compiles to the same `ExecutionGraphIR` as the GUI canvas. You can mix both: author in the canvas, then export to DSL, then hand-edit.

---

### F-2 · GUI ↔ DSL Round-Trip (❌ Pending)

**What:** Bidirectional: canvas → DSL export, DSL → canvas import.

- "Export to DSL" button generates `@simulation` block from current canvas
- "Import DSL" parses the macro and reconstructs the canvas layout
- This lets expert users hand-edit the DSL and see the result in the canvas

The IR is the common language. Both the canvas and the DSL compile to IR. Neither is "more real" than the other.

---

### F-3 · Embedded REPL / Notebook in GUI (❌ Pending)

**What:** A split-pane Julia REPL embedded in the authoring shell.

```
┌──────────────────────────────┬─────────────────────────────────┐
│  Canvas (2D model)           │  Julia REPL                     │
│                              │  julia> using SimViz            │
│                              │  julia> instance.zone_hooks     │
│                              │  julia> counter(instance, "wip")│
│                              │  julia> plot_histogram(...)     │
└──────────────────────────────┴─────────────────────────────────┘
```

- Runs in the same Julia process as the simulation
- `instance` is the live `SimulationInstance` — fully inspectable
- Changes to hooks via REPL immediately reflect in the hook editor tab
- Pluto.jl or a lightweight custom REPL widget

---

### F-4 · Shared Hook Library / Marketplace (⚠️ Partial — Scene Examples Catalog + Quick Presets + 10 `SimViz` Recipes Done)

**What:** A curated library of reusable hooks, disciplines, and routing functions that users can browse and apply from the GUI.

- **Implemented so far:**
  - Full-scene `ExamplesCatalog` ([`examples_catalog.jl`](../packages/GodotBridge/src/compiler/examples_catalog.jl)) with GUI Example Picker in [`authoring_shell.gd`](../godot/scripts/authoring_shell.gd).
  - 1-click **Quick Hook Presets** (`🎨 Color by Wait`, `⬆ Boost Priority`, `🏷 Stamp Attr`, `🔀 Reroute`), **Queue Comparator Presets** (`Preset: EDD`, `Preset: SPT`, `Preset: VIP + Aging`), and the **📚 Insert SimViz Recipe...** catalog (`10` domain recipes covering multi-queue priority pull, sequence-dependent setup time, conveyor accumulation/jam control, dynamic pallet/box creation, and custom DEVS event loops) in [`authoring_floating_inspector.gd`](../godot/scripts/authoring_floating_inspector.gd).
- **Remaining:** Searchable/shareable Hook Library browser for saving and loading custom user snippets across projects:

```
Hook Library
├── Color by wait time (Amber → Red escalation)   [✅ Built-in Preset]
├── Priority boost after N minutes                [✅ Built-in Preset]
├── Batch tracking (group entities by attribute)  [✅ Built-in Preset]
├── EDD discipline (requires due_date attribute)  [✅ Built-in Preset]
├── SPT discipline (requires estimated_service)   [✅ Built-in Preset]
├── Load balancing (shortest queue routing)       [✅ Native Dropdown]
├── Multi-queue pull (argmax / longest / filter)  [✅ Built-in Recipe (M-1)]
├── Sequence-dependent setup time                 [✅ Built-in Recipe (M-1)]
├── Circuit breaker (pause upstream if full)      [✅ Built-in Recipe (M-1)]
└── SLA monitor (log + alert when sojourn > threshold) [✅ Built-in Recipe (M-1)]
```

---

## Architecture Overview

```
                        ┌──────────────────────┐
                        │   GUI (Godot)        │
                        │                      │
  Canvas authoring ────▶│  Inspector & Popups  │─── Dropdowns / Bus / Wire UI → SceneSpec JSON
  DSL import      ────▶│  Hook editor         │─── Hook code + 10 SimViz Recipes → set_hook msg
  Optimization    ────▶│  Plot & Optim Studio │─── Live metrics & Pareto / Convergence
                        └──────────┬───────────┘
                                   │ WebSocket (MsgPack / JSON)
                        ┌──────────▼───────────┐
                        │  GodotBridge /       │
                        │  SimOptim (Julia)    │
                        │                      │
                        │  SceneCompiler  ──────│──▶ ExecutionGraphIR + PortDirectory + Containment
                        │  LogicCatalog   ──────│──▶ ZoneConfig (discipline/routing/comparator)
                        │  ZoneHooks      ──────│──▶ hook closures (`using SimCore.SimViz`)
                        │  HookContext    ──────│──▶ safe atomic mutation API (✅ Done I-2/I-3)
                        │  SimViz helpers ──────│──▶ 114 primitives + @doc catalog (✅ Done M-1)
                        │  LiveSimServer  ──────│──▶ hot-swap hooks + async SimOptim
                        └──────────┬───────────┘
                                   │
                        ┌──────────▼───────────┐
                        │  SimDES (Julia)       │
                        │                      │
                        │  dispatch!            │──▶ calls hooks at lifecycle & CustomUserEvent
                        │  ZoneConfig           │──▶ routing, discipline, intake & conveyor modes
                        │  FutureEventList      │──▶ DEVS event scheduling & signals (✅ Done M-1)
                        └──────────────────────┘
```

---

## Phased Roadmap Summary

```
COMPLETED (Through Phase 7G + I-1..I-4 + M-1)      MID-TERM (NEXT)         FAR FUTURE
────────────────────────────────────────────────   ──────────────────────  ──────────────
✅ 2D/3D Canvas authoring                          M-2 Signal GUI wiring   F-1 DSL macros
✅ Multi-wire bus ports & popups                   M-3 Live vars GUI dock  F-2 Round-trip
✅ Custom wire shapes & waypoints                  M-4 No-code attr route  F-3 Embedded REPL
✅ 3D conveyor presets & splines                                           F-4 Hook marketplace
✅ Live 2D/3D entity & KPI badges
✅ SimOptim + Optimization Studio
✅ I-1 Entity attributes & Source presets
✅ I-2 HookContext atomic mutations
✅ I-3 Visual mutation (color/mesh/size)
✅ I-4 Custom discipline + LIFO/EDD/SPT
✅ M-1 SimViz helper library (114 fns + @doc)
✅ M-1 EntityHandle, Ports & Containment API
✅ M-1 Multi-queue pull & Conveyor kinematics
```

**The guiding principle through all phases:** Every new capability should be reachable from the GUI. The code tier is an accelerator for expert users, not a requirement for anyone. The canvas and the code are two windows into the same model.

---

## Next Steps (Mid-Term M-2 to M-4)

1. ~~**Implement I-1** (entity attribute bag in `SimCore` + SceneSpec `default_attributes`)~~ ✅ Done
2. ~~**Implement I-2** (`HookContext` struct + `_pending_mutations` pattern in `zone_hooks.jl`)~~ ✅ Done
3. ~~**Implement I-3** (visual mutation: `set_color!`, `set_mesh!`, `set_size!`, propagate through `telemetry_adapter.jl` to 2D & 3D)~~ ✅ Done
4. ~~**Implement I-4** (custom discipline comparator closure in `ZoneConfig` + native `EDD` / `SPT` / `LIFO` support in `SimDES`)~~ ✅ Done
5. ~~**Implement M-1** (`SimCore.SimViz` helper library with 114 primitives across 13 categories, `EntityHandle` $O(1)$ addressing, directional port & containment queries, multi-queue pull, conveyor kinematics, compile-time `@doc` docstrings, 10 GUI recipes, and [`2026-09-30_simviz_helper_library_reference.md`](./2026-09-30_simviz_helper_library_reference.md))~~ ✅ Done (`118/118` tests passing)
6. **Complete M-2 & M-3 GUI surfaces** (2D canvas signal/event pulse visualization on `:signal`/`:event` wires, and a dedicated "User Variables & Logs" tab in the Plot Studio dock consuming `UserTelemetryStore` snapshots)
7. **Complete M-4** (No-code multi-branch `IF attribute <op> <value> THEN route to <target>` UI in the Station Inspector)
8. **DSL macros (`F-1`)** — syntax layer over the now-stable `SimCore.SimViz` semantics

