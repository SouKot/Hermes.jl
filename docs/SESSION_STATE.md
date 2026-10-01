# Antigravity SimViz — Session State & Handoff Guide (Phase 7G + I-1..I-4 Complete)

**Last Updated:** 2026-10-01
**Conversation ID:** `b190f1d8-e577-4d2d-9386-35c84a7dd33a`
**Workspace:** `/run/media/sourabh/SANDISK-2TB/antigravity/ABM`

---

## 2026-10-01 Restart Handoff: Conveyor Geometry

- The conveyor authoring work spans `godot/scripts/conveyor_curve_3d.gd`, the 2D/3D authoring views, both inspectors, the mesh factory, and `packages/GodotBridge/src/compiler/conveyor_curve.jl`. Eight presets remain available; converting one to `custom_spline` preserves its centerline before freeform edits.
- Geometry mode is entered by middle-clicking a conveyor, Shift+G, or the dock/floating Edit Conveyor Geometry button. Ports disappear in this mode. Width/end/bend/tangent handles, pivoted rotation, and curve-preserving bend insertion work in 2D; the 3D view provides helix radius/rise/turns and station-height handles. Connected flow endpoints reject edits that would move or reorient them.
- Preset controls preserve topology: S-curve span/offset/tension; L-bend legs/angle/radius; U-turn infeed and return reaches/radius; arc radius/sweep; serpentine 1-11 bends, pass length, lane center spacing; helix radius/turns/rise or pitch. Base width plus `geometry.width_profile` keys control local cross-section in the 2D and 3D renderers. Round hairpins and wide elbows use quarter-arc Beziers and dense render-only sampling. Legacy serpentine `pitch` is interpreted as `pass_spacing` when needed.
- Verification at handoff: Godot `tests/test_conveyor_interactive_gizmos.gd` 103/103, `tests/test_conveyor_curves_3d.gd` 100/100; Julia `packages/GodotBridge/test/test_conveyor_curves.jl` 163/163; `test_scenespec_compiler.jl` integration groups 29/29, 77/77, 44/44. Use `godot --headless --path godot --script res://tests/<test>.gd` and `julia --project=packages/SimOptim packages/GodotBridge/test/<test>.jl` from ABM. Godot reports ObjectDB leak warnings at test exit. The broader authoring-shell smoke test has separate existing schema/merge test errors; they were not repaired in this conveyor work.
- Remaining design extensions: automatic network rerouting on connected-end edits, local-coordinate migration, full 3D pitch/roll banking gizmos, and facility-wide collision clearance. The detailed conveyor authoring guide is at `/home/sourabh/.gemini/antigravity/brain/b190f1d8-e577-4d2d-9386-35c84a7dd33a/conveyor_types_and_authoring_guide.md` (outside this Git repo).
- Restart instruction: read this handoff and the guide, check `git status` and the latest commit, then continue from the current conveyor geometry implementation. Generated MP4/autosave outputs and empty test placeholders are intentionally outside the source commit.

---

## 1. Conversation History & User Decisions Summary

### A. Phase 7E-5 & Phase 7F (Previously Completed & Committed)
1. **Two-Window SimOptim GUI (`authoring_optim_setup.gd` & `authoring_optim_feedback.gd`):**
   - Window 1 (`OptimSetup`): Setup, Live Progress, and Candidate Preview (`[👁 Preview on Canvas]`, `[✓ Apply to Scene]`, `[📋 Full Report...]`).
   - Window 2 (`OptimFeedback`): 5-Tab Deep Diagnostics Report (`🏆 Feasible Solutions`, `✗ Failed Candidates`, `📈 Convergence`, `🔍 Parameter Explorer`, `💡 Recommendations`).
2. **General Parametric Conveyor Geometry & Universal Topology Solver (`conveyor_curve.jl`, `conveyor_curve_3d.gd`, `graph_search.jl`):**
   - 8 shape presets (`straight`, `s_curve`, `l_bend`, `u_turn`, `circular_arc`, `serpentine`, `spiral_helix`, `custom_spline`) with uniform arc-length baking and $C^1$ junction alignment.
   - Universal candidate layout & geometry synthesizer for all candidate topologies (including open trees, loops, and dead-ends).

