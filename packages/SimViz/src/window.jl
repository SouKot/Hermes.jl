"""
    window.jl — GLMakie figure + rendering pipeline

# Overview

`create_window!` builds the complete GLMakie Figure:

    ┌──────────────────────────────────────────────────────┐
    │  [Scenario Menu]  [Overlay Toggle]  [▶ ⏸ ⏭ ⏹] [spd]│  row 1
    ├────────────────────────────────┬─────────────────────┤
    │                                │  Stats panel        │
    │  Simulation canvas (Axis)      │  ─────────────────  │
    │  - agent scatter               │  t = 0.000 s        │  row 2
    │  - density heatmap (optional)  │  N = 80             │
    │  - wall linesegments           │  FPS: 60.3          │
    │                                │  …DES stats…        │
    └────────────────────────────────┴─────────────────────┘
    │  Parameter sliders (v₀, σ, ρ_on, ρ_off, door, N)   │  row 3
    └──────────────────────────────────────────────────────┘

`update_viz!` is called once per render frame. It:
1. Calls `step!(ctx.scene)` (if not paused)
2. Calls `serialize_world_ctx(ctx)` → `WorldSnapshot`
3. Updates every Observable in `SimVizState` from the snapshot

`run_visualization!` is the public entry point. It builds the world,
creates the window, wires controls, then starts the `@async` sim loop.

# GLMakie type conversions
The data layer uses headless-safe tuples:
- `Pos2f = NTuple{2,Float32}` → converted to `Point2f.(positions)` here
- `RGBAfTuple = NTuple{4,Float32}` → converted to `RGBAf.(colors)` here

Both conversions happen once per frame in `update_viz!`, before pushing
to Observables, so no GLMakie types leak into the data layer.

# GLMakie markersize must be Vec2f
`markersize` passed to `scatter!` **must** be `Vec2f`, never a plain `Float32`.
A scalar `Float32` causes GLMakie 0.10.x (Makie 0.21.x) to emit `uniform float scale`
in `sprites.vert`, but the shader swizzles it as `scale.xy` → C7505 GLSL link error.
`Vec2f` forces `uniform vec2 scale` → `.xy` is valid. (Confirmed by diagnostic, 2026-09-09.)
"""

# ── GLMakie is loaded here — this file is only included when a display is
# available (i.e., NOT in headless/CI mode). All other SimViz files are safe
# to load without a display.
using GLMakie
using GLMakie: Figure, Axis, Observable, scatter!, heatmap!, linesegments!,
               Label, Menu, SliderGrid, Toggle, Button, Colorbar,
               DataAspect, RGBAf, Point2f, Vec2f, on, @lift,
               deregister_interaction!, rowgap!, colgap!, GridLayout, Box, Circle
using SimCrowd: WallSegment, step!
using Ark: Query

# ── Theme ─────────────────────────────────────────────────────────────────────

const _SIMVIZ_DARK_BG   = RGBAf(0.09f0, 0.09f0, 0.11f0, 1f0)
const _SIMVIZ_PANEL_BG  = RGBAf(0.12f0, 0.12f0, 0.15f0, 1f0)
const _SIMVIZ_WALL_CLR  = RGBAf(0.50f0, 0.55f0, 0.60f0, 1f0)
const _SIMVIZ_AXIS_BG   = RGBAf(0.06f0, 0.07f0, 0.09f0, 1f0)
const _SIMVIZ_GRID_CLR  = RGBAf(0.20f0, 0.20f0, 0.24f0, 1f0)
const _SIMVIZ_TEXT_CLR  = RGBAf(0.88f0, 0.88f0, 0.90f0, 1f0)
const _SIMVIZ_ACCENT    = RGBAf(0.37f0, 0.62f0, 0.98f0, 1f0)

# ── Wall extraction helper ─────────────────────────────────────────────────────

"""
    _extract_wall_points(ark_world) :: Tuple{Vector{Point2f}, Vector{Point2f}}

Query all `WallSegment{Float32}` entities and return `(starts, ends)` as
`Point2f` vectors for use with `linesegments!(ax, starts, ends)`.
"""
function _extract_wall_points(ark_world)
    starts = Point2f[]
    ends   = Point2f[]
    for (_, ws_col) in Query(ark_world, (WallSegment{Float32},))
        for j in eachindex(ws_col)
            push!(starts, Point2f(ws_col[j].p1[1], ws_col[j].p1[2]))
            push!(ends,   Point2f(ws_col[j].p2[1], ws_col[j].p2[2]))
        end
    end
    return starts, ends
end

# ── Stats text builder ─────────────────────────────────────────────────────────

