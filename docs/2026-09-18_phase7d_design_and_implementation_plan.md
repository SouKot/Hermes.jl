# Phase 7D: Scene Authoring for DES, ABM, and Hybrid Models

**Date**: 2026-09-18
**Status**: Detailed design and implementation plan
**Prerequisites**: Phase 7C normal-scene monitoring and control acceptance complete
**Parallel deferred gate**: Phase 7C-06A connected 500K compact rendering and compact entity detail editing

## 1. Purpose

Phase 7D turns the Phase 7C monitoring client into a scene authoring tool. A user should be able to create, validate, save, reopen, and run DES, ABM, and hybrid scenes without coupling editor nodes to Julia runtime objects.

The central contract is `SceneSpec v1`:

```text
Godot authoring model
    -> SceneSpec v1
    -> pure validation
    -> Julia compilation
    -> runtime model
    -> Phase 7C RenderState
```

`SceneSpec` describes intent and topology. `RenderState` describes a running simulation. Commands mutate a running simulation. These remain separate models.

## 2. Outcomes

Phase 7D should deliver:

- A versioned, round-trip-safe SceneSpec implementation in Julia and Godot.
- A registry-driven element and model catalog.
- A 2D-first physical layout editor backed by a complete 3D spatial model.
- A synchronized 3D scene view for inspection, preview, level navigation, and runtime visualization.
- A typed process graph editor for flow and control dependencies.
- A schema-driven property inspector.
- ABM model selection and hybrid configuration.
- Reusable groups, templates, and compound subgraphs.
- Import/export with lossless round trips and atomic writes.
- A deterministic SceneSpec-to-runtime compiler.
- Validation that is fast locally and authoritative in Julia.
- Undo/redo, copy/paste, multi-select, and stable identifiers.
- Performance instrumentation and explicit degradation behavior.

The principal workflow is 2D-first because plan views are efficient for placing rooms, queues, conveyors, doors, and process equipment. The same authored transforms and geometry must produce the 3D view immediately; users do not maintain a second 3D copy.

## 3. Non-Goals

Phase 7D does not include:

- A general plugin marketplace. Registry interfaces are required; packaging is Phase 7E.
- Arbitrary user code execution inside Godot.
- Collaborative multi-user editing.
- Full timeline/replay authoring.
- GPU simulation authoring or shader graph editing.
- General-purpose mesh modeling, sculpting, or CAD replacement. Phase 7D consumes procedural geometry and registered assets.
- Connected 500K entity detail editing, which remains in 7C-06A.
- Replacing Julia as the authoritative simulation runtime.

## 4. Design Principles

### 4.1 Contract First

SceneSpec v1 is the source of truth for authored scenes. GUI widgets are projections of the document and must not become an independent schema.

### 4.2 Separate Four Models

```text
AuthoringDocument  editable structure, history, unknown fields
SceneSpec          portable versioned interchange contract
CompiledScene      validated Julia runtime construction plan
RenderState         live read-optimized visualization projection
```

No editor control should mutate `RenderState` or Julia runtime objects directly.

### 4.3 Registry Driven

Element kinds, ports, properties, visual metadata, compiler factories, and model capabilities come from registries. Adding an element should not require editing the graph editor, inspector, serializer, and validator independently.

### 4.4 Pure Core, Stateful Shell

Schema parsing, normalization, validation, compatibility checks, ID remapping, and compilation planning should be pure or side-effect-free functions. File dialogs, Godot controls, WebSocket transport, and runtime construction remain at the edges.

### 4.5 Preserve Unknown Data

Godot and Julia must preserve unknown fields at every supported nesting level. Unsupported element kinds remain editable placeholders with warnings instead of being deleted.

### 4.6 Deterministic Behavior

Given the same SceneSpec, registry versions, and random seed, validation and compilation results must be stable. Diagnostics are sorted deterministically by severity, object ID, and rule ID.

### 4.7 Performance by Data Ownership

- Editor document data is CPU-resident and optimized for editing.
- Runtime arrays remain data-oriented and can use multicore/GPU execution.
- Render data remains packed/instanced where scale requires it.
- GPU resources never become the only copy of authored state.

## 5. Proposed Architecture

