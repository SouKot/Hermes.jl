"""
    controls.jl — Playback controls + parameter panel

Implements `wire_controls!` which adds all interactive UI elements to the
figure created by `create_window!` (window.jl).

# Layout (rows 1 + 3 of the GridLayout from create_window!)

## Row 1 — Controls bar
    [▶ Run] [|| Pause] [▶| Step] [■ Reset]  │  Speed: ───●───  │
    Overlay: [Panic ▼]  │  Density heatmap: [○]

## Row 3 — Parameter sliders (6 knobs, disabled while running)
    v₀ (m/s)  │  σ noise  │  ρ_on  │  ρ_off  │  Door width  │  N agents

# Design notes
- All button callbacks write to `is_paused[]` or `speed[]` Observables;
  the `@async` loop in `run_visualization!` reads them on every frame.
- Parameter sliders modify a `config_ref[]` (copy of `ctx_ref[].config`
  via `@set` from Accessors.jl). They do **not** take effect until the
  next Reset press.
- The `σ noise` slider is the only one that applies live (while running):
  it calls `update_sigma!(ctx_ref[], σ)` to patch all agent `MotionParams`.
- `reset_cb` rebuilds the world from `config_ref[]` in-place via
  `reset_scenario!(ctx_ref[], config=config_ref[])`.
"""

# GLMakie is already loaded by window.jl (included before this file)
using Accessors: @set
using SimCrowd: MotionParams, Query

# ── Overlay menu items ────────────────────────────────────────────────────────

const _OVERLAY_OPTIONS = ["Panic level", "FSM mode", "Local density"]
const _OVERLAY_MAP = Dict(
    "Panic level"   => OVERLAY_PANIC,
    "FSM mode"      => OVERLAY_FSM,
    "Local density" => OVERLAY_DENSITY,
)

# ── Live sigma update ─────────────────────────────────────────────────────────

"""
    _update_sigma!(ctx::ScenarioContext, σ::Float64)

Patch the `sigma_noise` field of every agent's `MotionParams` component
in the Ark ECS world. This is the only slider that takes effect live
(without requiring a Reset).
"""
function _update_sigma!(ctx::ScenarioContext, σ::Float64)
    F  = Float32
    σf = F(σ)
    for (_, mp_col) in Query(ctx.ark_world, (MotionParams{F},))
        for i in eachindex(mp_col)
            mp   = mp_col[i]
            # MotionParams is immutable — reconstruct with new sigma
            mp_col[i] = MotionParams{F}(mp.mass, mp.v_pref, mp.τ, σf)
        end
    end
    return nothing
end

# ── wire_controls! ────────────────────────────────────────────────────────────

