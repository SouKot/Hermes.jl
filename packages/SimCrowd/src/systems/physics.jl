# ── Physics Integration System ──────────────────────────────────────────────────

using Ark
using StaticArrays
using LinearAlgebra

"""
    integrate_physics_system!(world, dt)

Updates agent velocities and positions using a Symplectic Euler integrator.
"""
function integrate_physics_system!(world::World, dt::F) where {F<:AbstractFloat}
    # Parameterized over the float type of dt
    for (entities, pos_col, vel_col, params_col, force_col) in Query(world, (Position{F}, Velocity{F}, MotionParams{F}, Force{F}))
        Threads.@threads for i in eachindex(pos_col)
            mass = params_col[i].mass
            acc = force_col[i].f / mass
            
            # Helbing Fluctuation Term — SDE noise breaks symmetrical friction locking.
            # Correct SDE scaling: velocity diffusion = σ × sqrt(dt) × Z → acc_noise = σ/sqrt(dt) × Z.
            # σ is per-agent (MotionParams.σ): 0.10 evacuation, 0.05 normal flow, 0.0 deterministic.
            acc += SVector(randn(F), randn(F)) * (params_col[i].σ / sqrt(dt))
            

            new_vel = vel_col[i].v + acc * dt
            
            # Clamp to maximum absolute speed (e.g. panic multiplier limits)
            speed = norm(new_vel)
            if speed > F(5.0)
                new_vel = (new_vel / speed) * F(5.0)
            end
            
            new_pos = pos_col[i].p + new_vel * dt
            
            vel_col[i] = Velocity(new_vel)
            pos_col[i] = Position(new_pos)
        end
    end

    for (entities, pos_col, vel_col, params_col, force_col) in Query(world, (Position{F}, Velocity{F}, ORCAParams{F}, Force{F}))
        Threads.@threads for i in eachindex(pos_col)
            mass = params_col[i].mass
            acc = force_col[i].f / mass
            
            new_vel = vel_col[i].v + acc * dt
            
            # Clamp to maximum absolute speed
            # BUG-ORCA-03 FIX: ORCA agents are pedestrians too, cap at 5.0 m/s (panic speed)
            speed = norm(new_vel)
            if speed > F(5.0)
                new_vel = (new_vel / speed) * F(5.0)
            end
            
            new_pos = pos_col[i].p + new_vel * dt
            
            vel_col[i] = Velocity(new_vel)
            pos_col[i] = Position(new_pos)
        end
    end
end
