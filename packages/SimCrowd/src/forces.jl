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
    contact_force(pos_i, vel_i, c_r_i, pos_j, vel_j, c_r_j; k, κ, μ)

Physical contact forces: body compression + sliding friction.
These are SYMMETRIC by construction — `contact_force(i→j) = −contact_force(j→i)` —
so Newton's 3rd law holds exactly. Safe for CellListMap `pairwise!`.

**ContactModel dispatch via `μ` sentinel** (see `ContactModel` in SimCrowd.jl):
- `iszero(μ)`  → `NoContact`:  returns zero (no body forces at all).
                  Automatically triggered when `collision_radius = 0`.
- `isinf(μ)`   → `Viscous`:   pure viscous `κ×g×Δv_t` with no Coulomb cap.
                  Helbing 2000 exact form; required for Faster-is-Slower effect.
- `0 < μ < Inf` → `Coulomb`: `clamp(κ×g×Δv_t, -μ×F_body, +μ×F_body)`.
                  Default for normal pedestrian walking (μ = 0.5, Helbing 2000 Table I).

GPU-safe: `isinf` and `iszero` compile to single-instruction IEEE 754 checks.
"""
@inline function contact_force(pos_i::SVector{2,F}, vel_i::SVector{2,F}, c_r_i::F,
                                pos_j::SVector{2,F}, vel_j::SVector{2,F}, c_r_j::F;
                                k::F=120000f0, κ::F=240000f0, μ::F=0.5f0) where {F<:AbstractFloat}
    r_ij = pos_i - pos_j
    d = norm(r_ij)
    d < F(1e-6) && return zero(SVector{2,F})

    n_ij = r_ij / d
    t_ij = SVector(-n_ij[2], n_ij[1])

    g = max(zero(F), (c_r_i + c_r_j) - d)

    # NoContact: collision_radius = 0 → g = 0 always, OR explicit μ = 0 sentinel.
    # Both routes return zero without computing body/friction forces.
    (iszero(g) || iszero(μ)) && return zero(SVector{2,F})

    f_body_mag = k * g
    f_body     = f_body_mag * n_ij

    Δv_t = dot(vel_j - vel_i, t_ij)

    # ContactModel dispatch:
    f_frict = if isinf(μ)
        # Viscous — Helbing 2000 exact; enables arch formation + FiS
        κ * g * Δv_t * t_ij
    else
        # Coulomb — standard cap: |f_frict| ≤ μ × |f_body|
        clamp(κ * g * Δv_t, -μ * f_body_mag, μ * f_body_mag) * t_ij
    end

    return f_body + f_frict
end


"""
    psychological_force(pos_i, vel_i, s_r_i, pos_j, s_r_j; A, B, λ)

Anisotropic psychological (social potential) force exerted on agent `i` by agent `j`.
Uses **agent i's velocity** for the field-of-view anisotropy weight (Helbing & Molnár 1995, eq. 5):

    wᵢ = λ + (1−λ) × (1 + cos φᵢ) / 2,    φᵢ = angle between i's heading and direction toward j

Agents pay full attention to threats ahead (w=1.0) and reduced attention behind (w=λ=0.5).

**ASYMMETRIC by definition**: `psychological_force(i,j)` ≠ `−psychological_force(j,i)` because
each agent uses its own velocity. Call this separately for each agent in a per-agent loop.
This is the ONLY asymmetric term in Helbing's SFM — see `contact_force` for the symmetric part.
"""
@inline function psychological_force(pos_i::SVector{2,F}, vel_i::SVector{2,F}, s_r_i::F,
                                      pos_j::SVector{2,F}, s_r_j::F;
                                      A::F=2000f0, B::F=0.08f0, λ::F=0.5f0) where {F<:AbstractFloat}
    r_ij = pos_i - pos_j
    d = norm(r_ij)
    d < F(1e-6) && return zero(SVector{2,F})

    n_ij          = r_ij / d
    social_overlap = (s_r_i + s_r_j) - d

    w = one(F)
    if dot(vel_i, vel_i) > F(1e-6)
        e_i   = vel_i / norm(vel_i)
        cos_φ = dot(e_i, -n_ij)
        w     = λ + (one(F) - λ) * (one(F) + cos_φ) / 2f0
    end

    return A * exp(social_overlap / B) * w * n_ij
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


"""
    gcf_force(pos_i, vel_i, s_r_i, pos_j, s_r_j; V₀, η, λ)

