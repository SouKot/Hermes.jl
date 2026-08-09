# ── Forces ─────────────────────────────────────────────────────────────────────

"""
    goal_seeking_force(pos, vel, goal, v₀, τ)

Computes the driving force towards a destination `goal`.
`v₀` is the desired speed, and `τ` is the relaxation time.
"""
@inline function goal_seeking_force(pos::SVector{2,F}, vel::SVector{2,F},
                                    goal::SVector{2,F}, v₀::F, τ::F) where {F<:AbstractFloat}
    dir = goal - pos
    dist = norm(dir)
    if dist < 1f-6
        return zero(SVector{2,F})
    end
    ê = dir / dist
    return (v₀ * ê - vel) / τ
end

"""
    agent_repulsion(pos_i, pos_j, r_i, r_j; A=2000f0, B=0.08f0)

Computes the social repulsion force exerted by agent `j` on agent `i`.
Uses the Helbing & Molnár (1995) Gaussian potential.
"""
@inline function agent_repulsion(pos_i::SVector{2,F}, pos_j::SVector{2,F}, 
                                 r_i::F, r_j::F; A::F=2000f0, B::F=0.08f0) where {F<:AbstractFloat}
    r_ij = pos_i - pos_j
    d = norm(r_ij)
    if d < 1f-6
        return zero(SVector{2,F})
    end
    return A * exp((r_i + r_j - d) / B) * (r_ij / d)
end

"""
    wall_repulsion(pos, wall_segment; A_w=2000f0, B_w=0.08f0)

Computes the repulsion force from a static wall segment (line from `p1` to `p2`).
Finds the closest point on the segment and repels the agent away.
"""
@inline function wall_repulsion(pos::SVector{2,F}, wall_segment::Tuple{SVector{2,F}, SVector{2,F}}; 
                                A_w::F=2000f0, B_w::F=0.08f0) where {F<:AbstractFloat}
    p1, p2 = wall_segment
    segment_vec = p2 - p1
    l2 = dot(segment_vec, segment_vec)
    
    if l2 == 0f0
        closest = p1
    else
        # Project pos onto segment, clamping t to [0, 1]
        t = max(0f0, min(1f0, dot(pos - p1, segment_vec) / l2))
        closest = p1 + t * segment_vec
    end
    
    r_w = pos - closest
    d_w = norm(r_w)
    if d_w < 1f-6
        return zero(SVector{2,F})
    end
    return A_w * exp(-d_w / B_w) * (r_w / d_w)
end
