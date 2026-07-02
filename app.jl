# Optimal Transport Networks — Genie/Stipple web app.
#
# Run with:  julia -t auto,1 --project=. app.jl
# then open  http://localhost:8000
#
# The interactive thread pool (`-t auto,1`) keeps the web server responsive
# while Ipopt blocks a default-pool thread during solves.

if Threads.nthreads(:interactive) == 0 && Threads.nthreads() < 2
    error("Start Julia with an interactive thread so the server stays responsive during solves:\n" *
          "    julia -t auto,1 --project=. app.jl")
end

using GenieFramework
using DataFrames, CSV, JSON3
using OptimalTransportNetworks
import Genie
import Genie.Renderer.Html

const APP_ROOT = @__DIR__

include(joinpath(APP_ROOT, "src", "AppState.jl"))
include(joinpath(APP_ROOT, "src", "NetworkData.jl"))
include(joinpath(APP_ROOT, "src", "ModelSetup.jl"))
include(joinpath(APP_ROOT, "src", "Solver.jl"))
include(joinpath(APP_ROOT, "src", "Outputs.jl"))

# ---------------------------------------------------------------------------
# Network loading (shared by the upload routes and the example loader)

const MODEL_REF = Ref{Any}(nothing) # latest connected reactive model (single-user tool)

function apply_nodes!(data::Vector{UInt8})
    df, errors, warnings = parse_nodes(data)
    df === nothing && return errors
    lock(STATE_LOCK) do
        STATE.nodes = df
    end
    return warnings
end

function apply_edges!(data::Vector{UInt8})
    df, geoms, errors, warnings = parse_edges(data)
    df === nothing && return errors
    lock(STATE_LOCK) do
        STATE.edges = df
        STATE.geometries = geoms
    end
    return warnings
end

"Revalidate after any network change, clear stale results, rebuild the map payload."
function refresh_network!(msgs::Vector{String})
    valid = false
    if STATE.nodes !== nothing && STATE.edges !== nothing
        errors, warnings = validate_network(STATE.nodes, STATE.edges)
        append!(msgs, errors)
        append!(msgs, warnings)
        valid = isempty(errors)
    elseif STATE.nodes === nothing && STATE.edges !== nothing
        push!(msgs, "Edges loaded — waiting for the nodes CSV.")
    elseif STATE.nodes !== nothing && STATE.edges === nothing
        push!(msgs, "Nodes loaded — waiting for the edges CSV.")
    end
    lock(STATE_LOCK) do
        STATE.network_valid = valid
        STATE.warnings = msgs
        STATE.results = nothing
        STATE.baseline = nothing
        STATE.run_info = Dict{Symbol, Any}()
    end
    rebuild_mapdata!()
    return valid
end

"Push server-side state into the connected browser model."
function sync_model!(m)
    m === nothing && return
    m.has_network[] = STATE.network_valid
    m.has_results[] = STATE.results !== nothing
    m.running[] = STATE.running
    m.warnings_text[] = join(STATE.warnings, " • ")
    if STATE.network_valid
        m.net_summary[] = "Loaded: " * network_summary(STATE.nodes, STATE.edges)
        bs = budget_stats(STATE.edges)
        txt = "Cost of existing network K₀ = $(round(bs.K_base, sigdigits = 5))"
        isnan(bs.K_max) || (txt *= " · full upgrade = $(round(bs.K_max, sigdigits = 5))")
        m.budget_text[] = txt
    else
        m.net_summary[] = ""
    end
    return
end

"Prefill K with the existing-network cost + 20% new investment (K = K₀ with no downgrading changes nothing)."
function prefill_budget!(m)
    (m === nothing || !STATE.network_valid) && return
    bs = budget_stats(STATE.edges)
    m.K[] = round(bs.K_base * 1.2, sigdigits = 4)
    return
end