§1.4 — Chraibi et al. (2010) Generalized Centrifugal Force (GCF) model.
Drop-in replacement for `psychological_force` when `SFMParams.η > 0`.

**Key difference from Helbing:** The repulsion decay length D_i depends on agent i's
speed, so fast agents maintain a larger personal space ahead:

    D_i = max(s_r_i × 0.1, s_r_i + η × ‖v_i‖)

where:
- `s_r_i`: personal space radius (m) — sets the minimum D_i floor
- `η`: speed-adaptation factor (s). Chraibi 2010: η ≈ 0.5 s.
  At v=1.5 m/s: D_i = 0.25 + 0.5×1.5 = 1.0 m (2–4× Helbing B=0.08 m)
  At v=0.0 m/s: D_i = 0.25 m (= social_radius)

**Anisotropy (λ):** Same Helbing formula as `psychological_force`.
Chraibi 2010 §II explicitly includes the kij anisotropy coefficient in GCFM.
Bug fix: previously gcf_force was isotropic (no λ), causing forces to cancel
exactly in a symmetric periodic corridor → all densities gave free-flow speed.

    cos_φ = dot(e_i, −n̂_ij)   # positive when j is ahead of i
    w = λ + (1 − λ) × (1 + cos_φ) / 2

**GPU-safe:** no dynamic dispatch, all IEEE 754 operations.

# References
- Chraibi, M., Seyfried, A., Schadschneider, A. (2010). *Generalized centrifugal-force model
  for pedestrian dynamics.* Physical Review E, 82(4), 046111. §II, eq. 8.
- Helbing, D. & Molnár, P. (1995). Social force model for pedestrian dynamics.
  Physical Review E, 51(5), 4282. (anisotropy, same formula).
"""
@inline function gcf_force(pos_i::SVector{2,F}, vel_i::SVector{2,F}, s_r_i::F,
                           pos_j::SVector{2,F}, s_r_j::F;
                           V₀::F=2000f0, η::F=0.5f0, λ::F=F(0.5)) where {F<:AbstractFloat}
    r_ij = pos_i - pos_j
    d    = norm(r_ij)
    d < F(1e-6) && return zero(SVector{2,F})

    n_ij = r_ij / d    # unit vector from j toward i

    # Speed-adapted range: D_i = s_r_i + η × ‖v_i‖
    # Floor at 0.1 × s_r_i prevents D_i→0 for stationary agents (avoids blowup).
    speed_i = norm(vel_i)
    D_i = max(s_r_i * F(0.1), s_r_i + η * speed_i)

    # Anisotropy weight: same formula as psychological_force.
    # Chraibi 2010 §II includes kij explicitly. Without it, forces cancel in
    # a symmetric periodic corridor and the fundamental diagram cannot be reproduced.
    w = one(F)
    if dot(vel_i, vel_i) > F(1e-6)
        e_i   = vel_i / speed_i
        cos_φ = dot(e_i, -n_ij)   # positive when j is ahead of i
        w     = λ + (one(F) - λ) * (one(F) + cos_φ) / F(2)
    end

    # GCF potential: V = V₀ × exp((s_r_i + s_r_j − d) / D_i)
    # Force = −∂V/∂pos_i = (V₀ / D_i) × exp(…) × w × n_ij
    # Same exponential structure as Helbing but with speed-adaptive decay length D_i.
    social_overlap = (s_r_i + s_r_j) - d
    return (V₀ / D_i) * exp(social_overlap / D_i) * w * n_ij
end

"""
    gcf_force_elliptical(pos_i, vel_i, pos_j; a₀, τ_gap, b_min, b_max, V₀, λ, v₀_ref)

§1.5 — Chraibi et al. (2010) §III — GCFM with velocity-direction elliptic semi-axes.
Drop-in replacement for `gcf_force` when `SFMParams.τ_gap > 0`.

