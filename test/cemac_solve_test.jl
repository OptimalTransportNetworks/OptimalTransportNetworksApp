# Opt-in solve test on the real CEMAC network with the study's calibration.
# This is a research-scale problem (196 nodes, 20 goods, cross-good congestion,
# gamma > beta): expect MINUTES per outer iteration — run it manually, not as a
# routine smoke test.
#
# Run: julia -t auto,1 --project=. test/cemac_solve_test.jl [max_iter]

using DataFrames, CSV, JSON3
using OptimalTransportNetworks

const APP_ROOT = dirname(@__DIR__)
include(joinpath(APP_ROOT, "src", "AppState.jl"))
include(joinpath(APP_ROOT, "src", "NetworkData.jl"))
include(joinpath(APP_ROOT, "src", "ModelSetup.jl"))
include(joinpath(APP_ROOT, "src", "Solver.jl"))
include(joinpath(APP_ROOT, "src", "Outputs.jl"))

max_iter = length(ARGS) >= 1 ? something(tryparse(Float64, ARGS[1]), 3.0) : 3.0

nodes_df, nerr, _ = parse_nodes(read(joinpath(APP_ROOT, "data", "CEMAC", "nodes.csv")))
edges_df, geoms, eerr, _ = parse_edges(read(joinpath(APP_ROOT, "data", "CEMAC", "edges.csv")))
@assert nodes_df !== nothing && edges_df !== nothing "CEMAC CSVs failed to parse: $(vcat(nerr, eerr))"

STATE.nodes = nodes_df
STATE.edges = edges_df
STATE.geometries = geoms
STATE.network_valid = true

bs = budget_stats(edges_df)
println("CEMAC: $(nrow(nodes_df)) nodes, $(nrow(edges_df)) edges, K_base = $(round(bs.K_base, digits = 1))")

# Study calibration (optimal_trans_african_networks_largest_pcities_loop_CR_duality.jl)
p = (alpha = 0.7, beta = 1.0, gamma = 1.2, rho = 2.0,
     K = round(bs.K_base + 2000, digits = 1), # ~ the study's Ki = 2e3 (millions USD)
     tol = 1e-4, min_iter = 2.0, max_iter = max_iter,
     sigma = 3.8, a = 1.0, nu = 2.0,
     labor_mobility = false, cross_good_congestion = true,
     annealing = false, duality = true,
     compute_baseline = true, solver_verbose = false,
     allow_downgrade = false,
     productivity_floor = true, # the study floors the whole Zjn matrix at 1e-3
     linear_solver = get(ENV, "OTN_HSL_LIB", "") == "" && find_hsl_lib() === nothing ? "mumps" : "ma57")

t0 = Base.time()
last_print = Ref(Base.time())
done_ok = Ref(false)
err_msg = Ref("")

println("Starting solve (baseline + up to $(Int(max_iter)) outer iterations)...")
flush(stdout)

# NB: stdout is captured by the app's console redirect during the solve, so all
# progress goes to stderr to reach the terminal/log.
start_solve!(p;
    on_progress = (it, dist) -> println(stderr, "[outer] iteration $it, distance $dist, t = $(round(Base.time() - t0, digits = 0)) s"),
    on_done = (results, baseline, param, mats, elapsed) -> begin
        done_ok[] = true
        println("DONE in $(round(elapsed, digits = 1)) s — welfare $(results[:welfare]) (baseline $(baseline === nothing ? "-" : baseline[:welfare]))")
        spent = sum(mats.delta_i .* results[:Ijk])
        println("budget check: sum(delta_i .* Ijk) = $(round(spent, digits = 1)) vs 2K = $(2 * p.K)")
    end,
    on_error = msg -> (err_msg[] = msg; println("ERROR: ", msg)))

while STATE.running
    sleep(5)
    if Base.time() - last_print[] > 60
        last_print[] = Base.time()
        println(stderr, "[status] still solving, t = $(round(Base.time() - t0, digits = 0)) s, " *
                        "console lines: $(length(STATE.console_lines)), " *
                        "last: $(isempty(STATE.console_lines) ? "-" : STATE.console_lines[end])")
    end
end
sleep(2)

println(done_ok[] ? "=== CEMAC SOLVE OK ===" : "=== CEMAC SOLVE FAILED: $(err_msg[]) ===")
exit(done_ok[] ? 0 : 1)