```text
Godot 7D Authoring Shell
├── SceneDocumentStore
│   ├── AuthoringDocument
│   ├── stable ID service
│   ├── selection state
│   └── document revision
├── EditorCommandStack
│   ├── execute
│   ├── undo/redo
│   ├── transaction grouping
│   └── dirty/save point
├── ElementCatalog
│   ├── registry client
│   ├── searchable palette
│   └── missing-type placeholders
├── LayoutEditor
│   ├── physical transforms
│   ├── levels and elevation
│   ├── snapping/guides
│   └── geometry tools
├── SpatialPreview3D
│   ├── synchronized 2D/3D selection
│   ├── procedural geometry and registered assets
│   ├── floor isolation and vertical connectors
│   └── authoring/runtime preview modes
├── ProcessGraphEditor
│   ├── typed ports
│   ├── flow links
│   ├── signal links
│   └── subgraph navigation
├── PropertyInspector
│   ├── schema-driven fields
│   ├── rule builder
│   └── validation feedback
├── SceneValidator
│   ├── incremental local rules
│   └── diagnostic index
├── SceneSerializer
│   ├── normalize
│   ├── JSON/MessagePack
│   └── atomic import/export
├── SceneBridgeClient
│   ├── validate request
│   ├── compile/load request
│   └── Ack/Error diagnostics
└── PreviewController
    ├── Phase 7C runtime viewport
    └── authoring/runtime mode boundary

Julia Authoring Backend
├── SceneSpecSchema
│   ├── typed records
│   ├── extension-field storage
│   └── migrations
├── ElementRegistry
│   ├── ElementDefinition
│   ├── PropertyDefinition
│   ├── PortDefinition
│   └── runtime factory
├── ModelRegistry
│   ├── ABM model capabilities
│   └── parameter schemas
├── SceneSpecValidator
│   ├── structural validation
│   ├── semantic validation
│   └── dependency validation
├── SceneCompiler
│   ├── normalized intermediate representation
│   ├── dependency schedule
│   ├── runtime construction
│   └── source-map diagnostics
└── SceneRepository
    ├── import/export
    ├── migration
    └── template/subgraph storage
```

## 6. SceneSpec v1 Contract

The existing `SceneSpecPayload` root fields remain:

- `spec_version`
- `scene`
- `simulation`
- `abm_config`
- `elements`
- `connections`
- `subgraphs`
- `overlays`
- `validation_metadata`

The canonical 7D schema adds an optional `spatial` section. `SceneSpecPayload` and both serializers must be extended to carry it without hiding core spatial semantics in an opaque extension map.

### 6.1 Spatial Coordinate and Level Model

Godot's Y-up convention is canonical:

```text
X   horizontal east/west
Y   elevation/height
Z   horizontal north/south
```

The 2D plan editor displays the X/Z plane for one active level. The 3D view uses X/Y/Z directly. Element transforms are stored once and shared by both views.

The optional root spatial section contains:

```json
{
  "coordinate_system": "right_handed_y_up",
  "length_unit": "meters",
  "origin": [0.0, 0.0, 0.0],
  "levels": [
    {
      "id": "level_ground",
      "name": "Ground Floor",
      "elevation": 0.0,
      "default_height": 3.0,
      "visible": true
    }
  ]
}
```

Each spatial element contains:

- `level_id`: owning floor/plane where applicable
- `transform.position`: absolute X/Y/Z anchor
- `transform.rotation`: canonical 3D rotation
- `transform.scale`: 3D scale
- `geometry`: backend-neutral dimensions, footprint, path, or polygon
- `visual`: optional registered asset/material/LOD references
- `vertical_extent`: base elevation and height where geometry needs it

For level-bound elements, `position.y` must equal the level elevation plus the local elevation offset after normalization. The normalized representation stores enough information to avoid ambiguity; editors may expose either absolute elevation or level plus local offset, but must not let them silently diverge.

Vertical connectors such as stairs, elevators, ramps, lifts, and multi-level conveyors reference source and target levels and expose typed spatial/flow ports. Validation checks endpoint elevations, accessible geometry, directionality, and connection compatibility.

2D geometry is not merely decorative. Footprints and paths are the source for procedural 3D extrusion where no asset is registered:

- room/wall footprint + height -> extruded room/walls
- door/exit span + height -> opening/portal
- conveyor path + width/elevation -> 3D conveyor segment
- queue/buffer region + height policy -> marked 3D zone
- machine/server anchor + dimensions -> procedural box or registered model