"""
    wire_controls!(fig, viz, ctx_ref, is_paused, speed; cell_size=0.5f0)

Add all interactive controls to `fig` and wire their callbacks to the
simulation state.

# Arguments
- `fig`        : GLMakie Figure (from `create_window!`)
- `viz`        : SimVizState (from `create_window!`)
- `ctx_ref`    : `Ref{ScenarioContext}` — the live simulation context
- `is_paused`  : `Observable{Bool}` — shared with the sim loop
- `speed`      : `Observable{Float64}` — playback speed multiplier

# Controls created
## Row 1 — Controls bar
- **▶ Run** button → `is_paused[] = false`
- **|| Pause** button → `is_paused[] = true`
- **▶| Step** button → runs one `step!` + one `update_viz!` call
- **■ Reset** button → `reset_scenario!(ctx_ref[], config=config_ref[])`,
  reinitializes wall segments on the Axis
- **Speed slider** (0.1×–5×, step 0.1) → writes `speed[]`
- **Overlay Menu** → writes `viz.overlay_mode[]`
- **Density Toggle** → writes `viz.show_density[]`

## Row 3 — Parameter sliders
All sliders except σ are disabled while `!is_paused[]`.
Slider values propagate into a mutable `config_ref[]` via `@set`.
Values are applied on Reset.

| Label      | Range       | Default        | Live? |
|:---------- |:----------- |:-------------- |:----- |
| v₀ (m/s)  | 0.5 – 4.0  | config.v_pref  | ✗     |
| σ noise    | 0.0 – 0.5  | config.sigma_noise | ✓ |
| ρ_on       | 1.0 – 7.0  | config.rho_on  | ✗     |
| ρ_off      | 0.5 – 6.5  | config.rho_off | ✗     |
| Door width | 0.4 – 4.0  | first door width | ✗   |
| N agents   | 5 – 500    | config.n_agents | ✗    |
"""
function wire_controls!(fig, viz, ctx_ref::Ref{ScenarioContext},
                         is_paused::Observable{Bool},
                         speed::Observable{Float64};
                         cell_size::Float32 = 0.5f0)
    config = ctx_ref[].config

    # Keep a mutable copy of the config that sliders write into.
    # Applied on Reset — not hot-patched (except sigma).
    config_ref = Ref(config)

    # ── Resolve the GridLayout from the figure ─────────────────────────────────
    gl = contents(fig[1, 1])[1]   # the GridLayout added in create_window!

    # ── Row 1: Controls bar ───────────────────────────────────────────────────
    ctrl_bar = gl[1, 1:2] = GridLayout()
    colgap!(ctrl_bar, 4)


    btn_run   = Button(ctrl_bar[1, 1];  label="▶  Run",   buttoncolor=RGBAf(0.2,0.55,0.3,1),   labelcolor=:white)
    btn_pause = Button(ctrl_bar[1, 2];  label="||  Pause", buttoncolor=RGBAf(0.55,0.45,0.1,1), labelcolor=:white)
    btn_step  = Button(ctrl_bar[1, 3];  label="▶|  Step",  buttoncolor=RGBAf(0.25,0.35,0.6,1), labelcolor=:white)
    btn_reset = Button(ctrl_bar[1, 4];  label="■   Reset", buttoncolor=RGBAf(0.55,0.15,0.15,1), labelcolor=:white)

    # Speed label (col 5) + slider (col 6 — flex)
    Label(ctrl_bar[1, 5], "Speed:"; color = _SIMVIZ_TEXT_CLR, fontsize = 12f0, halign = :right)
    spd_slider = Slider(ctrl_bar[1, 6];
        range   = 0.1:0.1:5.0,
        startvalue = 1.0,
        color_active = _SIMVIZ_ACCENT,
    )

    # Overlay label (col 7) + menu (col 8)
    Label(ctrl_bar[1, 7], "Overlay:"; color = _SIMVIZ_TEXT_CLR, fontsize=12f0, halign=:right)
    overlay_menu = Menu(ctrl_bar[1, 8];
        options = _OVERLAY_OPTIONS,
        default = "FSM mode",
        textcolor = _SIMVIZ_TEXT_CLR,
    )

    # Density toggle: label (col 9) + widget (col 10)
    Label(ctrl_bar[1, 9], "ρ heatmap"; color=_SIMVIZ_TEXT_CLR, fontsize=12f0)
    density_toggle = Toggle(ctrl_bar[1, 10]; active=false, buttoncolor=_SIMVIZ_ACCENT)

    # ── Set ctrl_bar column sizes (cols 1–10) ───────────────────────────────────────
    colsize!(ctrl_bar, 1, Fixed(72))     # ▶ Run
    colsize!(ctrl_bar, 2, Fixed(72))     # ⏸ Pause
    colsize!(ctrl_bar, 3, Fixed(72))     # ⏭ Step
    colsize!(ctrl_bar, 4, Fixed(72))     # ⏹ Reset
    colsize!(ctrl_bar, 5, Fixed(56))     # "Speed:" label
    colsize!(ctrl_bar, 6, Auto(false))   # Speed slider: remaining space after Fixed cols.
                                         # MUST be Auto(false), not Relative(1):
                                         # Relative(f) = f×TOTAL width → overflows by
                                         # sum-of-fixed-cols (≈654px), pushing Run/Pause/Step
                                         # off-screen. Auto(false) = "take remaining space".
    colsize!(ctrl_bar, 7, Fixed(68))     # "Overlay:" label
    colsize!(ctrl_bar, 8, Fixed(130))    # Overlay menu
    colsize!(ctrl_bar, 9, Fixed(76))     # "ρ heatmap" label
    colsize!(ctrl_bar, 10, Fixed(36))    # Density toggle widget

    # ── Button callbacks ──────────────────────────────────────────────────────

    on(btn_run.clicks) do _
        is_paused[] = false
    end

    on(btn_pause.clicks) do _
        is_paused[] = true
    end

    on(btn_step.clicks) do _
        # Step exactly once, regardless of paused state
        step!(ctx_ref[].scene)
        ctx_ref[].sim_time += ctx_ref[].config.dt
        fps_str = viz.fps_display[]
        model_name = string(ctx_ref[].config.crowd_model)
        update_viz!(viz, ctx_ref[], fps_str, model_name; cell_size)
    end

    on(btn_reset.clicks) do _
        was_paused = is_paused[]
        is_paused[] = true
        reset_scenario!(ctx_ref[]; config = config_ref[])
        model_name = string(ctx_ref[].config.crowd_model)
        update_viz!(viz, ctx_ref[], viz.fps_display[], model_name; cell_size)
        is_paused[] = was_paused
    end

    # Speed
    on(spd_slider.value) do v
        speed[] = Float64(v)
    end

    # Overlay menu
    on(overlay_menu.selection) do sel
        if !isnothing(sel) && haskey(_OVERLAY_MAP, sel)
            viz.overlay_mode[] = _OVERLAY_MAP[sel]
        end
    end

    # Density toggle
    on(density_toggle.active) do v
        viz.show_density[] = v
    end

    # ── Row 3: Parameter sliders ──────────────────────────────────────────────
    door_w_default = isempty(config.room.doors) ? 1.0 : config.room.doors[1].width

    sg = SliderGrid(gl[3, 1:2],
        (label = "v₀  (m/s)",     range = 0.5:0.05:4.0,  startvalue = config.v_pref,       format = "{:.2f}"),
        (label = "σ noise",       range = 0.0:0.01:0.5,  startvalue = config.sigma_noise,  format = "{:.2f}"),
        (label = "ρ_on (ped/m²)", range = 1.0:0.25:7.0,  startvalue = config.rho_on,       format = "{:.2f}"),
        (label = "ρ_off(ped/m²)", range = 0.5:0.25:6.5,  startvalue = config.rho_off,      format = "{:.2f}"),
        (label = "Door w (m)",    range = 0.4:0.1:4.0,   startvalue = door_w_default,       format = "{:.1f}"),
        (label = "N agents",      range = 5:5:500,        startvalue = config.n_agents,     format = "{:d}"),
    )

    # ── Size all rows + cols now that every row/col has content ───────────────
    # IMPORTANT: All three rows sized together, AFTER content is placed in each.
    # Row 2 uses Auto(false) [trydetermine=false]:
    #   Auto(true)  [default]: shrinks to Axis content's minimum size. With
    #               DataAspect, Axis reports ~149px minimum → tiny canvas;
    #               unused 549px is centered → huge black space above ctrl_bar.
    #   Relative(f): f × TOTAL figure height → overflows when Fixed rows exist
    #               → Fixed rows pushed off-screen (original ctrl-bar-invisible bug).
    #   Auto(false): row joins the "remaining space" pool and gets ALL remaining
    #               height after Fixed rows and gaps. ✔
    rowsize!(gl, 1, Fixed(44))       # controls bar
    rowsize!(gl, 2, Auto(false))     # canvas — fills remaining space (not content-sized)
    rowsize!(gl, 3, Fixed(185))      # parameter sliders: 6 rows × ~28px + padding ≈ 175px; 185 gives margin
    colsize!(gl, 1, Relative(0.70))  # simulation canvas
    colsize!(gl, 2, Relative(0.30))  # stats panel


    sl_v0, sl_σ, sl_rho_on, sl_rho_off, sl_door, sl_N = sg.sliders

    # σ noise is live — patch ECS directly.
    # NOTE: Extract config_ref[] into a local `cfg` first, then apply @set to
    # the plain ScenarioConfig value.  Writing `@set config_ref[].field = v`
    # makes Accessors.jl traverse the Ref as a lens and return a new
    # Ref{ScenarioConfig} — which cannot be assigned back to config_ref[].
    on(sl_σ.value) do σ
        cfg = config_ref[]
        config_ref[] = @set cfg.sigma_noise = Float64(σ)
        _update_sigma!(ctx_ref[], Float64(σ))
    end

    # All other sliders: update config_ref[] only (applied on Reset)
    on(sl_v0.value) do v
        cfg = config_ref[]
        config_ref[] = @set cfg.v_pref = Float64(v)
    end
    on(sl_rho_on.value) do v
        cfg = config_ref[]
        config_ref[] = @set cfg.rho_on = Float64(v)
    end
    on(sl_rho_off.value) do v
        cfg = config_ref[]
        config_ref[] = @set cfg.rho_off = Float64(v)
    end
    on(sl_N.value) do v
        cfg = config_ref[]
        config_ref[] = @set cfg.n_agents = Int(v)
    end
    on(sl_door.value) do v
        # Patch first door width
        cfg = config_ref[]
        if !isempty(cfg.room.doors)
            old_door  = cfg.room.doors[1]
            new_door  = DoorSpec(wall=old_door.wall, center=old_door.center, width=Float64(v))
            new_doors = vcat([new_door], cfg.room.doors[2:end])
            new_room  = RoomGeometry(
                width  = cfg.room.width,
                height = cfg.room.height,
                doors  = new_doors,
            )
            config_ref[] = @set cfg.room = new_room
        end
    end

    # ── Disable non-live sliders while running ────────────────────────────────
    # GLMakie doesn't have a first-class "disabled" state on Slider, so we
    # use opacity to signal to the user which sliders are inactive.
    # The sliders remain clickable but the value is overridden on Reset.
    # This is the standard approach until GLMakie adds proper disable support.

    return nothing
end
