# ── Physics Integration System ──────────────────────────────────────────────────

using Ark
using StaticArrays
using LinearAlgebra
using Random: Xoshiro

# Global call counter for automatic per-call noise seed variation.
# When step_count is not explicitly passed to integrate_physics_system!, this counter
# increments each call so noise is uncorrelated across time steps without requiring
# callers to track or pass a step number.
# Thread-safe (Threads.Atomic). Not reproducible across separate program runs, but
# that is intentional — stochastic arch-breaking should vary between runs.
# Pass explicit step_count ≥ 0 to override and get fully reproducible noise.
const _physics_call_counter = Threads.Atomic{Int}(0)

"""
    integrate_physics_system!(world, dt; max_speed=5.0f0, step_count=-1)

Updates agent velocities and positions using a Symplectic Euler integrator.

`max_speed` is the hard clamp applied to the velocity magnitude after each step
(m/s). Default 5.0 is pedestrian panic speed (Helbing 2000).
Pass `scene.config.max_speed` or use the `SimConfig` overload for scene-based simulations.

`step_count`: controls the per-agent noise seed:
- `step_count = -1` (default): uses a global atomic call counter that auto-increments each
  invocation. Noise is uncorrelated across time steps without any caller bookkeeping.
  Results vary between program runs (intentional — arch-breaking should not be deterministic).
- `step_count ≥ 0`: fully reproducible — seed = hash(entity) ⊻ (step_count << 32) ⊻ salt.
  Use when you need exactly reproducible noise (e.g., parameter sweeps, CI tests).
"""
function integrate_physics_system!(world::World, dt::F;
                                   max_speed::F=F(5.0),
                                   step_count::Int=-1) where {F<:AbstractFloat}
    # Resolve step counter: -1 = auto-increment global counter; ≥0 = use as-is.
    actual_step = step_count >= 0 ? step_count : Threads.atomic_add!(_physics_call_counter, 1)
    # Parameterized over the float type of dt.
    # Try/catch: Ark throws ArgumentError when a component type is not registered in the World.
    # This allows integrate_physics_system! to work with SFM-only or ORCA-only worlds.
    try
        for (entities, pos_col, vel_col, params_col, force_col) in Query(world, (Position{F}, Velocity{F}, MotionParams{F}, Force{F}))
            Threads.@threads for i in eachindex(pos_col)
                mass = params_col[i].mass
                acc  = force_col[i].f / mass

                # Helbing Fluctuation Term (Helbing et al. 2000, Eq. 2):
                #   ξᵢ(t) ~ Normal(0, σ²) per agent per step — breaks symmetrical arch deadlocks.
                #   SDE scaling: acc_noise = σ/√dt × Z, so velocity increment = σ√dt × Z (correct SDE).
                #
                # FIX (2026-08-24, Sprint 3J-fix):
                #   OLD: randn(F) — draws from Julia's global shared RNG, causing:
                #     1. Correlated noise across all agents (all advance same RNG in sequence)
                #     2. Data-race in Threads.@threads (concurrent writes to shared state)
                #     3. Arch-reinforcement instead of arch-breaking
                #   NEW: per-agent Xoshiro seeded by (entity_id ⊻ step_count ⊻ salt)
                #     → uncorrelated, thread-safe, fully reproducible
                σ = params_col[i].σ
                if σ > zero(F)
                    # hash(entities[i]) gives a stable UInt64 fingerprint per entity.
                    # Entity is an Ark struct (id + generation), not directly castable to UInt64.
                    seed = hash(entities[i]) ⊻ (UInt64(actual_step) ⊻ (UInt64(actual_step) << 32)) ⊻ 0xdeadbeef_cafecafe
                    rng  = Xoshiro(seed)
                    acc += SVector(randn(rng, F), randn(rng, F)) * (σ / sqrt(dt))
                end

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
    integrate_physics_system!(world, config::SimConfig; step_count=0)

`SimConfig`-based overload for use with `SimScene`. Reads `dt` and `max_speed` from config.
Pass `step_count` for reproducible per-agent stochastic noise (arch-breaking σ term).
"""
integrate_physics_system!(world::World, config::SimConfig{F}; step_count::Int=-1) where {F} =
    integrate_physics_system!(world, config.dt; max_speed=config.max_speed, step_count=step_count)

"""
    integrate_physics_system!(world, config::SimConfig, dt_eff)

Adaptive-dt overload: integrates using `dt_eff` (instead of `config.dt`) while
still reading `max_speed` from config. Used by `step!` when adaptive dt is active
(any HybridFSM agent in SFM_MODE → dt_eff = config.dt_sfm).
"""
integrate_physics_system!(world::World, config::SimConfig{F}, dt_eff::F; step_count::Int=-1) where {F} =
    integrate_physics_system!(world, dt_eff; max_speed=config.max_speed, step_count=step_count)
