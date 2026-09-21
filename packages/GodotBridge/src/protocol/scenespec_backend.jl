# packages/GodotBridge/src/protocol/scenespec_backend.jl
#
# Hardware-Agnostic Execution Backend Interface for SceneSpec and Simulation Runtime.
# Uses KernelAbstractions.jl to provide portable execution across Multicore CPU and
# any GPU vendor (NVIDIA CUDA, AMD ROCm, Apple Metal, Intel oneAPI).

using KernelAbstractions

"""
    AbstractExecutionBackend

Root abstract type for execution backends across SceneSpec spatial processing
and simulation pipelines.
"""
abstract type AbstractExecutionBackend end

"""
    AutoBackend

Automatic hardware probe backend. Probes system capabilities and selects
the highest-performing active hardware (functional GPU if available, else Multicore CPU).
"""
struct AutoBackend <: AbstractExecutionBackend end

"""
    CPUBackend

Multicore CPU execution backend powered by `KernelAbstractions.CPU()`.
Partitions work across Julia worker threads.
"""
struct CPUBackend <: AbstractExecutionBackend
    nthreads::Int
    ka_backend::KernelAbstractions.CPU
    CPUBackend(nthreads::Int=Threads.nthreads()) = new(nthreads, KernelAbstractions.CPU())
end

"""
    GPUBackend{B<:KernelAbstractions.Backend}

Universal GPU execution backend wrapping any active `KernelAbstractions.Backend`.
Zero vendor lock-in: supports NVIDIA CUDA, AMD ROCm, Apple Metal, Intel oneAPI.
"""
struct GPUBackend{B<:KernelAbstractions.Backend} <: AbstractExecutionBackend
    ka_backend::B
    device_name::String
    vendor::Symbol  # :cuda, :rocm, :metal, :oneapi, :generic
end

"""
    detect_available_gpu_backend() -> Union{GPUBackend, Nothing}

Dynamically probe for active and functional GPU accelerators without forcing
hard package dependencies at import time.
"""
function detect_available_gpu_backend()
    # 1. Probe NVIDIA CUDA
    if isdefined(Main, :CUDA)
        CUDA = getfield(Main, :CUDA)
        if hasmethod(CUDA.functional, ()) && CUDA.functional()
            dev_name = hasmethod(CUDA.name, (CUDA.CuDevice,)) ? CUDA.name(CUDA.device()) : "NVIDIA GPU"
            return GPUBackend(CUDA.CUDABackend(), string(dev_name), :cuda)
        end
    end

    # 2. Probe AMD ROCm
    if isdefined(Main, :AMDGPU)
        AMDGPU = getfield(Main, :AMDGPU)
        if hasmethod(AMDGPU.functional, ()) && AMDGPU.functional()
            dev_name = hasmethod(AMDGPU.name, (AMDGPU.HIPDevice,)) ? AMDGPU.name(AMDGPU.device()) : "AMD ROCm GPU"
            return GPUBackend(AMDGPU.ROCBackend(), string(dev_name), :rocm)
        end
    end

    # 3. Probe Apple Silicon Metal
    if isdefined(Main, :Metal)
        Metal = getfield(Main, :Metal)
        if hasmethod(Metal.functional, ()) && Metal.functional()
            dev_name = hasmethod(Metal.name, (Metal.MTLDevice,)) ? Metal.name(Metal.current_device()) : "Apple Metal GPU"
            return GPUBackend(Metal.MetalBackend(), string(dev_name), :metal)
        end
    end

    # 4. Probe Intel oneAPI
    if isdefined(Main, :oneAPI)
        oneAPI = getfield(Main, :oneAPI)
        if hasmethod(oneAPI.functional, ()) && oneAPI.functional()
            dev_name = hasmethod(oneAPI.name, (oneAPI.ZeDevice,)) ? oneAPI.name(oneAPI.device()) : "Intel oneAPI GPU"
            return GPUBackend(oneAPI.oneAPIBackend(), string(dev_name), :oneapi)
        end
    end

    return nothing
end

"""
    resolve_execution_backend(pref="auto") -> AbstractExecutionBackend

Resolves the active execution backend according to user preference
(`"auto"`, `"cpu"`, `"gpu"`) and available hardware capabilities.
"""
function resolve_execution_backend(pref::Union{String, Symbol, AbstractExecutionBackend}="auto")::AbstractExecutionBackend
    if isa(pref, CPUBackend) || isa(pref, GPUBackend)
        return pref
    elseif isa(pref, AutoBackend)
        pref_str = "auto"
    else
        pref_str = lowercase(string(pref))
    end

    if pref_str == "gpu"
        gpu = detect_available_gpu_backend()
        if gpu !== nothing
            return gpu
        else
            @warn "GPU execution requested, but no functional GPU backend (CUDA, ROCm, Metal, oneAPI) was detected. Falling back to CPU multithreading."
            return CPUBackend()
        end
    elseif pref_str == "cpu"
        return CPUBackend()
    else # "auto"
        gpu = detect_available_gpu_backend()
        return gpu !== nothing ? gpu : CPUBackend()
    end
end

"""
    get_ka_backend(backend::AbstractExecutionBackend) -> KernelAbstractions.Backend

Extracts the concrete `KernelAbstractions.Backend` instance from an `AbstractExecutionBackend`.
"""
function get_ka_backend(backend::AbstractExecutionBackend)::KernelAbstractions.Backend
    if isa(backend, CPUBackend)
        return backend.ka_backend
    elseif isa(backend, GPUBackend)
        return backend.ka_backend
    elseif isa(backend, AutoBackend)
        resolved = resolve_execution_backend(backend)
        return get_ka_backend(resolved)
    else
        return KernelAbstractions.CPU()
    end
end

