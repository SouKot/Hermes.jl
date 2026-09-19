# SceneSpec v1 Specification & Contract Freeze

**Date**: 2026-09-18  
**Status**: Frozen v1 Contract  
**Applies to**: `GodotBridge` (Julia), `godot/` (Godot 4 Client), and `fixtures/scenespec/`

---

## 1. Overview & Purpose

`SceneSpec v1` is the declarative interchange contract between the authoring frontend (Godot) and the simulation runtime (Julia). It completely describes the intent, geometry, process topology, and simulation parameters of a discrete-event (DES), agent-based (ABM), or hybrid simulation.

`SceneSpec` is **not** a live simulation state. It describes:
1. **Physical Layout**: spatial elements, transforms, geometry, levels, and elevation.
2. **Process Graph**: process flow, signal, and metric connections between typed ports.
3. **Simulation Configuration**: time, units, random seed, and selected crowd models.
4. **Authoring Metadata**: process canvas positions, colors, and notes.

---

## 2. Coordinate System & Spatial Model

### 2.1 Right-Handed Z-Up Convention

`SceneSpec v1` canonically adopts the **right-handed Z-up** coordinate system:

| Axis | Meaning | 2D Plan Orientation |
| :--- | :--- | :--- |
| **$X$** | Horizontal East / West | Horizontal axis on screen ($+X$ = right) |
| **$Y$** | Horizontal North / South | Vertical axis on screen ($+Y$ = up/north) |
| **$Z$** | Vertical Elevation / Height | Out of the screen towards the viewer ($+Z$ = up) |

### 2.2 Alignment with 2D Plan and Simulation Physics

1. **Floor Plan Directness**: In 2D floor plans, math, and CAD, the ground plane is naturally $(X, Y)$. Placing an object at $(x, y)$ in the 2D layout editor directly corresponds to ground coordinates without axis swapping.
2. **Julia Physics Consistency**: In `SimCore` and `SimCrowd`, 2D agents and obstacles are parameterized as $(x, y)$ coordinates with $(v_x, v_y)$ velocities. With $Z$-up, $(x, y)$ are the ground coordinates, and $Z$ is the level elevation.
3. **Godot 3D Visualization Boundary**: Godot's 3D engine is internally $Y$-up. The 3D viewport renderer projects SceneSpec coordinates:
   $$(x_{\text{godot}}, y_{\text{godot}}, z_{\text{godot}}) = (x, z, -y)$$
   This transformation is isolated to the 3D rendering boundary. The underlying simulation data model remains strictly $Z$-up.

### 2.3 Levels & Vertical Elevation

The root `spatial` section defines levels:

```json
"spatial": {
  "coordinate_system": "right_handed_z_up",
  "length_unit": "meters",
  "origin": [0.0, 0.0, 0.0],
  "levels": [
    {
      "id": "level_ground",
      "name": "Ground Floor",
      "elevation": 0.0,
      "default_height": 3.0,
      "visible": true
    },
    {
      "id": "level_mezzanine",
      "name": "Mezzanine Level",
      "elevation": 3.5,
      "default_height": 3.0,
      "visible": true
    }
  ]
}
```

For any level-bound element:
$$Z = \text{level.elevation} + \text{local\_elevation\_offset}$$

Vertical connectors (stairs, elevators, ramps, vertical conveyors) reference `source_level_id` and `target_level_id` and specify `vertical_extent: { "base_elevation": z_min, "height": delta_z }`.

---

## 3. Schema Structure

### 3.1 Root Object

| Field | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `spec_version` | String | Yes | Version string, canonically `"1.0.0"`. |
| `scene` | Object | Yes | Scene identification and authoring metadata. |
| `simulation` | Object | Yes | Simulation execution configuration. |
| `abm_config` | Object / null | Yes | Crowd / agent dynamics configuration. |
| `spatial` | Object / null | No | Multi-level and coordinate system metadata. |
| `elements` | Array of Object | Yes | Spatial and process elements. |
| `connections` | Array of Object | Yes | Directed links between element ports. |
| `subgraphs` | Array of Object | Yes | Groups, templates, and compound nodes. |
| `overlays` | Array of Object | Yes | Visual layers (heatmaps, paths, zones). |
| `validation_metadata` | Object | Yes | Validation status and diagnostic records. |
| `extensions` | Object | No | Namespaced extension dictionary. |
| *(unknown)* | Any | No | Any additional unknown root keys preserved verbatim. |

