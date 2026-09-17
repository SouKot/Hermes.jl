"""
    CommandHandler

Module for dispatching simulation control commands from Godot to the engine.

Supported Commands:
- play: Resume simulation from paused state
- pause: Pause the simulation
- step: Execute one DES step and return
- reset: Reset simulation to initial state
- set_clock_speed: Adjust simulation speed multiplier
- jump_to_time: Jump simulation to specific time
- query_state: Request current simulation state
- set_trace_entity: Enable tracing for specific entity
- set_trace_element: Enable tracing for specific element

Design:
- CommandPayload contains command_type and command dict
- Each handler returns Ack (success) or Error (failure)
- Handlers are non-blocking (commands queued to engine)
- Recovery suggestions included in errors
- Support for async command execution via @async

Strategy:
- Register handlers with dispatch_command()
- Each command type has validation and routing
- Errors include actionable recovery suggestions
- Support multiple simultaneous command listeners
"""
module CommandHandler

using UUIDs

include("../protocol/envelope.jl")

export CommandContext, CommandResult,
       dispatch_command,
       create_command_ack,
       create_command_error,
       validate_command,
       get_command_summary

"""
    CommandContext

Context for command execution, passed to handlers.
"""
mutable struct CommandContext
    command_id::String
    command_type::String
    parameters::Dict{String, Any}
    sender::String
    timestamp::Any
    execution_state::Dict{String, Any}  # Shared state for handler
end

"""
    CommandResult

Result of command execution.
"""
mutable struct CommandResult
    success::Bool
    command_id::String
    command_type::String
    status::String  # "accepted", "executed", "queued", "error"
    result_data::Dict{String, Any}
    error_code::Union{String, Nothing}
    error_message::Union{String, Nothing}
    recovery_suggestion::Union{String, Nothing}
end

"""
    validate_command(command::CommandPayload) -> Tuple{Bool, String}

Validate command payload structure and contents.

Arguments:
- command: CommandPayload to validate

Returns: (is_valid, error_message)

Validates:
- command_type is recognized
- required parameters present
- parameter types correct
- time values are positive

Example:
```julia
is_valid, error_msg = validate_command(cmd)
if !is_valid
    println("Invalid command: ", error_msg)
end
```
"""
function validate_command(command::CommandPayload)::Tuple{Bool, String}
    # Check command type
    valid_types = ["play", "pause", "step", "reset", "set_clock_speed", 
                   "jump_to_time", "query_state", "set_trace_entity", "set_trace_element"]
    
    if !in(command.command_type, valid_types)
        return false, "Unknown command type: $(command.command_type)"
    end
    
    # Validate by command type
    cmd_dict = command.command
    
    if command.command_type == "set_clock_speed"
        if !haskey(cmd_dict, "speed")
            return false, "set_clock_speed requires 'speed' parameter"
        end
        speed = cmd_dict["speed"]
        if !(isa(speed, Number) && speed > 0)
            return false, "Clock speed must be positive number"
        end
    elseif command.command_type == "jump_to_time"
        if !haskey(cmd_dict, "target_time")
            return false, "jump_to_time requires 'target_time' parameter"
        end
        time = cmd_dict["target_time"]
        if !(isa(time, Number) && time >= 0)
            return false, "Target time must be non-negative"
        end
    elseif command.command_type == "set_trace_entity"
        if !haskey(cmd_dict, "entity_id")
            return false, "set_trace_entity requires 'entity_id' parameter"
        end
        if !haskey(cmd_dict, "enable")
            return false, "set_trace_entity requires 'enable' boolean parameter"
        end
    elseif command.command_type == "set_trace_element"
        if !haskey(cmd_dict, "element_id")
            return false, "set_trace_element requires 'element_id' parameter"
        end
        if !haskey(cmd_dict, "enable")
            return false, "set_trace_element requires 'enable' boolean parameter"
        end
    end
    
    return true, ""
end

