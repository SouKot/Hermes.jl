# packages/GodotBridge/src/runtime/runtime_manager.jl
#
# RuntimeManager — Staging Sandbox, Atomic Activation, and Lifecycle Controller.
# Guarantees that draft scene edits in Godot compile in a staging environment first;
# invalid drafts produce diagnostic feedback without interrupting or crashing the live model.

using SimCore
import SimCore: pause!
using SimDES

"""
    RuntimeManager

Thread-safe manager for simulation lifecycle, staging compilation, and atomic pointer swapping.
"""
mutable struct RuntimeManager
    active_instance::Union{SimulationInstance, Nothing}
    latest_diagnostics::Vector{CompilerDiagnostic}
    lock::ReentrantLock
    runner_task::Union{Task, Nothing}
    stop_runner_signal::Threads.Atomic{Bool}
end

function RuntimeManager()
    return RuntimeManager(
        nothing,
        CompilerDiagnostic[],
        ReentrantLock(),
        nothing,
        Threads.Atomic{Bool}(false)
    )
end

"""
    stage_and_activate!(manager::RuntimeManager, raw_spec; clock_speed::Float64=1.0) -> Tuple{Bool, Vector{CompilerDiagnostic}}

Compiles `raw_spec` in staging. If compilation produces errors, preserves the previous
running instance and returns diagnostics. If successful, atomically activates the new instance.
"""
function stage_and_activate!(
    manager::RuntimeManager,
    raw_spec;
    clock_speed::Float64 = 1.0
)::Tuple{Bool, Vector{CompilerDiagnostic}}
    # 1. Compile in staging sandbox
    comp_res = compile_scenespec(raw_spec)
    manager.latest_diagnostics = comp_res.diagnostics

    if !comp_res.success || has_errors(comp_res.diagnostics)
        return (false, comp_res.diagnostics)
    end

    # 2. Atomic swap under lock
    lock(manager.lock) do
        # Stop background runner if active
        stop_runner!(manager)

        # Build new instance
        new_inst = SimulationInstance(
            "sim_$(time_ns())",
            comp_res.world,
            comp_res.fel,
            comp_res.zone_configs,
            comp_res.source_map,
            comp_res.execution_ir;
            clock_speed = clock_speed
        )

        manager.active_instance = new_inst
    end

    return (true, comp_res.diagnostics)
end

"""
    stop_runner!(manager::RuntimeManager)

Cooperatively stops any active background simulation runner task.
"""
function stop_runner!(manager::RuntimeManager)
    manager.stop_runner_signal[] = true
    if manager.active_instance !== nothing
        pause!(manager.active_instance)
    end
    if manager.runner_task !== nothing
        try
            wait(manager.runner_task)
        catch
        end
        manager.runner_task = nothing
    end
    manager.stop_runner_signal[] = false
end

"""
    play!(manager::RuntimeManager, on_tick::Function)

Starts real-time continuous background stepping on the active simulation instance.
"""
function play!(manager::RuntimeManager, on_tick::Function)
    inst = manager.active_instance
    inst === nothing && return false

    lock(manager.lock) do
        stop_runner!(manager)
        inst.is_running[] = true
        inst.is_paused[] = false
        inst.interrupt_requested[] = false
        manager.stop_runner_signal[] = false

        SimCore.unpause!(inst.clock)

        manager.runner_task = Threads.@spawn begin
            try
                while inst.is_running[] && !manager.stop_runner_signal[]
                    # Advance in uniform ~30 Hz time slices scaled by clock speed
                    spd = isfinite(inst.clock.speed_factor) ? inst.clock.speed_factor : 1.0
                    dt_slice = max(0.001, 0.033 * spd)
                    t_target = inst.world.time + dt_slice
                    step_until!(inst, t_target; on_tick=on_tick, tick_interval_sec=0.033)
                    
                    if Base.isempty(inst.fel) && inst.world.time >= t_target
                        # All events completed / idle
                        sleep(0.01)
                    end
                end
            catch e
                @warn "Simulation runner encountered error: $e"
            finally
                inst.is_running[] = false
                inst.is_paused[] = true
            end
        end
    end
    return true
end

"""
    pause!(manager::RuntimeManager)

Pauses the active simulation instance immediately.
"""
function pause!(manager::RuntimeManager)
    stop_runner!(manager)
    return true
end

"""
    step!(manager::RuntimeManager, duration::Float64, unit::AbstractString, on_tick::Function) -> Float64

Advances simulation by `duration` converted from `unit` ("s", "m", "h", "d").
Runs without arbitrary time ceilings.
"""
function step!(
    manager::RuntimeManager,
    duration::Float64,
    unit::AbstractString,
    on_tick::Function
)::Float64
    inst = manager.active_instance
    inst === nothing && return 0.0

    stop_runner!(manager)
    scale = normalize_time_unit_scale(unit)
    dt = duration * scale
    t_target = inst.world.time + dt

    inst.is_running[] = true
    inst.is_paused[] = false

    final_t = step_until!(inst, t_target; on_tick=on_tick, tick_interval_sec=0.033, fast_forward=true)

    inst.is_running[] = false
    inst.is_paused[] = true
    return final_t
end
