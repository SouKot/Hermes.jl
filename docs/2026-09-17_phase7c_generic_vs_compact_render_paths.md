# Phase 7C: Generic vs Compact Render Paths

## Summary

The Godot client now has two entity-state representations:

1. **Generic path**: full per-entity dictionaries retained in `entities_by_id`.
2. **Compact path**: packed positions and IDs retained in contiguous arrays and rendered through `MultiMeshInstance2D`.

The generic path is optimized for usability and inspection. The compact path is optimized for scale and memory behavior.

## Generic Path

### What it stores

Each entity remains a full Godot `Dictionary`, including fields such as:

- stable ID
- kind
- current location
- trajectory history
- properties
- extension fields

The state store indexes these dictionaries by ID. Render-state publication deep-copies the dictionaries so the viewport does not mutate protocol state.

### Advantages

- Preserves all protocol fields.
- Easy to inspect selected entities.
- Supports arbitrary extension properties.
- Simple to debug and reason about.
- Works naturally with lifecycle deltas that add, update, or remove individual entities.
- Best representation for small and medium scenes.

### Disadvantages

- High allocation overhead per entity.
- Many strings, hash tables, arrays, and object headers.
- Deep copies multiply memory use.
- MessagePack encode/decode creates additional simultaneous representations.
- Poor fit for 100K-500K entity rendering.
- Per-entity trajectories and properties are expensive when most entities are only being drawn as points.

### Measured 500K behavior

The current generic synthetic path measured:

- Peak RSS: `6,369,472 KB`, approximately `6.08 GiB`
- Decode p99: approximately `11.06 s`
- State-application p99: approximately `4.36 s`
- Render-state publication p99: approximately `1.33 s`

This is not an acceptable 500K live-client representation.

## Compact Path

### What it stores

For large entity populations, the snapshot carries a compact binary position buffer:

```text
[x0, y0, x1, y1, x2, y2, ...]
```

The state store converts it into:

- `PackedVector2Array` positions
- `PackedStringArray` stable IDs
- no per-entity dictionaries
- no trajectory/property dictionaries for the bulk render population

The viewport submits those positions through one `MultiMeshInstance2D`.

### Advantages

- Memory scales close to linearly with numeric data volume.
- Avoids per-entity dictionaries and strings in the render path.
- Avoids deep-copying a 500K entity object graph.
- Matches Godot's instanced-rendering architecture.
- Supports visibility caps and degraded rendering.
- Much lower decode/state/render overhead for bulk visualization.
- Suitable for 100K-500K entity populations.

### Disadvantages

- Does not preserve arbitrary per-entity fields in the bulk render representation.
- Individual inspection requires a separate detail channel or lookup mechanism.
- Entity lifecycle deltas must be designed around packed-array updates or periodic compact snapshots.
- Trajectories need a separate bounded buffer or sampling policy.
- Less convenient for debugging than dictionaries.
- Requires protocol producers to publish compact numeric fields consistently.

### Measured 500K behavior

The compact end-to-end synthetic path measured:

- Peak RSS: `239,056 KB`, approximately `234 MiB`
- Decode p99: `1.621 ms`
- State-application p99: `182.435 ms`
- Render-state publication p99: `0.003 ms`
- MultiMesh viewport submission p99: `0.005 ms`

The isolated MultiMesh smoke test measured:

- Peak RSS: `102,428 KB`, approximately `100 MiB`
- Frame p50: `6.899 ms`
- Frame p99: `6.914 ms`

Compared with the generic path, the compact end-to-end path reduced peak RSS by approximately 26.6x.

## Selection Rule

The current state-store threshold is:

```text
entity_count < 10,000  -> generic dictionaries
entity_count >= 10,000 -> compact packed representation
```

### Use the generic path when

- The scene has fewer than 10,000 entities.
- The user is actively inspecting entity properties.
- The model has rich heterogeneous extension fields.
- Per-entity trajectories are important.
- Debugging protocol content is more important than maximum throughput.

The current six-entity Phase 7C fixture uses this path. That is why selection and inspector details remain straightforward.

### Use the compact path when

- The scene has 10,000 or more entities.
- The primary task is monitoring motion, occupancy, density, or aggregate behavior.
- Most entities share the same visual representation.
- Memory and frame time are the limiting concerns.
- The renderer can use sampling, culling, or aggregation.

The compact path should be the default for large DES, ABM, and hybrid populations.

## Inspection Strategy for Compact Scenes

Compact rendering does not eliminate inspection. It changes how inspection works:

1. Render all entities through packed arrays and MultiMesh.
2. Pick an entity by index or spatial lookup.
3. Request or retrieve detailed state for only the selected entity.
4. Display that detail in the inspector.
5. Keep only a small number of selected/detail records as dictionaries.

This avoids retaining 500K full dictionaries merely to inspect one entity.

## Protocol Recommendation

Protocol v1 should support both forms explicitly:

- full entity records for small scenes and detail snapshots
- compact binary positions/velocities/colors/IDs for large scenes
- metadata declaring entity count, coordinate layout, and numeric types
- bounded trajectory samples rather than unbounded histories

The compact path should not silently discard information. It should make clear which fields are bulk-render fields and which are available through detail lookup.

## Decision

Use a hybrid client strategy:

- **Generic dictionaries for interaction and inspection at small scale.**
- **Packed arrays plus MultiMesh for bulk visualization at large scale.**
- **Detail-on-demand lookup for selected compact entities.**
- **Explicit caps for trajectories, density cells, and selected records.**

The generic path remains valuable, but it must not be used as the 500K rendering architecture.

## Remaining Acceptance Boundary

The compact path has passed synthetic 500K state-store and MultiMesh measurements. Final 500K GUI acceptance still requires a connected Julia fixture that emits the compact binary position payload and a connected Godot process that receives and renders it end to end.
