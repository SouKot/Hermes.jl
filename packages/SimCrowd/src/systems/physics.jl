# ── Physics Integration System ──────────────────────────────────────────────────

using Ark
using StaticArrays
using LinearAlgebra

"""
    integrate_physics_system!(world, dt; max_speed=5.0f0)

Updates agent velocities and positions using a Symplectic Euler integrator.

`max_speed` is the hard clamp applied to the velocity magnitude after each step
(m/s). Default 5.0 is pedestrian panic speed (Helbing 2000).
Pass `scene.config.max_speed` or use the `SimConfig` overload for scene-based simulations.
"""
function integrate_physics_system!(world::World, dt::F; max_speed::F=F(5.0)) where {F<:AbstractFloat}
    # Parameterized over the float type of dt.
    # Try/catch: Ark throws ArgumentError when a component type is not registered in the World.
    # This allows integrate_physics_system! to work with SFM-only or ORCA-only worlds.
    try
        for (entities, pos_col, vel_col, params_col, force_col) in Query(world, (Position{F}, Velocity{F}, MotionParams{F}, Force{F}))
            Threads.@threads for i in eachindex(pos_col)
                mass = params_col[i].mass
                acc = force_col[i].f / mass
                
                # Helbing Fluctuation Term — SDE noise breaks symmetrical friction locking.
                # Correct SDE scaling: velocity diffusion = σ × sqrt(dt) × Z → acc_noise = σ/sqrt(dt) × Z.
                # σ is per-agent (MotionParams.σ): 0.10 evacuation, 0.05 normal flow, 0.0 deterministic.
                acc += SVector(randn(F), randn(F)) * (params_col[i].σ / sqrt(dt))
                

                new_vel = vel_col[i].v + acc * dt
                
                # Clamp to maximum absolute speed (configurable via max_speed, default 5.0 m/s panic)
                speed = norm(new_vel)
                if speed > max_speed
                    new_vel = (new_vel / speed) * max_speed
                end
                
                new_pos = pos_col[i].p + new_vel * dt
                
                vel_col[i] = Velocity(new_vel)
                pos_col[i] = Position(new_pos)
            end
        end
    catch e
        e isa ArgumentError || rethrow()
    end
end
# NOTE: ORCAParams loop deliberately removed (2026-08-21).
# ORCA agents carry both MotionParams and ORCAParams. The MotionParams loop above
# already integrates them correctly:
#   update_orca_system_cpu! sets Force = mass × (v_orca − v_old) / dt
#   MotionParams loop: v_new = v_old + Force/mass × dt = v_orca  ✓
# A separate ORCAParams loop would read the already-updated vel_col (v_orca) and
# integrate a second time: v_new = v_orca + (v_orca − v_old) = 2v_orca − v_old  ✗
# This was a double-integration bug giving ORCA agents 2× velocity per step.


"""
    integrate_physics_system!(world, config::SimConfig)

`SimConfig`-based overload for use with `SimScene`. Reads `dt` and `max_speed` from config.
"""
integrate_physics_system!(world::World, config::SimConfig{F}) where {F} =
    integrate_physics_system!(world, config.dt; max_speed=config.max_speed)
