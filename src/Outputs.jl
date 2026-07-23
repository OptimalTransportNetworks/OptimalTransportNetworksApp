# Derived metrics from a solve, the JSON payload served to the map, and the
# downloadable results CSVs.
#
# Edge values are extracted from the J×J result matrices with the research-code
# symmetrization: value = (M[from, to] + M[to, from]) / 2.
# The "percent upgraded" measure generalizes the R post-processing formula
#   perc_ug = pmin(pmax((Ijk - Ijk_orig) / (cap - Ijk_orig) * 100, 0), 100)
# using each edge's upper bound Iu as the cap (the R code hard-coded 90/100 km/h).

jnum(x::Real) = isfinite(x) ? round(Float64(x), sigdigits = 7) : nothing
jnum(::Any) = nothing

sym_avg(M::AbstractMatrix, f::Int, t::Int) = (M[f, t] + M[t, f]) / 2

getvec(res, k::Symbol) = res !== nothing && haskey(res, k) && res[k] isa AbstractArray ?
    vec(Float64.(res[k])) : nothing

function perc_upgrade(Inew::Float64, Iold::Float64, Iu_e::Float64, global_cap::Float64)
    cap = isfinite(Iu_e) ? Iu_e : global_cap
    denom = cap - Iold
    denom <= 1e-12 && return Inew - Iold > 1e-9 ? 100.0 : 0.0
    return clamp((Inew - Iold) / denom * 100, 0.0, 100.0)
end

"Percentage change robust to negative baselines (utility can be negative when rho > 1)."
function pct_gain(new::AbstractVector, old::AbstractVector)
    return [abs(o) > 1e-12 ? (n - o) / abs(o) * 100 : NaN for (n, o) in zip(new, old)]
end

# ---------------------------------------------------------------------------
# Result tables (shared by the CSV downloads and the map payload)

function edge_table()
    edges = STATE.edges
    results = STATE.results
    df = DataFrame(from = edges.from, to = edges.to,
                   delta_i = Float64.(edges.delta_i),
                   delta_tau = Float64.(edges.delta_tau),
                   Ijk_orig = Float64.(edges.Ijk))
    results === nothing && return df

    Ijk = results[:Ijk]
    df.Ijk = [sym_avg(Ijk, f, t) for (f, t) in zip(df.from, df.to)]
    df.increase = max.(df.Ijk .- df.Ijk_orig, 0.0)

    iu = hasproperty(edges, :Iu) ? [ismissing(v) ? Inf : Float64(v) for v in edges.Iu] :
                                   fill(Inf, nrow(edges))
    finite_iu = filter(isfinite, iu)
    global_cap = isempty(finite_iu) ? max(maximum(df.Ijk), maximum(df.Ijk_orig)) : maximum(finite_iu)
    df.perc_upgraded = [perc_upgrade(df.Ijk[i], df.Ijk_orig[i], iu[i], global_cap)
                        for i in 1:nrow(df)]

    if haskey(results, :Qjkn)
        Q = results[:Qjkn]
        N = size(Q, 3)
        total = zeros(nrow(df))
        for n in 1:N
            # Base.view: `view` is ambiguous in Main under `using GenieFramework` (see Solver.jl)
            qn = [sym_avg(Base.view(Q, :, :, n), f, t) for (f, t) in zip(df.from, df.to)]
            N > 1 && (df[!, "Qjk_$n"] = qn)
            total .+= qn
        end
        df.Qjk_total = total
    end
    return df
end

function node_table()
    nodes = STATE.nodes
    results = STATE.results
    baseline = STATE.baseline
    df = DataFrame(node = nodes.node, lon = nodes.lon, lat = nodes.lat,
                   population = Float64.(nodes.population),
                   productivity = Float64.(nodes.productivity))
    hasproperty(nodes, :housing) && (df.housing = Float64.(nodes.housing))
    hasproperty(nodes, :product) && (df.product = nodes.product)
    hasproperty(nodes, :name) && (df.name = string.(nodes.name))

    for (res, suffix) in ((baseline, "_orig"), (results, ""))
        res === nothing && continue
        for k in (:uj, :cj, :Cj, :PCj, :Lj)
            v = getvec(res, k)
            v !== nothing && length(v) == nrow(df) && (df[!, string(k) * suffix] = v)
        end
        if haskey(res, :Yjn)
            df[!, "Yj" * suffix] = vec(sum(res[:Yjn], dims = 2))
        end
    end

    if results !== nothing && baseline !== nothing
        for k in ("uj", "cj", "Cj", "PCj")
            if k in names(df) && k * "_orig" in names(df)
                df[!, k * "_gain_pct"] = pct_gain(df[!, k], df[!, k * "_orig"])
            end
        end
    end
    return df
