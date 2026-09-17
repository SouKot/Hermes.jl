# Phase 7C: Godot GUI Shell and Live Visualization

**Date**: 2026-09-17
**Status**: 7C-00 and 7C-01 implemented; live Julia interoperability validated
**Prerequisite**: Phase 7B bridge implementation and bridge-only acceptance complete
**External gate**: Live WebSocket, Godot decoding, rendering, and backpressure measurements

## 1. Purpose

Phase 7C creates the first usable Godot 4 client for the Julia simulation bridge. It is the visual and interactive consumer of Protocol v1.

The first release should let a user:

- Connect to a local Julia runtime.
- Receive and validate Hello, Snapshot, Delta, Ack, and Error messages.
- View DES elements and entities in a live viewport.
- Inspect selected element/entity state.
- Play, pause, step, reset, and change simulation speed.
- See connection, simulation, FPS, entity-count, and warning status.
- Recover from reconnects, stale deltas, and malformed messages.

The complete scene editor, extension marketplace, advanced port authoring, replay timeline, and GPU renderer should be built on these foundations rather than mixed into the first shell.

## 2. Current Foundation

Phase 7B already provides:

- Protocol v1 envelope and payload definitions.
- MessagePack production transport and JSON debug output.
- Snapshot and delta generation.
- Dirty-state and adaptive update policies.
- Typed full snapshot and typed delta byte paths.
- Command worker infrastructure.
- DES, ABM, and hybrid adapter concepts.
- Performance benchmarks through 500K elements/entities.

The Godot client must treat Protocol v1 as the external contract. It must not depend on Julia implementation details such as `ElementState`, `EntitySnapshot`, adapter types, or Julia dictionaries.

## 3. Scope

### 3.1 In Scope for Phase 7C

- New Godot 4 desktop project.
- Transport connection lifecycle.
- MessagePack decoding for Protocol v1.
- Client-side state store for full snapshots and deltas.
- Live viewport rendering.
- DES element visualization.
- Entity visualization and basic trajectories.
- Runtime control strip.
- Inspector and status panels.
- Reconnect and revision recovery behavior.
- Frame-time and render-performance instrumentation.
- Minimal end-to-end test scene and Julia fixture.

### 3.2 Explicitly Deferred

- Full SceneSpec authoring and persistence editor.
- Typed flow/control port graph editor.
- Arbitrary extension/plugin marketplace.
- Complex timeline/replay controls.
- GPU rendering backend.
- Collaborative editing.
- Production packaging and distribution.

These belong to Phase 7D or later, but Phase 7C must leave extension points for them.

## 4. Design Principles

### 4.1 Protocol Boundary

The Godot client consumes decoded protocol records, not Julia structs. Every inbound message passes through:

```text
WebSocket bytes
    -> MessagePack decoder
    -> envelope validation
    -> payload validation
    -> revision/state application
    -> render snapshot
```

Malformed messages must become visible protocol errors, not crashes in the render loop.

### 4.2 Separate Simulation State from Render State

The network thread/task must never mutate scene nodes directly.

```text
Transport task
    -> inbound message queue
    -> protocol/state task
    -> immutable or versioned RenderState
    -> render thread / scene nodes
```

The viewport consumes the latest complete render state. If rendering falls behind, it may skip intermediate states but must not apply deltas out of order.

### 4.3 Separate Runtime UI from Authoring UI

The first shell uses the same panel roles planned for authoring, but the authoring controls remain shallow:

```text
left:   scene hierarchy / connection status
center: live viewport
right:  inspector / selected state
bottom: transport controls / timeline placeholder / metrics
```

The panel system should be replaceable and persist layout state without coupling to simulation data.

### 4.4 Data-Oriented Rendering

Do not create one heavyweight Godot node per agent at 500K scale.

Use:

- `MultiMeshInstance2D` or equivalent instanced rendering for entities.
- Packed arrays for positions, colors, scales, and visibility.
- Separate lightweight nodes for selected/inspected entities.
- Batched element rendering by element kind.
- Optional pooled trajectory line data with a configurable display cap.

The renderer must have explicit degradation modes:

- Full detail.
- Reduced trajectory detail.
- Aggregated density view.
- Entity sampling or visibility culling.

### 4.5 Extensibility

Use interfaces/resources for:

- Message handlers.
- Render layers.
- Element visualizers.
- Entity visualizers.
- Inspector providers.
- Command providers.
- Future flow/control port visualizers.

A new model type should register visualizers and metadata rather than modify the transport core.

## 5. Proposed Godot Architecture

