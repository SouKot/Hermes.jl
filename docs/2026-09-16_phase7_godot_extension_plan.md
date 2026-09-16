# Hermes.jl — Phase 7 Godot Desktop GUI and Extension Ecosystem Plan

**Date**: 2026-09-16  
**Scope**: Concrete execution plan for Phase 7 of the visualization roadmap  
**Primary goals**: modularity, extensibility, performance, and testability  
**Related docs**: [Implementation Phases](./2026-08-07_implementation_phases.md), [SimViz README](../packages/SimViz/README.md), [Top-level README](../README.md)

---

## 1. Why Phase 7 Exists

SimViz currently provides a strong headless + GLMakie workflow, but the current
visualization path is still a fixed application layout. Phase 7 is the point at
which the project should move from a demo-oriented viewer to a **user-editable,
protocol-driven desktop GUI**.

Phase 7 is not just “replace the window system.” It is the phase where we define:

- a stable Julia ↔ GUI communication contract,
- a reusable scene model for DES and ABM content,
- support for selectable crowd models in hybrid scenes,
- a first-class extension story for user-authored libraries,
- and a layout that is flexible enough to evolve without rebuilding the engine.

This is the right time to start **designing** Phase 7, but the exact GUI pixel
layout should remain provisional until the first interactive prototype exists.

---

## 2. Design Principles

### 2.1 Modularity

- Keep the engine, the protocol, and the GUI separated.
- Make the GUI consume scene specs and snapshots rather than simulation internals.
- Separate DES element libraries, ABM element libraries, and UI widgets.

### 2.2 Extensibility

- Allow users to load reusable libraries of elements such as conveyors, machines,
  queues, gates, doors, and crowd behaviors.
- Use Julia as the primary extension language.
- Design extensions as packages or package-like modules with explicit manifests.

### 2.3 Performance

- Avoid per-agent scene-node rendering in Godot.
- Use bulk snapshot updates, delta updates where possible, and compact payloads.
- Keep the simulation backend independent from the GUI so CPU/GPU simulation
  performance is not constrained by frontend implementation details.

### 2.4 Testability

- Every subphase should have at least one measurable test or acceptance check.
- Favor small, independently testable milestones over one large UI rewrite.
- Validate protocol, rendering, and extension loading separately.

---

## 3. Recommended Phase 7 Scope

### What Phase 7 should include

- Julia snapshot server and control protocol.
- Godot desktop GUI shell.
- Editable scene layout for DES + ABM.
- Explicit model selection for hybrid / ABM-backed scenes.
- Extension libraries for reusable simulation elements.
- A registry/discovery flow for installed extensions.

### What Phase 7 should not try to solve immediately

- Browser deployment.
- Perfect final layout decisions.
- Embedded Julia code editing as a hard requirement.
- A huge plugin marketplace or remote extension repository.

Those are later concerns. Phase 7 should first establish the local desktop
authoring workflow.

---

## 4. Subphase Plan

## Phase 7A — Contracts and Protocol

**Goal**: Freeze the wire format and the scene model before any large GUI work.

### Deliverables

- Canonical scene schema.
- Snapshot message format.
- Command message format.
- Extension manifest format.
- Versioning rules for compatibility.

### Testable subtasks

- [ ] Define a `SceneSpec` structure for layout, simulation parameters, overlays,
  selected model, and extension references.
- [ ] Define a `SnapshotFrame` structure for agent state, DES state, and time.
- [ ] Define a `CommandFrame` structure for play/pause/reset/speed/edit events.
- [ ] Define an `ExtensionManifest` structure for names, versions, assets, and
  entrypoints.
- [ ] Add a round-trip test for scene spec serialization and deserialization.
- [ ] Add a schema-version compatibility test for forward/backward reads.

### Key decisions in this subphase

- The scene model must include an explicit crowd-model field for every scene
  where ABM is used.
- Hybrid scenarios must not be hardcoded to one ABM model.
- The protocol should support both full-state snapshots and incremental diffs.