end

# ---------------------------------------------------------------------------
# Map payload

edge_metric_defs(df::DataFrame) = begin
    defs = Any[]
    function push_metric!(key, label, palette; diverging = false, domain = nothing)
        key in names(df) || return
        v = collect(skipmissing(df[!, key]))
        v = filter(isfinite, Float64.(v))
        isempty(v) && return
        lo, hi = domain === nothing ? (minimum(v), maximum(v)) : (domain[1], domain[2])
        push!(defs, Dict("key" => key, "label" => label, "palette" => palette,
                         "min" => jnum(lo), "max" => jnum(hi), "diverging" => diverging))
    end
    push_metric!("Ijk", "Final infrastructure (Ijk)", "viridis")
    push_metric!("increase", "Infrastructure increase (Ijk − initial)", "ylorrd")
    push_metric!("perc_upgraded", "Percent upgraded (% of Iu − initial)", "ylorrd"; domain = (0.0, 100.0))
    push_metric!("Qjk_total", "Total flow (all goods)", "ylorrd")
    for c in names(df)
        if startswith(c, "Qjk_") && c != "Qjk_total"
            push_metric!(c, "Flow of good $(c[5:end])", "ylorrd")
        end
    end
    push_metric!("Ijk_orig", "Initial infrastructure (input Ijk)", "inferno")
    defs
end

node_metric_defs(df::DataFrame) = begin
    defs = Any[]
    function push_metric!(key, label, palette; diverging = false)
        key in names(df) || return
        v = filter(isfinite, Float64.(collect(skipmissing(df[!, key]))))
        isempty(v) && return
        lo, hi = minimum(v), maximum(v)
        diverging && (hi = max(abs(lo), abs(hi)); lo = -hi)
        push!(defs, Dict("key" => key, "label" => label, "palette" => palette,
                         "min" => jnum(lo), "max" => jnum(hi), "diverging" => diverging))
    end
    push_metric!("uj_gain_pct", "Welfare (utility) gain %", "rdbu"; diverging = true)
    push_metric!("cj_gain_pct", "Consumption (per capita) gain %", "rdbu"; diverging = true)
    push_metric!("PCj_gain_pct", "Price index change %", "rdbu"; diverging = true)
    push_metric!("uj", "Utility per worker (uj)", "viridis")
    push_metric!("cj", "Consumption per capita (cj)", "viridis")
    push_metric!("Cj", "Aggregate consumption (Cj)", "viridis")
    push_metric!("PCj", "Consumption price index (PCj)", "viridis")
    push_metric!("Lj", "Labor / population (Lj)", "viridis")
    push_metric!("Yj", "Production (Yj)", "viridis")
    push_metric!("population", "Population (input)", "viridis")
    push_metric!("productivity", "Productivity (input)", "viridis")
    defs
end

function feature_properties(row)
    props = Dict{String, Any}()
    for (k, v) in pairs(row)
        key = string(k)
        (key == "lon" || key == "lat") && continue
        props[key] = v isa Real ? jnum(v) : (v === missing ? nothing : string(v))
    end
    return props
end

"Build features for whatever is loaded — nodes only, edges only, or both."
function build_features()
    nodes, edges = STATE.nodes, STATE.edges

    edf = edges === nothing ? nothing : edge_table()
    edge_features = Any[]
    if edf !== nothing
        J = nodes === nothing ? 0 : nrow(nodes)
        for (i, row) in enumerate(eachrow(edf))
            geom = i <= length(STATE.geometries) ? STATE.geometries[i] : nothing
            local coords
            if geom !== nothing
                coords = Any[[jnum(p[1]), jnum(p[2])] for p in geom]
            elseif 1 <= row.from <= J && 1 <= row.to <= J
                coords = Any[[jnum(nodes.lon[row.from]), jnum(nodes.lat[row.from])],
                             [jnum(nodes.lon[row.to]), jnum(nodes.lat[row.to])]]
            else
                continue # no WKT geometry and no nodes to place the edge — skip
            end
            push!(edge_features, Dict(
                "type" => "Feature",
                "geometry" => Dict("type" => "LineString", "coordinates" => coords),
                "properties" => feature_properties(row)))
        end
    end

    ndf = nodes === nothing ? nothing : node_table()
    node_features = Any[]
    if ndf !== nothing
        for row in eachrow(ndf)
            push!(node_features, Dict(
                "type" => "Feature",
                "geometry" => Dict("type" => "Point",
                                   "coordinates" => [jnum(row.lon), jnum(row.lat)]),
                "properties" => feature_properties(row)))
        end
    end

    return edf, ndf, edge_features, node_features