Agent i is represented as an ellipse oriented in its velocity direction:
- **Front semi-axis**:  `a(v) = a₀ + τ_gap × ‖v_i‖`  (grows with speed → more space ahead)
- **Side semi-axis**:   `b(v) = b_max − (b_max − b_min) × ‖v‖/v₀_ref`  (narrows with speed)

The effective overlap distance between agent i (ellipse) and agent j (circle radius a₀) is:

    effective_overlap = r_ellipse_i_toward_j + a₀ − d

where the ellipse radius toward j is computed from the standard ellipse polar-radius formula:

    r_ellipse = a(v)⋅b(v) / √( (b(v)⋅cosθ)² + (a(v)⋅sinθ)² )

θ is the angle from v_i to the i→j direction.

**Same exponential potential** as circular `gcf_force`: V = V₀ × exp(overlap/D_i).
**Same anisotropy** λ as Helbing/GCFM-circular.

# Default calibration (Chraibi 2010, Table I)
- `a₀ = 0.25m`  (body radius at rest = collision_radius)
- `τ_gap = 0.53s` (time-gap for personal space growth)
- `b_min = 0.25m`, `b_max = 0.30m` (shoulder width range)

# References
- Chraibi, M., Seyfried, A., Schadschneider, A. (2010). *Generalized centrifugal-force model
  for pedestrian dynamics.* Physical Review E, 82(4), 046111. §III, Eq. 10–12.
"""
@inline function gcf_force_elliptical(pos_i::SVector{2,F}, vel_i::SVector{2,F},
                                       pos_j::SVector{2,F};
                                       a₀::F=F(0.25),        # body radius at rest (m)
                                       τ_gap::F=F(0.53),     # Chraibi 2010 Table I
                                       b_min::F=F(0.25),     # lateral semi-axis at high speed (m)
                                       b_max::F=F(0.30),     # lateral semi-axis at rest (m)
                                       V₀::F=F(70f0),        # potential strength (N)
                                       λ::F=F(0.5),          # anisotropy weight
                                       v₀_ref::F=F(1.34)) where {F<:AbstractFloat}
    r_ij = pos_i - pos_j
    d    = norm(r_ij)
    d < F(1e-6) && return zero(SVector{2,F})
    n_ij = r_ij / d

    speed_i = norm(vel_i)

    # §III Eq.10: velocity-direction semi-axes
    # a(v): front axis grows with speed (more personal space ahead when moving)
    a_i = a₀ + τ_gap * speed_i
    # b(v): lateral axis shrinks with speed (shoulder compression during fast walking)
    b_i = b_max - (b_max - b_min) * min(speed_i / v₀_ref, one(F))

    # Angle θ from vel_i direction to i→j (i.e., −n_ij direction)
    if speed_i > F(1e-6)
        e_i  = vel_i / speed_i
        cosθ = clamp(dot(e_i, -n_ij), F(-1), F(1))
        sinθ = sqrt(max(zero(F), one(F) - cosθ * cosθ))
    else
        cosθ = one(F); sinθ = zero(F)
        e_i  = n_ij   # fallback when stationary
    end

    # Ellipse polar radius: r = a⋅b / √((b⋅cosθ)² + (a⋅sinθ)²)
    denom     = sqrt((b_i * cosθ)^2 + (a_i * sinθ)^2)
    r_ellipse = denom > F(1e-6) ? (a_i * b_i / denom) : a₀

    # Effective overlap: positive when j is inside i's personal ellipse
    effective_overlap = (r_ellipse + a₀) - d   # a₀ = j's body radius

    # Decay length: use front semi-axis (mirrors circular D_i = s_r + η⋅v)
    D_i = max(a₀ * F(0.1), a_i)

    # Anisotropy: same Helbing formula as gcf_force
    w = one(F)
    if speed_i > F(1e-6)
        cos_φ = dot(e_i, -n_ij)
        w = λ + (one(F) - λ) * (one(F) + cos_φ) / F(2)
    end

    return (V₀ / D_i) * exp(effective_overlap / D_i) * w * n_ij
end
