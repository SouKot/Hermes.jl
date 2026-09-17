using BenchmarkTools
using Statistics
using GodotBridge

snapshot = GodotBridge.SnapshotPayload(
    "1.0.0", "benchmark", 1.0, UInt64(1), 1.0f0, "running",
    Dict{String, Any}[], Dict{String, Any}[], nothing,
    Dict{String, Any}[], String[], false
)
envelope = GodotBridge.MessageEnvelope(
    "1.0", "typed-benchmark", UInt64(1), "julia", "godot", "snapshot"
)
future = GodotBridge.CommandFuture()
command = :step

message_trial = @benchmark GodotBridge.Message($envelope, $snapshot) samples=100 evals=1
item_trial = @benchmark GodotBridge.CommandWorkItem($command, $future) samples=100 evals=1

summary(trial) = (
    median_ns=median(trial.times),
    p99_ns=quantile(trial.times, 0.99),
    allocations=allocs(trial),
    bytes=memory(trial)
)

println("message=", summary(message_trial))
println("command_work_item=", summary(item_trial))
println("message_type=", typeof(GodotBridge.Message(envelope, snapshot)))
println("queue_item_type=", typeof(GodotBridge.CommandWorkItem(command, future)))