"""
    _build_stats_text(snap, fps_str, model_name) :: String

Build the monospace multi-line string for the stats panel from a `WorldSnapshot`.
"""
function _build_stats_text(snap::WorldSnapshot, fps_str::String,
                            model_name::String) :: String
    s = snap.stats
    ρ_avg = snap.n_agents > 0 ?
        round(sum(snap.local_densities) / snap.n_agents, digits=2) : 0.00
    rho_util = s.elapsed_sim_time > 0.0 ?
        round(s.busy_time / s.elapsed_sim_time, digits=3) : 0.000

    return """
Model:    $(model_name)
────────────────────
t =       $(round(snap.sim_time, digits=3)) s
N agents: $(snap.n_agents)
N DES:    $(snap.n_des_agents)
$(fps_str)

── FSM Density ──────
ρ̄ local:  $(ρ_avg) ped/m²

── DES Stats ────────
Events:   $(s.total_events)
Arrivals: $(s.total_arrivals)
Departs:  $(s.total_departures)
ρ server: $(rho_util)
"""
end

# ── create_window! ─────────────────────────────────────────────────────────────

"""
    create_window!(ctx::ScenarioContext; cell_size=0.5f0) -> (fig, viz)

Create the GLMakie figure and wire all Observables. Returns the `Figure` and
the `SimVizState` container.

# Layout (3-row GridLayout)
- **Row 1** (height=40px): controls bar (play/pause/step/reset, speed slider,
  overlay menu, density toggle)
- **Row 2** (flex): simulation canvas (left 70%) + stats panel (right 30%)
- **Row 3** (height=120px): parameter sliders

`ctx.config` is used to:
- Set Axis limits from `config.room.width` / `config.room.height`
- Set `cell_size` for the density grid
- Initialize `markersize` for the scatter plot

!!! warning "GLMakie Observables threading"
    `update_viz!` runs in an `@async` task on the Julia main thread.
    GLMakie requires all Observable updates that touch rendered objects to
    happen on the thread that owns the OpenGL context (main thread).
    Do NOT push Observable updates from a separate `@spawn` task.
"""
function create_window!(ctx::ScenarioContext; cell_size::Float32 = 0.5f0)
    config = ctx.config
    W = Float32(config.room.width)
    H = Float32(config.room.height)
    r = Float32(config.r_body)

    # ── Figure ────────────────────────────────────────────────────────────────
    fig = Figure(
        size            = (1440, 900),
        backgroundcolor = _SIMVIZ_DARK_BG,
        figure_padding  = (8, 8, 8, 8),
    )

    # ── GridLayout skeleton ─────────────────────────────────────────────────────
    # GridLayoutBase requires a row/col to exist (have content) before rowsize!/
    # colsize! can be called on it.  We defer sizing to after content is placed:
    #   Row 2 sizes → set below, after Axis + stats panel are placed
    #   Row 1 + 3 sizes → set in wire_controls! after ctrl_bar + SliderGrid placed
    gl = fig[1, 1] = GridLayout()
    rowgap!(gl, 6)
    colgap!(gl, 6)


    # ── Row 2 Left: simulation Axis ───────────────────────────────────────────
    ax = Axis(
        gl[2, 1];
        aspect           = DataAspect(),
        backgroundcolor  = _SIMVIZ_AXIS_BG,
        xgridcolor       = _SIMVIZ_GRID_CLR,
        ygridcolor       = _SIMVIZ_GRID_CLR,
        xgridwidth       = 0.6f0,
        ygridwidth       = 0.6f0,
        xticklabelcolor  = _SIMVIZ_TEXT_CLR,
        yticklabelcolor  = _SIMVIZ_TEXT_CLR,
        xlabelcolor      = _SIMVIZ_TEXT_CLR,
        ylabelcolor      = _SIMVIZ_TEXT_CLR,
        titlecolor       = _SIMVIZ_TEXT_CLR,
        title            = config.label,
        xlabel           = "x (m)",
        ylabel           = "y (m)",
        limits           = (-0.5f0, W + 0.5f0, -0.5f0, H + 0.5f0),
    )

    # ── Build SimVizState ─────────────────────────────────────────────────────
    nx, ny = density_grid_size(W, H, cell_size)
    viz = SimVizState(
        positions    = Observable(Pos2f[]),
        agent_colors = Observable(RGBAfTuple[]),
        density_grid = Observable(zeros(Float32, nx, ny)),
        stats_text   = Observable(""),
        sim_time     = Observable(0.0),
        agent_count  = Observable(0),
        fps_display  = Observable("FPS: —"),
        overlay_mode = Observable(OVERLAY_FSM),
        show_density = Observable(false),
    )

    # ── Makie positions / colors: convert from data-layer tuples to Makie types
    # IMPORTANT: use map() + typed comprehension, NOT @lift + broadcast.
    # @lift RGBAf.(empty_vec) yields Vector{Union{}} when the source array is empty
    # (Makie can't infer the broadcast return type), which breaks assemble_colors.
    # Typed comprehensions always return the concrete element type, even for [].
    makie_positions = map(ps  -> Point2f[Point2f(p) for p in ps],  viz.positions)
    makie_colors    = map(cls -> RGBAf[RGBAf(c...) for c in cls],  viz.agent_colors)

    # ── Density heatmap (rendered first = below agents) ───────────────────────
    xs = LinRange(0f0, W, nx + 1)
    ys = LinRange(0f0, H, ny + 1)
    hm = heatmap!(ax, xs, ys, viz.density_grid;
        colormap    = :YlOrRd,
        colorrange  = (0f0, 6f0),
        alpha       = 0.45f0,
        visible     = viz.show_density,
        interpolate = false,
    )
    Colorbar(gl[2, 1], hm;
        label       = "ρ (ped/m²)",
        labelcolor  = _SIMVIZ_TEXT_CLR,
        tickcolor   = _SIMVIZ_TEXT_CLR,
        ticklabelcolor = _SIMVIZ_TEXT_CLR,
        width       = 12,
        height      = Relative(0.5f0),
        halign      = :right,
        valign      = :top,
        tellheight  = false,
        tellwidth   = false,
    )

    # ── Wall linesegments ─────────────────────────────────────────────────────
    # Makie 0.21+ linesegments! expects a single interleaved vector:
    # [start1, end1, start2, end2, ...] — NOT two separate vectors.
    wall_starts, wall_ends = _extract_wall_points(ctx.ark_world)
    if !isempty(wall_starts)
        seg_pts = Point2f[]
        for i in eachindex(wall_starts)
            push!(seg_pts, Point2f(wall_starts[i]))
            push!(seg_pts, Point2f(wall_ends[i]))
        end
        linesegments!(ax, seg_pts;
            color     = _SIMVIZ_WALL_CLR,
            linewidth = 3f0,
        )
    end

    # ── Agent scatter ─────────────────────────────────────────────────────────
    scatter!(ax, makie_positions;
        color      = makie_colors,
        marker     = Circle,        # explicit type avoids :circle Symbol → BezierPath GLSL bug
        markersize = Vec2f(2r * 80f0),  # MUST be Vec2f: Float32 scalar causes GLMakie to emit
                                        # `uniform float scale` in sprites.vert, but the shader
                                        # does `scale.xy` (swizzle on scalar) → C7505 link error.
                                        # Vec2f → `uniform vec2 scale` → .xy valid. (diag Part D ✓)
        strokewidth = 0.5f0,
        strokecolor = RGBAf(1f0, 1f0, 1f0, 0.25f0),
    )

    # ── Row 2 Right: stats panel ──────────────────────────────────────────────
    stats_panel = gl[2, 2] = GridLayout()
    Box(fig[1, 1][2, 2]; color = _SIMVIZ_PANEL_BG, strokewidth = 0)

    Label(stats_panel[1, 1], viz.stats_text;
        font         = "JuliaMono",
        fontsize     = 12f0,
        color        = _SIMVIZ_TEXT_CLR,
        halign       = :left,
        valign       = :top,
        word_wrap    = false,
        justification = :left,
    )

    # ── Size row 2 + cols 1,2 (content now exists in all three) ──────────────
    rowsize!(gl, 2, Relative(1))    # canvas + stats (flex)
    colsize!(gl, 1, Relative(0.70))
    colsize!(gl, 2, Relative(0.30))
    # Rows 1 and 3 are sized in wire_controls! after ctrl_bar/SliderGrid placed.

    return fig, viz