Registered element definitions may provide a 3D scene/mesh reference, pivot convention, default dimensions, material slots, and LOD policy. Missing assets fall back to deterministic procedural geometry so every valid scene remains visible.

### 6.2 Required Additions and Clarifications

Each editable record should support an `extensions` map for unknown namespaced data. Existing unknown keys must also be retained verbatim during v1 round trips.

Scene metadata should include:

- stable scene ID
- human-readable name
- revision number
- required libraries and version ranges
- created/modified timestamps
- optional content hash

Element records separate simulation placement from graph layout:

```text
transform.position / rotation / scale   physical simulation space
editor.graph_position                  process graph canvas
editor.collapsed / color / notes       non-runtime authoring metadata
```

This resolves the existing ambiguity where one `position` might be interpreted as both physical and graph position.

### 6.3 Typed Port Definition

A port definition contains:

- stable port ID
- direction: `input` or `output`
- semantic kind: `flow`, `metric`, `signal`, `control`, or `event`
- data type or entity contract
- cardinality: `one` or `many`
- required/optional status
- unit/dimension metadata where applicable
- documentation and display metadata

Initial compatibility rules:

- flow output -> compatible flow input
- metric output -> compatible signal/control input
- event output -> compatible event/control input
- identical units or an explicit registered conversion
- input cardinality and exclusivity must be respected
- output-to-output and input-to-input are invalid

Compatibility logic must live in one shared rule specification with fixtures consumed by both Julia and Godot tests.

### 6.4 Connection Definition

Connections keep stable IDs and explicit endpoint records. They may carry:

- link type
- enabled state
- ordering/priority
- optional condition/rule expression
- optional latency/capacity metadata
- extension data

Connections that reference missing libraries or removed ports remain in the document as invalid, repairable records.

### 6.5 Property Schema

Element and model properties use declarative definitions:

- name and stable key
- scalar/enum/vector/resource/distribution type
- default value
- required flag
- numeric range and step
- unit
- visibility condition
- restart-required flag
- runtime-editable flag
- validation rules
- display group and documentation

The inspector is generated from this schema. Custom widgets may be registered later, but common properties cannot require custom GUI code.

### 6.6 Subgraphs

Subgraphs support three roles:

- `group`: organization only
- `template`: reusable copy with deterministic ID remapping
- `compound`: encapsulated node with exposed typed ports

Subgraph instances track:

- template ID and version
- instance ID
- internal element/connection ID map
- parameter overrides
- exposed ports
- detached/local modifications

## 7. Authoring State and Editing Semantics

### 7.1 Document Store

`SceneDocumentStore` owns one document revision. UI panels receive read-only snapshots or targeted signals. All mutations enter through editor commands.

### 7.2 Undo and Redo

Use command-based history with transaction grouping:

```text
EditorCommand
├── apply(document)
├── revert(document)
├── affected IDs
├── merge key
└── user-facing description
```

Examples:

- add/remove element
- move/resize element
- connect/disconnect ports
- change property
- change ABM model
- instantiate/detach subgraph
- paste with ID remapping

Continuous drags merge into one command. A save point records the revision considered clean. History is bounded by command count and estimated memory.

### 7.3 Copy, Paste, and Duplicate

Paste creates deterministic fresh IDs and rewrites internal references atomically. References outside the copied selection are either preserved as explicit external references or omitted with diagnostics according to the operation mode.

### 7.4 Multi-Select

Bulk property editing is allowed only for properties shared by every selected definition. Mixed values display an indeterminate state. One bulk edit is one undo transaction.

### 7.5 Validation Timing

- Cheap structural/local rules run incrementally after each transaction.
- Expensive global graph and dependency validation is debounced.
- Julia performs authoritative validation before compile/load.
- Export may preserve invalid drafts, but run/compile is blocked by errors.

## 8. Validation and Diagnostics

Diagnostics contain:

- stable rule ID
- severity: info/warning/error
- object kind and stable ID
- property/port path
- human-readable message
- optional suggested fix
- source: Godot local validator, Julia validator, compiler, or runtime

Validation layers:

1. Schema and required fields.
2. Unique stable IDs.
3. Registry/library availability and version compatibility.
4. Property type, range, enum, unit, and cross-property constraints.
5. Port existence, direction, type, unit, and cardinality.
6. Required connection completeness.
7. Flow cycle policy and unreachable elements.
8. Signal/control dependency cycles.
9. Subgraph boundary and override validity.
10. DES/ABM/hybrid model capability compatibility.
11. Runtime-editability and restart requirements.

