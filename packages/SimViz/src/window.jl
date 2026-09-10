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
               Label, Menu, Slider, SliderGrid, Toggle, Button, Colorbar,
               DataAspect, RGBAf, Point2f, Vec2f, on, @lift,
               deregister_interaction!, rowgap!, colgap!, GridLayout, Box, Circle
using SimCrowd: WallSegment, step!, apply_boundary!
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

    # ── Server utilisation ρ = busy_time / elapsed_sim_time
    rho_util = s.elapsed_sim_time > 0.0 ?
        round(s.busy_time / s.elapsed_sim_time, digits=3) : 0.000

    # ── Derived M/M/1 queue metrics (from current snapshot)
    # n_des_agents = L = total in system (queue + server)
    # server is busy iff at least one agent is in service (n_des - n_queue = 1)
    L      = snap.n_des_agents                    # mean system length (current)
    server_busy = L > 0                           # at least one agent present
    n_queue = max(0, L - (server_busy ? 1 : 0))  # waiting in queue
    n_svc   = server_busy ? 1 : 0                 # currently being served

    # Throughput (departures per sim-second)
    λ_eff = s.elapsed_sim_time > 0.0 ?
        round(s.total_departures / s.elapsed_sim_time, digits=3) : 0.000

    # Mean sojourn time estimate W = L / λ_eff  (Little's Law)
    W_est = λ_eff > 0.0 ? round(L / λ_eff, digits=2) : "—"

    return """
Model:    $(model_name)
────────────────────
t =       $(round(snap.sim_time, digits=1)) s
$(fps_str)

── System State ─────
🔵 In service:  $(n_svc)
🟢 In queue:    $(n_queue)
   Total (L):   $(L)

── Event Counts ─────
Arrived (total): $(s.total_arrivals)
Departed (done): $(s.total_departures)
In system now:   $(L)  [= arr − dep]
Events fired:    $(s.total_events)

── Performance ──────
ρ server:  $(rho_util)  [busy frac]
λ_eff:     $(λ_eff) /s  [throughput]
W (est):   $(W_est) s   [sojourn]

── FSM Density ──────
ρ̄ local:  $(ρ_avg) ped/m²
N ABM:    $(snap.n_agents)
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
# ── Wall geometry helper ─────────────────────────────────────────────────────

"""
    _build_wall_segments(ark_world) -> Vector{Pos2f}

Extract all wall segments from `ark_world` and return them as an interleaved
vector of `Pos2f` endpoints: `[start1, end1, start2, end2, ...]`.
Returns `Pos2f[]` when there are no walls.

