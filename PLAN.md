# OptimalTransportNetworksApp — Implementation Plan

> **Status: implemented** (see README.md for usage). Deviations from this plan,
> made during implementation:
> - The solver console streams via a polled REST endpoint (`/api/console?after=N`,
>   incremental line cursor) instead of a Stipple reactive field — pushing a
>   growing string through the WebSocket would resend the whole console on every
>   update.
> - The map's output selectors are plain HTML `<select>`s in the map panel
>   (outside the Vue-managed DOM), driven by `map.js`; the map and console live
>   entirely outside Stipple, so Vue re-renders can never destroy Leaflet's DOM.
> - Results CSVs are written to `public/downloads/` and served statically
>   instead of via dedicated download routes.
> - `/api/network.geojson` + `/api/results.geojson` were merged into a single
>   `/api/mapdata` payload (nodes FC + edges FC + metric metadata + summary).
> - Recommended invocation is `julia -t auto,1` (interactive thread pool for the
>   server; the solve runs on a default-pool thread via `Threads.@spawn :default`).
> - The K-doubling convention was verified in `rescale_network!` (full symmetric
>   matrix sum) — the sidebar K is undirected units, doubled internally. K is
>   prefilled with 1.2 × K₀ since K = K₀ with no-downgrading bounds is a no-op.
> - Baseline runs set `param.K = sum(delta_i .* I0)` exactly, because
>   `optimal_network` rescales `I0` to exhaust the budget at entry.

