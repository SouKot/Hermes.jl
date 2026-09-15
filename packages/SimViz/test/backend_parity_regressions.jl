using Test
using SimCrowd

@testset "ScenarioConfig backend parity regressions" begin
    function _backend_parity_case(model; backend::Symbol=:threads, n_agents::Int=8,
                                  correction_iters::Int=1)
        cfg = HL.ScenarioConfig(
            n_agents=n_agents,
            crowd_model=model,
            execution_backend=backend,
            correction_iters=correction_iters,
            vel_impulse_iters=0,
        )
        ctx = HL.build_world!(cfg)
        HL.step!(ctx.scene)
        return ctx
    end

    @testset "CPU builder parity" begin
        for model in (HL.MODEL_SFM, HL.MODEL_ORCA, HL.MODEL_HYBRID_FSM, HL.MODEL_CSM)
            ctx = _backend_parity_case(model; backend=:threads, correction_iters=1)
            @test ctx.scene.search isa SimCrowd.RadixSpatialHash
            @test SimCrowd.backend_kind(SimCrowd.resolve_execution_backend(ctx.scene.search)) == :cpu
        end
    end

    @testset "CUDA builder parity" begin
        cuda_ok = false
        try
            @eval using CUDA
            cuda_ok = CUDA.functional()
        catch
            cuda_ok = false
        end

        if !cuda_ok
            @info "CUDA backend parity regression skipped — no functional CUDA device."
            @test true
        else
            for model in (HL.MODEL_SFM, HL.MODEL_ORCA, HL.MODEL_HYBRID_FSM, HL.MODEL_CSM)
                correction_iters = model == HL.MODEL_CSM ? 0 : 0
                ctx = _backend_parity_case(model; backend=:cuda, correction_iters=correction_iters)
                @test ctx.scene.search isa SimCrowd.RadixSpatialHash
                @test SimCrowd.backend_kind(SimCrowd.resolve_execution_backend(ctx.scene.search)) == :cuda
            end
        end
    end

    @testset "Invalid backend selector throws" begin
        cfg = HL.ScenarioConfig(crowd_model=HL.MODEL_SFM, execution_backend=:bogus)
        @test_throws ArgumentError HL.build_world!(cfg)
    end
end