Called once on window creation and again on every Reset so that geometry
changes (e.g. door-width slider) are reflected immediately.
"""
function _build_wall_segments(ark_world)::Vector{Pos2f}
    starts, ends = _extract_wall_points(ark_world)
    segs = Pos2f[]
    for i in eachindex(starts)
        push!(segs, Pos2f(starts[i]))
        push!(segs, Pos2f(ends[i]))
    end
    return segs
end

function create_window!(ctx::ScenarioContext; cell_size::Float32 = 0.5f0)
    config = ctx.config
    W = Float32(config.room.width)
    H = Float32(config.room.height)

    r = Float32(config.r_body)

    # ── Figure size: sized dynamically so the DataAspect canvas row (Row 2)
    #    fills most of the window with minimal wasted black space.
    #
    #    Layout overhead (fixed rows + gaps + padding):
    #      Row 1 (ctrl_bar): 44 px
    #      Row 3 (sliders) : 185 px   (6 sliders × ~28px + padding)
    #      2 rowgaps        :  12 px
    #      figure_padding   :  16 px
    #      total overhead   : 257 px
    #
    #    Canvas column is ~70% of figure width (after 16px padding + 6px colgap).
    #    Subtract ~40px for y-axis labels to get the DataAspect-constrained
    #    inner axis width, then scale by the room aspect ratio (H/W) to get the
    #    required canvas row height.  Add 60px for x-axis/title decorations.
    _fig_w         = 1440
    _canvas_col_px = 0.70f0 * Float32(_fig_w - 22)  # 22 = padding16 + colgap6
    _inner_w_px    = _canvas_col_px - 40f0           # subtract y-axis label width
    _canvas_h_px   = _inner_w_px * (H / W)           # DataAspect-required height
    _row2_h_px     = _canvas_h_px + 60f0             # add axis title + xlabel space
    _fig_h         = round(Int, _row2_h_px + 257f0)  # add fixed row overhead (44+185+12+16)
    _fig_h         = clamp(_fig_h, 480, 980)         # safety clamp

    fig = Figure(
        size            = (_fig_w, _fig_h),
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
        positions        = Observable(Pos2f[]),
        agent_colors     = Observable(RGBAfTuple[]),
        des_positions    = Observable(Pos2f[]),
        des_colors       = Observable(RGBAfTuple[]),
        agent_markersize = Observable((2f0*r, 2f0*r)),   # diameter = 2×r_body as (w,h) tuple
        axis_limits      = Observable((-0.5f0, W + 0.5f0, -0.5f0, H + 0.5f0)),
        density_grid     = Observable(zeros(Float32, nx, ny)),
        stats_text       = Observable(""),
        sim_time         = Observable(0.0),
        agent_count      = Observable(0),
        fps_display      = Observable("FPS: —"),
        overlay_mode     = Observable(OVERLAY_FSM),
        show_density     = Observable(false),
        wall_segments    = Observable(_build_wall_segments(ctx.ark_world)),
    )

    # ── Reactive Axis limits: wired to viz.axis_limits so room-resize updates the view
    on(viz.axis_limits) do lims
        xlims!(ax, lims[1], lims[2])
        ylims!(ax, lims[3], lims[4])
    end

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

    # ── Wall linesegments (Observable — updated on Reset) ────────────────────
    # Makie 0.21+ linesegments! expects a single interleaved vector:
    # [start1, end1, start2, end2, ...] — NOT two separate vectors.
    # wall_segments lives in SimVizState so update_viz! can push new geometry
    # after the door-width slider is changed and Reset is pressed.
    #
    # NOTE: we must map Pos2f → Point2f here because linesegments! needs the
    # concrete Makie type. We use a lifted Observable rather than re-computing
    # inside the callback to keep the mapping in one place.
    makie_walls = map(segs -> Point2f[Point2f(p) for p in segs], viz.wall_segments)
    linesegments!(ax, makie_walls;
        color     = _SIMVIZ_WALL_CLR,
        linewidth = 3f0,
    )

    # markersize = agent_markersize Observable (NTuple→Vec2f mapped, data units).
    # Observable binding means: when r_body slider fires + Reset is pressed,
    # push!(viz.agent_markersize, (2*new_r, 2*new_r)) → scatter redraws with new dot size.
    # markerspace = :data ensures the size scales with axis zoom, not pixels.
    #
    # IMPORTANT: Vec2f is mandatory (not Float32 / scalar).  A Float32 scalar
    # makes GLMakie 0.10.x emit `uniform float scale` in sprites.vert, but the
    # shader swizzles it as `scale.xy` → C7505 GLSL link error.
    # Vec2f → `uniform vec2 scale` → .xy valid. (Confirmed: diagnostic Part D)
    makie_markersize = map(t -> Vec2f(t[1], t[2]), viz.agent_markersize)
    scatter!(ax, makie_positions;
        color       = makie_colors,
        marker      = Circle,
        markersize  = makie_markersize,  # Observable{Vec2f} — updated by radius slider
        markerspace = :data,
        strokewidth = 0.5f0,
        strokecolor = RGBAf(1f0, 1f0, 1f0, 0.25f0),
    )

    # ── DES agent scatter (M/M/1 dots) ────────────────────────────────────────
    # Rendered on top of the crowd layer. DES dots span ~0.5m radius in data
    # units (1.0m diameter) — prominent in Demo 2's 2m-tall corridor.
    # Color: green = waiting in queue; blue = in service (set in update_viz!).
    makie_des_pos    = map(ps  -> Point2f[Point2f(p) for p in ps],  viz.des_positions)
    makie_des_colors = map(cls -> RGBAf[RGBAf(c...) for c in cls],  viz.des_colors)
    scatter!(ax, makie_des_pos;
        color       = makie_des_colors,
        marker      = Circle,
        markersize  = Vec2f(1.0f0),  # 0.5m radius — clearly visible in 2m-tall corridor
        markerspace = :data,
        strokewidth = 2.5f0,
        strokecolor = RGBAf(1f0, 1f0, 1f0, 0.85f0),  # bright white halo
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

    # Row 2 (canvas) is sized in wire_controls! together with Rows 1 and 3,
    # after all row content is placed. Using Auto() there lets it fill the
    # remaining space after the Fixed control bar and slider rows.

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

    # ── Wall geometry (cheap; only non-trivially changes after door-width Reset)
    viz.wall_segments[] = _build_wall_segments(ctx.ark_world)

    # ── Reactive geometry: sync markersize + axis bounds from current config ───
    # Called every frame so that after Reset (with new r_body / room dims) the
    # scatter dot size and axis view update immediately without recreating the window.
    let r = Float32(ctx.config.r_body),
        W = Float32(ctx.config.room.width),
        H = Float32(ctx.config.room.height)
        viz.agent_markersize[] = (2f0 * r, 2f0 * r)     # NTuple{2,Float32} — mapped to Vec2f in scatter
        viz.axis_limits[]      = (-0.5f0, W + 0.5f0, -0.5f0, H + 0.5f0)
    end

    # ── DES agent dots (M/M/1 customers from sim_world.crowd_agents) ──────────
    # Color: green = waiting in queue; blue = in service.
    # desired_speed field acts as a proxy for service state:
    # default (1.34 m/s) = waiting; elevated (μ) = in service.
    # Colors are vivid and saturated so dots stand out against the dark background.
    _GREEN_WAIT = (0.10f0, 0.95f0, 0.40f0, 1.00f0)  # vivid lime-green (waiting)
    _BLUE_SVC   = (0.15f0, 0.55f0, 1.00f0, 1.00f0)  # vivid electric-blue (in service)
    agents = ctx.sim_world.crowd_agents
    n_des  = length(agents)
    des_pos_buf = Vector{Pos2f}(undef, n_des)
    des_clr_buf = Vector{RGBAfTuple}(undef, n_des)
    for (k, (_, ag)) in enumerate(agents)
        des_pos_buf[k] = (Float32(ag.position[1]), Float32(ag.position[2]))
        # Agents at service position have elevated desired_speed (set to μ)
        # Waiting agents use default 1.34 m/s — treat anything ≠ 1.34 as in-service
        des_clr_buf[k] = ag.desired_speed ≈ 1.34f0 ? _GREEN_WAIT : _BLUE_SVC
    end
    viz.des_positions[] = des_pos_buf
    viz.des_colors[]    = des_clr_buf

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
    # NOTE: start PAUSED so the window opens with a clean t=0 state. The user
    # presses ▶ Run to begin the simulation. This also prevents the M/M/1
    # ScheduledEvent at t=0 from firing before the window is fully visible.
    is_paused = Observable(true)
    speed     = Observable(1.0)    # 1.0 = real-time; 2.0 = 2× speed

    model_name = string(config.crowd_model)

    # ── Wire controls ─────────────────────────────────────────────────────────
    wire_controls!(fig, viz, ctx_ref, is_paused, speed; cell_size)

    # ── Initial frame: paint agents in their starting positions before the
    #    async loop has a chance to tick.  Without this, the scatter Observable
    #    starts empty (Pos2f[]) so no dots appear until the first @async tick.
    update_viz!(viz, ctx_ref[], "FPS: —", model_name; cell_size)

    # ── FPS tracking ──────────────────────────────────────────────────────────
    last_frame_ns  = Ref(time_ns())
    fps_filter     = Ref(60.0)       # exponential moving average

    # ── Open window FIRST so isopen(fig.scene) == true when @async checks it ─
    # Diagnostic confirmed: isopen() returns false before display() attaches a
    # GLFW screen.  The @async loop would see false on its first iteration and
    # exit immediately, leaving the simulation permanently frozen at t=0.
    display(fig)

    # ── Async simulation loop ─────────────────────────────────────────────────
    # IMPORTANT: The entire body is wrapped in try/catch so that any error
    # (e.g. from step! on a rebuilt scene after Reset) is logged rather than
    # silently killing the loop. Without this, a single error after Reset would
    # permanently freeze the simulation with no visible feedback.
    @async while isopen(fig.scene)
        t_frame = @elapsed begin
            try
                if !is_paused[]
                    step!(ctx_ref[].scene)
                    ctx_ref[].sim_time += ctx_ref[].config.dt
                    # Dispatch any DES events that have fired (alarm, M/M/1 tick, etc.)
                    _dispatch_events!(ctx_ref[], ctx_ref[].sim_time)
                    # Remove agents that have reached their goal (flux_boundary=true)
                    for bc in ctx_ref[].boundaries
                        apply_boundary!(ctx_ref[].ark_world, bc)
                    end
                end

                # FPS EMA: α=0.1 → ~10-frame smoothing
                dt_frame = (time_ns() - last_frame_ns[]) * 1e-9
                last_frame_ns[] = time_ns()
                fps_filter[] = 0.9 * fps_filter[] + 0.1 * (1.0 / max(dt_frame, 1e-6))
                fps_str = "FPS: $(round(fps_filter[], digits=1))"

                update_viz!(viz, ctx_ref[], fps_str, model_name; cell_size)
            catch err
                @warn "[SimViz] Sim loop error (loop continues): $err" exception=(err, catch_backtrace())
                # Pause on error so user sees the frozen state rather than a crash
                is_paused[] = true
            end
        end

        # Sleep remaining frame budget (target: dt / speed)
        target_dt = Float64(ctx_ref[].config.dt) / speed[]
        leftover   = target_dt - t_frame
        leftover > 0.001 && sleep(leftover)
    end

    return nothing
end
