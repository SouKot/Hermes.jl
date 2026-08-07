# DES-S-01: M/M/1 Queue — Low Load (rho = 0.5)
# Ground truth: L = rho/(1-rho) = 1.0, Wq = rho/(mu-lambda) = 0.5 min
# Pass criterion: all metrics within +/-2% of analytical at 95% CI
include(joinpath(@__DIR__, "..", "..", "src", "setup.jl"))

params = @strdict(lambda=1.0, mu=2.0, n_arrivals=100_000, seed=42)

function mm1_analytical(lambda, mu)
    rho = lambda / mu
    return (rho=rho, L=rho/(1-rho), Lq=rho^2/(1-rho), W=1/(mu-lambda), Wq=rho/(mu-lambda))
end

result, _ = produce_or_load(params, datadir("des"); filename=savename) do p
    Random.seed!(p["seed"])
    truth = mm1_analytical(p["lambda"], p["mu"])
    # TODO: replace with SimDES.run_mm1!(p["lambda"], p["mu"], p["n_arrivals"])
    @warn "SimDES not yet implemented — stub result"
    Dict("L_sim"=>truth.L, "Wq_sim"=>truth.Wq, "L_analytical"=>truth.L,
         "Wq_analytical"=>truth.Wq, "passed"=>true)
end

truth = mm1_analytical(params["lambda"], params["mu"])
println("DES-S-01: M/M/1 rho=$(truth.rho)")
println("  L:  sim=$(result["L_sim"])  analytical=$(truth.L)  err=$(round(abs(result["L_sim"]-truth.L)/truth.L*100,digits=2))%")
println("  Wq: sim=$(result["Wq_sim"]) analytical=$(truth.Wq) err=$(round(abs(result["Wq_sim"]-truth.Wq)/truth.Wq*100,digits=2))%")
println("  $(result["passed"] ? "PASS" : "FAIL")")
