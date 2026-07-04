# Parsing and validation of uploaded network CSVs, including a minimal
# WKT LINESTRING parser for the optional edge `geometry` column.

const NODE_REQUIRED = ["node", "lon", "lat", "population", "productivity"]
const EDGE_REQUIRED = ["from", "to", "delta_i", "delta_tau", "Ijk"]

"Parse 'LINESTRING (lon lat, lon lat, ...)' into a vector of (lon, lat) tuples, or nothing."
function parse_linestring(s::AbstractString)
    m = match(r"(?i)^\s*LINESTRING\s*\(([^)]*)\)\s*$", s)
    m === nothing && return nothing
    pts = Tuple{Float64, Float64}[]
    for pair in split(m.captures[1], ',')
        xy = split(strip(pair))
        length(xy) < 2 && return nothing
        lon = tryparse(Float64, xy[1])
        lat = tryparse(Float64, xy[2])
        (lon === nothing || lat === nothing) && return nothing
        push!(pts, (lon, lat))
    end
    return length(pts) >= 2 ? pts : nothing
end

parse_linestring(::Missing) = nothing

function read_csv_bytes(data::Vector{UInt8})
    try
        return CSV.read(data, DataFrame; stringtype = String), nothing
    catch e
        return nothing, sprint(showerror, e)
    end
end

function coerce_float!(errors::Vector{String}, df::DataFrame, col::String; allow_missing::Bool = false)
    v = df[!, col]
    if any(ismissing, v)
        allow_missing || push!(errors, "Column '$col' contains missing values.")
        return
    end
    try
        df[!, col] = Float64.(v)
    catch
        push!(errors, "Column '$col' is not numeric.")
    end
    return
end

function coerce_int!(errors::Vector{String}, df::DataFrame, col::String)
    v = df[!, col]
    if any(ismissing, v)
        push!(errors, "Column '$col' contains missing values.")
        return
    end
    try
        df[!, col] = Int.(v)
    catch
        push!(errors, "Column '$col' is not an integer column.")
    end
    return
end

"Parse and validate the nodes CSV. Returns (df_or_nothing, errors, warnings)."
function parse_nodes(data::Vector{UInt8})
    errors = String[]
    warnings = String[]
    df, err = read_csv_bytes(data)
    err !== nothing && return nothing, ["Nodes CSV could not be parsed: $err"], warnings

    cols = String.(names(df))
    missing_cols = setdiff(NODE_REQUIRED, cols)
    if !isempty(missing_cols)
        return nothing, ["Nodes CSV is missing required column(s): $(join(missing_cols, ", ")). " *
                         "Required: node, lon, lat, population, productivity (+ recommended: housing)."], warnings
    end

    coerce_int!(errors, df, "node")
    for c in ("lon", "lat", "population", "productivity")
        coerce_float!(errors, df, c)
    end
    if "housing" in cols
        if any(ismissing, df.housing)
            push!(warnings, "Column 'housing' has missing values — falling back to population × (1 − alpha).")
            select!(df, Not("housing"))
        else
            coerce_float!(errors, df, "housing")
        end
    else
        push!(warnings, "No 'housing' column — using population × (1 − alpha) as Hj.")
    end
    if "product" in cols
        coerce_int!(errors, df, "product")
    end
    isempty(errors) || return nothing, errors, warnings

    sort!(df, :node)
    J = nrow(df)
    if df.node != 1:J
        return nothing, ["Node ids must be consecutive integers 1..J (found $(J) rows, ids $(minimum(df.node))..$(maximum(df.node)))."], warnings
    end
    all(-180 .<= df.lon .<= 180) || push!(errors, "Column 'lon' has values outside [-180, 180].")
    all(-90 .<= df.lat .<= 90) || push!(errors, "Column 'lat' has values outside [-90, 90].")
    all(df.population .> 0) || push!(errors, "Column 'population' must be strictly positive.")
    all(df.productivity .>= 0) || push!(errors, "Column 'productivity' must be non-negative.")
    if hasproperty(df, :product)
        P = maximum(df.product)
        all(1 .<= df.product .<= P) || push!(errors, "Column 'product' must contain integers in 1..N.")
    end

    return isempty(errors) ? df : nothing, errors, warnings
