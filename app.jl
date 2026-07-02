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

function apply_nodes!(data::Vector{UInt8}, filename::String)
    df, errors, warnings = parse_nodes(data)
    df === nothing && return errors
    lock(STATE_LOCK) do
        STATE.nodes = df
        STATE.nodes_filename = filename
    end
    return warnings
end

function apply_edges!(data::Vector{UInt8}, filename::String)
    df, geoms, errors, warnings = parse_edges(data)
    df === nothing && return errors
    lock(STATE_LOCK) do
        STATE.edges = df
        STATE.geometries = geoms
        STATE.edges_filename = filename
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
    m.nodes_loaded[] = STATE.nodes !== nothing
    m.edges_loaded[] = STATE.edges !== nothing
    m.nodes_file_text[] = STATE.nodes === nothing ? "" : "✓ " * STATE.nodes_filename
    m.nodes_file_sub[] = STATE.nodes === nothing ? "" : "$(nrow(STATE.nodes)) nodes"
    m.edges_file_text[] = STATE.edges === nothing ? "" : "✓ " * STATE.edges_filename
    m.edges_file_sub[] = STATE.edges === nothing ? "" : "$(nrow(STATE.edges)) edges"
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

"Clear one uploaded file (kind = :nodes or :edges) and refresh."
function clear_file!(m, kind::Symbol)
    lock(STATE_LOCK) do
        if kind == :nodes
            STATE.nodes = nothing
            STATE.nodes_filename = ""
        else
            STATE.edges = nothing
            STATE.edges_filename = ""
            STATE.geometries = EdgeGeometry[]
        end
    end
    refresh_network!(String[])
    sync_model!(m)
    return
end

"Prefill K with the existing-network cost + 20% new investment (K = K₀ with no downgrading changes nothing)."
function prefill_budget!(m)
    (m === nothing || !STATE.network_valid) && return
    bs = budget_stats(STATE.edges)
    K = bs.K_base * 1.2
    # keep the prefill feasible when upper bounds cap the buildable network
    isnan(bs.K_max) || (K = min(K, bs.K_base + 0.5 * (bs.K_max - bs.K_base)))
    m.K[] = round(K, sigdigits = 4)
    return
end

function handle_upload(kind::Symbol)
    fp = Genie.Requests.filespayload()
    isempty(fp) && return Genie.Renderer.respond("No file received", "text/plain", 400)
    file = first(values(fp))
    data = Vector{UInt8}(file.data)
    fname = isempty(file.name) ? string(kind, ".csv") : file.name
    msgs = kind == :nodes ? apply_nodes!(data, fname) : apply_edges!(data, fname)
    valid = refresh_network!(msgs)
    m = MODEL_REF[]
    sync_model!(m)
    if valid
        prefill_budget!(m)
        m === nothing || (m.status_text[] = "Network loaded — ready to run.")
    end
    return Genie.Renderer.respond(JSON3.write(Dict("ok" => true, "messages" => msgs)), "application/json")
end

"Load a bundled dataset from data/<dir>; returns (success, message)."
function load_dataset!(dir::String, label::String)
    nodes_path = joinpath(APP_ROOT, "data", dir, "nodes.csv")
    edges_path = joinpath(APP_ROOT, "data", dir, "edges.csv")
    (isfile(nodes_path) && isfile(edges_path)) || return false, "Dataset not found under data/$dir/."
    msgs = apply_nodes!(read(nodes_path), "nodes.csv ($label)")
    append!(msgs, apply_edges!(read(edges_path), "edges.csv ($label)"))
    valid = refresh_network!(msgs)
    return valid, valid ? "$label network loaded — ready to run." : "$label network failed validation."
end