A scene may be saved with errors as a draft. It may not be compiled or run until all blocking errors are resolved.

## 9. Scene Compilation

Compilation is an explicit pipeline:

```text
SceneSpec
 -> parse and preserve extensions
 -> migrate compatible older schema
 -> normalize defaults and units
 -> validate
 -> resolve libraries and model capabilities
 -> build typed intermediate representation
 -> partition flow/control/spatial dependencies
 -> construct runtime in a staging context
 -> validate runtime invariants
 -> atomically activate or return diagnostics
```

Compilation must never partially replace a running scene. Failure leaves the prior runtime intact.

A source map links compiled runtime IDs back to SceneSpec IDs so Julia errors select the correct Godot element/property.

## 10. Modularity and Extension Contracts

### 10.1 ElementDefinition

An element library registers one definition containing:

- stable kind and semantic version
- display name/category/icon
- property schema
- typed ports
- physical visualizer metadata
- process graph metadata
- Julia compiler/runtime factory
- supported simulation modes
- migration hooks

### 10.2 ModelDefinition

An ABM model registers:

- model name/version
- required packages/backends
- parameter schema
- supported geometry and entity fields
- CPU/GPU capabilities
- deterministic/reproducibility constraints
- runtime factory and validator

### 10.3 Missing Extensions

Unavailable definitions render as placeholders that preserve data and connections. Users can inspect raw properties, install/resolve dependencies later, or replace the node. Missing extensions never cause silent data loss.

## 11. Multicore and GPU Design

### 11.1 Godot CPU Work

Safe worker tasks:

- JSON/MessagePack parsing into detached data
- global validation on immutable document snapshots
- search/catalog indexing
- layout algorithms
- import diffing and migration previews

Godot scene nodes, `GraphEdit`, controls, and GPU resources are updated only on the main thread. Worker results carry the document revision they were computed from; stale results are discarded.

### 11.2 Julia Multicore Work

Validation is partitionable by element, connection, subgraph, and global graph passes. Parallel passes produce immutable diagnostic vectors and merge deterministically.

Compilation may parallelize independent element construction and resource preparation only when factories declare thread safety. Final graph wiring and runtime activation remain deterministic barriers.

### 11.3 GPU Work

GPU acceleration belongs to runtime preview and simulation kernels, not schema editing. SceneSpec stores backend-neutral intent plus optional backend preferences:

```text
backend_preference: auto | cpu | gpu
required_capabilities: [...]
fallback_policy: allow | warn | reject
```

The compiler chooses a backend from registered capabilities and reports the decision. GPU resources are created after validation, off the editor mutation path, and activated atomically.

### 11.4 Performance Budgets

Initial editor budgets, subject to measurement:

- local edit feedback: <= 16 ms p50
- incremental validation: <= 50 ms p95 for 1K elements
- global validation: <= 500 ms p95 for 10K elements
- undo/redo command application: <= 50 ms p95 for normal edits
- save/export: <= 1 s for 10K-element SceneSpec
- graph pan/zoom: 60 FPS target at 1K visible nodes
- offscreen graph nodes use culling or simplified rendering
- 3D authoring preview: 60 FPS target for 10K simple visible objects using instancing and LOD
- 2D/3D selection synchronization: <= 50 ms p95
- floor visibility change: <= 100 ms p95 for 10K authored objects

Benchmarks must report p50/p95/p99 and peak RSS. GPU timing is reported separately from CPU submission time.

## 12. UI and Workflow

The Phase 7C shell gains an explicit mode switch:

- **Monitor**: existing live runtime UI
- **Layout 2D**: primary plan authoring on the active level
- **Preview 3D**: synchronized spatial inspection and runtime preview
- **Process**: DES/control graph

Expected authoring workflow:

1. Create or open a SceneSpec.
2. Add elements from a searchable catalog.
3. Place physical elements in Layout 2D and assign their level, elevation, and height.
4. Inspect the same document immediately in Preview 3D; selection remains synchronized.
5. Connect flow and signal ports in Process mode.
6. Configure properties in the inspector.
7. Select ABM model/backend where supported.
8. Resolve validation diagnostics.
9. Save/export the draft.
10. Compile/load into Julia.
11. Switch to Monitor and run using Phase 7C controls in 2D or 3D preview.