### Acceptance criteria

- A scene spec can be sent from Julia, parsed by the GUI, and round-tripped back.
- A command packet can update simulation control state without touching the GUI.
- Model selection is explicit and serializable.

---

## Phase 7B — Julia Runtime Bridge

**Goal**: Keep the engine-side code minimal and protocol-driven.

### Deliverables

- Julia WebSocket server inside SimViz.
- Snapshot streaming at a controlled cadence.
- Command handling for control and layout updates.
- Model-switching hooks for hybrid / ABM-backed scenes.

### Testable subtasks

- [ ] Add a start/stop server entrypoint for the visualization runtime.
- [ ] Implement compact binary snapshot serialization.
- [ ] Implement command handlers for play/pause/step/reset/speed.
- [ ] Implement scene update handlers for layout diffs and topology edits.
- [ ] Add a protocol smoke test that sends a snapshot and receives an ACK-like
  response.
- [ ] Add a control test that verifies clock speed changes propagate correctly.
- [ ] Add a model-selection test that confirms the runtime can accept different
  ABM models for hybrid scenes.

### Performance notes

- Prefer Float32 and UInt8 payloads for bandwidth-sensitive state.
- Keep snapshot generation allocation-light.
- Use delta updates for moving entities when practical.

### Acceptance criteria

- The runtime can stream snapshots to a GUI client without blocking the engine.
- The runtime can accept and apply control messages deterministically.
- The runtime can rebuild or patch the scene from layout edits.

---

## Phase 7C — Godot Shell and Layout

**Goal**: Build a minimal but complete GUI shell before advanced editors.

### Deliverables

- Godot 4 desktop project.
- Connection bootstrap and local runtime settings.
- Live viewport for agent fields and DES indicators.
- Control strip and basic inspector.

### Layout recommendation

This is the right time to define the **information architecture**, but not the
final pixel-perfect layout.

Recommended starting arrangement:

- left: library tree / scene hierarchy,
- center: live viewport,
- right: inspector / properties,
- bottom: timeline / controls / simulation status.

This is a strong default for authoring workflows, but the exact docking, sizes,
and emphasis should remain adjustable until the first usability pass.

### Testable subtasks

- [ ] Boot the Godot project and connect it to a local Julia runtime.
- [ ] Render a single incoming snapshot in the viewport.
- [ ] Add play/pause/reset controls wired to the runtime.
- [ ] Add a basic FPS and agent-count display.
- [ ] Add a layout persistence test for saving/restoring panel arrangement.

### Performance notes

- Render large crowds using instanced rendering, not one node per agent.
- Keep viewport updates independent from editor widgets.
- Use one render path for crowd agents and another for DES indicators only when
  necessary.

### Acceptance criteria

- A minimal scene can be loaded, viewed, and controlled in the GUI.
- The GUI can show live state without stalling when the simulation changes.

---

## Phase 7D — Scene Editor for DES + ABM

**Goal**: Let users author and modify simulation scenes in the GUI.

### Deliverables

- Layout editor for rooms, doors, gates, exits, machines, conveyors, queues, and
  buffers.
- Process graph editor for DES logic and hybrid triggers.
- Explicit ABM model selection where supported.
- Import/export of editable scenes.

### Testable subtasks

- [ ] Add editor nodes for common DES elements.
- [ ] Add editor nodes for common ABM-adjacent elements.
- [ ] Add property inspector bindings for node parameters.
- [ ] Add a scene export format that Julia can read directly.
- [ ] Add a scene re-import test that preserves topology and metadata.
- [ ] Add a hybrid-scene test that switches between supported crowd models.

### Model-switching policy

- Hybrid or ABM-backed scenes should let the user choose the crowd model.
- Fixed demos may still use defaults, but the editor should not hardcode them.
- The GUI should clearly show which scenes are editable and which are template-
  fixed.

### Acceptance criteria

- A user can create a scene, save it, reopen it, and continue editing.
- A user can choose the ABM model for supported hybrid scenes from the GUI.

