# ── Forces ─────────────────────────────────────────────────────────────────────

"""
    goal_seeking_force(pos, vel, goal, v₀, τ)

Computes the driving force towards a destination `goal`.
`v₀` is the desired speed, and `τ` is the relaxation time.
"""
@inline function goal_seeking_force(pos::SVector{2,F}, vel::SVector{2,F},
                                    goal::SVector{2,F}, v₀::F, τ::F, mass::F) where {F<:AbstractFloat}
    dir = goal - pos
    dist = norm(dir)
    if dist < 1f-6
        return zero(SVector{2,F})
    end
    ê = dir / dist
    return mass * (v₀ * ê - vel) / τ
end

"""
    agent_repulsion(pos_i, pos_j, r_i, r_j; A=2000f0, B=0.08f0)

Computes the social repulsion force exerted by agent `j` on agent `i`.
Uses the Helbing & Molnár (1995) / Helbing, Farkas & Vicsek (2000) model:
  - Psychological force: A × exp((r_ij − d)/B) × n̂_ij  (always active, decays exponentially)
  - Body compression:    k × g(d)                × n̂_ij  (contact only)
  - Viscous friction:    κ × g(d) × (Δv·t̂)      × t̂_ij  (contact only)
    capped at μ × F_body (Coulomb cap, per agent from AgentParams.μ)

Note on μ: Helbing 2000 uses pure viscous friction (no cap). The cap is kept here
for numerical stability and to allow per-scenario tuning:
  μ = 0.5  → normal pedestrian contact (CRW-M-01 lane formation)
  μ = 10.0 → effectively uncapped ≈ Helbing exact (3C faster-is-slower, panic)
The CPU pipeline threads per-agent μ (social.jl). Wall friction uses per-agent
μ from AgentParams directly in wall_repulsion.
"""
@inline function agent_repulsion(pos_i::SVector{2,F}, vel_i::SVector{2,F}, social_r_i::F, collision_r_i::F,
                                 pos_j::SVector{2,F}, vel_j::SVector{2,F}, social_r_j::F, collision_r_j::F;
                                 A::F=2000f0, B::F=0.08f0, k::F=120000f0, κ::F=240000f0,
                                 λ::F=0.5f0, μ::F=0.5f0) where {F<:AbstractFloat}
    r_ij = pos_i - pos_j
    d = norm(r_ij)
    if d < 1f-6
        return zero(SVector{2,F})
    end

    n_ij = r_ij / d
    t_ij = SVector(-n_ij[2], n_ij[1])

    social_overlap = (social_r_i + social_r_j) - d
    f_psych = A * exp(social_overlap / B) * n_ij

    collision_overlap = (collision_r_i + collision_r_j) - d
    g_overlap = max(0f0, collision_overlap)

    f_body_mag = k * g_overlap
    f_body     = f_body_mag * n_ij

    Δv_ji_t = dot(vel_j - vel_i, t_ij)
    f_frict_viscous = κ * g_overlap * Δv_ji_t
    # Coulomb cap: friction ≤ μ × body_force.
    # μ=0.5 → normal walking; μ=10.0 → effectively Helbing-exact (arch formation).
    f_frict_max    = μ * f_body_mag
    f_frict_clamped = clamp(f_frict_viscous, -f_frict_max, f_frict_max)
    f_frict = f_frict_clamped * t_ij

    w = 1f0
    if dot(vel_i, vel_i) > 1f-6
        e_i = vel_i / norm(vel_i)
        cos_φ = dot(e_i, -n_ij)
        w = λ + (1f0 - λ) * (1f0 + cos_φ) / 2f0
    end

    return f_psych * w + f_body + f_frict
end


"""
    wall_repulsion(pos, wall_segment; A_w=2000f0, B_w=0.08f0)

Computes the repulsion force from a static wall segment (line from `p1` to `p2`).
Finds the closest point on the segment and repels the agent away.
"""
@inline function wall_repulsion(pos_i::SVector{2,F}, vel_i::SVector{2,F}, social_r_i::F, collision_r_i::F, wall_segment::Tuple{SVector{2,F}, SVector{2,F}}; 
                                A_w::F=2000f0, B_w::F=0.08f0, k::F=120000f0, κ::F=240000f0, μ::F=0.1f0) where {F<:AbstractFloat}
    p1, p2 = wall_segment
    segment_vec = p2 - p1
    l2 = dot(segment_vec, segment_vec)
    
    if l2 == 0f0
        closest = p1
    else
        t = max(0f0, min(1f0, dot(pos_i - p1, segment_vec) / l2))
        closest = p1 + t * segment_vec
    end
    
    r_iw = pos_i - closest
    d = norm(r_iw)
    if d < 1f-6
        return zero(SVector{2,F})
    end
    
    n_iw = r_iw / d
    t_iw = SVector(-n_iw[2], n_iw[1])
    
    social_overlap = social_r_i - d
    f_psych = A_w * exp(social_overlap / B_w) * n_iw
    
    collision_overlap = collision_r_i - d
    g_overlap = max(0f0, collision_overlap)
    
    f_body_mag = k * g_overlap
    f_body = f_body_mag * n_iw
    
    Δv_wi_t = dot(zero(SVector{2,F}) - vel_i, t_iw)
    f_frict_viscous = κ * g_overlap * Δv_wi_t
    f_frict_max = μ * f_body_mag
    f_frict_clamped = clamp(f_frict_viscous, -f_frict_max, f_frict_max)
    f_frict = f_frict_clamped * t_iw
    
    return f_psych + f_body + f_frict
end