The process graph uses compact edge ports, type colors, tooltips, connection previews, and progressive disclosure for nodes with many ports. Critical state is communicated by text/icon as well as color.

## 13. Import, Export, and Versioning

- Canonical editable format: UTF-8 JSON SceneSpec.
- Production wire format: MessagePack envelope with `scene_spec` kind.
- Exports are atomic: write temporary file, validate, fsync where practical, rename.
- Imports never mutate the open document until parsing and migration complete.
- A preview reports additions, removals, migrations, missing libraries, and diagnostics.
- Round-trip tests compare normalized semantics and preserved unknown fields, not incidental dictionary order.
- Major unsupported schema versions fail without mutation.
- Minor compatible versions preserve unknown fields and apply defaults.

## 14. Security and Reliability

- SceneSpec data is declarative; no arbitrary code runs during import.
- Script references are identifiers resolved through trusted registries.
- File paths are normalized and sandboxed relative to the project where possible.
- Imported resource sizes and nesting depths are bounded.
- Compiler staging prevents invalid scenes from replacing a working runtime.
- Autosave writes recoverable drafts independently of explicit exports.

## 15. Manageable Implementation Plan

### 7D-00: Contract Freeze and Golden Fixtures

**Tasks**:

- [ ] Reconcile SceneSpec examples into one canonical v1 schema.
- [ ] Freeze Y-up X/Z plan coordinates, physical transforms, levels, elevation/height, and graph-layout metadata fields.
- [ ] Define unknown-field preservation rules.
- [ ] Define normalized semantic equality.
- [ ] Create minimal DES, ABM, hybrid, two-level spatial, invalid, missing-library, and future-field fixtures.
- [ ] Add Julia SceneSpec encode/decode/round-trip tests.
- [ ] Add Godot fixture decode/encode tests.

**Exit criteria**: Golden fixtures round-trip Julia -> Godot -> Julia without topology, IDs, metadata, or unknown-field loss.

### 7D-01: Typed SceneSpec Core

**Tasks**:

- [ ] Add typed Julia records for scene metadata, simulation, spatial levels/transforms, elements, ports, connections, subgraphs, and diagnostics.
- [ ] Add Godot-side authoring records/resources with extension storage.
- [ ] Implement parse, normalize, clone, semantic comparison, and immutable snapshot APIs.
- [ ] Add v1 minor-version migration hooks.
- [ ] Enforce size, depth, and ID limits.

**Exit criteria**: Typed cores pass schema, compatibility, malformed-input, and unknown-field tests without GUI dependencies.

### 7D-02: Element and Model Registries

**Tasks**:

- [ ] Define `ElementDefinition`, property schema, port schema, and runtime factory interfaces.
- [ ] Define 2D footprint, procedural 3D, registered asset, pivot, material, and LOD metadata interfaces.
- [ ] Define `ModelDefinition` and CPU/GPU capability metadata.
- [ ] Register source, sink, queue, server, buffer, conveyor, router, and conditional merge definitions.
- [ ] Register supported ABM models and parameters.
- [ ] Implement version resolution and missing-definition placeholders.
- [ ] Add registry conformance tests.

**Exit criteria**: A new test element and model register without modifying editor-core source files.

### 7D-03: Document Store and Command History

**Tasks**:

- [ ] Implement revisioned `SceneDocumentStore`.
- [ ] Implement command apply/revert and bounded undo/redo.
- [ ] Group drag, bulk edit, and paste operations into transactions.
- [ ] Track dirty/save/autosave revisions.
- [ ] Implement deterministic ID creation and remapping.
- [ ] Add command property-based or sequence tests.

**Exit criteria**: Random valid edit/undo sequences return to the exact normalized starting document.

### 7D-04: Incremental Validation and Diagnostics

**Tasks**:

- [ ] Implement shared compatibility fixtures and Godot local rules.
- [ ] Implement authoritative Julia structural, semantic, dependency, and capability validation.
- [ ] Add debounced global validation on immutable revisions.
- [ ] Add diagnostic index, navigation, and suggested-fix command hooks.
- [ ] Discard stale worker results by revision.
- [ ] Benchmark 1K and 10K element validation.

**Exit criteria**: Invalid fixtures produce the same rule IDs in Julia and Godot, and editor interaction stays within the stated budgets.

