# OptimalTransportNetworksApp

A [Genie.jl](https://genieframework.com/) web application for running optimal
transport network simulations with
[OptimalTransportNetworks.jl](https://github.com/SebKrantz/OptimalTransportNetworks.jl)
(Fajgelbaum & Schaal, 2020, *Econometrica*) on user-supplied networks, with
interactive map visualization of the results.

Layout: dark collapsible sidebar (uploads, parameters, Run button, results) on
the left; map panel on the right with a basemap dropdown and a layers panel
controlling, per layer (edges/nodes), the colour variable, colour map, size
variable, and a transformation (level/log/log10/sqrt/…) applied to the scale.
Uploaded nodes or edges are visualized immediately (edges-only requires a WKT
`geometry` column). Live solver output streams into a console at the bottom of
the map, and a running optimization can be aborted from the Run button.
ⓘ icons explain every field without cluttering the UI.

## Quick start

```bash
cd OptimalTransportNetworksApp
julia --project=. -e 'using Pkg; Pkg.instantiate()'   # first time only
julia -t auto,1 --project=. app.jl
```

Then open <http://localhost:8000>, click **Load example network**, and hit
**Run Optimization**. Set `OTN_PORT` to change the port.

> **Threads:** `-t auto,1` matters. It gives Julia an interactive thread pool
> for the web server, so the UI stays responsive while Ipopt blocks a
> default-pool thread during solves. The app refuses to start single-threaded.

## Input format

A network consists of two CSV files (column names are case-sensitive; extra
columns are kept and shown in map popups).

### Nodes CSV

| column         | required | description                                            |
|----------------|----------|--------------------------------------------------------|
| `node`         | yes      | integer id; must be consecutive `1..J`                 |
| `lon`, `lat`   | yes      | WGS84 coordinates                                      |
| `population`   | yes      | population / labor `Lj` (any consistent unit)          |
| `productivity` | yes      | productivity of the node's good (`Zjn`)                |
| `housing`      | recommended | housing supply `Hj`; fallback: `population × (1 − alpha)` |
| `product`      | optional | integer good index `1..N` — enables multi-good economies (each node produces one good, which keeps the fast Armington solver path) |
| `name`         | optional | label used in map popups                               |

### Edges CSV

One row per undirected edge:

| column      | required | description                                                       |
|-------------|----------|-------------------------------------------------------------------|
| `from`, `to`| yes      | node ids                                                          |
| `delta_i`   | yes      | infrastructure building cost per unit of `I` on this edge         |
| `delta_tau` | yes      | iceberg transport friction                                        |
| `Ijk`       | yes      | existing infrastructure level (e.g. speed in km/h, Graff 2024 convention) |
| `Il`        | optional | lower bound on `I` (default: `Ijk`, i.e. no downgrading; toggle "Allow downgrading" for `Il = 0`) |
| `Iu`        | optional | upper bound on `I` (default: unbounded); also the cap in the percent-upgraded output |
| `geometry`  | optional | WKT `LINESTRING (lon lat, lon lat, ...)` used to draw the edge on the map |

Two datasets are bundled:

- `data/example/` — a small synthetic 30-node network (**Load example**);
  regenerate with `julia data/example/generate_example.jl`.
- `data/CEMAC/` — the **real CEMAC road network** from the OptimalCEMACRoads
  study by Krantz & Bougna (2026) (196 city nodes, 313 edges, 20 goods; existing network only, no
  hypothetical links): infrastructure = average speed in km/h, upgrade costs per
  km/h up to a 90 km/h cap, and Graff (2024) iceberg trade costs.
  **Load CEMAC network** also applies the study's calibration (alpha 0.7,
  gamma 1.2, sigma 3.8, a 1, rho 0, cross-good congestion, duality). Regenerate
  with `julia --project=. data/CEMAC/generate_cemac.jl` (requires the
  OptimalCEMACRoads data locally).

## Budget semantics

The sidebar budget `K` is in **undirected edge units**: the model's constraint
is `sum over edges of delta_i × Ijk ≤ K`. (Internally the package sums the full
symmetric J×J matrix, so the app passes `2K`; this matches the `* 2` convention
in the research codebases.) After loading a network the sidebar shows the cost
of the existing network `K₀` and prefills `K` with `1.2 × K₀` (20% new
investment). With the default no-downgrading bounds, `K = K₀` leaves the network
unchanged; the amount above `K₀` is what gets invested.

## Outputs

**Edge outputs** (map + `edges_results.csv`): final infrastructure `Ijk`,
infrastructure increase `max(Ijk − Ijk_orig, 0)`, percent upgraded
`clamp((Ijk − Ijk_orig)/(Iu − Ijk_orig) × 100, 0, 100)`, total and per-good
flows `Qjk`. Edge values symmetrize the two directions as `(M[i,j] + M[j,i])/2`.

**Node outputs** (map + `nodes_results.csv`): utility `uj`, consumption `cj`/`Cj`,
price index `PCj`, labor `Lj`, production `Yj` — plus `_orig` baseline values and
percentage gains when the baseline comparison run is enabled (it solves the
allocation on the *existing* network first, like the research workflows).

The verbose output of `optimal_network()` (outer-loop iterations, and the full
Ipopt log if "Full Ipopt output" is toggled) streams into a console panel at the
bottom of the map while the solver runs. While a solve is running the Run button
turns into **Abort Optimization**, which stops Ipopt cooperatively at the next
iteration (via an intermediate callback in OptimalTransportNetworks.jl).

## Ipopt linear solver (HSL)

The default linear solver is HSL **ma57**; `ma27`/`ma77`/`ma86`/`ma97` and the
bundled open-source `mumps` are selectable under Advanced options. The `ma*`
solvers are substantially faster and more robust on large problems (MUMPS tends
to stall on CEMAC-scale multi-good networks) but require
[Coin-HSL](https://licences.stfc.ac.uk/product/coin-hsl) (free academic
licence): download [libHSL](https://licences.stfc.ac.uk/product/libhsl-2023_11_7),
which ships the Julia package `HSL_jll.jl`, and install it with
`Pkg.develop(path="…/HSL_jll.jl-2023.11.7")` (see
[HSL.jl](https://github.com/JuliaSmoothOptimizers/HSL.jl)). The app picks it up
from any environment on the load path (e.g. the default `@v1.x` environment), or
from `OTN_HSL_LIB` / `/usr/local/lib/libhsl.dylib`. If no usable HSL library is
found the run falls back to MUMPS with a note in the console.

## Basemaps

CartoDB Positron (default) / DarkMatter, OpenStreetMap, OpenTopoMap, Esri
WorldStreetMap / WorldTopoMap / WorldImagery via
[leaflet-providers](https://github.com/leaflet-extras/leaflet-providers), plus
Google Maps / Google Terrain as plain XYZ tile layers. **Note:** keyless Google
tiles technically violate Google's ToS; for anything beyond local research use,
switch to the [GoogleMutant](https://gitlab.com/IvanSanchez/Leaflet.GridLayer.GoogleMutant)
plugin with an API key, or remove those two entries in `public/js/map.js`.

## Architecture

- `app.jl` — Genie/Stipple reactive app: sidebar bindings, run handler, REST routes.
- `src/NetworkData.jl` — CSV parsing, validation, WKT LINESTRING parser.
- `src/ModelSetup.jl` — edge list → `param`/`graph` and the J×J matrices.
- `src/Solver.jl` — background solve on a default-pool thread with fd-level
  stdout capture (catches both Julia iteration lines and Ipopt's C output).
  One solve at a time.
- `src/Outputs.jl` — derived metrics, GeoJSON payload, results CSVs
  (written to `public/downloads/`).
- `public/js/map.js` — Leaflet module (outside the Vue-managed DOM); polls
  `/api/version` and fetches `/api/mapdata` + `/api/console` incrementally.

Limitations (by design, v1): single user, one solve at a time, partial labor
mobility (region-based) not exposed.

## Testing

```bash
julia -t auto,1 --project=. test/headless_test.jl     # parse → validate → solve → outputs
julia -t auto,1 --project=. test/app_test.jl          # button-driven app flow (load → run → results)
julia -t auto,1 --project=. test/stream_abort_test.jl # live console streaming + abort latency
julia -t auto,1 --project=. test/cemac_solve_test.jl  # opt-in research-scale CEMAC solve (long)
```
