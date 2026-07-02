# Headless end-to-end test of the app's solve pipeline (no web server).
# Exercises: CSV parsing/validation -> model build -> background solve with
# stdout capture -> derived outputs -> map JSON -> results CSVs.
#
# Run: julia -t auto,1 --project=. test/headless_test.jl

using DataFrames, CSV, JSON3
using OptimalTransportNetworks

const APP_ROOT = dirname(@__DIR__)
include(joinpath(APP_ROOT, "src", "AppState.jl"))
include(joinpath(APP_ROOT, "src", "NetworkData.jl"))
include(joinpath(APP_ROOT, "src", "ModelSetup.jl"))
include(joinpath(APP_ROOT, "src", "Solver.jl"))
include(joinpath(APP_ROOT, "src", "Outputs.jl"))

macro check(cond, msg)
    quote
        if $(esc(cond))
            println("PASS: ", $(esc(msg)))
        else
            println("FAIL: ", $(esc(msg)))
            global FAILED = true
        end
    end
end
FAILED = false

# --- 1. Parse example CSVs ---------------------------------------------------
nodes_df, nerr, nwarn = parse_nodes(read(joinpath(APP_ROOT, "data", "example", "nodes.csv")))
edges_df, geoms, eerr, ewarn = parse_edges(read(joinpath(APP_ROOT, "data", "example", "edges.csv")))
@check nodes_df !== nothing "nodes.csv parses ($(isempty(nerr) ? "no errors" : join(nerr, "; ")))"
@check edges_df !== nothing "edges.csv parses ($(isempty(eerr) ? "no errors" : join(eerr, "; ")))"
@check count(g -> g !== nothing, geoms) == nrow(edges_df) "all LINESTRING geometries parsed"

verr, vwarn = validate_network(nodes_df, edges_df)
@check isempty(verr) "cross-validation passes: $(join(verr, "; "))"
println("  validation warnings: ", isempty(vwarn) ? "(none)" : join(vwarn, "; "))

# Broken inputs must be rejected
bad = parse_nodes(Vector{UInt8}("node,lon\n1,2\n"))
@check bad[1] === nothing "nodes CSV with missing columns is rejected"
bad_edges = copy(edges_df); bad_edges.to[1] = 999
verr2, _ = validate_network(nodes_df, bad_edges)
@check !isempty(verr2) "out-of-range edge reference is caught"

# --- 2. Load into STATE ------------------------------------------------------
STATE.nodes = nodes_df
STATE.edges = edges_df
STATE.geometries = geoms
STATE.network_valid = true

bs = budget_stats(edges_df)
println("  K_base = $(round(bs.K_base, digits = 1)), K_max = $(round(bs.K_max, digits = 1))")
@check bs.K_base > 0 "budget stats computed"

# --- 3. Background solve with console capture --------------------------------
p = (alpha = 0.5, beta = 1.0, gamma = 1.0, rho = 2.0,
     K = round(bs.K_base * 1.2, digits = 1),
     tol = 1e-4, min_iter = 3.0, max_iter = 12.0,
     sigma = 5.0, a = 0.8, nu = 2.0,
     labor_mobility = false, cross_good_congestion = false,
     annealing = false, duality = true,
     compute_baseline = true, solver_verbose = false,
     allow_downgrade = false)

progress_hits = Int[]
done_payload = Ref{Any}(nothing)
error_msg = Ref{String}("")

started = start_solve!(p;
    on_progress = (it, dist) -> push!(progress_hits, it),
    on_done = (results, baseline, param, mats, elapsed) -> begin
        done_payload[] = (results, baseline, param, mats, elapsed)
    end,
    on_error = msg -> (error_msg[] = msg))

@check started "solve launched"

t0 = time()
while STATE.running && time() - t0 < 600
    sleep(0.5)
end
sleep(1.0) # allow on_done to finish

@check !STATE.running "solve completed within timeout"
@check isempty(error_msg[]) "no solver error ($(first(error_msg[], 200)))"
@check done_payload[] !== nothing "on_done fired"
@check !isempty(progress_hits) "progress callback fired ($(length(progress_hits)) iterations seen)"
@check any(l -> occursin("Iteration No.", l), STATE.console_lines) "console captured iteration lines"

if done_payload[] !== nothing
    results, baseline, param, mats, elapsed = done_payload[]
    summary = finish_run!(results, baseline, param, mats, p, elapsed)
    println("  ", summary)

    @check haskey(results, :Ijk) "results contain Ijk"
    @check baseline !== nothing && haskey(baseline, :welfare) "baseline solved"

    # Budget convention: sum(delta_i .* Ijk) over the full symmetric matrix = 2K
    spent = sum(mats.delta_i .* results[:Ijk])
    @check isapprox(spent, 2 * p.K, rtol = 1e-3) "budget exhausted: sum(delta_i .* Ijk) = $(round(spent, digits=1)) ≈ 2K = $(2 * p.K)"
    # Bounds respected
    @check all(results[:Ijk] .>= mats.Il .- 1e-6) "lower bounds respected"
    @check all(results[:Ijk] .<= mats.Iu .+ 1e-6) "upper bounds respected"

    # --- 4. Outputs -----------------------------------------------------------
    edf = edge_table()
    ndf = node_table()
    for c in ("Ijk", "increase", "perc_upgraded", "Qjk_total")
        @check c in names(edf) "edge table has $c"
    end
    @check all(0 .<= edf.perc_upgraded .<= 100) "perc_upgraded in [0, 100]"
    for c in ("uj", "cj", "PCj", "uj_orig", "uj_gain_pct")
        @check c in names(ndf) "node table has $c"
    end

    d = JSON3.read(STATE.mapdata_json)
    @check d.has_results == true "mapdata has_results"
    @check length(d.edges.features) == nrow(edges_df) "mapdata edge feature count"
    @check length(d.nodes.features) == nrow(nodes_df) "mapdata node feature count"
    @check length(d.edge_metrics) >= 4 "edge metrics present ($(length(d.edge_metrics)))"
    @check length(d.node_metrics) >= 5 "node metrics present ($(length(d.node_metrics)))"
    @check d.edges.features[1].geometry.coordinates isa AbstractVector "edge geometry serialized"

    @check isfile(joinpath(DOWNLOADS_DIR, "nodes_results.csv")) "nodes_results.csv written"
    @check isfile(joinpath(DOWNLOADS_DIR, "edges_results.csv")) "edges_results.csv written"
end

println(FAILED ? "\n=== TEST FAILURES ===" : "\n=== ALL TESTS PASSED ===")
exit(FAILED ? 1 : 0)