### 7D-05: Authoring Shell and Catalog

**Tasks**:

- [ ] Add Monitor/Layout/Process mode navigation.
- [ ] Add Preview 3D mode navigation and shared selection state.
- [ ] Add new/open/save/save-as/autosave state.
- [ ] Add searchable registry-driven element catalog.
- [ ] Add scene hierarchy and diagnostic panels.
- [ ] Add missing-library placeholder visuals.
- [ ] Persist panel layout independently of simulation state.

**Exit criteria**: Users can create an empty scene, add registered elements, save a draft, reopen it, and see diagnostics.

### 7D-06: Physical Layout Editor

**Tasks**:

- [ ] Add selection, multi-select, move, rotate, scale, duplicate, and delete.
- [ ] Add snapping, guides, world units, bounds, and camera fit.
- [ ] Add level creation, active-level isolation, elevation, and local-height editing.
- [ ] Add geometry editors for rooms, walls, doors, exits, gates, machines, conveyors, queues, and buffers.
- [ ] Generate inspector fields from property schemas.
- [ ] Add transform and geometry validation.
- [ ] Add undo/redo and round-trip tests for every tool.

**Exit criteria**: A multi-level warehouse/crowd layout can be authored in plan view, saved, reopened, and compared semantically without loss.

### 7D-06A: Synchronized 3D Spatial View

**Purpose**: Let users author efficiently in 2D and immediately inspect the same scene in 3D without duplicating scene state.

**Tasks**:

- [ ] Add Preview 3D mode backed by the same `SceneDocumentStore` revision as Layout 2D.
- [ ] Generate deterministic 3D fallback geometry from footprints, paths, dimensions, elevation, and height.
- [ ] Add registry-provided 3D scenes/meshes, pivot metadata, material slots, and procedural fallback rules.
- [ ] Synchronize selection, hover, visibility, focus, and inspector state between 2D and 3D.
- [ ] Add orbit, pan, zoom, frame-selection, orthographic/perspective, and active-level isolation controls.
- [ ] Add floor slabs, ceilings, wall extrusion, openings, and optional cutaway/exploded-level views.
- [ ] Add stairs, ramps, elevators, lifts, and multi-level conveyors as validated vertical connectors.
- [ ] Display authored and live entities at their X/Y/Z position, with level/elevation fallback when only plan coordinates are available.
- [ ] Add instancing, frustum culling, visibility ranges, LOD, and aggregate rendering for large 3D previews.
- [ ] Add 2D-to-3D semantic parity, selection synchronization, multi-level, and performance tests.

**Initial editing boundary**:

- 2D remains the primary geometry-authoring surface.
- Level, elevation, height, and common dimensions are editable in the inspector and 2D tools.
- 3D initially supports inspection, selection, camera navigation, and simple transform/elevation gizmos.
- General mesh editing and CAD operations remain out of scope.

**Exit criteria**: A user can build a two-floor scene in 2D, assign elevations/heights, connect floors, switch to 3D, inspect the exact same elements and entities, and round-trip the scene without spatial divergence. The 3D preview meets its measured frame and memory budgets.

### 7D-07: Typed Process Graph Editor

**Tasks**:

- [ ] Add compact typed port visuals and overflow disclosure.
- [ ] Add flow, metric/signal, control, and event connection workflows.
- [ ] Reject invalid links during preview and emit diagnostics after import.
- [ ] Add graph culling, pan/zoom, selection, and keyboard deletion.
- [ ] Add auto-layout as an optional worker task.
- [ ] Add 1K-visible-node performance fixture.

**Exit criteria**: Users can build and validate source -> queue -> server -> sink plus a non-local conditional routing example.

### 7D-08: Inspector, Rules, and Runtime Edit Policy

**Tasks**:

- [ ] Render scalar, enum, vector, distribution, resource, and unit-aware fields.
- [ ] Add mixed-value multi-selection editing.
- [ ] Add no-code condition/rule builder and compatible metric browser.
- [ ] Mark restart-required versus runtime-editable properties.
- [ ] Route runtime edits through commands with Ack/Error.
- [ ] Add invalid-input, rule-preview, and command rejection tests.

**Exit criteria**: Property changes validate, undo, save, compile, and either apply live or clearly require restart.

### 7D-09: ABM and Hybrid Configuration

**Tasks**:

