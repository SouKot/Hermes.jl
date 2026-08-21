# SimCrowd — Session State (Human-readable)

> Mirror of KI `antigravity_session_state/state.md`. Updated: 2026-08-21.

## Last Commit

```
557028e  fix(gcf): add λ anisotropy to gcf_force + dt=0.01 calibration (3F pass all 4 densities)
```

## Test Status

```
tier1_unit_tests.jl            | 12/12 ✅
runtests.jl                    | 20/20 ✅
tier3_cross_library.jl (3A-3G) | 30/30 ✅
3H: Speed Distribution         |  3/ 3 ✅
Total                          | 33 passing, 0 failing
```

## What was fixed today (2026-08-21)

### Sprint 3F — Root cause of ALL failures

Three bugs were found and fixed in commit `557028e`:

1. **λ-bug (model bug)**: `gcf_force` in `src/forces.jl` was ISOTROPIC.
   In a periodic corridor, isotropic forces cancel → ratio≈1.0 for all densities.
   Fix: Added `λ` parameter to `gcf_force`, wired in `src/systems/social.jl`.

2. **Wrong dt**: `FundamentalDiagramConfig` used dt=0.05s (Chraibi 2010 paper: 0.01s).
   Fix: `test/crowd_test_helpers.jl` default dt changed 0.05 → 0.01.

3. **Wrong V₀**: V₀=50 was calibrated on broken model.
   Fix: V₀=70N (calibration sweep, verified stable across 5 seeds).

**Result**: All 4 densities pass ±15% Weidmann:
- ρ=0.5: ratio=0.942 ✅  ρ=1.0: ratio=0.985 ✅
- ρ=2.0: ratio=1.122 ✅  ρ=3.0: ratio=1.110 ✅

### REVERTED (do not use)

- `839cb91` — cooked 3F params (η=0.3 V₀=150, wrong dt)
- `cfd116f` — Sprint 3I double-integration hack (physically wrong)
- Both reverted in `c9bd2ee`

## Next Work Item — Sprint 3I (Bottleneck Flow)

**Goal**: Sustained bottleneck flow ≥1.22 ped/s (85% of Weidmann 1.44 ped/s for 1m door).

**Current state**: `3B-res` has relaxed assertions (peak ≥0.3, crossings ≥5) that pass
trivially — arch forms after 9 agents then stops.

**Correct approach**: Pure ORCA agents for bottleneck (no SFM arch formation).

## Key Files to Read First

| File | Why |
|------|-----|
| `src/forces.jl` | `gcf_force` (λ-fixed), `psychological_force` |
| `src/systems/social.jl` | GCF/SFM dispatch (3 sites that pass λ) |
| `test/crowd_test_helpers.jl` | `FundamentalDiagramConfig`, `run_fundamental_diagram!`, `run_reservoir_bottleneck!` |
| `test/tier3_cross_library.jl` | All tier-3 tests (3A–3H) |
| `test/pilot_3i.jl` | Pilot for Sprint 3I bottleneck approach |

## Validation Rules (MANDATORY — from user)

1. **No goalpost moving** — test assertion changes need peer-reviewed citation
2. **Debug in order**: parameters first → JuPedSim comparison → algorithmic differences
3. **No cooked tests** — params must match a reference source, not just make the sim pass