### B. Phase 7G Design Discussions & Agreed Architecture
During the Phase 7G design review ([port_cardinality_and_entity_visualization_report.md](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/docs/phase7f_design/port_cardinality_and_entity_visualization_report.md) and [plan_phase7g_ports_cardinality_and_telemetry.md](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/docs/phase7f_design/plan_phase7g_ports_cardinality_and_telemetry.md)), the user and agent established the following architectural rules:
1. **No Mid-Belt Side-Transfer Ports:**
   - If a product needs to enter a queue mid-way along a conveyor, the user models it with two conveyors (`Conveyor_1 -> Queue -> Conveyor_2` or branching from `Conveyor_1`'s multi-wire `flow_out`).
2. **Perimeter Edge-Aligned Ports (Zero Internal Side Bays):**
   - Removed the legacy 36px/64px internal Left/Right port bays (`left_w = 0`, `right_w = 0`) so 100% of a block's 2D footprint is available for its physical body and live telemetry.
   - **Left Edge (`x = 0`):** `flow_in` (Green `#2ecc71`, normal `(-1, 0)`).
   - **Right Edge (`x = size.x`):** `flow_out` (Green `#2ecc71`, normal `(+1, 0)`).
   - **Top Edge (`y = 0`):** `signal` / control inputs (Orange `#f39c12`, normal `(0, -1)`) — on **Queue (`release_signal`)**, **Server (`pause_signal`)**, and **Conveyor (`speed_signal`)**.
   - **Bottom Edge (`y = size.y`):** `metric` outputs (Purple `#9b59b6`, normal `(0, +1)`).
3. **Port Interaction Cleanup (2026-09-29):**
   - Removed the static `×N` rectangle badge next to ports and its left-click trigger.
   - **Left-click + drag** on any port is exclusively for drawing new wires.
   - **Right-click** on any connected port ($\ge 1$ connections) opens the **Bus Port Channel Manager Popup** ([authoring_channel_popup.gd](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/godot/scripts/authoring_channel_popup.gd)) with `[▲]`/`[▼]` priority reordering, live flow rates, and `[✕]` single-channel deletion.
4. **Custom Connection Wire Shapes, Interactive Waypoints & Expanded Floating Wire Pop-up (Option 1B, 2026-09-29):**
   - **Port-Normal Aware Routing Modes (`bezier`, `orthogonal`, `chamfer` 45°, `straight`):** All 4 wire shapes respect port normals (Left/Right exit horizontally; Top/Bottom exit vertically).
   - **Scene-Wide Default Wire Shape:** Top toolbar `∿ Shape: Curved / Ortho 90° / Metro 45° / Straight` dropdown applies to all connections set to `"auto"`.
   - **Interactive On-Canvas Waypoint (`●`) & Midpoint (`⊕`) Handles:** Left-clicking a wire selects it and reveals `⊕` segment handles (drag to create a bend) and `●` waypoint handles (drag to move; right-click a `●` handle to remove that single bend) across all 4 wire types.
   - **Plain Right-Click on Wire → Expanded Floating Wire Pop-up ([authoring_wire_popup.gd](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/godot/scripts/authoring_wire_popup.gd)):** Self-contained floating panel with Shape Mode (`Auto`, `∿ Curve`, ` orthogonal 90°`, `Metro 45°`, `╱ Straight`), Tension/Corner Radius slider, Stroke Style (`Solid`, `Dashed`, `Dotted`), Width (`1.5–5.0 px`), Color Override + `[Reset]`, `[↺ Reset Bends]`, and `[🗑 Delete Wire]`.
   - **Shift + Right-Click on Wire:** Immediately deletes the wire.
5. **Immediate Customization Roadmap Actions `I-1` through `I-4` (2026-09-29):**
   - **`I-1` · Entity Attribute Bag & `default_attributes`:** Per-entity `Dict{String, Any}` metadata in `SimWorld.entity_attributes` (`EntityState`), Source block `default_attributes` (`"auto_increment"`, `"due_date_offset"`, `"rand_uniform(a,b)"`, `"rand_int(a,b)"`, literals), Source Inspector preset editor, and expandable entity attribute rows in `authoring_outliner.gd`.
   - **`I-2` · `HookContext` Safe Atomic Mutation API:** `HookContext` (`set_attribute!`, `set_priority!`, `route_to!`, `get_attribute`, `has_attribute`) with queued atomic application after hook return (`apply_hook_mutations!`), SceneSpec `properties["hooks"]` compilation, and 1-click Quick Hook Presets in `authoring_floating_inspector.gd` Tab 4 (`🔗 Hooks`).
   - **`I-3` · Visual Mutation from Hooks:** `set_color!`, `set_mesh!`, `set_size!`, and `reset_visual!` in `HookContext`, propagated via `telemetry_adapter.jl` to both 2D Canvas and 3D Viewport.
   - **`I-4` · Custom Queue Discipline Comparator & Native `LIFO` / `EDD` / `SPT`:** Native `LIFO`, `EDD`, `SPT` plus `custom_discipline` comparator closure `(entity_a, entity_b) -> Bool` in `SimDES.ZoneConfig`, `logic_catalog.jl`, `authoring_floating_inspector.gd`, and `authoring_rule_panel.gd`.

---

## 2. Modified & Added Files

* **Julia Runtime & Compiler (`packages/SimCore/`, `packages/SimDES/`, `packages/GodotBridge/`):**
  * [packages/SimCore/src/world.jl](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimCore/src/world.jl) — `EntityState`, `entity_attributes`, `entity_visuals`, `entity_route_overrides`, `get_attribute`, `has_attribute`.
  * [packages/SimDES/src/zone.jl](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimDES/src/zone.jl) & [packages/SimDES/src/dispatch.jl](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/SimDES/src/dispatch.jl) — `LIFO`, `EDD`, `SPT`, `custom_discipline` comparator closure, and `entity_route_overrides` in `_route_entity!`.
  * [packages/GodotBridge/src/runtime/zone_hooks.jl](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/GodotBridge/src/runtime/zone_hooks.jl) — `HookContext`, queued visual/behavioral mutations, `apply_hook_mutations!`, `parse_hook_expr`, `parse_discipline_expr`.
  * [packages/GodotBridge/src/compiler/des_compiler.jl](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/GodotBridge/src/compiler/des_compiler.jl) & [packages/GodotBridge/src/compiler/scenespec_compiler.jl](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/GodotBridge/src/compiler/scenespec_compiler.jl) — `default_attributes` seeding, `custom_discipline` compilation, and `properties["hooks"]` compilation.
  * [packages/GodotBridge/src/runtime/telemetry_adapter.jl](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/GodotBridge/src/runtime/telemetry_adapter.jl) — Per-entity visual overrides (`color`, `mesh_type`, `size_scale`, `size_dims`) and `properties["attributes"]` in telemetry snapshots.
* **Godot 4 Authoring & Visualization (`godot/`):**
  * [godot/scripts/authoring_wire_popup.gd](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/godot/scripts/authoring_wire_popup.gd) — Expanded Floating Wire Pop-up (Option 1B).
  * [godot/scripts/authoring_2d_canvas.gd](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/godot/scripts/authoring_2d_canvas.gd) — Port-normal 4-mode wire routing (`bezier`, `orthogonal`, `chamfer`, `straight`) and interactive `●`/`⊕` waypoint handles.
  * [godot/scripts/authoring_floating_inspector.gd](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/godot/scripts/authoring_floating_inspector.gd) — Source `default_attributes` editor + presets, Queue `Custom` comparator editor + presets, and Tab 4 `HookContext` reference + Quick Hook Presets.
  * [godot/scripts/authoring_rule_panel.gd](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/godot/scripts/authoring_rule_panel.gd) & [godot/scripts/authoring_outliner.gd](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/godot/scripts/authoring_outliner.gd) — Custom comparator support and live entity attribute sub-rows.
* **Tests:**
  * [godot/tests/test_phase7g_ports_cardinality_and_telemetry.gd](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/godot/tests/test_phase7g_ports_cardinality_and_telemetry.gd) — **22/22 assertion groups passing**.
  * [packages/GodotBridge/test/test_scenespec_compiler.jl](file:///run/media/sourabh/SANDISK-2TB/antigravity/ABM/packages/GodotBridge/test/test_scenespec_compiler.jl) — **150/150 assertions passing** (including 44 assertions for `I-1`–`I-4`).
