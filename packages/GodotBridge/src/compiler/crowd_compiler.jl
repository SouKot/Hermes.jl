# packages/GodotBridge/src/compiler/crowd_compiler.jl
#
# Crowd & Spatial Obstacle Sub-Compiler for SceneSpec v1.
# Lowers crowd spawner nodes and spatial element boundaries into SimCore Crowd structures.

using SimCore: CrowdAgent, CrowdObstacle
using StaticArrays: SVector

"""
    CrowdCompilationArtifacts

Crowd agents, obstacles, and spawner definitions generated from spatial SceneSpec nodes.
"""
struct CrowdCompilationArtifacts
    obstacles::Vector{CrowdObstacle}
    spawners::Vector{IRCrowdSpawnerNode}
    diagnostics::Vector{CompilerDiagnostic}
end

"""
    compile_crowd_graph(ir::ExecutionGraphIR) -> CrowdCompilationArtifacts

Extracts crowd spawners and generates axis-aligned bounding boxes (AABBs) for physical stations
as pedestrian obstacles in the navigation mesh.
"""
function compile_crowd_graph(ir::ExecutionGraphIR)::CrowdCompilationArtifacts
    diagnostics = CompilerDiagnostic[]
    obstacles = CrowdObstacle[]
    spawners = IRCrowdSpawnerNode[]

    # 1. Collect spawners
    for (elem_id, node) in ir.nodes
        if node isa IRCrowdSpawnerNode
            push!(spawners, node)
        end
    end

    # 2. Convert solid stations (servers, queues) into crowd obstacles
    for (elem_id, node) in ir.nodes
        if node isa IRServerNode || node isa IRQueueNode
            if haskey(ir.spatial_positions, elem_id) && haskey(ir.spatial_dimensions, elem_id)
                pos = ir.spatial_positions[elem_id]
                dim = ir.spatial_dimensions[elem_id]

                # Convert 3D position (x, y, z) and dimension (dx, dy, dz) to 2D ground AABB (x, z)
                half_w = Float32(dim[1] / 2.0)
                half_d = Float32(dim[3] / 2.0)
                cx = Float32(pos[1])
                cz = Float32(pos[3])

                x1 = cx - half_w
                y1 = cz - half_d
                x2 = cx + half_w
                y2 = cz + half_d

                push!(obstacles, CrowdObstacle(x1, y1, x2, y2))
            end
        end
    end

    return CrowdCompilationArtifacts(obstacles, spawners, diagnostics)
end