end

"Parse and validate the edges CSV. Returns (df_or_nothing, geometries, errors, warnings)."
function parse_edges(data::Vector{UInt8})
    errors = String[]
    warnings = String[]
    geoms = EdgeGeometry[]
    df, err = read_csv_bytes(data)
    err !== nothing && return nothing, geoms, ["Edges CSV could not be parsed: $err"], warnings

    cols = String.(names(df))
    missing_cols = setdiff(EDGE_REQUIRED, cols)
    if !isempty(missing_cols)
        return nothing, geoms, ["Edges CSV is missing required column(s): $(join(missing_cols, ", ")). " *
                                "Required: from, to, delta_i, delta_tau, Ijk (+ optional: Il, Iu, geometry)."], warnings
    end

    coerce_int!(errors, df, "from")
    coerce_int!(errors, df, "to")
    for c in ("delta_i", "delta_tau", "Ijk")
        coerce_float!(errors, df, c)
    end
    for c in ("Il", "Iu")
        c in cols && coerce_float!(errors, df, c; allow_missing = true)
    end
    isempty(errors) || return nothing, geoms, errors, warnings

    if "geometry" in cols
        nfail = 0
        for g in df.geometry
            pts = g isa AbstractString ? parse_linestring(g) : nothing
            pts === nothing && !ismissing(g) && g isa AbstractString && (nfail += 1)
            push!(geoms, pts)
        end
        nfail > 0 && push!(warnings, "$nfail geometry value(s) could not be parsed as LINESTRING — using straight lines for those edges.")
    else
        geoms = EdgeGeometry[nothing for _ in 1:nrow(df)]
    end

    all(df.delta_i .>= 0) || push!(errors, "Column 'delta_i' must be non-negative.")
    all(df.delta_tau .>= 0) || push!(errors, "Column 'delta_tau' must be non-negative.")
    all(df.Ijk .>= 0) || push!(errors, "Column 'Ijk' must be non-negative.")

    return isempty(errors) ? df : nothing, geoms, errors, warnings
end

"Cross-validation once both files are loaded. Returns (errors, warnings)."
function validate_network(nodes::DataFrame, edges::DataFrame)
    errors = String[]
    warnings = String[]
    J = nrow(nodes)
    seen = Set{Tuple{Int, Int}}()
    for (i, r) in enumerate(eachrow(edges))
        f, t = r.from, r.to
        if !(1 <= f <= J) || !(1 <= t <= J)
            push!(errors, "Edge row $i references a node id outside 1..$J ($f → $t).")
            continue
        end
        f == t && push!(errors, "Edge row $i is a self-loop at node $f.")
        key = minmax(f, t)
        key in seen ? push!(errors, "Duplicate edge $f — $t at row $i (the graph is undirected; list each edge once).") :
                      push!(seen, key)
        if hasproperty(edges, :Il) && !ismissing(r.Il) && r.Il > r.Ijk
            push!(warnings, "Edge $f — $t: Il > Ijk; the lower bound will be clamped to Ijk.")
        end
        if hasproperty(edges, :Iu) && !ismissing(r.Iu) && r.Iu < r.Ijk
            push!(warnings, "Edge $f — $t: Iu < Ijk; the upper bound will be raised to Ijk.")
        end
    end

    if isempty(errors)
        adj = [Int[] for _ in 1:J]
        for r in eachrow(edges)
            push!(adj[r.from], r.to)
            push!(adj[r.to], r.from)
        end
        visited = falses(J)
        visited[1] = true
        stack = [1]
        while !isempty(stack)
            u = pop!(stack)
            for v in adj[u]
                if !visited[v]
                    visited[v] = true
                    push!(stack, v)
                end
            end
        end
        n_unreachable = count(!, visited)
        n_unreachable > 0 && push!(warnings,
            "$n_unreachable node(s) are disconnected from node 1 — the solver may fail or leave them in autarky.")
    end

    return errors, warnings
end

function network_summary(nodes::DataFrame, edges::DataFrame)
    n_goods = hasproperty(nodes, :product) ? maximum(nodes.product) : 1
    return "$(nrow(nodes)) nodes, $(nrow(edges)) edges, $n_goods good$(n_goods > 1 ? "s" : "")"
end
