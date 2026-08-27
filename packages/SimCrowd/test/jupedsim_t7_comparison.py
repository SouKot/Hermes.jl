"""
jupedsim_t7_comparison.py — Direct comparison between JuPedSim and our SimCrowd
on the T7 bottleneck (10×4m room, 1m door, 80 agents).

Questions answered:
  Q1: Safety cap — does JuPedSim need one? (inspect direction computation)
  Q2: Wall repulsion scope — is it lateral-only or all-direction?
  Q3: How does JuPedSim achieve T7? What params? What validation do they use?

Runs 4 configurations:
  A) JuPedSim default params (a=8.0, D=0.1, T=1.0)
  B) JuPedSim with our tuned params (a=8.0, D=0.2, T=0.8)
  C) JuPedSim V1-style (no geometry repulsion)
  D) JuPedSim with waypoint routing (pre-route to door center)
"""

import jupedsim as jps
import shapely
import numpy as np
import math, time

# ── T7 geometry ──────────────────────────────────────────────────────────────
ROOM_L, ROOM_W = 10.0, 4.0
DOOR_CY, DOOR_HALF = 2.0, 0.5
EXIT_X = 10.5
T_MAX = 120.0
DT = 0.05
N = 80
SEED = 42


def build_geometry():
    """10×4m room with 1m door at right wall center."""
    room = shapely.box(0, 0, ROOM_L, ROOM_W)
    door = shapely.box(ROOM_L - 0.01, DOOR_CY - DOOR_HALF, ROOM_L + 2.0, DOOR_CY + DOOR_HALF)
    return shapely.union(room, door)


def place_agents(n=80, seed=42):
    """Grid placement with jitter — same layout as SimCrowd tier3 test."""
    rng = np.random.default_rng(seed)
    cols = max(1, math.ceil(math.sqrt(n * 9.0 / 3.4)))
    rows = math.ceil(n / cols)
    sp_x = 9.0 / (cols + 1)
    sp_y = 3.4 / (rows + 1)
    positions = []
    for k in range(n):
        row, col = divmod(k, cols)
        x = 0.5 + (col + 1) * sp_x + 0.05 * (rng.random() - 0.5)
        y = 0.3 + (row + 1) * sp_y + 0.05 * (rng.random() - 0.5)
        x = max(0.3, min(9.7, x))
        y = max(0.3, min(3.7, y))
        positions.append((x, y))
    return positions


def run_scenario(label, model, agent_params_fn, use_waypoint=False, verbose=True):
    """Run one bottleneck configuration. Returns flow_rate, n_passed, t_exit, deadlock."""
    geo = build_geometry()

    sim = jps.Simulation(
        model=model,
        geometry=geo,
        dt=DT,
    )

    # Exit stage — a notional exit past the door
    if use_waypoint:
        # Route: agents first go to waypoint at (9.5, 2.0) then to exit
        wp = sim.add_waypoint_stage((9.5, DOOR_CY), 0.5)
        exit_stage = sim.add_exit_stage([(EXIT_X, DOOR_CY - DOOR_HALF),
                                          (EXIT_X + 0.5, DOOR_CY - DOOR_HALF),
                                          (EXIT_X + 0.5, DOOR_CY + DOOR_HALF),
                                          (EXIT_X, DOOR_CY + DOOR_HALF)])
        journey = sim.add_journey(jps.JourneyDescription([wp, exit_stage]))
    else:
        exit_stage = sim.add_exit_stage([(EXIT_X, DOOR_CY - DOOR_HALF),
                                          (EXIT_X + 0.5, DOOR_CY - DOOR_HALF),
                                          (EXIT_X + 0.5, DOOR_CY + DOOR_HALF),
                                          (EXIT_X, DOOR_CY + DOOR_HALF)])
        journey = sim.add_journey(jps.JourneyDescription([exit_stage]))

    positions = place_agents(N, SEED)
    for pos in positions:
        params = agent_params_fn(journey, exit_stage)
        params.position = pos
        sim.add_agent(params)

    # Run simulation
    n_passed = 0
    t_first = None
    t_last = None
    t = 0.0

    while t < T_MAX and sim.agent_count() > 0:
        sim.iterate()
        t += DT
        removed = N - sim.agent_count() - n_passed
        if removed > 0:
            if t_first is None:
                t_first = t
            t_last = t
            n_passed += removed

    deadlock = (t >= T_MAX and n_passed < N)
    if n_passed > 1 and t_last is not None and t_first is not None:
        flow_rate = (n_passed - 1) / (t_last - t_first) if t_last > t_first else 0.0
    else:
        flow_rate = 0.0
    t_exit = t_last if t_last else T_MAX

    if verbose:
        status = "DEADLOCK❌" if deadlock else ("OK✅" if flow_rate >= 1.22 else "low")
        print(f"  [{label:30s}]  flow={flow_rate:.3f} ped/s  t_exit={t_exit:.1f}s  "
              f"passed={n_passed}/{N}  {status}")

    return dict(flow=flow_rate, passed=n_passed, t_exit=t_exit, deadlock=deadlock)


print("=" * 70)
print("JuPedSim T7 Bottleneck Comparison (10×4m room, 1m door, N=80)")
print("JuPedSim version:", jps.__version__)
print("=" * 70)

