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
    for (entities, pos_col, vel_col, params_col, force_col) in Query(world, (Position{F}, Velocity{F}, AgentParams{F}, Force{F}))
        Threads.@threads for i in eachindex(pos_col)
            mass = params_col[i].mass
            acc = force_col[i].f / mass
            
            # Helbing Fluctuation Term (breaks symmetrical friction locking)
            # Correct SDE scaling: velocity diffusion = sigma * sqrt(dt) * Z.
            # So acc_noise = (sigma / sqrt(dt)) * Z
            # BUG-SFM-02 FIX: sigma = 0.1 m/s (Helbing 2000, Table I / Appendix).
            # Helbing 1995 pedestrian-flow calibration used 0.05 m/s; the 2000 paper's
            # evacuation/panic scenario uses 0.1 m/s. At 0.05 the arch-breaking time
            # for 13 stuck agents (crowd pressure < arch friction) exceeds 500s.
            # At 0.1 m/s: arch-break time ≈ 1.5s, all agents clear within ~200s.
            sigma = 0.1f0  # m/s velocity diffusion — Helbing 2000 evacuation calibration
            acc += SVector(randn(F), randn(F)) * (sigma / sqrt(dt))
            

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