- [ ] Add registry-driven ABM model selector.
- [ ] Filter models by scene capabilities and installed backends.
- [ ] Add CPU/GPU preference and fallback controls.
- [ ] Validate required geometry, fields, and hybrid triggers.
- [ ] Add model-switch migration preview.
- [ ] Test SFM, ORCA, HybridFSM, and CSM configurations where supported.

**Exit criteria**: A hybrid fixture switches supported models without losing unrelated SceneSpec content and compiles or returns actionable diagnostics.

### 7D-10: Groups, Templates, and Compound Subgraphs

**Tasks**:

- [ ] Implement groups and nested navigation.
- [ ] Package selections as versioned templates.
- [ ] Instantiate templates with deterministic ID remapping.
- [ ] Expose typed compound ports and parameter overrides.
- [ ] Detect recursion and invalid boundary references.
- [ ] Add template update/detach policy and tests.

**Exit criteria**: A queue-server-router template can be instantiated twice, edited independently, exported, and re-imported without collisions.

### 7D-11: Import, Export, and Scene Repository

**Tasks**:

- [ ] Implement canonical JSON export and MessagePack transport.
- [ ] Implement atomic writes and autosave recovery.
- [ ] Add import migration/diff preview.
- [ ] Preserve unsupported fields and invalid connections.
- [ ] Add recent-project and template repository APIs.
- [ ] Add corruption, cancellation, and interrupted-write tests.

**Exit criteria**: Valid and invalid drafts survive round trip; interrupted export never corrupts the previous valid file.

### 7D-12: Julia Compiler and Runtime Activation

**Tasks**:

- [ ] Define normalized typed compiler IR.
- [ ] Resolve registries, ports, models, units, and dependencies.
- [ ] Build deterministic flow/control schedules.
- [ ] Construct runtime in staging and activate atomically.
- [ ] Produce SceneSpec source-map diagnostics.
- [ ] Support cancellation and stale compile-result rejection.
- [ ] Add deterministic compile and failed-activation tests.

**Exit criteria**: A SceneSpec created in Godot compiles into a runnable Julia DES, ABM, or hybrid scene; failure preserves the previous runtime.

### 7D-13: Performance, Multicore, and GPU Readiness

**Tasks**:

- [ ] Benchmark 1K and 10K element documents and 1K visible graph nodes.
- [ ] Measure edit, validation, save, compile, 2D render, 3D render, GPU submission, and peak RSS separately.
- [ ] Parallelize safe validation/compiler passes with deterministic merging.
- [ ] Add main-thread ownership assertions for Godot UI/GPU resources.
- [ ] Add backend capability/fallback tests.
- [ ] Test cancellation, rapid edits, stale workers, and long sessions.

**Exit criteria**: Budgets are measured at p50/p95/p99, no stale worker mutates a newer document, and CPU/GPU fallback is deterministic.

### 7D-14: End-to-End Acceptance

**Tasks**:

- [ ] Author a minimal DES scene entirely in Godot.
- [ ] Author an ABM layout and select a supported model.
- [ ] Author a hybrid scene with a non-local metric condition.
- [ ] Author a two-level scene in 2D and verify synchronized 3D geometry, vertical connectors, and entity elevations.
- [ ] Save, close, reopen, validate, compile, run, and inspect each scene.
- [ ] Verify undo/redo and autosave recovery.
- [ ] Verify missing-extension repair workflow.
- [ ] Capture performance and usability evidence.

**Exit criteria**: A user can author, validate, persist, compile, run, monitor, and safely revise DES, ABM, and hybrid scenes without editing Julia source, and can inspect the same spatial scene consistently in synchronized 2D and 3D views.

## 16. Dependency Order

```text
7D-00 Contract/Fixtures
  -> 7D-01 Typed SceneSpec Core
    -> 7D-02 Registries
      -> 7D-03 Document/History
        -> 7D-04 Validation
          -> 7D-05 Authoring Shell
            -> 7D-06 Layout Editor
              -> 7D-06A Synchronized 3D View
            -> 7D-07 Process Graph
              -> 7D-08 Inspector/Rules
                -> 7D-09 ABM/Hybrid
                -> 7D-10 Subgraphs
                  -> 7D-11 Import/Export
                    -> 7D-12 Julia Compiler
                      -> 7D-13 Performance/Readiness
                        -> 7D-14 Acceptance
```

Parallelism after foundations:

