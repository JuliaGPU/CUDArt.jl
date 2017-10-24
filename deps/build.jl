using Compat

using CUDAapi, CUDAdrv


## discovery routines

# find NVML library and SMI executable
function find_nvml(driver_path)
    if is_windows()
        nvml_dir = joinpath(ENV["ProgramFiles"], "NVIDIA Corporation", "NVSMI")
        if !isdir(nvml_libdir)
            error("Could not determine NVIDIA driver installation location.")
        end
    else
        nvml_dir = driver_path
    end

    # find NVML library
    libnvml_path = nothing
    try
        libnvml_path = find_library(CUDAapi.libnvml, nvml_dir)
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
        warn("NVML not found, resorting to nvidia-smi")
    end

    # find SMI binary
    nvidiasmi_path = nothing
    try
        nvidiasmi_path = find_binary("nvidia-smi", nvml_dir)
        if !success(`$nvidiasmi_path`)
            warn("nvidia-smi failure")
            nvidiasmi_path = nothing
        end
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
        warn("nvidia-smi not found")
    end

    if nvidiasmi_path == nothing && libnvml_path == nothing
        if is_apple()
            warn("NVML nor nvidia-smi can be found.")
        else
            error("NVML nor nvidia-smi can be found.")
        end
    end

    return libnvml_path, nvidiasmi_path
end


## Makefile replacement

const utilsfile = "utils"
const libfile = "libwrapcuda"

function build(toolchain, arch)
    compiler = toolchain.cuda_compiler
    flags = ["--compiler-bindir", toolchain.host_compiler, "--gpu-architecture", arch]

    cd(@__DIR__) do
        rm("$(libfile).$(Libdl.dlext)", force=true)
        is_windows() && rm("$(libfile).exp", force=true)
        rm("$(utilsfile).ptx", force=true)

        logging_run(`$compiler $flags --shared wrapcuda.c -o $(libfile).$(Libdl.dlext)`)
        logging_run(`$compiler $flags -ptx $(utilsfile).cu`)
    end

    cd(joinpath(@__DIR__, "..", "test")) do
        rm("vadd.ptx", force=true)
        logging_run(`$compiler $flags -ptx vadd.cu`)
    end

    nothing
end


## main

const config_path = joinpath(@__DIR__, "ext.jl")
const previous_config_path = config_path * ".bak"

function main()
    ispath(config_path) && mv(config_path, previous_config_path; remove_destination=true)
    config = Dict{Symbol,Any}()


    ## gather info

    # discover the CUDA toolkit
    config[:toolkit_path] = find_toolkit()
    config[:toolkit_version] = find_toolkit_version(config[:toolkit_path])

    # discover the runtime library
    config[:libcudart_path] = find_library("cudart", config[:toolkit_path])

    # select the highest compatible device capability
    device_cap = minimum(capability(dev) for dev in devices())
    toolchain_caps = CUDAapi.devices_for_cuda(config[:toolkit_version])
    isempty(toolchain_caps) && error("No support for CUDA $(config[:toolkit_version])")
    filter!(cap -> cap<=device_cap, toolchain_caps)
    isempty(toolchain_caps) && error("None of your devices supported by CUDA $(config[:toolkit_version])")
    cap = maximum(toolchain_caps)

    # discover driver and related utilities
    driver_path = find_driver()
    config[:libnvml_path], config[:nvidiasmi_path] = find_nvml(driver_path)

    # discover a toolchain and build code
    toolchain = find_toolchain(config[:toolkit_path], config[:toolkit_version])
    config[:cuda_compiler] = toolchain.cuda_compiler
    config[:host_compiler] = toolchain.host_compiler
    config[:architecture] = CUDAapi.shader(cap)
    build(toolchain, config[:architecture])


    ## (re)generate ext.jl

    function globals(mod)
        all_names = names(mod, true)
        filter(name-> !any(name .== [module_name(mod), Symbol("#eval"), :eval]), all_names)
    end

    if isfile(previous_config_path)
        @debug("Checking validity of existing ext.jl...")
        @eval module Previous; include($previous_config_path); end
        previous_config = Dict{Symbol,Any}(name => getfield(Previous, name)
                                           for name in globals(Previous))

        if config == previous_config
            info("CUDArt.jl has already been built for this toolchain, no need to rebuild")
            mv(previous_config_path, config_path)
            return
        end
    end

    open(config_path, "w") do fh
        write(fh, "# autogenerated file with properties of the toolchain\n")
        for (key,val) in config
            write(fh, "const $key = $(repr(val))\n")
        end
    end

    # refresh the compile cache
    # NOTE: we need to do this manually, as the package will load & precompile after
    #       not having loaded a nonexistent ext.jl in the case of a failed build,
    #       causing it not to precompile after a subsequent successful build.
    Base.compilecache("CUDArt")
end

main()
