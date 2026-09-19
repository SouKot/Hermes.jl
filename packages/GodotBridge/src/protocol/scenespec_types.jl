"""
    scenespec_types.jl

Strongly-typed in-memory domain structures for SceneSpec v1.
Zero GUI dependencies. Provides concrete, immutable types for simulation compilers,
graph analysis, and validation engines with lossless round-trip capability to
SceneSpecPayload and untyped dictionaries.
"""

"""
    LibraryRequirement

Represents an external or built-in library requirement (e.g. `SimElements/DES`, `>=0.1.0`).
"""
struct LibraryRequirement
    name::String
    version::String
end

"""
    SceneMetadata

High-level scene identification, authoring information, and required library dependencies.
"""
struct SceneMetadata
    id::String
    name::String
    description::String
    author::String
    created_at::String
    modified_at::String
    revision::Int
    required_libraries::Vector{LibraryRequirement}
    extensions::Dict{String, Any}
end

"""
    SimulationConfig

Execution configuration including mode (:des_only, :abm_only, :hybrid), time bounds,
random seed, and unit definitions.
"""
struct SimulationConfig
    mode::Symbol
    start_time::Float64
    end_time::Float64
    warmup_time::Float64
    random_seed::UInt64
    time_unit::String
    space_unit::String
    extensions::Dict{String, Any}
end

"""
    ABMConfig

Crowd / agent dynamics configuration, model bindings, execution policies, and parameters.
"""
struct ABMConfig
    enabled::Bool
    model_name::Union{String, Nothing}
    model_version::Union{String, Nothing}
    model_library::Union{String, Nothing}
    backend_preference::Union{Symbol, Nothing}
    fallback_policy::Union{Symbol, Nothing}
    parameters::Dict{String, Any}
    extensions::Dict{String, Any}
end

"""
    SpatialLevel

A discrete vertical building level, floor, or elevation plane.
Elevation is relative to world origin Z=0.
"""
struct SpatialLevel
    id::String
    name::String
    elevation::Float64
    default_height::Float64
    visible::Bool
    extensions::Dict{String, Any}
end

"""
    SpatialConfig

Spatial reference system metadata. Canonically uses "right_handed_z_up" with meters.
"""
struct SpatialConfig
    coordinate_system::String
    length_unit::String
    origin::NTuple{3, Float64}
    levels::Vector{SpatialLevel}
    extensions::Dict{String, Any}
end

"""
    TransformRecord

3D position, rotation (Euler angles in radians/degrees per convention), and scale.
In canonical right-handed Z-up: X=East/West, Y=North/South, Z=Height.
"""
struct TransformRecord
    position::NTuple{3, Float64}
    rotation::NTuple{3, Float64}
    scale::NTuple{3, Float64}
end

"""
    GeometryRecord

Physical spatial geometry of an element (e.g. bounding box, polygon, or waypoints).
"""
struct GeometryRecord
    shape::String
    dimensions::Vector{Float64}
    vertices::Union{Vector{NTuple{2, Float64}}, Nothing}
    waypoints::Union{Vector{NTuple{3, Float64}}, Nothing}
    width::Union{Float64, Nothing}
    height::Union{Float64, Nothing}
    extensions::Dict{String, Any}
end

"""
    EditorMetadata

Visual canvas layout metadata for the 2D process flow editor.
Strictly decoupled from physical 3D transforms.
"""
struct EditorMetadata
    graph_position::NTuple{2, Float64}
    collapsed::Bool
    color::Union{String, Nothing}
    notes::Union{String, Nothing}
    extensions::Dict{String, Any}
end

"""
    PortRecord

Typed connection endpoint on an element (flow, metric, signal, control, event).
"""
struct PortRecord
    id::String
    name::String
    direction::Symbol   # :input, :output
    kind::Symbol        # :flow, :metric, :signal, :control, :event
    data_type::String
    cardinality::Symbol # :one, :many
    required::Bool
    unit::Union{String, Nothing}
    description::Union{String, Nothing}
    extensions::Dict{String, Any}
end

"""
    ElementRecord

A discrete-event station, queue, crowd obstacle, spawner, or hybrid gateway.
"""
struct ElementRecord
    id::String
    name::String
    kind::String
    library::String
    library_version::String
    level_id::String
    transform::TransformRecord
    geometry::GeometryRecord
    editor::EditorMetadata
    properties::Dict{String, Any}
    input_ports::Vector{PortRecord}
    output_ports::Vector{PortRecord}
    metric_ports::Vector{PortRecord}
    vertical_extent::Union{Dict{String, Any}, Nothing}
    visual::Union{Dict{String, Any}, Nothing}
    extensions::Dict{String, Any}
end

"""
    ConnectionRecord

Directed link between an output port of a source element and an input port of a target element.
"""
struct ConnectionRecord
    id::String
    source_element::String
    source_port::String
    target_element::String
    target_port::String
    link_type::Symbol  # :flow, :signal, :metric, :control, :event
    enabled::Bool
    ordering::Int
    condition::Union{String, Nothing}
    latency::Union{Float64, Nothing}
    capacity::Union{Int, Nothing}
    extensions::Dict{String, Any}
end

"""
    SubgraphRecord

Group, template, or compound node hierarchy containing nested elements and connections.
"""
struct SubgraphRecord
    id::String
    name::String
    role::Symbol # :group, :template, :compound
    template_id::Union{String, Nothing}
    template_version::Union{String, Nothing}
    elements::Vector{String}
    connections::Vector{String}
    exposed_ports::Vector{Dict{String, Any}}
    parameter_overrides::Dict{String, Any}
    extensions::Dict{String, Any}
end

"""
    DiagnosticRecord

Validation finding (error, warning, or info) pinpointing an element, connection, or property.
"""
struct DiagnosticRecord
    rule_id::String
    severity::Symbol # :error, :warning, :info
    object_kind::String
    object_id::String
    property_path::String
    message::String
    suggested_fix::Union{String, Nothing}
end

"""
    ValidationMetadataRecord

Summary of model validation state, diagnostics list, and validator engine metadata.
"""
struct ValidationMetadataRecord
    is_valid::Bool
    diagnostic_count::Int
    last_validated_at::String
    validator_version::String
    diagnostics::Vector{DiagnosticRecord}
    extensions::Dict{String, Any}
end

"""
    OverlayRecord

Visual layer or analytical overlay (heatmaps, density maps, flow paths, spatial zones).
"""
struct OverlayRecord
    id::String
    name::String
    kind::String
    level_id::String
    visible::Bool
    properties::Dict{String, Any}
    extensions::Dict{String, Any}
end

"""
    TypedSceneSpec

The top-level strongly-typed domain model for SceneSpec v1.
Guarantees concrete types, right-handed Z-up spatial coordinates, typed ports,
and lossless retention of unknown fields/extensions.
"""
struct TypedSceneSpec
    spec_version::String
    scene::SceneMetadata
    simulation::SimulationConfig
    abm_config::Union{ABMConfig, Nothing}
    spatial::Union{SpatialConfig, Nothing}
    elements::Vector{ElementRecord}
    connections::Vector{ConnectionRecord}
    subgraphs::Vector{SubgraphRecord}
    overlays::Vector{OverlayRecord}
    validation_metadata::ValidationMetadataRecord
    extensions::Dict{String, Any}
end

