# Antigravity SimViz — Session State & Handoff Guide (Through M-1 Complete)

**Last Updated:** 2026-09-30
**Conversation ID:** `b190f1d8-e577-4d2d-9386-35c84a7dd33a`
**Workspace:** `/run/media/sourabh/SANDISK-2TB/antigravity/ABM`

---

## 1. Completed Milestones & Architectural Decisions Summary

### A. Phase 7G Additions: Custom Wire Shapes, Waypoints & Wire Styling Popup
1. **Four Port-Normal-Aware Wire Routing Modes (`godot/scripts/authoring_2d_canvas.gd`):**
   - `bezier` (smooth S-curve departing along port normal $\vec{n}_s$ and arriving along $-\vec{n}_t$), `orthogonal` (90° Manhattan with rounded corners), `chamfer` (45° angled turns), and `straight` (direct polyline).
   - **Scene-Wide Default Wire Shape Dropdown (`〰 Shape: Bezier / Ortho / 45° / Line`)** in the top toolbar (`godot/scripts/authoring_shell.gd`).
   - **Interactive Draggable Waypoints (`●`) & Segment Midpoint Handles (`⊕`):** Clicking a wire selects it, reveals draggable waypoint handles (`●`) and midpoint insertion handles (`⊕`), and double-clicking a waypoint removes it (all Undo/Redo-backed in `godot/scripts/authoring_document_store.gd`).
   - **Right-Click Wire Styling Popup (`godot/scripts/authoring_wire_popup.gd`):** Per-wire shape override, stroke style (`solid`, `dashed`, `dotted`), width (`1.0–6.0 px`), curvature/corner radius, color override, `[Reset Waypoints]`, and `[Apply to All Wires]`.

### B. Customization Roadmap Immediate Actions (`I-1` – `I-4` Complete)
1. **`I-1` Entity Attribute Bag:**
   - `world.entity_attributes` (`Dict{UInt64, Dict{String, Any}}`) in `packages/SimCore/src/world.jl`, seeded on arrival in `packages/GodotBridge/src/compiler/des_compiler.jl`.
   - Source Block Inspector (`DEFAULT ENTITY ATTRIBUTES`) and live entity attribute sub-rows in `godot/scripts/authoring_outliner.gd`.
2. **`I-2` & `I-3` `HookContext` Safe Atomic Mutations & Live Visual Overrides:**
   - Queued `HookCommand` mutations (`set_color!`, `set_mesh!`, `set_size!`, `reset_visual!`, `set_priority!`, `route_to!`, `set_attr!`) in `packages/GodotBridge/src/runtime/zone_hooks.jl`, propagated to 2D/3D via `packages/GodotBridge/src/runtime/telemetry_adapter.jl`.
3. **`I-4` Native `LIFO`, `EDD`, `SPT` & Custom Julia Comparator Discipline:**
   - Implemented in `packages/SimDES/src/zone.jl`, `packages/SimDES/src/dispatch.jl`, `packages/GodotBridge/src/compiler/logic_catalog.jl`, and exposed in Queue Inspector & `godot/scripts/authoring_rule_panel.gd`.

### C. Milestone `M-1`: `SimViz` Helper Library & User Scripting Vocabulary (Complete)
1. **Unboxed 64-bit `EntityHandle` (`O(1)` Addressing) & Batch Vectorization:**
   - Every simulation entity (stations, queues, conveyors, sources, sinks, containers, and flowing discrete items) is addressed via an unboxed 64-bit `EntityHandle` (`idx::UInt32`, `gen::UInt16`, `kind_tag::UInt8`, `flags::UInt8`) in `packages/SimCore/src/world.jl`.
   - Inside any hook, `ctx` (`HookContext`) is resolved implicitly via `current_ctx()`, `self()` / `self_handle()` refers to the owning station/block, and `item()` / `item_handle()` refers to the flowing item.
   - All mutators (`set_speed!`, `pause!`, `resume!`, `set_capacity!`, `set_servers!`, `set_color!`, `set_attr!`, etc.) accept `Vector{EntityHandle}` for zero-overhead batch operations (e.g., `set_speed!(entities_of_kind(:conveyor), 2.0)`).
