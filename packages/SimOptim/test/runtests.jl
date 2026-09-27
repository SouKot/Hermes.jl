using Test
using SimOptim

@testset "SimOptim Test Suite" begin
    include("test_phase7e2_sciml_p1_p2.jl")
    include("test_phase7e3_graph_search.jl")
    include("test_phase7e4_server_integration.jl")
end