"Parameter calibration of the CEMAC study (optimal_trans_african_networks_..._CR_duality.jl)."
function set_cemac_calibration!(m)
    m.alpha[] = 0.7
    m.beta[] = 1.0
    m.gamma[] = 1.2 # IRS case of the study; > beta, solved without annealing there
    m.rho[] = 2.0
    m.sigma[] = 3.8 # Armington
    m.a[] = 1.0
    m.nu[] = 2.0
    m.cross_good_congestion[] = true
    m.annealing[] = false
    m.duality[] = true
    m.tol[] = 1.0e-5
    m.min_iter[] = 15
    m.max_iter[] = 45
    m.productivity_floor[] = true # study floors the whole Zjn matrix at 1e-3
    return
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
            allow_downgrade = m.allow_downgrade[],
            productivity_floor = m.productivity_floor[],
            linear_solver = m.linear_solver[])
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
    @in productivity_floor = false
    @in linear_solver = "mumps"
    # actions
    @in run = false
    @in load_example = false
    @in load_cemac = false
    @in clear_nodes = false
    @in clear_edges = false
    # status
    @out running = false
    @out has_network = false
    @out has_results = false
    @out status_text = "Upload a network or load the example."
    @out net_summary = ""
    @out budget_text = ""
    @out warnings_text = ""
    @out results_text = ""
    # upload display state
    @out nodes_loaded = false
    @out edges_loaded = false
    @out nodes_file_text = ""
    @out nodes_file_sub = ""
    @out edges_file_text = ""
    @out edges_file_sub = ""

    @onchange isready begin
        MODEL_REF[] = __model__
        sync_model!(__model__)
        # network loaded before this client connected and K untouched -> anchor it
        if STATE.network_valid && K == 1.0
            prefill_budget!(__model__)
        end
    end

    @onbutton load_example begin
        MODEL_REF[] = __model__
        _, msg = load_dataset!("example", "example")
        sync_model!(__model__)
        prefill_budget!(__model__)
        status_text = msg
    end

    @onbutton load_cemac begin
        MODEL_REF[] = __model__
        ok, msg = load_dataset!("CEMAC", "CEMAC")
        sync_model!(__model__)
        prefill_budget!(__model__)
        if ok
            set_cemac_calibration!(__model__)
            msg = "CEMAC network loaded with the study's calibration — ready to run."
        end
        status_text = msg
    end

    @onbutton clear_nodes begin
        MODEL_REF[] = __model__
        clear_file!(__model__, :nodes)
        status_text = "Nodes cleared."
    end

    @onbutton clear_edges begin
        MODEL_REF[] = __model__
        clear_file!(__model__, :edges)
        status_text = "Edges cleared."
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
# UI (sidebar content; the map, console and modals live in the layout, outside Vue)

# Small ⓘ button; map.js opens the matching modal via a delegated click handler.
info_icon(key::String) = Html.span("", class = "info-icon", data__info = key,
                                   role = "button", title = "More info")

field_row(label::String, key::String) =
    Html.div(class = "field-row", [Html.span(label, class = "field-label"), info_icon(key)])

