using Test
using GodotBridge
using SimCore
using SimDES

@testset "Simulation Run Summary & Audit Reporting Tests" begin
    # 1. Compile standard tandem model
    mgr = RuntimeManager()
    scenespec = create_default_scene()
    ok, diags = stage_and_activate!(mgr, scenespec)
    @test ok
    @test !has_errors(diags)
    
    instance = mgr.active_instance
    
    # 2. Run simulation for 20 simulated seconds
    step_until!(instance, 20.0; fast_forward=true)
    
    # 3. Generate summary report
    summary = generate_run_summary(instance)
    
    @test summary.sim_time >= 19.9
    @test summary.total_arrivals > 0
    @test summary.total_departures > 0
    @test summary.effective_throughput > 0.0
    @test summary.sojourn_mean > 0.0
    @test summary.flow_balance_ok == true
    @test summary.flow_balance_error == 0
    @test !isempty(summary.stations)
    
    # 4. Test ASCII report formatting
    report_text = format_ascii_report(summary)
    @test occursin("ANTIGRAVITY SIMVIZ - SIMULATION RUN AUDIT REPORT", report_text)
    @test occursin("GLOBAL EMPIRICAL OPERATIONAL METRICS", report_text)
    @test occursin("MATHEMATICAL VALIDATION & INVARIANT AUDIT", report_text)
    @test occursin("PER-STATION PERFORMANCE BREAKDOWN", report_text)
    @test occursin("Conservation of Flow", report_text)
    @test occursin("Little's Law Invariant", report_text)
    println("\nSample Generated ASCII Report:\n", report_text)
    
    # 5. Test CSV export
    csv_text = export_summary_csv(summary)
    @test occursin("station_id,element_type,utilization_pct", csv_text)
    lines = split(strip(csv_text), "\n")
    @test length(lines) >= 2 # header + at least 1 station
end
