# Global mutable application state. This is a single-user local tool:
# one loaded network, one solve at a time.

const EdgeGeometry = Union{Nothing, Vector{Tuple{Float64, Float64}}}

Base.@kwdef mutable struct AppData
    nodes::Union{DataFrame, Nothing} = nothing
    edges::Union{DataFrame, Nothing} = nothing
    geometries::Vector{EdgeGeometry} = EdgeGeometry[]
    warnings::Vector{String} = String[]
    network_valid::Bool = false
    # last solve
    results::Union{Dict{Symbol, Any}, Nothing} = nothing
    baseline::Union{Dict{Symbol, Any}, Nothing} = nothing
    run_info::Dict{Symbol, Any} = Dict{Symbol, Any}()
    # map payload (prebuilt JSON string served to the frontend) + change counter
    mapdata_json::String = "{\"version\":0,\"has_network\":false,\"has_results\":false}"
    version::Int = 0
    running::Bool = false
    # console ring buffer with absolute line indexing so clients poll incrementally
    console_lines::Vector{String} = String[]
    console_offset::Int = 0 # absolute index of console_lines[1] minus 1
end

const STATE = AppData()
const STATE_LOCK = ReentrantLock()

const CONSOLE_MAX_LINES = 5000

function console_push!(lines::Vector{String})
    lock(STATE_LOCK) do
        append!(STATE.console_lines, lines)
        excess = length(STATE.console_lines) - CONSOLE_MAX_LINES
        if excess > 0
            deleteat!(STATE.console_lines, 1:excess)
            STATE.console_offset += excess
        end
    end
    return nothing
end

console_push!(line::String) = console_push!([line])

function console_clear!()
    lock(STATE_LOCK) do
        empty!(STATE.console_lines)
        STATE.console_offset = 0
    end
    return nothing
end

"Lines with absolute index > `after`, plus the current total count and run status."
function console_since(after::Int)
    lock(STATE_LOCK) do
        total = STATE.console_offset + length(STATE.console_lines)
        start_rel = max(after, STATE.console_offset) - STATE.console_offset + 1
        lines = start_rel <= length(STATE.console_lines) ?
            STATE.console_lines[start_rel:end] : String[]
        return (lines = lines, total = total, running = STATE.running)
    end
end