2. **Strictly Directional Port Topology (`:in` / `:out`, Slots `[1..N]`):**
   - `ports`, `input_ports`, `output_ports`, `connected_ports`, `connected_entities`, `connected_entity(port, slot=1)`, `connected_entity_where`, `connected_entities_where`, `connected_entity_argmin`, `connected_entity_argmax`, `upstream_entities`, `downstream_entities`, `send_signal!`, `read_signal`, `emit_port_event!`.
3. **Symmetric Containment Hierarchy (Upward & Downward, Shortest to Longest Flavors):**
   - Upward ("Who Contains Me?"): `container_entity()`, `container_entity(target)`, `root_container()`, `ancestors()`, `has_container()`.
   - Downward ("What Do I Contain?"): `contained_entities()`, `contained_count()`, `contains_entity()`, `contained_entity(k)`, `first_contained()`, `last_contained()`, `contained_entity_where`, `contained_entities_where`, `contained_entity_argmin`, `contained_entity_argmax`, `put_inside!`, `take_out!`.
4. **Multi-Queue Pull / Intake (`:in_flow` Bus `[1..N]`):**
   - Multi-queue servers (`N` queues $\to$ `1` server) automatically retain distinct `ZoneID`s per queue in `packages/GodotBridge/src/compiler/des_compiler.jl`.
   - Pull helpers: `port_head_items`, `port_all_items`, `pull_from_port!`, `pull_from_port_slot_order!`, `pull_from_port_round_robin!`, `pull_from_port_longest!`, `pull_from_port_highest_fill!`, `pull_from_port_where!`, `pull_from_port_argmin!`, `pull_from_port_argmax!`, `set_intake_mode!`.
5. **Custom Server Primitives, Low-Level DEVS Event Engine & Conveyor Kinematics:**
   - Custom server: `set_service_time!`, `add_setup_time!`, `last_processed_attr`, `start_service!`, `complete_service!`, `seize_capacity!`, `release_capacity!`, `dequeue_where!`.
   - DEVS FEL (`CustomUserEvent` in `packages/SimCore/src/events.jl`): `set_process_mode!(:custom)`, `schedule_event!`, `schedule_at!`, `schedule_every!`, `cancel_event!`, `cancel_all_events!`, `event_tag`, `event_payload`, `after!`, `forward_entity!`.
   - Conveyor kinematics (`EntityKinematics`): `set_conveyor_mode!(:free_flow | :accumulating | :indexing)`, `path_length`, `distance`, `progress`, `speed`, `set_distance!`, `set_progress!`, `step_distance!`, `set_speed!`, `entities_along_path`, `entity_ahead`, `entity_behind`, `gap_ahead`.
6. **Docstrings, Introspection Catalog & Reference Manual:**
   - All **114 primitives** in `packages/SimCore/src/simviz_helpers.jl` are registered in `HELPER_CATALOG` with compile-time `@doc` bindings and `helper_docs_markdown(; category=nothing)`.
   - Full user reference manual created at `docs/2026-09-30_simviz_helper_library_reference.md`.
   - Roadmap updated at `docs/2026-09-25_simviz_customization_roadmap.md`.

---

## 2. Verification Status
* `packages/GodotBridge/test/test_simviz_helper_library.jl` — **118 / 118 tests passing**.
* `packages/GodotBridge/test/test_scenespec_compiler.jl` — **127 / 127 tests passing**.
* `godot/tests/test_phase7g_ports_cardinality_and_telemetry.gd` — **22 / 22 assertion groups passing**.

---

## 3. Next Planned Milestones (Post-Restart)
1. **`M-2` GUI Surface:** Visual signal/event pulse animation along `:signal` and `:event` wires on the 2D canvas + no-code Signal Trigger builder in the Floating Inspector (backend signaling & `CustomUserEvent` already complete in `M-1`).
2. **`M-3` GUI Surface:** Dedicated **"User Variables & Logs"** tab in the Godot Plot Studio dock and live counter badges in the Model Outliner consuming `UserTelemetryStore` snapshots (`user_counters`, `user_gauges`, `user_metrics`, `user_tallies`, `user_logs`).
3. **`M-4` No-Code Multi-Branch Attribute Routing UI:** Station Inspector `IF attribute <op> <value> THEN route to <target> OTHERWISE <default>` builder.