- 7D-06 and 7D-07 may proceed in parallel after 7D-05.
- 7D-06A starts after the shared spatial schema and first 7D-06 geometry tools stabilize; asset/LOD infrastructure may proceed in parallel.
- Registry fixtures, validator rules, and compiler factories should be developed together per element kind.
- Performance benchmarks begin at 7D-01 and run continuously; 7D-13 is hardening, not the first measurement.

## 17. Test Matrix

### Unit

- schema parsing/defaulting/migration
- unknown-field preservation
- port compatibility and cardinality
- property validation and units
- command apply/revert
- deterministic ID remapping
- subgraph boundary resolution
- registry conformance
- compiler normalization
- level/elevation normalization and vertical connector validation
- procedural 2D-footprint-to-3D geometry generation

### Integration

- Julia <-> Godot SceneSpec round trip
- registry -> catalog -> inspector
- editor transaction -> validation -> serialization
- synchronized 2D selection/edit -> 3D projection -> SceneSpec round trip
- runtime entity position -> level/elevation -> 3D visualization
- SceneSpec -> compiler IR -> runtime
- property edit -> command -> Ack/Error -> refreshed state
- model selection -> capability validation -> backend choice

### Property and Fuzz

- random valid graphs preserve semantics after round trip
- random command sequences undo to the initial document
- malformed/bounded inputs do not crash or allocate without limit
- paste/duplicate never creates ID collisions

### Performance

- 1K/10K element document load and save
- incremental/global validation p50/p95/p99
- graph interaction with 1K visible nodes
- 3D preview with 1K/10K visible authored objects and instanced repeated assets
- multi-floor visibility, cutaway, and 2D/3D selection latency
- compiler multicore scaling and deterministic output
- CPU/GPU backend preparation and fallback
- long-session history and autosave memory growth

### Acceptance Fixtures

- tandem queue DES
- conveyor/packing hierarchy
- room/door crowd ABM
- two-level facility with stairs/elevator and entities on both levels
- hybrid queue-to-crowd transition
- conditional merge with non-local metric
- missing extension and version migration
- reusable queue-server-router template

## 18. Risks and Decisions

### Schema duplication

**Decision**: Keep one semantic schema and golden fixtures. Julia validation is authoritative; Godot local rules optimize feedback.

### Editor/runtime coupling

**Decision**: Compile SceneSpec into a staging runtime and keep RenderState separate.

### Extension drift

**Decision**: Version registries, preserve missing definitions, and require migration hooks for incompatible changes.

### Graph complexity

**Decision**: Use typed links, progressive port disclosure, subgraphs, culling, and optional auto-layout.

### Undo memory growth

**Decision**: Store commands/diffs, merge continuous operations, bound history, and benchmark long sessions.

### Multicore nondeterminism

**Decision**: Parallelize independent immutable passes and merge diagnostics/results in stable order.

### GPU availability

**Decision**: Store backend-neutral intent, validate capabilities, and provide explicit fallback policy.

### 2D/3D spatial divergence

**Decision**: Both views project one canonical Y-up transform and geometry model. No independent Godot 2D and 3D authored copies are allowed. Semantic parity and round-trip tests gate every spatial tool.

### Asset dependence and inconsistent pivots

**Decision**: Registry assets declare pivots, dimensions, material slots, and LOD metadata. Deterministic procedural geometry is always available as a fallback, so missing assets never make a scene invisible or unloadable.

### Multi-floor ambiguity

**Decision**: Levels have stable IDs and elevations; elements declare a level plus normalized elevation semantics. Cross-level movement requires explicit vertical connector elements and cannot be inferred from overlapping plan coordinates.

### Invalid imported scenes

**Decision**: Preserve and repair invalid drafts; block compilation, not opening or saving.

## 19. First Implementation Slice

Start with one vertical slice rather than the full editor:

1. Canonical minimal DES SceneSpec fixture: source -> queue -> server -> sink on a named ground level with explicit spatial metadata.
2. Julia and Godot typed parsing with unknown-field preservation.
3. Registry definitions for those four elements.
4. Pure port/type validator.
5. Minimal document store with add/move/connect/property commands and undo.
6. Canonical JSON save/reopen.
7. Minimal deterministic 3D projection test from the same element transforms and footprints.
8. Headless Julia -> Godot -> Julia round-trip test.

This slice proves the contract and ownership boundaries before investing in the full visual editor.