```text
GodotBridgeClient
├── ConnectionManager
│   ├── WebSocket transport
│   ├── reconnect policy
│   └── connection status
├── ProtocolCodec
│   ├── MessagePack decoder
│   ├── envelope validation
│   └── payload validation
├── InboundMessageQueue
├── SimulationStateStore
│   ├── full snapshot application
│   ├── delta application
│   ├── revision tracking
│   └── resync requests
├── RenderStatePublisher
├── CommandClient
│   ├── play/pause/step/reset
│   └── command acknowledgements
├── ViewportController
│   ├── element layer
│   ├── entity layer
│   ├── trajectory layer
│   └── overlay layer
├── InspectorController
├── SceneHierarchyController
└── StatusController
```

### 5.1 ConnectionManager

Responsibilities:

- Connect to configurable host/port.
- Send or await Hello handshake.
- Track connection state: `disconnected`, `connecting`, `connected`, `degraded`, `reconnecting`.
- Reconnect with bounded exponential backoff.
- Notify other systems through signals/events.
- Never block the render thread.

Configuration:

```text
host: 127.0.0.1
port: 9000
reconnect_enabled: true
max_reconnect_delay_ms: 5000
message_queue_capacity: configurable
```

### 5.2 ProtocolCodec

Responsibilities:

- Decode MessagePack bytes.
- Validate envelope version and message kind.
- Validate required payload fields.
- Preserve unknown extension fields where possible.
- Produce structured decode errors with message IDs.

JSON is allowed only for debug fixtures and diagnostics. Production traffic remains MessagePack.

### 5.3 SimulationStateStore

State store responsibilities:

- Apply a full snapshot atomically.
- Apply a delta only when `parent_message_id` or revision matches the local state.
- Reject stale or out-of-order deltas.
- Request or wait for a full snapshot after mismatch.
- Maintain indexed element/entity state.
- Publish immutable/versioned render data.

Conceptual state:

```text
StateStore
├── scene_id
├── snapshot_version
├── simulation_time
├── step_count
├── simulation_state
├── elements_by_id
├── entities_by_id
├── abm_state
├── overlays
├── warnings
├── last_message_id
└── revision
```

The store should not expose mutable dictionaries directly to scene nodes.

### 5.4 ViewportController

Initial rendering layers:

1. Background/world layer.
2. DES element layer.
3. Entity instancing layer.
4. Trajectory layer.
5. ABM density/heatmap layer.
6. Selection/highlight layer.
7. Warning/overlay layer.

Coordinate handling must be explicit:

- Simulation coordinates to viewport coordinates.
- Origin and axis orientation.
- Scale and camera transform.
- World bounds and auto-fit.
- Missing or invalid coordinates.

### 5.5 CommandClient

Commands should be asynchronous:

```text
user action
    -> command ID
    -> MessagePack Command
    -> pending command map
    -> Ack/Error
    -> UI state update
```

The UI must show pending and rejected states. It must not assume that clicking `play` means the simulation is already running.

### 5.6 InspectorController

The inspector consumes a generic inspected-state interface:

```text
Inspectable
├── display name
├── kind
├── stable ID
├── standard fields
├── metrics
├── properties
└── extension fields
```

This allows DES queues, ABM agents, hybrid elements, and future plugin types to share the inspector without sharing rendering code.

## 6. UI Design

### 6.1 Initial Layout