end

# ── update_viz! ───────────────────────────────────────────────────────────────

"""
    update_viz!(viz::SimVizState, ctx::ScenarioContext,
                fps_str::String, model_name::String;
                cell_size::Float32 = 0.5f0)

Pull a fresh `WorldSnapshot` from `ctx` and push it to all Observables.

Called once per frame from the `@async` simulation loop in `run_visualization!`.

# What gets updated every frame
- `viz.positions[]`     — agent (x,y) as `Pos2f` tuples
- `viz.agent_colors[]`  — per-agent RGBA color tuples
- `viz.density_grid[]`  — recomputed if `viz.show_density[]`
- `viz.stats_text[]`    — multi-line string for the stats panel
- `viz.sim_time[]`      — current simulated time (s)
- `viz.agent_count[]`   — number of live agents

# Density grid
Recomputed each frame only if `viz.show_density[]` is `true`. For 100×200
grids (~20k cells) this takes ~0.05 ms — well within the 16 ms budget.

!!! note "GLMakie thread safety"
    This function MUST be called from the same thread as the GLMakie event loop.
    Use `@async` (not `Threads.@spawn`) in the caller.
"""
function update_viz!(viz::SimVizState, ctx::ScenarioContext,
                     fps_str::String, model_name::String;
                     cell_size::Float32 = 0.5f0)
    snap = serialize_world_ctx(ctx)
    n    = snap.n_agents

    # ── Positions (Pos2f tuples — converted to Point2f in @lift) ─────────────
    viz.positions[] = snap.positions

    # ── Colors (RGBAfTuple — converted to RGBAf in @lift) ────────────────────
    colors_buf = Vector{RGBAfTuple}(undef, n)
    compute_agent_colors!(colors_buf, snap, viz.overlay_mode[])
    viz.agent_colors[] = colors_buf

    # ── Density grid (only when overlay is visible) ───────────────────────────
    if viz.show_density[]
        W  = Float32(ctx.config.room.width)
        H  = Float32(ctx.config.room.height)
        nx, ny = density_grid_size(W, H, cell_size)
        grid   = viz.density_grid[]
        if size(grid) != (nx, ny)
            grid = zeros(Float32, nx, ny)
        end
        compute_density_grid!(grid, snap.positions, cell_size, W, H)
        viz.density_grid[] = grid
    end

    # ── Stats ─────────────────────────────────────────────────────────────────
    viz.stats_text[]  = _build_stats_text(snap, fps_str, model_name)
    viz.sim_time[]    = snap.sim_time
    viz.agent_count[] = n
    viz.fps_display[] = fps_str

    return nothing