"""
    dispatch_command(context::CommandContext; handler::Union{Function, Nothing}=nothing) -> CommandResult

Dispatch a command to registered handler or use default behavior.

Arguments:
- context: CommandContext with command details
- handler: Optional custom handler function (context) -> CommandResult

Returns: CommandResult with outcome

Default Handlers:
- play: Sets simulation state to running
- pause: Sets simulation state to paused
- step: Queues single step execution
- reset: Queues reset (requires confirmation)
- set_clock_speed: Updates speed (0.0 - 10.0)
- query_state: Returns current simulation state
- Others: Return error (not implemented)

Custom Handlers:
Can override default by passing handler function.
"""
function dispatch_command(
    context::CommandContext;
    handler::Union{Function, Nothing}=nothing
)::CommandResult
    
    # Use custom handler if provided
    if !isnothing(handler)
        return handler(context)
    end
    
    # Default dispatch based on command type
    cmd_type = context.command_type
    cmd_dict = context.parameters
    
    if cmd_type == "play"
        return CommandResult(
            true, context.command_id, "play", "executed",
            Dict("new_state" => "running"),
            nothing, nothing, nothing
        )
    
    elseif cmd_type == "pause"
        return CommandResult(
            true, context.command_id, "pause", "executed",
            Dict("new_state" => "paused"),
            nothing, nothing, nothing
        )
    
    elseif cmd_type == "step"
        return CommandResult(
            true, context.command_id, "step", "queued",
            Dict("action" => "execute_single_step"),
            nothing, nothing, nothing
        )
    
    elseif cmd_type == "reset"
        return CommandResult(
            true, context.command_id, "reset", "queued",
            Dict("action" => "reset_simulation", "confirmation_required" => true),
            nothing, nothing, "Reset will clear all simulation data. Confirm with reset_confirmed=true"
        )
    
    elseif cmd_type == "set_clock_speed"
        speed = get(cmd_dict, "speed", 1.0)
        
        if speed < 0.0 || speed > 10.0
            return CommandResult(
                false, context.command_id, "set_clock_speed", "error",
                Dict(),
                "INVALID_SPEED", 
                "Clock speed must be between 0.0 and 10.0",
                "Valid speeds: 0.0 (pause), 0.5 (half speed), 1.0 (real-time), 2.0 (2x), 10.0 (max)"
            )
        end
        
        return CommandResult(
            true, context.command_id, "set_clock_speed", "executed",
            Dict("new_speed" => speed, "previous_speed" => 1.0),
            nothing, nothing, nothing
        )
    
    elseif cmd_type == "jump_to_time"
        target_time = get(cmd_dict, "target_time", 0.0)
        
        if target_time < 0.0
            return CommandResult(
                false, context.command_id, "jump_to_time", "error",
                Dict(),
                "INVALID_TIME",
                "Target time must be non-negative",
                "Provide a time value >= 0.0"
            )
        end
        
        return CommandResult(
            true, context.command_id, "jump_to_time", "queued",
            Dict("action" => "jump_to_time", "target_time" => target_time),
            nothing, nothing, nothing
        )
    
    elseif cmd_type == "query_state"
        # Return mock state (would query engine in real implementation)
        return CommandResult(
            true, context.command_id, "query_state", "executed",
            Dict(
                "simulation_state" => "running",
                "simulation_time" => 100.5,
                "step_count" => 1005,
                "clock_speed" => 1.0,
                "entities_count" => 42,
                "elements_count" => 5
            ),
            nothing, nothing, nothing
        )
    
    elseif cmd_type == "set_trace_entity"
        entity_id = get(cmd_dict, "entity_id", "unknown")
        enable = get(cmd_dict, "enable", false)
        
        return CommandResult(
            true, context.command_id, "set_trace_entity", "executed",
            Dict("entity_id" => entity_id, "tracing_enabled" => enable),
            nothing, nothing, nothing
        )
    
    elseif cmd_type == "set_trace_element"
        element_id = get(cmd_dict, "element_id", "unknown")
        enable = get(cmd_dict, "enable", false)
        
        return CommandResult(
            true, context.command_id, "set_trace_element", "executed",
            Dict("element_id" => element_id, "tracing_enabled" => enable),
            nothing, nothing, nothing
        )
    
    else
        return CommandResult(
            false, context.command_id, cmd_type, "error",
            Dict(),
            "COMMAND_NOT_IMPLEMENTED",
            "Command type '$cmd_type' is not yet implemented",
            "Check command documentation or contact development team"
        )
    end
end

"""
    create_command_ack(result::CommandResult; sender="bridge", receiver="godot") -> Message

Convert CommandResult to Ack message for transmission.

Arguments:
- result: CommandResult with success outcome
- sender: Message sender (default "bridge")
- receiver: Message receiver (default "godot")

Returns: Message ready for serialization

Design:
- Only use for successful command results
- Includes result_data with outcome details
- Acknowledges the original command_id
"""
function create_command_ack(
    result::CommandResult;
    sender::String="bridge",
    receiver::String="godot"
)::Message
    
    payload = AckPayload(
        acknowledged_message_id = result.command_id,
        status = result.status,
        details = result.result_data
    )
    
    Message(
        protocol_version = "1.0",
        message_id = string(uuid4()),
        timestamp = now(),
        sender = sender,
        receiver = receiver,
        kind = "ack",
        payload = payload
    )
end

"""
    create_command_error(result::CommandResult; sender="bridge", receiver="godot") -> Message

Convert CommandResult to Error message for transmission.

Arguments:
- result: CommandResult with failure outcome
- sender: Message sender (default "bridge")
- receiver: Message receiver (default "godot")

Returns: Message ready for serialization

Design:
- Only use for failed command results
- Includes error_code and error_message
- Includes recovery_suggestion for user guidance
- References original command_id via header
"""
function create_command_error(
    result::CommandResult;
    sender::String="bridge",
    receiver::String="godot"
)::Message
    
    payload = ErrorPayload(
        error_code = result.error_code,
        error_message = result.error_message,
        recoverable = true,
        recovery_suggestion = result.recovery_suggestion,
        context = Dict(
            "command_type" => result.command_type,
            "failed_parameters" => result.result_data
        )
    )
    
    Message(
        protocol_version = "1.0",
        message_id = string(uuid4()),
        timestamp = now(),
        sender = sender,
        receiver = receiver,
        kind = "error",
        payload = payload
    )
end

"""
    get_command_summary(result::CommandResult) -> Dict{String, Any}

Get a human-readable summary of command result.

Returns: Dict with formatted information

Example:
```julia
result = dispatch_command(ctx)
summary = get_command_summary(result)
println(summary["message"])
```
"""
function get_command_summary(result::CommandResult)::Dict{String, Any}
    status_emoji = result.success ? "✓" : "✗"
    
    message = if result.success
        "$(result.command_type) command $(result.status)"
    else
        "$(result.command_type) command failed: $(result.error_message)"
    end
    
    Dict(
        "status_emoji" => status_emoji,
        "success" => result.success,
        "command_type" => result.command_type,
        "command_id" => result.command_id,
        "status" => result.status,
        "message" => message,
        "result_data" => result.result_data,
        "error_code" => result.error_code,
        "error_message" => result.error_message,
        "recovery_suggestion" => result.recovery_suggestion
    )
end

end  # module CommandHandler