```text
┌──────────────────────┬──────────────────────────────────────────────┬──────────────────────┐
│ Scene / Runtime Tree │                 Live Viewport                │ Inspector / Metrics  │
│ connection state     │ elements, entities, overlays                │ selected state       │
│ element groups       │ camera and render diagnostics                │ properties           │
├──────────────────────┴──────────────────────────────────────────────┴──────────────────────┤
│ connection | play | pause | step | reset | speed | sim time | FPS | entities | warnings  │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Required States

Every major panel needs:

- Loading state.
- Connected/ready state.
- Disconnected state.
- Reconnecting state.
- Protocol error state.
- Empty state.
- Overload/degraded-render state.

### 6.3 Accessibility and Usability

- Keyboard-accessible play/pause/step/reset.
- Visible focus state.
- Text labels or tooltips for unfamiliar controls.
- No critical state communicated by color alone.
- Stable panel dimensions so live data cannot resize the layout.

## 7. Manageable Implementation Plan

### 7C-00: Project Bootstrap

**Deliverables**:

- Godot 4 project.
- Main scene.
- Basic theme and layout resources.
- Local development configuration.

**Tasks**:

- [x] Create `project.godot`.
- [x] Create main scene and root application controller.
- [x] Add reusable panel layout.
- [x] Add local host/port settings.
- [x] Add a deterministic placeholder scene for offline UI development.

**Exit criteria**: Project opens and displays the shell without a Julia runtime.

### 7C-01: Protocol and Connection Layer

**Deliverables**:

- WebSocket connection manager.
- MessagePack decoder.
- Hello handshake.
- Reconnect state machine.

**Tasks**:

- [x] Implement connection lifecycle signals.
- [x] Implement binary receive queue.
- [x] Implement MessagePack envelope decoding.
- [x] Validate protocol version and message kind.
- [x] Add reconnect backoff.
- [x] Add malformed-message handling.
- [x] Add a fake transport for deterministic tests.

**Exit criteria**: Godot connects to the Julia fixture, receives Hello, and recovers from disconnect.

### 7C-02: Client State Store

**Deliverables**:

- Full snapshot application.
- Delta application.
- Revision mismatch handling.
- Render-state publication.

**Tasks**:

- [x] Define typed Godot-side records for envelope and payloads.
- [x] Index elements and entities by stable ID.
- [x] Apply full snapshots atomically.
- [x] Apply added/updated/removed elements.
- [x] Apply entity lifecycle and movement updates.
- [x] Reject stale deltas.
- [x] Request or wait for resynchronization after mismatch.
- [x] Add fixture-based snapshot/delta tests.

**Exit criteria**: A deterministic message sequence produces the expected state store contents.

### 7C-03: Viewport Foundation

**Deliverables**:

- Camera and coordinate transform.
- Element layer.
- Instanced entity layer.
- Selection/highlight layer.

**Tasks**:

- [ ] Implement world-to-viewport transform.
- [ ] Render queues/resources with stable visual identity.
- [ ] Render entities using instancing.
- [ ] Update transforms from published render state.
- [ ] Add camera pan/zoom/fit.
- [ ] Add selection by stable ID.
- [ ] Add a render cap and degraded mode.

**Exit criteria**: 100K synthetic entities render without one-node-per-entity architecture.

### 7C-04: Runtime Controls and Inspector

**Deliverables**:

- Control strip.
- Command client.
- Inspector.
- Status metrics.

**Tasks**:

- [ ] Add play/pause/step/reset controls.
- [ ] Add speed control.
- [ ] Track pending command IDs.
- [ ] Render Ack/Error results.
- [ ] Add element/entity inspector.
- [ ] Add simulation time and step display.
- [ ] Add FPS, update rate, entity count, and warning counters.

**Exit criteria**: Every control produces a protocol command and displays its acknowledged/rejected state.

### 7C-05: Trajectories, ABM Fields, and Overlays

**Deliverables**:

- Optional trajectory layer.
- Density/heatmap layer.
- Overlay and warning layer.

**Tasks**:

- [ ] Add trajectory sampling and display cap.
- [ ] Add density-grid visualization.
- [ ] Add heatmap color mapping.
- [ ] Add warning/overlay rendering.
- [ ] Add toggles for expensive visual layers.
- [ ] Benchmark each layer independently.

**Exit criteria**: ABM and DES states can be displayed together without coupling their renderers.

### 7C-06: Performance and Resilience

**Deliverables**:

- Render/update benchmark harness.
- Backpressure behavior.
- Reconnect and recovery tests.

**Tasks**:

- [ ] Add synthetic 10K/100K/500K message fixtures.
- [ ] Measure decode time.
- [ ] Measure state-store application time.
- [ ] Measure render submission time.
- [ ] Measure frame time and p99 frame time.
- [ ] Test slow transport and dropped deltas.
- [ ] Test reconnect and full snapshot recovery.
- [ ] Add memory-growth checks.

**Exit criteria**: A slow client cannot block the simulation, and a reconnect recovers to a valid full state.

### 7C-07: End-to-End Acceptance

**Deliverables**:

- Julia fixture runtime.
- Godot automated smoke test.
- Manual acceptance checklist.

**Tasks**:

- [ ] Start Julia fixture and Godot client together.
- [ ] Verify Hello handshake.
- [ ] Verify full snapshot display.
- [ ] Verify delta stream display.
- [ ] Verify play/pause/step/reset.
- [ ] Verify selection and inspector.
- [ ] Verify disconnect/reconnect.
- [ ] Capture desktop and viewport metrics.

**Exit criteria**: A user can connect, observe, control, disconnect, reconnect, and recover a simulation without manual state repair.

## 8. Dependency Order

```text
7C-00 Bootstrap
    -> 7C-01 Connection/Protocol
        -> 7C-02 State Store
            -> 7C-03 Viewport
                -> 7C-04 Controls/Inspector
                    -> 7C-05 ABM/Overlays
                        -> 7C-06 Performance/Resilience
                            -> 7C-07 End-to-End Acceptance
