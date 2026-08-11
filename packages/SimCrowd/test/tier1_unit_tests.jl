using Test
using SimCrowd
using StaticArrays
using LinearAlgebra

# ── Tier 1: Mathematical Unit Tests ─────────────────────────────────────────
# These tests verify individual force functions in complete isolation.
# They are deterministic (no random seeds, no ECS), and test pure math.
# ALL tests must pass after a correct implementation. Calibration doesn't matter here.
# Reference: Helbing & Molnár 1995, Helbing et al. 2000, van den Berg et al. 2011.

@testset "Tier 1: Force Function Unit Tests" begin

    # ── Goal-seeking force ──────────────────────────────────────────────────

    @testset "T1-01: Goal force points toward goal" begin
        # Agent at origin, goal at (10, 0), stationary
        F = goal_seeking_force(
            SVector(0.0f0, 0.0f0),   # pos
            SVector(0.0f0, 0.0f0),   # vel
            SVector(10.0f0, 0.0f0),  # goal
            1.4f0, 0.5f0, 80.0f0    # v_pref, τ, mass
        )
        @test F[1] > 0.0f0   # must push in +x direction
        @test abs(F[2]) < 1f-3  # negligible y component
    end

    @testset "T1-02: Goal force magnitude matches Helbing formula" begin
        # F = mass * (v0 * ê − v) / τ
        # With v=0, pos=(0,0), goal=(1,0): F = mass * v0 / τ in +x
        mass = 80.0f0; v0 = 1.4f0; τ = 0.5f0
        F = goal_seeking_force(
            SVector(0.0f0, 0.0f0),
            SVector(0.0f0, 0.0f0),
            SVector(1.0f0, 0.0f0),
            v0, τ, mass
        )
        expected_magnitude = mass * v0 / τ  # = 80 * 1.4 / 0.5 = 224 N
        @test abs(F[1] - expected_magnitude) < 0.1f0
        @test abs(F[2]) < 1f-3
    end

    @testset "T1-03: Goal force is zero at target" begin
        # Agent exactly at goal with zero velocity: force must be zero
        F = goal_seeking_force(
            SVector(5.0f0, 5.0f0),
            SVector(0.0f0, 0.0f0),
            SVector(5.0f0, 5.0f0),   # same as pos
            1.4f0, 0.5f0, 80.0f0
        )
        @test norm(F) < 1f-3
    end

    @testset "T1-04: Goal force reduces if agent already moving toward goal" begin
        # Agent already at v0 in goal direction → force should be near zero
        v0 = 1.4f0; τ = 0.5f0; mass = 80.0f0
        F_stationary = goal_seeking_force(
            SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0),
            SVector(10.0f0, 0.0f0), v0, τ, mass
        )
        F_moving = goal_seeking_force(
            SVector(0.0f0, 0.0f0), SVector(v0, 0.0f0),  # already at v_pref
            SVector(10.0f0, 0.0f0), v0, τ, mass
        )
        @test norm(F_moving) < norm(F_stationary)  # less force needed
        @test norm(F_moving) < 1.0f0               # near zero (just correcting noise)
    end

    # ── Agent repulsion force ───────────────────────────────────────────────

    @testset "T1-05: Repulsion force points away from neighbour" begin
        # Agent i at (0,0), agent j at (0.5, 0)
        # Net force on i must point in -x (away from j)
        F = agent_repulsion(
            SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.25f0, 0.2f0,
            SVector(0.5f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.25f0, 0.2f0
        )
        @test F[1] < 0.0f0   # repelled in -x
        @test abs(F[2]) < abs(F[1]) * 0.01f0  # symmetric setup → no y component
    end

    @testset "T1-06: Repulsion decays with distance" begin
        # Social force must decrease as agents move further apart
        function repulsion_at_dist(d)
            norm(agent_repulsion(
                SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.25f0, 0.2f0,
                SVector(d, 0.0f0),     SVector(0.0f0, 0.0f0), 0.25f0, 0.2f0
            ))
        end
        @test repulsion_at_dist(0.6f0) > repulsion_at_dist(1.0f0)
        @test repulsion_at_dist(1.0f0) > repulsion_at_dist(2.0f0)
        @test repulsion_at_dist(2.0f0) > repulsion_at_dist(5.0f0)
    end

    @testset "T1-07: Body compression force is zero when not in contact" begin
        # Agents far apart: d > r_i + r_j → no body force, only social force
        # The body force (k * g_overlap) must contribute zero when d > collision radii sum
        # We can verify by checking force at d >> sum_radius vs d at contact
        r_i = 0.2f0; r_j = 0.2f0  # collision radii
        # At d = 2.0m, agents are not in contact → no body/friction force
        F_far = agent_repulsion(
            SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.4f0, r_i,
            SVector(2.0f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.4f0, r_j;
            k=1.2f5, κ=2.4f5
        )
        # At d = 0.3m < 0.4m (in contact), body force kicks in
        F_contact = agent_repulsion(
            SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.4f0, r_i,
            SVector(0.3f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.4f0, r_j;
            k=1.2f5, κ=2.4f5
        )
        # Contact force should be much larger than far force (body term adds significant force)
        @test norm(F_contact) > norm(F_far) * 10.0f0
    end

    @testset "T1-08: Sliding friction direction is tangential" begin
        # Agent i at rest, agent j moving in +y direction, agents in contact
        # Friction on i should be in +y direction (dragged along by j)
        F = agent_repulsion(
            SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0),   # i: pos, vel
            0.25f0, 0.2f0,
            SVector(0.3f0, 0.0f0), SVector(0.0f0, 2.0f0),   # j: pos (close), vel in +y
            0.25f0, 0.2f0;
            k=1.2f5, κ=2.4f5, μ=0.5f0
        )
        # Normal (repulsion) force is in -x. Friction force on i due to j moving in +y
        # The tangential direction t_ij = perpendicular to n_ij = (0, 1) when n_ij=(1,0)
        # So friction should give F[2] > 0 (i gets dragged in +y by j moving in +y)
        @test F[2] > 0.0f0   # tangential component in +y
        @test abs(F[2]) > 0.0f0  # non-zero friction
    end

    @testset "T1-09: Friction is zero when μ=0" begin
        # μ=0 → Coulomb cap = 0 → all friction clamped to zero
        F_mu0 = agent_repulsion(
            SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.25f0, 0.2f0,
            SVector(0.3f0, 0.0f0), SVector(0.0f0, 2.0f0), 0.25f0, 0.2f0;
            k=1.2f5, κ=2.4f5, μ=0.0f0
        )
        F_mu05 = agent_repulsion(
            SVector(0.0f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.25f0, 0.2f0,
            SVector(0.3f0, 0.0f0), SVector(0.0f0, 2.0f0), 0.25f0, 0.2f0;
            k=1.2f5, κ=2.4f5, μ=0.5f0
        )
        # With μ=0 the tangential (y) component must be zero
        @test abs(F_mu0[2]) < 1f-3
        # With μ=0.5 the tangential component must be non-zero
        @test abs(F_mu05[2]) > 1.0f0
    end

    # ── Wall repulsion ──────────────────────────────────────────────────────

    @testset "T1-10: Wall repulsion points away from wall" begin
        # Wall from (0,0) to (10,0) along the x-axis. Agent above wall at (5, 0.3).
        # Force on agent must point in +y (away from wall).
        F = wall_repulsion(
            SVector(5.0f0, 0.3f0),   # agent pos, above the wall
            SVector(0.0f0, 0.0f0),   # vel
            0.4f0, 0.25f0,           # social_radius, collision_radius
            (SVector(0.0f0, 0.0f0), SVector(10.0f0, 0.0f0))  # wall segment
        )
        @test F[2] > 0.0f0   # pushed away from wall (in +y)
        @test abs(F[1]) < abs(F[2]) * 0.01f0  # symmetric → no x component
    end

    @testset "T1-11: Wall repulsion decays with distance" begin
        function wall_force_at_dist(y)
            norm(wall_repulsion(
                SVector(5.0f0, y), SVector(0.0f0, 0.0f0), 0.4f0, 0.25f0,
                (SVector(0.0f0, 0.0f0), SVector(10.0f0, 0.0f0))
            ))
        end
        @test wall_force_at_dist(0.3f0) > wall_force_at_dist(0.5f0)
        @test wall_force_at_dist(0.5f0) > wall_force_at_dist(1.0f0)
    end

    # ── Anisotropy ──────────────────────────────────────────────────────────

    @testset "T1-12: Anisotropic weight — agents behind exert less force" begin
        # Agent i moving in +x. Agent j1 is in front (+x), agent j2 is behind (-x).
        # Repulsion from j1 (in front/field of view) should be >= from j2 (behind).
        vel_i = SVector(1.4f0, 0.0f0)   # moving in +x
        # j in front of i (at +x, so n_ij points to -x, meaning j is ahead)
        F_front = agent_repulsion(
            SVector(0.0f0, 0.0f0), vel_i, 0.25f0, 0.2f0,
            SVector(0.6f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.25f0, 0.2f0;
            λ=0.5f0
        )
        # j behind i (at -x)
        F_behind = agent_repulsion(
            SVector(0.0f0, 0.0f0), vel_i, 0.25f0, 0.2f0,
            SVector(-0.6f0, 0.0f0), SVector(0.0f0, 0.0f0), 0.25f0, 0.2f0;
            λ=0.5f0
        )
        # Helbing: agents in the field of view get full weight (w=1),
        # agents behind get reduced weight (w=λ < 1).
        # So norm(F_front) should be >= norm(F_behind)
        @test norm(F_front) >= norm(F_behind)
    end

end