---

## Phase 7E — Extension SDK and Libraries

**Goal**: Provide user-facing libraries of reusable elements for DES and ABM.

### Deliverables

- Julia extension SDK.
- Package-style manifests for element libraries.
- Extension discovery / registry UI.
- Local-first install/load/enable/disable workflow.

### What the extension system should support

- DES elements: machines, conveyors, buffers, service stations, queues, gates.
- ABM elements: crowd behaviors, entry/exit policies, overlays, route-choice
  behaviors.
- Hybrid widgets: custom controls, scenario templates, and visualization aids.

### Testable subtasks

- [ ] Define extension base traits and registration hooks.
- [ ] Define manifest metadata for versioning and dependencies.
- [ ] Add a sample DES extension library.
- [ ] Add a sample ABM extension library.
- [ ] Add a registry UI test for discovery and loading.
- [ ] Add a compatibility test for two extension versions.

### Julia vs embedded editor decision

- Julia should be the primary authoring language for extensions.
- The first version should favor **external editor integration**.
- An embedded code editor in Godot is optional and should only be added after the
  SDK and extension workflow are stable.

### Why defer embedded editing

- It increases UI complexity.
- It can distract from the core workflow.
- It is easier to add later than to remove if the extension model evolves.

### Acceptance criteria

- A user can install or load an extension library and immediately use its
  elements in the GUI.
- Extension loading is modular and does not require modifying core engine code.

---

## Phase 7F — Performance, Validation, and Layout Lock-In

**Goal**: Finalize what works after the prototype is exercised.

### Deliverables

- End-to-end regression tests.
- Rendering and update performance measurements.
- Usability pass on the panel layout.
- Packaging and onboarding material.

### Testable subtasks

- [ ] Add a full round-trip test: Julia scene → Godot render → user edit → Julia
  update.
- [ ] Add a snapshot throughput benchmark.
- [ ] Add a large-crowd rendering benchmark.
- [ ] Add a layout usability checklist and revise the panel arrangement if needed.
- [ ] Add a starter project or tutorial for creating a first extension.

### Performance targets

- Simulation-side rendering should remain responsive under large agent counts.
- Snapshot updates should not block simulation stepping.
- Editor interactions should remain fast even when the scene contains many
  entities.

### Layout lock-in rule

- Lock the **information architecture** early.
- Delay hard layout finalization until the first prototype and usability pass.
- After the first prototype, preserve the best-known layout as the default, but
  keep docking/resizing configurable.

---

## 5. Recommended Decision Matrix

### What to decide now

- The protocol shape.
- The extension manifest shape.
- The fact that hybrid scenes must be able to choose their ABM model.
- The editor should be plugin-aware from the start.
- The default panel organization.

### What to defer until prototype feedback

- Exact pixel layout.
- Whether an embedded Julia editor is truly needed.
- Whether a remote extension catalog is worth the complexity.
- Whether the final default should emphasize authoring, monitoring, or playback.

### What not to defer

- Model selection for hybrid scenes.
- Extension architecture.
- Performance constraints for large-crowd rendering.
- The scene schema and protocol versioning.

---

## 6. Suggested First Implementation Slice

If we want a manageable first milestone, this is the most practical order:

1. Define the scene schema and snapshot protocol.
2. Add a Julia WebSocket server that streams a tiny scene.
3. Build a Godot shell that displays the snapshot and basic controls.
4. Expose ABM model selection in the scene spec.
5. Add one or two sample extension libraries.
6. Add one full round-trip test.

This gives us a useful vertical slice without overcommitting to the final UI.

---

## 7. Summary

Phase 7 should be treated as a **platform phase**, not just a new windowing
layer. The key architectural decisions are:

- the GUI must consume a stable protocol,
- hybrid scenes must not be locked to one ABM model,
- extensions should be Julia-first and library-driven,
- the layout should be designed now but finalized later,
- and performance must be preserved through bulk updates and instanced rendering.

That is the right foundation for a maintainable Godot-based user experience.