using CUDA

@testset "Task 6 — Backend staging regressions" begin
    function make_orca_regression_world(F::Type{Float32}=Float32)
        world = World(Position{F}, Velocity{F}, AgentGeometry{F}, MotionParams{F},
                      SFMParams{F}, ORCAParams{F}, Goal{F}, Force{F}, WallSegment{F})

        new_entity!(world, (WallSegment(SVector(F(4), F(0)), SVector(F(4), F(8))),))
        new_entity!(world, (WallSegment(SVector(F(0), F(0)), SVector(F(8), F(0))),))

        shared = from_agent_params(F(0.2), F(80), F(1.4), F(0.5), F(0.5), F(0.0))
        orca_a = ORCAParams(F(2.0), F(0.5), 8, F(6.0), F(0.2), F(1.4), F(0.5), F(80.0))

        new_entity!(world, (
            Position(SVector(F(1.0), F(1.5))),
            Velocity(SVector(F(0.0), F(0.0))),
            shared...,
            orca_a,
            Goal(SVector(F(3.5), F(6.0))),
            Force(SVector(F(0.0), F(0.0)))
        ))

        new_entity!(world, (
            Position(SVector(F(1.8), F(2.2))),
            Velocity(SVector(F(0.0), F(0.0))),
            shared...,
            orca_a,
            Goal(SVector(F(3.2), F(5.2))),
            Force(SVector(F(0.0), F(0.0)))
        ))

        return world
    end

    function collect_forces(world, F::Type{Float32}=Float32)
        forces = SVector{2,F}[]
        for (_, force_col) in Query(world, (Force{F},))
            for i in eachindex(force_col)
                push!(forces, force_col[i].f)
            end
        end
        return forces
    end

    @testset "Shared staging helpers — CPU wall copy" begin
        backend = CPU()
        base = BaseGPUContext(backend, Float32, 2, 4)
        positions = [SVector(1.0f0, 2.0f0), SVector(3.0f0, 4.0f0)]
        velocities = [SVector(0.1f0, 0.2f0), SVector(0.3f0, 0.4f0)]
        radii = Float32[0.2f0, 0.25f0]
        wall_p1s = [SVector(0.0f0, 0.0f0), SVector(2.0f0, 0.0f0), SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0)]
        wall_p2s = [SVector(1.0f0, 0.0f0), SVector(2.0f0, 1.0f0), SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0)]

        SimCrowd.stage_agent_data!(base, positions, velocities, radii)
        SimCrowd.stage_static_geometry!(base, wall_p1s, wall_p2s, 2)

        cpu_positions = Vector{SVector{2,Float32}}(undef, 2)
        cpu_velocities = Vector{SVector{2,Float32}}(undef, 2)
        cpu_radii = Vector{Float32}(undef, 2)
        cpu_wall_p1s = Vector{SVector{2,Float32}}(undef, 4)
        cpu_wall_p2s = Vector{SVector{2,Float32}}(undef, 4)
        copyto!(cpu_positions, base.dev_positions)
        copyto!(cpu_velocities, base.dev_velocities)
        copyto!(cpu_radii, base.dev_radii)
        copyto!(cpu_wall_p1s, base.dev_wall_p1s)
        copyto!(cpu_wall_p2s, base.dev_wall_p2s)

        @test cpu_positions == positions
        @test cpu_velocities == velocities
        @test cpu_radii == radii
        @test cpu_wall_p1s[1:2] == wall_p1s[1:2]
        @test cpu_wall_p2s[1:2] == wall_p2s[1:2]
    end

    @testset "CPU ORCA smoke — shared staging path" begin
        dt = 0.01f0
        world = make_orca_regression_world()
        search = RadixSpatialHash(CPU(), 2, SVector(0.0f0, 0.0f0), SVector(8.0f0, 8.0f0), 1.0f0)

        lp3 = SimCrowd.update_orca_system!(world, search, CPU(), dt)
        forces = collect_forces(world)

        @test lp3 isa Integer
        @test length(forces) == 2
        @test all(force -> all(isfinite, force), forces)
        @test any(force -> norm(force) > 0.0f0, forces)
    end

    @testset "CUDA ORCA smoke + parity — optional" begin
        cuda_ok = CUDA.functional()

        if !cuda_ok
            @info "CUDA ORCA regression skipped — no functional CUDA device."
            @test true
        else
            dt = 0.01f0
            world_cpu = make_orca_regression_world()
            world_gpu = make_orca_regression_world()
            search_cpu = RadixSpatialHash(CPU(), 2, SVector(0.0f0, 0.0f0), SVector(8.0f0, 8.0f0), 1.0f0)
            search_gpu = RadixSpatialHash(CUDA.CUDABackend(), 2, SVector(0.0f0, 0.0f0), SVector(8.0f0, 8.0f0), 1.0f0)

            CUDA.allowscalar(false)
            SimCrowd.update_orca_system!(world_cpu, search_cpu, CPU(), dt)
            SimCrowd.update_orca_system!(world_gpu, search_gpu, CUDA.CUDABackend(), dt)
            CUDA.synchronize()

            cpu_forces = collect_forces(world_cpu)
            gpu_forces = collect_forces(world_gpu)

            @test length(cpu_forces) == 2
            @test length(gpu_forces) == 2
            for i in eachindex(cpu_forces)
                @test cpu_forces[i] ≈ gpu_forces[i] atol=5f-3 rtol=5f-3
            end
        end
    end

    @testset "SimCore reduction parity — optional CUDA" begin
        accel_ok = false
        try
            accel_ok = applicable(gpu_mean_var, [1.0, 2.0]) && applicable(gpu_histogram, [1.0, 2.0], 2)
        catch
            accel_ok = false
        end
        cuda_ok = CUDA.functional()

        if !(accel_ok && cuda_ok)
            @info "SimCore CUDA reduction parity skipped — extension or device unavailable."
            @test true
        else
            samples = Float64[0.5, 1.0, 1.5, 2.5, 3.5, 4.5]
            μ_cpu, var_cpu = gpu_mean_var(samples)
            μ_gpu, var_gpu = gpu_mean_var(CUDA.CuArray(samples))
            edges_cpu, counts_cpu = gpu_histogram(samples, 4; lo=0.0, hi=4.0)
            edges_gpu, counts_gpu = gpu_histogram(CUDA.CuArray(samples), 4; lo=0.0, hi=4.0)

            @test μ_cpu ≈ μ_gpu atol=1e-10
            @test var_cpu ≈ var_gpu atol=1e-10
            @test edges_cpu == edges_gpu
            @test counts_cpu == counts_gpu
        end
    end
end