function handle_upload(kind::Symbol)
    fp = Genie.Requests.filespayload()
    isempty(fp) && return Genie.Renderer.respond("No file received", "text/plain", 400)
    data = Vector{UInt8}(first(values(fp)).data)
    msgs = kind == :nodes ? apply_nodes!(data) : apply_edges!(data)
    valid = refresh_network!(msgs)
    m = MODEL_REF[]
    sync_model!(m)
    if valid
        prefill_budget!(m)
        m === nothing || (m.status_text[] = "Network loaded — ready to run.")
    end
    return Genie.Renderer.respond(JSON3.write(Dict("ok" => true, "messages" => msgs)), "application/json")
end

function load_example!()
    nodes_path = joinpath(APP_ROOT, "data", "example", "nodes.csv")
    edges_path = joinpath(APP_ROOT, "data", "example", "edges.csv")
    (isfile(nodes_path) && isfile(edges_path)) || return "Example data not found under data/example/."
    msgs = apply_nodes!(read(nodes_path))
    append!(msgs, apply_edges!(read(edges_path)))
    valid = refresh_network!(msgs)
    return valid ? "Example network loaded — ready to run." : "Example network failed validation."
end

# ---------------------------------------------------------------------------
# Reactive app

# Built outside the handler macros: Stipple rewrites reactive field names inside
# handler bodies, which breaks NamedTuple keys like `alpha = ...`.
function params_from_model(m)
    return (alpha = Float64(m.alpha[]), beta = Float64(m.beta[]), gamma = Float64(m.gamma[]),
            rho = Float64(m.rho[]), K = Float64(m.K[]),
            tol = Float64(m.tol[]), min_iter = Float64(m.min_iter[]), max_iter = Float64(m.max_iter[]),
            sigma = Float64(m.sigma[]), a = Float64(m.a[]), nu = Float64(m.nu[]),
            labor_mobility = m.labor_mobility[],
            cross_good_congestion = m.cross_good_congestion[],
            annealing = m.annealing[], duality = m.duality[],
            compute_baseline = m.compute_baseline[],
            solver_verbose = m.solver_verbose[],
            allow_downgrade = m.allow_downgrade[])
end

@app begin
    # model parameters
    @in alpha = 0.5
    @in beta = 1.0
    @in gamma = 1.0
    @in rho = 2.0
    @in K = 1.0
    # solver controls
    @in tol = 1.0e-5
    @in min_iter = 20
    @in max_iter = 200
    # advanced
    @in sigma = 5.0
    @in a = 0.8
    @in nu = 2.0
    @in labor_mobility = false
    @in cross_good_congestion = false
    @in annealing = true
    @in duality = true
    @in compute_baseline = true
    @in solver_verbose = false
    @in allow_downgrade = false
    # actions
    @in run = false
    @in load_example = false
    # status
    @out running = false
    @out has_network = false
    @out has_results = false
    @out status_text = "Upload a network or load the example."
    @out net_summary = ""
    @out budget_text = ""
    @out warnings_text = ""
    @out results_text = ""

    @onchange isready begin
        MODEL_REF[] = __model__
        sync_model!(__model__)
    end

    @onbutton load_example begin
        MODEL_REF[] = __model__
        msg = load_example!()
        sync_model!(__model__)
        prefill_budget!(__model__)
        status_text = msg
    end

    @onbutton run begin
        MODEL_REF[] = __model__
        if gamma > beta && !annealing
            status_text = "Note: gamma > beta makes the problem non-convex — consider enabling annealing."
        end
        m = __model__
        p = params_from_model(m)
        started = start_solve!(p;
            on_progress = (it, dist) -> begin
                m.status_text[] = "Iteration $it / $(Int(round(p.max_iter))) — distance $(round(dist, sigdigits = 3)) (tol $(p.tol))"
            end,
            on_done = (results, baseline, param, mats, elapsed) -> begin
                summary = finish_run!(results, baseline, param, mats, p, elapsed)
                m.running[] = false
                m.has_results[] = true
                m.results_text[] = summary
                m.status_text[] = "Done — select outputs on the map."
            end,
            on_error = msg -> begin
                m.running[] = false
                m.status_text[] = "Error: " * first(msg, 400)
            end)
        if started
            running = true
            has_results = false
            status_text = "Solving — see console for solver output..."
        else
            status_text = "Could not start: " * (STATE.running ? "a solve is already running." : "no valid network loaded.")
        end
    end
