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
    for (entities, pos_col, vel_col, force_col) in Query(world, (Position{F}, Velocity{F}, Force{F}))
        Threads.@threads for i in eachindex(pos_col)
            new_vel = vel_col[i].v + force_col[i].f * dt
            
            # Clamp to maximum speed (e.g. panic multiplier)
            speed = norm(new_vel)
            if speed > F(5.0)
                new_vel = (new_vel / speed) * F(5.0)
            end
            
            # x_{t+1} = x_t + v_{t+1} * dt
            new_pos = pos_col[i].p + new_vel * dt
            
            vel_col[i] = Velocity(new_vel)
            pos_col[i] = Position(new_pos)
        end
    end
end