### 3.2 Physical Transform vs. Process Graph Canvas

Physical placement and process graph layout are strictly separated in every element:

```json
{
  "id": "queue_01",
  "name": "Buffer Queue",
  "kind": "queue",
  "library": "SimElements/DES",
  "library_version": "1.0.0",
  "level_id": "level_ground",
  "transform": {
    "position": [10.0, 20.0, 0.0],
    "rotation": [0.0, 0.0, 0.0],
    "scale": [1.0, 1.0, 1.0]
  },
  "geometry": {
    "shape": "box",
    "dimensions": [4.0, 2.0, 1.0]
  },
  "editor": {
    "graph_position": [240.0, 120.0],
    "collapsed": false,
    "color": "#4A90E2",
    "notes": "Main intake buffer"
  }
}
```

- `transform`: Absolute 3D coordinates $(X, Y, Z)$ in meters.
- `editor.graph_position`: 2D canvas coordinates $(u, v)$ in pixels for the process flow editor.

---

## 4. Typed Port Taxonomy

Every element exposes typed ports:

| Port Kind | Direction | Allowed Target Kinds | Cardinality | Usage |
| :--- | :--- | :--- | :--- | :--- |
| `flow` | `output` | `flow` (`input`) | `one` or `many` | Physical or logical discrete entities moving through network. |
| `metric` | `output` | `signal`, `control` (`input`) | `many` | Continuous or sampled telemetry (e.g. queue length, occupancy). |
| `signal` | `input` / `output` | `signal`, `control` (`input`) | `one` or `many` | Control signals or trigger thresholds for conditional logic. |
| `control` | `input` | `signal`, `metric` (`output`) | `one` | Parameter modulating behavior (e.g. service rate, door open/closed). |
| `event` | `output` | `event`, `control` (`input`) | `many` | Discrete triggers (e.g. breakdown, alarm, shift change). |

### Cardinality Rules
- `one`: Exactly zero or one incoming/outgoing link permitted.
- `many`: Multiple connections permitted.

---

## 5. Unknown-Field Preservation Rules

To guarantee forward and backward compatibility:
1. **Root-Level Unknowns**: Any key at the root of a SceneSpec payload that is not defined in Section 3.1 must be preserved verbatim in `extensions` (or as a direct property) and written back during serialization.
2. **Element-Level Unknowns**: Any key inside an element record that is not recognized must be retained and re-emitted without modification.
3. **Port, Connection, Level & Subgraph Unknowns**: Any extra fields on child records must survive decoding and encoding.
4. **Explicit `extensions` Maps**: `extensions` dictionaries at any level are preserved verbatim as namespaced user data.
5. **No Data Loss on Partial Support**: If Godot or Julia does not understand a library, element kind, or attribute, it must not drop or alter that data.

---

## 6. Normalized Semantic Equality

Two SceneSpec documents $A$ and $B$ are **semantically equal** ($A \equiv B$) if and only if:

1. **Key Order Independence**: Object/map key ordering is completely ignored (`{"a": 1, "b": 2} == {"b": 2, "a": 1}`).
2. **Floating-Point Tolerance**: All floating-point numbers are compared with tolerance:
   $$|a - b| \le \text{atol} + \text{rtol} \times |b|, \quad \text{atol} = 10^{-6}, \; \text{rtol} = 10^{-6}$$
   Integers and floats that represent identical values (e.g. `1` vs `1.0`) are considered equal in JSON numeric contexts.
3. **Keyed Array Order Independence**: Arrays of records that possess a unique `id` attribute are compared as unordered sets sorted by `id`:
   - `elements` (sorted by `id`)
   - `connections` (sorted by `id`)
   - `subgraphs` (sorted by `id`)
   - `levels` (sorted by `id`)
   - `input_ports`, `output_ports`, `metric_ports` (sorted by `id`)
4. **Preserved Fields Equality**: Unknown fields and `extensions` must be identical under the same recursive rules.
5. **Diagnostics**: When $A \not\equiv B$, the comparator must emit the exact mismatch path (e.g., `elements[id="queue_01"].transform.position[2]: 0.0 != 3.5`).