end

# ── run_visualization! ────────────────────────────────────────────────────────

"""
    run_visualization!(config::ScenarioConfig; cell_size=0.5f0) -> nothing

**Top-level entry point for SimViz.**

1. Calls `build_world!(config)` → `ScenarioContext`
2. Calls `create_window!(ctx)` → `(fig, viz)`
3. Calls `wire_controls!(fig, viz, ctx, ctx_ref, is_paused, speed)` (controls.jl)
4. Starts `@async` sim loop: `step! → update_viz! → sleep(dt/speed)`
5. Displays the figure and blocks until the window is closed

# Frame budget
At 60 FPS the budget is 16.7 ms per frame. The sim loop sleeps for
`max(0, dt/speed - elapsed)` seconds to keep the frame rate stable.
The `@elapsed` macro is used to measure `step! + update_viz!` time.

# Usage
```julia
using SimViz
run_visualization!(ScenarioConfig())                    # default scenario
run_visualization!(ScenarioConfig(n_agents=200, crowd_model=MODEL_ORCA))
run_visualization!(evacuation_scenario())               # 4B: built-in demo
```
"""
function run_visualization!(config::ScenarioConfig; cell_size::Float32 = 0.5f0)
    ctx     = build_world!(config)
    ctx_ref = Ref(ctx)

    fig, viz = create_window!(ctx; cell_size)

    # Mutable playback state — shared between the UI callbacks and the sim loop
    is_paused = Observable(true)
    speed     = Observable(1.0)   # 1.0 = real-time; 2.0 = 2× speed

    model_name = string(config.crowd_model)

    # ── Wire controls ─────────────────────────────────────────────────────────
    wire_controls!(fig, viz, ctx_ref, is_paused, speed; cell_size)

    # ── FPS tracking ──────────────────────────────────────────────────────────
    last_frame_ns  = Ref(time_ns())
    fps_filter     = Ref(60.0)       # exponential moving average

    # ── Async simulation loop ─────────────────────────────────────────────────
    @async while isopen(fig.scene)
        t_frame = @elapsed begin
            if !is_paused[]
                step!(ctx_ref[].scene)
                ctx_ref[].sim_time += ctx_ref[].config.dt
            end

            # FPS EMA: α=0.1 → ~10-frame smoothing
            dt_frame = (time_ns() - last_frame_ns[]) * 1e-9
            last_frame_ns[] = time_ns()
            fps_filter[] = 0.9 * fps_filter[] + 0.1 * (1.0 / max(dt_frame, 1e-6))
            fps_str = "FPS: $(round(fps_filter[], digits=1))"

            update_viz!(viz, ctx_ref[], fps_str, model_name; cell_size)
        end

        # Sleep remaining frame budget (target: dt / speed)
        target_dt = Float64(ctx_ref[].config.dt) / speed[]
        leftover   = target_dt - t_frame
        leftover > 0.001 && sleep(leftover)
    end

    display(fig)
    return nothing
end
