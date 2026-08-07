# Common setup for all Hermes validation experiments
using DrWatson
@quickactivate "HermesExperiments"
using Random, Statistics, StatsBase, DataFrames, CSV
println("Hermes experiment environment ready. Results -> ", datadir())