function ui()
    [
        h4("Transport Network Optimizer", class = "app-title")
        Html.div(class = "subtitle-row", [
            p("Optimal transport networks in spatial equilibrium — Fajgelbaum & Schaal (2020)",
              class = "app-subtitle")
            info_icon("guide")
        ])

        field_row("Upload Nodes CSV", "nodes-csv")
        Html.div(class = "upload-field", [
            Html.div(v__if = "!nodes_loaded", [
                Html.input(type = "file", id = "nodes-file", accept = ".csv", class = "file-input")
            ])
            Html.div(@iif(:nodes_loaded), class = "upload-loaded", [
                Html.div(class = "upload-meta", [
                    p(@text(:nodes_file_text), class = "upload-name")
                    p(@text(:nodes_file_sub), class = "upload-sub")
                ])
                btn("Clear", @click(:clear_nodes), size = "sm", flat = true, nocaps = true,
                    class = "clear-btn")
            ])
        ])
        field_row("Upload Edges CSV", "edges-csv")
        Html.div(class = "upload-field", [
            Html.div(v__if = "!edges_loaded", [
                Html.input(type = "file", id = "edges-file", accept = ".csv", class = "file-input")
            ])
            Html.div(@iif(:edges_loaded), class = "upload-loaded", [
                Html.div(class = "upload-meta", [
                    p(@text(:edges_file_text), class = "upload-name")
                    p(@text(:edges_file_sub), class = "upload-sub")
                ])
                btn("Clear", @click(:clear_edges), size = "sm", flat = true, nocaps = true,
                    class = "clear-btn")
            ])
        ])
        Html.div(class = "btn-row", [
            btn("Load example", @click(:load_example), size = "sm", flat = true, nocaps = true,
                class = "ghost-btn", title = "Small synthetic 30-node network")
            btn("Load CEMAC network", @click(:load_cemac), size = "sm", flat = true, nocaps = true,
                class = "ghost-btn", title = "Real CEMAC road network (196 cities, 20 goods) with the study's calibration")
        ])
        p(@text(:net_summary), class = "net-summary", @iif(:net_summary))
        p(@text(:warnings_text), class = "warnings-text", @iif(:warnings_text))

        Html.hr(class = "sep")

        field_row("Model Parameters", "params")
        Html.div(class = "param-grid", [
            numberfield("alpha", :alpha, dense = true, outlined = true, dark = true, step = "0.05")
            numberfield("beta", :beta, dense = true, outlined = true, dark = true, step = "0.1")
            numberfield("gamma", :gamma, dense = true, outlined = true, dark = true, step = "0.1")
            numberfield("rho", :rho, dense = true, outlined = true, dark = true, step = "0.5")
        ])

        field_row("Infrastructure Budget (K)", "budget")
        numberfield("", :K, dense = true, outlined = true, dark = true)
        p(@text(:budget_text), class = "budget-text", @iif(:budget_text))

        field_row("Solver Controls", "solver")
        Html.div(class = "param-grid", [
            numberfield("tol", :tol, dense = true, outlined = true, dark = true)
            numberfield("min_iter", :min_iter, dense = true, outlined = true, dark = true, step = "1")
            numberfield("max_iter", :max_iter, dense = true, outlined = true, dark = true, step = "1")
        ])

        expansionitem(label = "Advanced options", dense = true, dense__toggle = true, dark = true,
                      class = "advanced", header__class = "advanced-header", [
            Html.div(class = "adv-inner", [
                Html.div(class = "param-grid", [
                    numberfield("sigma", :sigma, dense = true, outlined = true, dark = true, step = "0.5")
                    numberfield("a", :a, dense = true, outlined = true, dark = true, step = "0.05")
                    numberfield("nu", :nu, dense = true, outlined = true, dark = true, step = "0.5")
                ])
                toggle("Labor mobility", :labor_mobility, dense = true, dark = true, size = "sm")
                toggle("Cross-good congestion", :cross_good_congestion, dense = true, dark = true, size = "sm")
                toggle("Simulated annealing (only if gamma > beta)", :annealing, dense = true, dark = true, size = "sm")
                toggle("Duality solver (fixed labor, beta ≤ 1)", :duality, dense = true, dark = true, size = "sm")
                toggle("Baseline comparison run", :compute_baseline, dense = true, dark = true, size = "sm")
                toggle("Full Ipopt output in console", :solver_verbose, dense = true, dark = true, size = "sm")
                toggle("Allow downgrading (lower bound 0)", :allow_downgrade, dense = true, dark = true, size = "sm")
                toggle("Productivity floor (Zjn ≥ 1e-3, all goods)", :productivity_floor, dense = true, dark = true, size = "sm")
                StippleUI.Selects.select(:linear_solver, options = ["mumps", "ma57", "ma86"],
                                         label = "Ipopt linear solver",
                                         dense = true, outlined = true, dark = true, options__dense = true,
                                         title = "ma57/ma86 require a licensed HSL library (auto-detected; falls back to MUMPS)")
                Html.div(class = "adv-info", [Html.span("Details on the advanced options", class = "adv-info-text"), info_icon("advanced")])
            ])
        ])

        btn("Run Optimization", @click(:run), color = "primary", class = "run-btn", nocaps = true,
            icon = "play_arrow", loading = :running, disable! = "running || !has_network")
        p(@text(:status_text), class = "status-line")

        Html.div(@iif(:has_results), class = "results-box", [
            Html.div(class = "field-row", [Html.span("Results", class = "field-label"), info_icon("outputs")])
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
    <link rel="stylesheet" href="/css/app.css?v=5">
    <style>[v-cloak] { display: none; }</style>
    <% join(Stipple.Layout.theme(), "\\n    ") %>
  </head>
  <body>
    <div id="otn-shell">
      <div id="otn-sidebar">
        <div id="sidebar-topbtns">
          <button id="sidebar-collapse" title="Collapse sidebar">&#8249;</button>
        </div>
        <div id="sidebar-scroll">
          <% Stipple.page(model, partial = true, v__cloak = true, [Stipple.Genie.Renderer.Html.@yield], Stipple.@if(:isready)) %>
        </div>
      </div>
      <div id="otn-main">
        <div id="map"></div>
        <button id="sidebar-reopen" class="hidden" title="Show sidebar">&#8250;</button>
        <div id="map-topright">
          <div class="map-card" id="basemap-card">
            <select id="basemap-select" title="Basemap"></select>
          </div>
          <div class="map-card hidden" id="layers-card">
            <div class="layer-row">
              <input type="checkbox" id="edges-visible" checked>
              <label for="edges-visible">Edges</label>
              <select id="edge-metric" title="Edge output to visualize"></select>
            </div>
            <div class="layer-row">
              <input type="checkbox" id="nodes-visible" checked>
              <label for="nodes-visible">Nodes</label>
              <select id="node-metric" title="Node output to visualize"></select>
            </div>
            <div id="map-summary"></div>
          </div>
          <div class="map-card" id="zoom-card">
            <button id="zoom-in" title="Zoom in">+</button>
            <button id="zoom-out" title="Zoom out">&minus;</button>
          </div>
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
    <div id="info-modal" class="hidden">
      <div id="info-overlay"></div>
      <div id="info-card">
        <button id="info-close" title="Close">✕</button>
        <h2 id="info-title"></h2>
        <div id="info-body"></div>
      </div>
    </div>
    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" crossorigin=""></script>
    <script src="https://unpkg.com/leaflet-providers@2.0.0/leaflet-providers.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chroma-js@2.4.2/chroma.min.js"></script>
    <script src="/js/map.js?v=3"></script>
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