A Genie.jl web application to run optimal transport network simulations with
[OptimalTransportNetworks.jl](https://github.com/SebKrantz/OptimalTransportNetworks.jl)
(Fajgelbaum & Schaal 2020) on user-uploaded networks, visualized on an interactive
Leaflet map.

This plan is grounded in:
- The package API (`init_parameters`, `create_graph(type="custom")`, `optimal_network`)
  in `../OptimalTransportNetworks.jl/src/`.
- The data/workflow conventions of the three research codebases:
  `OptimalCEMACRoads/code/4_GE_simulation`,
  `OptimalAfricanRoads/code/10_GE_simulation_regional`,
  `OptimalAfricanRoads/code/11_GE_simulation_trans_african`
  and their R post-processing scripts (`analyze_*_results.R`).

---

## 1. Goal & Scope

A local single-user research tool (runs on `localhost`, one solve at a time) with:

- **Left sidebar**: network upload (nodes + edges CSV), model parameters
  (`alpha`, `beta`, `gamma`, `rho`), budget `K`, solver controls (`tol`,
  `min_iter`, `max_iter`), advanced options, and a **Run Optimization** button.
- **Right main panel**: Leaflet map (CartoDB.Positron default) with zoom control,
  distance scale, basemap switcher (CartoDB Positron/DarkMatter, OSM, OpenTopoMap,
  Esri WorldStreetMap/WorldTopoMap/WorldImagery, Google Maps/Terrain), an output
  selector (edge and node quantities), and a collapsible **console** at the bottom
  streaming the live `optimal_network()` verbose output.
- Visualizable outputs: at minimum final infrastructure `Ijk`, infrastructure
  increase `Ijk - Ijk_orig`, percent upgrading (R-code formula), plus flows,
  and node quantities (consumption, utility/welfare, prices, population).

Out of scope for v1: multi-user sessions, authentication, solve cancellation
(see §13 Future extensions).

---

## 2. Architecture Decision

**GenieFramework.jl (Genie + Stipple + StippleUI) reactive app + a hand-written
Leaflet JS module.**

Rationale:
- Stipple gives two-way binding for all sidebar fields and push-updates over its
  WebSocket for free — no manual channel code for the console stream or the
  run-button state machine.
- There is no mature Stipple Leaflet component, so the map is a plain JS module
  (`public/js/map.js`) using Leaflet + the `leaflet-providers` plugin. It talks to
  the backend two ways:
  1. **Small state** (selected output, version counters, running flag) via the
     Stipple/Vue model (watched client-side).
  2. **Bulk data** (network/results GeoJSON) via plain REST endpoints
     (`GET /api/...`), fetched when a version counter in the reactive model
     increments. Large payloads never go through the reactive WebSocket.

The long-running solve runs on a separate Julia thread (`Threads.@spawn`); the app
must be started with ≥2 threads (`julia -t auto`).

---

## 3. Directory Layout

```
OptimalTransportNetworksApp/
├── PLAN.md                     # this file
├── Project.toml                # app environment (OptimalTransportNetworks via Pkg.develop)
├── Manifest.toml
├── app.jl                      # entry point: Stipple @app, routes, layout
├── src/
│   ├── NetworkData.jl          # CSV parsing, validation, WKT LINESTRING parser
│   ├── ModelSetup.jl           # DataFrames -> param, graph, I0, Il, Iu
│   ├── Solver.jl               # background solve, stdout capture, progress parsing
│   ├── Outputs.jl              # results -> derived metrics + GeoJSON generation
│   └── AppState.jl             # global mutable app state + solve lock
├── public/
│   ├── css/app.css             # layout, console panel, map controls styling
│   └── js/map.js               # Leaflet module (basemaps, layers, legend, popups)
├── uploads/                    # uploaded CSVs (gitignored)
├── data/
│   └── example/                # bundled small example network
│       ├── nodes.csv
│       └── edges.csv
└── README.md                   # run instructions, CSV format documentation
```

Frontend libraries via CDN (pinned versions in the layout template): Leaflet 1.9.x,
leaflet-providers, chroma.js (color scales/legends). No JS build step.

---

## 4. Data Contract (CSV schemas)

### 4.1 `nodes.csv`

| column         | required | type    | maps to                                    |
|----------------|----------|---------|--------------------------------------------|
| `node`         | yes      | Int     | node id `1:J` (must be consecutive after sorting; validated) |
| `lon`          | yes      | Float   | `x` in `create_graph`                       |
| `lat`          | yes      | Float   | `y` in `create_graph`                       |
| `population`   | yes      | Float   | `Lj`                                        |
| `productivity` | yes      | Float   | `Zjn` (see product handling below)          |
| `housing`      | yes      | Float   | `Hj` (if blank/missing column: fallback `population .* (1-alpha)`, the convention used in the research code) |
| `product`      | optional | Int     | good index `1:N`; enables multi-good economies |
| `name`         | optional | String  | popup label                                 |

**Product handling:** without a `product` column, `N = 1` and
`Zjn = reshape(productivity, J, 1)`. With it, `N = maximum(product)` and
`Zjn[j, product[j]] = productivity[j]` (zeros elsewhere) — exactly the
Armington construction from the research scripts, which keeps the fast
direct-Ipopt/dual solver path (each node produces ≤ 1 good).

### 4.2 `edges.csv`

| column      | required | type   | maps to                                                   |
|-------------|----------|--------|-----------------------------------------------------------|
| `from`,`to` | yes      | Int    | adjacency + symmetric matrix fill (must reference `node` ids; `from != to`; duplicate undirected pairs rejected) |
| `delta_i`   | yes      | Float  | `graph[:delta_i][from,to] = graph[:delta_i][to,from]` — building cost per unit of `I` |
| `delta_tau` | yes      | Float  | `graph[:delta_tau]` symmetric — iceberg transport friction |
| `Ijk`       | yes      | Float  | existing infrastructure → `I0` matrix and baseline for increase/percent-upgrade metrics |
| `Il`        | optional | Float  | lower bound matrix (default: `Ijk`, i.e. no downgrading — the research-code convention; a sidebar toggle "allow downgrading" sets default to 0 instead) |
| `Iu`        | optional | Float  | upper bound matrix (default: `Inf`); also used as the cap in the percent-upgrade formula |
| `geometry`  | optional | String | WKT `LINESTRING (lon lat, lon lat, ...)` for map display; fallback: straight line between node coordinates |

WKT parsing: a small hand-rolled parser in `NetworkData.jl` (LINESTRING only,
~20 lines; regex-split on commas inside the parentheses). Avoids heavy geo
dependencies (ArchGDAL/LibGEOS).

**Validation** (run on upload, errors shown in the sidebar):
node ids consecutive 1..J; all `from`/`to` present in nodes; positive
`population`; nonnegative `delta_i`/`delta_tau`/`Ijk`; `Il <= Ijk <= Iu`
where given; connected graph check (warn if disconnected components);
lon/lat in valid ranges.

---

## 5. Model Construction (`ModelSetup.jl`)

Following the research scripts (e.g. `optimal_regional_transport_networks.jl`):

```julia
param = init_parameters(; alpha, beta, gamma, rho, K = 2 * K_user,
                          sigma, a, N,
                          labor_mobility, cross_good_congestion,
                          annealing, duality,
                          tol, min_iter, max_iter, verbose = solver_verbose)

adj = falses(J, J)
for e in eachrow(edges); adj[e.from, e.to] = adj[e.to, e.from] = true; end

graph = create_graph(param, type = "custom",
                     x = nodes.lon, y = nodes.lat, adjacency = adj,
                     Lj = nodes.population, Zjn = Zjn, Hj = Hj)

graph[:delta_i]   = delta_i_matrix     # overwrite Euclidean defaults
graph[:delta_tau] = delta_tau_matrix

results = optimal_network(param, graph; I0 = I0, Il = Il, Iu = Iu,
                          verbose = solver_verbose)
```

Key points:

- **K doubling convention:** in all three research codebases the budget passed to
  the model is `2 ×` the undirected-network cost (`K = (K_base + extra) * 2`),
  because the symmetric `delta_i` matrix counts every edge twice in the budget
  constraint. The sidebar `K` is the *undirected* budget the user thinks in;
  `ModelSetup.jl` doubles it internally. **Verify at implementation time** against
  `rescale_network!` in `src/main/optimal_network.jl` (flagged in §12).
- **Budget helper:** after upload, compute and display in the sidebar
  `K_base = sum(delta_i .* I0)/2` (cost of the existing network) and
  `K_max = sum(delta_i .* Iu)/2` (cost of maxing out, if `Iu` finite), and
  pre-fill `K` with `K_base` so the user has an anchored starting point.
- **Baseline run:** a sidebar checkbox "Compute baseline allocation" (default on)
  first calls `optimal_network(param, graph; I0 = I0, solve_allocation = true)`
  to get `uj_orig`, `Cj_orig`, `PCj_orig`, etc. on the *existing* network —
  enabling gain metrics (`uj/uj_orig - 1`) exactly as in the research workflow.
- Convexity guards mirror the package: warn in the UI if `gamma > beta`
  (non-convex; annealing recommended) before running.

---

## 6. Solve Execution (`Solver.jl`)

### 6.1 Threading & locking

- Start the app with `julia -t auto` (README documents this; `app.jl` errors at
  startup if `Threads.nthreads() < 2`).
- One solve at a time: a `ReentrantLock` + `running::Bool`; the Run button is
  disabled while running. (`redirect_stdout` is process-global, so concurrent
  solves would interleave console output anyway.)

### 6.2 Console capture

`optimal_network` prints iteration lines via `println`
(`"Iteration No. $counter distance=$distance duration=$(...) secs. Welfare=$(...)"`,
`src/main/optimal_network.jl:189`) and Ipopt writes its log to fd 1 from C —
both are captured by a fd-level redirect:

```julia
pipe = Pipe(); Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
redirect_stdout(pipe.in)
reader = @async for line in eachline(pipe.out)
    push_console_line(line)          # appends to a buffer
end
task = Threads.@spawn try
    optimal_network(param, graph; I0, Il, Iu, verbose)
finally
    redirect_stdout(original_stdout); close(pipe.in)
end
```

- **Throttled flush:** Ipopt can print hundreds of lines/second. The reader
  accumulates lines and a 250 ms timer flushes them into the reactive
  `console_text` field (capped at the last ~2000 lines) so the WebSocket isn't
  flooded.
- **Progress:** each flushed batch is scanned with
  `r"^Iteration No\. (\d+) distance=([0-9.eE+-]+)"` to update a progress
  indicator (`iter / max_iter`, current `distance` vs `tol`) shown next to the
  Run button.
- On completion (or exception — caught and shown in console + a Quasar
  notification), results are stored in `AppState`, GeoJSON regenerated,
  `results_version` incremented (triggers client refetch), and the button
  re-enabled.

---

## 7. Frontend Layout

StippleUI layout: `q-layout` with a fixed left `q-drawer` (~340 px) and a
`q-page-container` whose page is a full-height `<div id="map">` plus overlays.

### 7.1 Sidebar (top → bottom)

1. **Network upload**
   - Two `uploader` components ("Nodes CSV", "Edges CSV") posting to
     `POST /api/upload/nodes` and `POST /api/upload/edges`.
   - After both are parsed + validated: summary chip ("`J` nodes, `E` edges,
     `N` goods"), validation errors listed in red, and the network is drawn on
     the map immediately (styled by uploaded `Ijk`) with `fitBounds`.
   - "Load example network" link (loads `data/example/`).
2. **Model parameters** (Quasar number inputs with tooltips giving the economic
   interpretation, defaults = package defaults):
   - `alpha` (0.5, ∈(0,1)), `beta` (1), `gamma` (1), `rho` (2)
   - `K` — budget (pre-filled from budget helper, see §5); displays `K_base`/`K_max` hints
3. **Solver controls**: `tol` (1e-5), `min_iter` (20), `max_iter` (200)
4. **Advanced** (collapsed `q-expansion-item`):
   - `sigma` (5), `a` (0.8)
   - `labor_mobility` (off), `cross_good_congestion` (off), `nu` (2, shown only
     if congestion on), `annealing` (on; only relevant if `gamma > beta`),
     `duality` (on), `solver verbose` (off → only iteration lines, on → full
     Ipopt log), "compute baseline allocation" (on), "allow downgrading" (off)
5. **Run Optimization** button (primary, full width) + progress bar/spinner +
   last-run summary (welfare, % gain vs baseline, iterations, wall time).
6. **Download results** buttons (enabled after a run): `nodes_results.csv`,
   `edges_results.csv` — same column conventions as the research code
   (`uj`, `Cj`, `PCj`, … with `_orig` baseline columns; `Ijk_orig`, `Ijk`,
   `Qjk_1..N`).

### 7.2 Map panel

Built in `public/js/map.js`:

- **Basemaps** via `L.control.layers` (collapsed, top-right), using
  leaflet-providers where available:
  - CartoDB.Positron (**default**), CartoDB.DarkMatter, OpenStreetMap.Mapnik,
    OpenTopoMap, Esri.WorldStreetMap, Esri.WorldTopoMap, Esri.WorldImagery
  - **Google Maps / Google Terrain**: plain XYZ layers
    (`https://mt{0-3}.google.com/vt/lyrs=m|p&x={x}&y={y}&z={z}`). *Note: keyless
    Google tiles technically violate Google ToS; acceptable for a local research
    tool, and the README documents the GoogleMutant + API-key alternative.*
- **Controls:** default zoom control (top-left), `L.control.scale({metric:true})`
  (bottom-left, the distance legend), color-gradient legend (bottom-right,
  chroma.js, updates with output switch).
- **Output selector:** a floating card (top-center or below the layers control)
  with two Quasar selects bound to reactive fields:
  - *Edge output*: Final infrastructure `Ijk` · Infrastructure increase ·
    Percent upgraded · Total flow `Qjk` · Flow of good n (one entry per good) ·
    Original infrastructure `Ijk_orig` (pre-run: only `Ijk_orig` available)
  - *Node output*: Utility `uj` · Per-capita consumption `cj` · Aggregate
    consumption `Cj` · Price index `PCj` · Population `Lj` · Production `Yj` ·
    and (with baseline) Welfare gain % `(uj/uj_orig−1)·100`, Consumption gain %,
    plus "None"
- **Rendering:** one `L.geoJSON` layer for edges (canvas renderer for
  performance), one for nodes (circle markers). Each feature carries *all*
  metrics as properties, so switching output restyles client-side without
  refetching. Edge color from a chroma scale (viridis for `Ijk`, YlOrRd for
  increase/percent — matching the R maps), width scaled to value (1–8 px);
  node radius ∝ √population, color by selected node output.
  Click popups show all properties nicely formatted.

### 7.3 Console panel

- Absolutely positioned panel over the bottom of the map (~35% height),
  dark background, monospace, auto-scrolls to the newest line.
- Header bar: "Solver output", copy button, and an **✕** close button;
  a small "Console" reopen button remains when closed.
- Opens automatically when a run starts.

---

## 8. Derived Output Formulas (`Outputs.jl`)

Edge values are extracted from the J×J result matrices with the research-code
symmetrization (`res_to_vec`): `val = (M[from,to] + M[to,from]) / 2`;
flows sum both directions of `Qjkn`.

| output                  | formula (per edge)                                                       | source convention |
|-------------------------|--------------------------------------------------------------------------|-------------------|
| Final infrastructure    | `Ijk` (from `results[:Ijk]`)                                             | edge results CSVs |
| Infrastructure increase | `max(Ijk - Ijk_orig, 0)`                                                 | `diff = pmin(pmax(Ijk - Ijk_orig, 0), cap)` in `analyze_*_results.R` |
| **Percent upgraded**    | `clamp((Ijk - Ijk_orig) / (Iu - Ijk_orig) * 100, 0, 100)` (NaN-safe when `Iu == Ijk_orig`; edges with `Iu = Inf` fall back to `max` of finite `Iu`, else `max(Ijk)`) | `perc_ug = pmin(pmax((Ijk - Ijk_orig)/(100 - Ijk_orig)*100, 0), 100)` — generalized: the R code's hard-coded 90/100 km/h cap is exactly the per-edge upper bound `Iu` |
| Total flow              | `sum over n of (Qjkn[from,to,n] + Qjkn[to,from,n])`                       | `Qjk_n` columns   |
| Flow of good n          | same, single `n`                                                          |                   |

Node metrics come directly from the results dict (`uj`, `cj`, `Cj`, `PCj`, `Lj`,
`Yj = sum(Yjn, dims=2)`), gains relative to the baseline allocation where computed.
Aggregate welfare gain shown in the sidebar: `sum(uj .* Lj) / sum(uj_orig .* Lj_orig) - 1`.

GeoJSON generation: `JSON3`-serialized FeatureCollections; edge geometry from the
uploaded LINESTRING (parsed once at upload) or straight node-to-node lines.

---

## 9. HTTP API (Genie routes)

| route                            | method | purpose                                             |
|----------------------------------|--------|-----------------------------------------------------|
| `/`                              | GET    | Stipple app page                                    |
| `/api/upload/nodes`              | POST   | multipart CSV → parse, validate, store              |
| `/api/upload/edges`              | POST   | multipart CSV → parse, validate, store              |
| `/api/example`                   | POST   | load bundled example network                        |
| `/api/network.geojson`           | GET    | current network (nodes + edges FeatureCollections, input metrics only) |
| `/api/results.geojson`           | GET    | network with all result metrics as properties       |
| `/api/download/nodes_results.csv`| GET    | node results CSV                                    |
| `/api/download/edges_results.csv`| GET    | edge results CSV                                    |

Reactive model (Stipple `@app`) fields: the parameter/solver/advanced values
(§7.1), `running::Bool`, `progress::Float64`, `status_text`, `console_text`,
`console_open::Bool`, `network_version::Int`, `results_version::Int`,
`edge_output::String`, `node_output::String`, `run::Bool` (button),
`load_example::Bool`, validation/summary strings. JS watches the version
counters and output selects via Stipple's client-side model.

---

## 10. Dependencies (`Project.toml`)

- `GenieFramework` (Genie, Stipple, StippleUI)
- `OptimalTransportNetworks` — `Pkg.develop(path="../OptimalTransportNetworks.jl")`
  so the app always runs the local dev version
- `CSV`, `DataFrames`, `JSON3`
- Julia ≥ 1.10 (user runs 1.12; keep the Manifest resolved under the running
  Julia so `Ipopt_jll` ≥ 1.15 is used — old MUMPS builds segfault on larger problems)

Run: `julia -t auto --project=. app.jl` → `http://localhost:8000`.

---

## 11. Example Dataset (`data/example/`)

A small synthetic network (~30 nodes, ~50 edges) generated by a throwaway script:
nodes on a rough geographic grid (e.g. around Central Africa for realistic
basemap context) with heterogeneous population/productivity, one port-like
high-productivity node; edges with `delta_i` = distance-proportional cost,
`delta_tau = 0.116 * log(dist_km / 1.609)` (the Graff 2024 iceberg convention from
the research code), `Ijk` mixing paved/unpaved speeds (20–80), `Iu = 100`,
straight-line geometries. Small enough that a full solve takes seconds — this
doubles as the app's end-to-end test case.

---

## 12. Implementation Phases

Each phase ends in a runnable state.

**Phase 1 — Scaffold & map shell**
- `Project.toml`, `app.jl` with empty reactive model, drawer + page layout,
  `map.js` with all basemaps, zoom, scale control, layer switcher, console panel
  markup (static), CSS.
- ✔ App starts, map renders with Positron and all basemaps switchable.

**Phase 2 — Upload & network display**
- `NetworkData.jl` (CSV parsing, WKT parser, validation), upload routes,
  `/api/network.geojson`, client fetch-on-version, edge/node rendering + popups,
  fitBounds, example dataset + loader, budget helper values.
- ✔ Uploading the example CSVs draws the network styled by `Ijk_orig`.

**Phase 3 — Solve pipeline & console**
- `ModelSetup.jl`, `Solver.jl` (spawn, stdout capture, throttled console,
  progress parsing, lock, error handling), Run button state machine, baseline
  run, **verify the K-doubling convention** against `rescale_network!` with the
  example network (compare a direct script run vs. the app).
- ✔ Run on the example network completes; console shows live Ipopt + iteration
  lines; welfare summary appears.

**Phase 4 — Results visualization**
- `Outputs.jl` (metrics table of §8, GeoJSON with all properties),
  `/api/results.geojson`, output selectors, chroma color scales + gradient
  legend, width scaling, node metrics + gains, download CSV routes.
- ✔ All edge outputs (final `Ijk`, increase, % upgraded, flows) and node outputs
  switchable with correct legends; results CSVs match research-code column
  conventions.

**Phase 5 — Polish & docs**
- Input tooltips, non-convexity warning (`gamma > beta`), disconnected-graph
  warning, error notifications, console cap, README (run instructions, CSV
  format spec, Google-tiles ToS note), `.gitignore`.
- ✔ Fresh-clone → README instructions → working app.

---

## 13. Risks, Verification Points & Future Extensions

**Verify during implementation**
- K-doubling: confirm the budget constraint sums the full symmetric matrix
  (research code's `* 2`); adjust the sidebar semantics if not (Phase 3).
- `optimal_network(..., verbose=...)` vs `param[:verbose]` interaction on the
  direct-Ipopt path (which controls Ipopt's `print_level`).
- Reused Ipopt problem objects and `redirect_stdout` interact at the fd level —
  confirm C-side output is captured on macOS (it should be; redirect dups fd 1).

**Known risks / mitigations**
- Large networks (≥ several thousand edges): canvas renderer, simplified
  geometries client-side if needed; GeoJSON payloads are fetched once per run.
- Ipopt log volume: throttled console flush + line cap (§6.2).
- Google tile ToS (§7.2) — documented, optional.
- No cancel in v1: killing a running Ipopt solve in-thread is unsafe.

**Future extensions**
- Solve in a separate worker process (Malt.jl): clean per-process stdout capture
  and a real **Cancel** button (kill worker).
- Scenario comparison (two runs side by side / difference maps).
- `apply_geography` support (elevation/obstacle uploads).
- Per-session state for multi-user deployment.
- Editable networks (click-to-add edges, edit `Iu`/`delta_i` in a table view).