# ── Configuration A: JuPedSim default params ─────────────────────────────────
print("\n[A] JuPedSim CSM V1 — DEFAULT params (a=8.0, D=0.1, T=1.0, v0=1.2)")
print("    strength_geometry_repulsion=5.0, range_geometry_repulsion=0.02")
model_A = jps.CollisionFreeSpeedModel(
    strength_neighbor_repulsion=8.0,
    range_neighbor_repulsion=0.1,
    strength_geometry_repulsion=5.0,
    range_geometry_repulsion=0.02,
)
def params_A(journey, stage):
    return jps.CollisionFreeSpeedModelAgentParameters(
        time_gap=1.0, desired_speed=1.2, radius=0.2,
        journey_id=journey, stage_id=stage)

r_A = run_scenario("JuPedSim default", model_A, params_A)

# ── Configuration B: Our tuned params on JuPedSim ────────────────────────────
print("\n[B] JuPedSim CSM V1 — OUR tuned params (a=8.0, D=0.2, T=0.8, v0=1.34)")
model_B = jps.CollisionFreeSpeedModel(
    strength_neighbor_repulsion=8.0,
    range_neighbor_repulsion=0.2,
    strength_geometry_repulsion=5.0,
    range_geometry_repulsion=0.02,
)
def params_B(journey, stage):
    return jps.CollisionFreeSpeedModelAgentParameters(
        time_gap=0.8, desired_speed=1.34, radius=0.2,
        journey_id=journey, stage_id=stage)

r_B = run_scenario("JuPedSim our-tuned params", model_B, params_B)

# ── Configuration C: No geometry repulsion ────────────────────────────────────
print("\n[C] JuPedSim CSM V1 — OUR params, zero geometry repulsion")
model_C = jps.CollisionFreeSpeedModel(
    strength_neighbor_repulsion=8.0,
    range_neighbor_repulsion=0.2,
    strength_geometry_repulsion=0.0,
    range_geometry_repulsion=0.02,
)
r_C = run_scenario("JuPedSim no-wall repulsion", model_C, params_B)

# ── Configuration D: Default params + waypoint routing ────────────────────────
print("\n[D] JuPedSim CSM V1 — DEFAULT params + waypoint at (9.5, 2.0)")
r_D = run_scenario("JuPedSim default + waypoint", model_A, params_A, use_waypoint=True)

# ── Configuration E: Sweep D_neighbor with JuPedSim's own routing ─────────────
print("\n[E] D_neighbor sweep with JuPedSim default routing (T=1.0, v0=1.2):")
print("    D      flow    passed  status")
for D_n in [0.05, 0.10, 0.15, 0.20, 0.30, 0.40]:
    model_e = jps.CollisionFreeSpeedModel(
        strength_neighbor_repulsion=8.0,
        range_neighbor_repulsion=D_n,
        strength_geometry_repulsion=5.0,
        range_geometry_repulsion=0.02,
    )
    r = run_scenario(f"D={D_n:.2f}", model_e, params_A, verbose=False)
    status = "OK✅" if r['flow'] >= 1.22 else ("DEADLOCK" if r['deadlock'] else "low")
    print(f"    {D_n:.2f}   {r['flow']:.3f}   {r['passed']:>2}/{N}   {status}")

# ── Configuration F: JuPedSim V2 (per-agent params) ──────────────────────────
print("\n[F] JuPedSim CSM V2 (per-agent params) — default + waypoint:")
model_F = jps.CollisionFreeSpeedModelV2()
print(f"    V2 defaults: {model_F}")

print("\n" + "=" * 70)
print("SUMMARY")
print(f"  A (JPS default, no waypoint):    flow={r_A['flow']:.3f}  {'OK✅' if r_A['flow'] >= 1.22 else 'DEADLOCK❌' if r_A['deadlock'] else 'low'}")
print(f"  B (our params, no waypoint):     flow={r_B['flow']:.3f}  {'OK✅' if r_B['flow'] >= 1.22 else 'DEADLOCK❌' if r_B['deadlock'] else 'low'}")
print(f"  C (our params, no wall rep):     flow={r_C['flow']:.3f}  {'OK✅' if r_C['flow'] >= 1.22 else 'low'}")
print(f"  D (JPS default + waypoint):      flow={r_D['flow']:.3f}  {'OK✅' if r_D['flow'] >= 1.22 else 'DEADLOCK❌' if r_D['deadlock'] else 'low'}")

# ── Inspect JuPedSim's geometry repulsion mathematically ─────────────────────
print("\n" + "=" * 70)
print("WALL REPULSION ANALYSIS — JuPedSim's approach")
print("   range_geometry_repulsion = 0.02m")
print("   strength_geometry_repulsion = 5.0")
print("   Effective distance (3 decay lengths): 3 × 0.02 = 0.06m")
print("   At d=0.02m: repulsion = 5.0 × exp(-0.02/0.02) = 5.0 × 0.368 = 1.84 [a.u.]")
print("   At d=0.10m: repulsion = 5.0 × exp(-0.10/0.02) = 5.0 × 0.0067 = 0.03 [a.u.]")
print("   → Wall repulsion is essentially ZERO beyond 0.1m from wall")
print("   → Our D_wall=0.2m vs JuPedSim D_wall=0.02m: 10× wider")
print()
print("   JuPedSim's wall repulsion: contact-avoidance only (last 6cm)")
print("   Our V2's wall repulsion:   flow-shaping influence (up to ~60cm)")
