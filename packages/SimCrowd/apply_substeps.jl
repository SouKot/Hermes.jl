using Pkg
Pkg.add("Regex")

content = read("test/run_validations.jl", String)

# This is tricky because the inner blocks are slightly different.
# I will instead just replace `integrate_physics_system!(world, dt)` globally with:
# `integrate_physics_system!(world, dt)` is used, but we need the sub-step loop.