end

# ---------------------------------------------------------------------------
# UI (sidebar content; the map and console live in the layout, outside Vue)

function ui()
    [
        h4("Transport Network Optimizer", class = "app-title")
        p("Optimal transport networks in spatial equilibrium — Fajgelbaum & Schaal (2020)", class = "app-subtitle")

        h6("1 · Network", class = "section-title")
        uploader(label = "Nodes CSV — node, lon, lat, population, productivity, housing",
                 url = "/api/upload/nodes", method = "POST", auto__upload = true, accept = ".csv",
                 max__files = 1, dense = true, flat = true, bordered = true, class = "upload-box")
        uploader(label = "Edges CSV — from, to, delta_i, delta_tau, Ijk, Il, Iu, geometry",
                 url = "/api/upload/edges", method = "POST", auto__upload = true, accept = ".csv",
                 max__files = 1, dense = true, flat = true, bordered = true, class = "upload-box")
        btn("Load example network", @click(:load_example), size = "sm", color = "secondary",
            outline = true, nocaps = true, class = "example-btn")
        p(@text(:net_summary), class = "net-summary", @iif(:net_summary))
        p(@text(:warnings_text), class = "warnings-text", @iif(:warnings_text))

        h6("2 · Model parameters", class = "section-title")
        Html.div(class = "param-grid", [
            numberfield("alpha", :alpha, dense = true, outlined = true, step = "0.05",
                        title = "Cobb-Douglas share of traded goods in utility")
            numberfield("beta", :beta, dense = true, outlined = true, step = "0.1",
                        title = "Congestion elasticity in transport costs")
            numberfield("gamma", :gamma, dense = true, outlined = true, step = "0.1",
                        title = "Elasticity of transport cost w.r.t. infrastructure")
            numberfield("rho", :rho, dense = true, outlined = true, step = "0.5",
                        title = "Curvature of utility (inequality aversion; 0 = utilitarian)")
        ])
        numberfield("K — infrastructure budget (delta_i cost units)", :K, dense = true, outlined = true,
                    title = "Total budget in the same units as delta_i × infrastructure. Prefilled with the cost of the existing network.")
        p(@text(:budget_text), class = "budget-text", @iif(:budget_text))

        h6("3 · Solver", class = "section-title")
        Html.div(class = "param-grid", [
            numberfield("tol", :tol, dense = true, outlined = true,
                        title = "Convergence tolerance for the network fixed point")
            numberfield("min_iter", :min_iter, dense = true, outlined = true, step = "1",
                        title = "Minimum outer iterations")
            numberfield("max_iter", :max_iter, dense = true, outlined = true, step = "1",
                        title = "Maximum outer iterations")
        ])

        expansionitem(label = "Advanced options", dense = true, dense__toggle = true,
                      header__class = "advanced-header", [
            Html.div(class = "param-grid", [
                numberfield("sigma", :sigma, dense = true, outlined = true, step = "0.5",
                            title = "Elasticity of substitution across goods")
                numberfield("a", :a, dense = true, outlined = true, step = "0.05",
                            title = "Labor curvature in production Z L^a (must be ≤ 1)")
                numberfield("nu", :nu, dense = true, outlined = true, step = "0.5",
                            title = "Congestion substitution elasticity (cross-good congestion only)")
            ])
            toggle("Labor mobility", :labor_mobility, dense = true)
            toggle("Cross-good congestion", :cross_good_congestion, dense = true)
            toggle("Simulated annealing (only if gamma > beta)", :annealing, dense = true)
            toggle("Duality solver (fixed labor, beta ≤ 1)", :duality, dense = true)
            toggle("Baseline comparison run", :compute_baseline, dense = true)
            toggle("Full Ipopt output in console", :solver_verbose, dense = true)
            toggle("Allow downgrading (default lower bound = current Ijk)", :allow_downgrade, dense = true)
        ])

        btn("Run Optimization", @click(:run), color = "primary", class = "run-btn", nocaps = true,
            icon = "play_arrow", loading = :running, disable! = "running || !has_network")
        p(@text(:status_text), class = "status-line")

        Html.div(@iif(:has_results), class = "results-box", [
            p(@text(:results_text), class = "results-text")
            a("Download node results (CSV)", href = "/downloads/nodes_results.csv", target = "_blank", class = "dl-link")
            a("Download edge results (CSV)", href = "/downloads/edges_results.csv", target = "_blank", class = "dl-link")
        ])
    ]