end

function run_summary_dict()
    info = STATE.run_info
    d = Dict{String, Any}()
    STATE.results !== nothing && (d["welfare"] = jnum(get(STATE.results, :welfare, NaN)))
    STATE.baseline !== nothing && (d["welfare_baseline"] = jnum(get(STATE.baseline, :welfare, NaN)))
    if haskey(d, "welfare") && haskey(d, "welfare_baseline") &&
       d["welfare"] !== nothing && d["welfare_baseline"] !== nothing
        w, w0 = d["welfare"], d["welfare_baseline"]
        abs(w0) > 1e-12 && (d["welfare_gain_pct"] = jnum((w - w0) / abs(w0) * 100))
    end
    haskey(info, :elapsed) && (d["elapsed"] = jnum(info[:elapsed]))
    haskey(info, :K_user) && (d["K"] = jnum(info[:K_user]))
    return d
end

"Rebuild the JSON payload served at /api/mapdata and bump the version counter.
Partial uploads are visualized immediately: nodes-only and edges-only payloads
carry the respective layer; `has_network` still means both-loaded-and-valid."
function rebuild_mapdata!()
    lock(STATE_LOCK) do
        newv = STATE.version + 1
        if STATE.nodes === nothing && STATE.edges === nothing
            STATE.mapdata_json = JSON3.write(Dict(
                "version" => newv, "has_network" => false, "has_results" => false))
        else
            edf, ndf, edge_features, node_features = build_features()
            d = Dict{String, Any}(
                "version" => newv,
                "has_network" => STATE.network_valid,
                "has_results" => STATE.results !== nothing,
                "summary" => run_summary_dict())
            if STATE.nodes !== nothing
                d["n_goods"] = hasproperty(STATE.nodes, :product) ? maximum(STATE.nodes.product) : 1
                d["node_metrics"] = node_metric_defs(ndf)
                d["nodes"] = Dict("type" => "FeatureCollection", "features" => node_features)
            end
            if edf !== nothing && !isempty(edge_features)
                d["edge_metrics"] = edge_metric_defs(edf)
                d["edges"] = Dict("type" => "FeatureCollection", "features" => edge_features)
            end
            STATE.mapdata_json = JSON3.write(d)
        end
        STATE.version = newv
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Post-solve wiring

const DOWNLOADS_DIR = joinpath(dirname(@__DIR__), "public", "downloads")

function write_results_csvs!()
    mkpath(DOWNLOADS_DIR)
    CSV.write(joinpath(DOWNLOADS_DIR, "nodes_results.csv"), node_table())
    CSV.write(joinpath(DOWNLOADS_DIR, "edges_results.csv"), edge_table())
    return nothing
end

"Store a finished run in STATE, regenerate downloads + map payload; returns a summary string."
function finish_run!(results, baseline, param, mats, p::NamedTuple, elapsed::Float64)
    lock(STATE_LOCK) do
        STATE.results = results
        STATE.baseline = baseline
        STATE.run_info = Dict{Symbol, Any}(:elapsed => elapsed, :K_user => p.K)
    end
    write_results_csvs!()
    rebuild_mapdata!()

    w = get(results, :welfare, NaN)
    parts = ["Welfare: $(round(w, sigdigits = 6))"]
    if baseline !== nothing
        w0 = get(baseline, :welfare, NaN)
        if abs(w0) > 1e-12
            push!(parts, "gain vs. existing network: $(round((w - w0) / abs(w0) * 100, digits = 2))%")
        end
    end
    push!(parts, "solved in $(round(elapsed, digits = 1)) s")
    return join(parts, " — ")
end