```

7C-03 can use an offline fake state store while 7C-01/7C-02 are developed. 7C-05 should not block the first live DES viewport. 7C-06 must begin before visual polish is considered complete.

## 9. Testing Strategy

### Unit Tests

- Protocol decoder fixtures.
- State-store snapshot/delta transitions.
- Revision mismatch handling.
- Command pending/ack/error transitions.
- Coordinate transforms.
- Render-layer visibility rules.

### Integration Tests

- Julia fixture to Godot Hello.
- Full snapshot followed by deltas.
- Entity arrival/departure/movement.
- Reconnect and full resynchronization.
- Slow-client queue behavior.

### Performance Tests

Measure separately:

- MessagePack decode.
- State application.
- Render-state publication.
- Viewport submission.
- Actual frame time.
- Memory growth.

Use median and p99 values. Do not accept a design based only on mean FPS.

## 10. Phase 7C Acceptance Criteria

Phase 7C is complete only when:

- [ ] Godot project opens and runs offline.
- [ ] Godot connects to Julia using Protocol v1 MessagePack.
- [ ] Full snapshots and deltas produce correct visible state.
- [ ] DES elements, entities, and ABM fields render through separate layers.
- [ ] Runtime controls produce and handle commands.
- [ ] Inspector displays selected state and extension properties.
- [ ] Reconnect and revision mismatch recovery work.
- [ ] 100K+ entities use instanced/batched rendering.
- [ ] Slow clients do not block simulation updates.
- [ ] Median and p99 frame metrics are recorded.
- [ ] No unbounded memory growth in a long-running fixture.
- [ ] Manual and automated smoke checks pass.

## 11. Risks and Decisions

### Risk: Protocol drift

**Decision**: Generate or validate Godot-side records against Protocol v1 fixtures. Do not duplicate protocol semantics informally in UI code.

### Risk: Node-per-entity rendering

**Decision**: Use instancing and packed render arrays from the first viewport implementation.

### Risk: Full snapshot stalls

**Decision**: Apply full snapshots atomically off the render path where practical and show a degraded/loading state for large recovery snapshots.

### Risk: Slow WebSocket client

**Decision**: Per-client bounded queues, stale-delta dropping, and full resynchronization.

### Risk: Overbuilding the editor too early

**Decision**: Finish the monitoring/control shell and state-store contract before SceneSpec authoring.

### Risk: GPU assumptions

**Decision**: Keep GPU rendering optional. The first renderer must be correct and measurable on CPU-compatible hardware.

## 12. Immediate Next Actions

1. Create the Godot 4 project and main scene.
2. Create a deterministic Julia fixture that emits Hello, full snapshot, deltas, and command acknowledgements.
3. Implement `ConnectionManager` and fake transport together.
4. Implement the state store before scene-node wiring.
5. Render a single queue and a small entity set.
6. Add the first end-to-end smoke test.
7. Measure decode, state application, and frame time before expanding the UI.

## 13. Bootstrap Status

The initial Godot project shell now exists at `ABM/godot/` with:

- Godot 4.7.2 project configuration.
- Main scene and controller script.
- Offline monitoring layout with runtime tree, viewport, inspector, and transport strip.
- Placeholder DES/entity visualization.
- Play, pause, step, reset, and connect fixture controls.

The shell is intentionally offline-first. WebSocket and MessagePack integration
begin in 7C-01 after the visual layout and control loop are verified.

## 14. 7C-01 Implementation Status

The connection/protocol layer is now implemented in `godot/scripts/`:

- `protocol_codec.gd`: MessagePack encode/decode for Protocol v1 primitives,
    envelope validation, and bounded nesting depth.
- `connection_manager.gd`: `WebSocketPeer` lifecycle, binary packet handling,
    reconnect backoff, connection-state signals, and protocol-error signals.
- `fake_transport.gd`: deterministic message/byte injection for offline tests.
- `tests/protocol_smoke.gd`: headless codec smoke test covering Hello-style
    envelopes, maps, arrays, strings, numbers, booleans, and schema validation.

Godot 4.7.2 headless validation passes. The live interoperability smoke test
also passes against the Julia bridge through `HTTP.WebSockets`: Godot receives
Hello, Snapshot, and Ack messages, and Julia receives the Godot command. The
next 7C task is the state store and delta application layer.

## 15. 7C-02 Implementation Status

The client state store is implemented in `godot/scripts/state_store.gd`.
It atomically applies full snapshots, indexes elements and entities by stable
ID, applies lifecycle/update deltas, tracks revisions and parent message IDs,
publishes render-state dictionaries, and emits a resync signal for stale or
out-of-order deltas. The main shell is wired to consume published state.

Headless validation passes through `tests/state_store_smoke.gd`.