end

# ---------------------------------------------------------------------------
# Layout: sidebar (Vue/Stipple) + map & console (plain DOM, untouched by Vue)

const APP_LAYOUT = """
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <% Stipple.sesstoken() %>
    <title>Optimal Transport Networks</title>
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" crossorigin="">
    <link rel="stylesheet" href="/css/app.css">
    <style>[v-cloak] { display: none; }</style>
    <% join(Stipple.Layout.theme(), "\\n    ") %>
  </head>
  <body>
    <div id="otn-shell">
      <div id="otn-sidebar">
        <% Stipple.page(model, partial = true, v__cloak = true, [Stipple.Genie.Renderer.Html.@yield], Stipple.@if(:isready)) %>
      </div>
      <div id="otn-main">
        <div id="map"></div>
        <div id="output-card" class="hidden">
          <div class="output-row"><label>Edges</label><select id="edge-metric"></select></div>
          <div class="output-row"><label>Nodes</label><select id="node-metric"></select></div>
          <div id="map-summary"></div>
        </div>
        <div id="legend" class="hidden"></div>
        <div id="console-panel" class="hidden">
          <div id="console-header">
            <span class="console-title">Solver output</span>
            <span id="console-status"></span>
            <span style="flex:1"></span>
            <button id="console-copy" title="Copy to clipboard">copy</button>
            <button id="console-close" title="Close">✕</button>
          </div>
          <pre id="console-body"></pre>
        </div>
        <button id="console-reopen" class="hidden" title="Show solver console">Console</button>
      </div>
    </div>
    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" crossorigin=""></script>
    <script src="https://unpkg.com/leaflet-providers@2.0.0/leaflet-providers.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chroma-js@2.4.2/chroma.min.js"></script>
    <script src="/js/map.js"></script>
  </body>
</html>
"""

@page("/", ui, layout = APP_LAYOUT)

# ---------------------------------------------------------------------------
# REST API (bulk data + console; polled by the frontend)

Genie.Router.route("/api/mapdata") do
    Genie.Renderer.respond(STATE.mapdata_json, "application/json")
end

Genie.Router.route("/api/version") do
    Genie.Renderer.respond(JSON3.write(Dict("version" => STATE.version, "running" => STATE.running)),
                           "application/json")
end

Genie.Router.route("/api/console") do
    after = something(tryparse(Int, string(Genie.Requests.getpayload(:after, "0"))), 0)
    r = console_since(after)
    Genie.Renderer.respond(JSON3.write(Dict("lines" => r.lines, "total" => r.total, "running" => r.running)),
                           "application/json")
end

Genie.Router.route("/api/upload/nodes", method = Genie.Router.POST) do
    try
        handle_upload(:nodes)
    catch e
        Genie.Renderer.respond("Upload failed: " * sprint(showerror, e), "text/plain", 500)
    end
end

Genie.Router.route("/api/upload/edges", method = Genie.Router.POST) do
    try
        handle_upload(:edges)
    catch e
        Genie.Renderer.respond("Upload failed: " * sprint(showerror, e), "text/plain", 500)
    end
end

# ---------------------------------------------------------------------------
# Server

Genie.config.server_document_root = joinpath(APP_ROOT, "public")
Genie.config.log_requests = false # request logs would pollute the captured solver console

if get(ENV, "OTN_NO_SERVER", "0") != "1" # gate for tests that drive the app in-process
    port = something(tryparse(Int, get(ENV, "OTN_PORT", "8000")), 8000)
    @info "Optimal Transport Networks app → http://localhost:$port  (threads: $(Threads.nthreads()) default, $(Threads.nthreads(:interactive)) interactive)"
    Genie.up(port, "127.0.0.1"; async = false)
end
