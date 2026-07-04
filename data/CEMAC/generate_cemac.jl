# Builds the bundled CEMAC network (data/CEMAC/nodes.csv, edges.csv) from the
# real CEMAC road network used in
#   OptimalCEMACRoads/code/4_GE_simulation/optimal_trans_african_networks_largest_pcities_loop_CR_duality.jl
# using only the existing network (graph_orig_MACR_90kmh_google.csv) — the
# hypothetical additional links (graph_add) are omitted.
#
# Conventions replicated from that script (following Graff 2024):
# - infrastructure Ijk   = average speed in km/h = (distance/1000) / (duration/60)
# - iceberg cost         = max(0.1158826 * log(dist_km / 1.609), 0)
# - upgrade cost         = total_cost / (Iu − Ijk), where
#                          total_cost = ug_cost_km * dist_km / 1e6  (millions USD'15)
#                          and Iu = max(Ijk, 90 km/h); 0 where Iu ≈ Ijk
# - population in thousands (zeros floored at 1e-3), productivity = GDP per capita
#   (gdp / pop_thousands / 1e6), ports boosted by 2.1 * outflows / population
# - housing column omitted: the app then uses Hj = population × (1 − alpha),
#   which is exactly the script's Hj for any chosen alpha
#
# Run: julia --project=. data/CEMAC/generate_cemac.jl

using DataFrames, CSV

const SRC = "/Users/sebastiankrantz/Documents/World Bank/OptimalCEMACRoads/data/transport_network/csv"

edges = CSV.read(joinpath(SRC, "graph_orig_MACR_90kmh_google.csv"), DataFrame)
nodes = CSV.read(joinpath(SRC, "graph_nodes_MACR_90kmh_google.csv"), DataFrame)

# Real (routed) edge shapes, simplified with rmapshaper::ms_simplify(keep = 0.1)
# and exported to WKT LINESTRINGs by the R side (edges_real_simplified.qs ->
# csv/edges_real_simplified_geometry.csv, keyed by the same from/to node indices).
geom = CSV.read(joinpath(SRC, "edges_real_simplified_geometry.csv"), DataFrame)

# --- nodes -------------------------------------------------------------------
population = nodes.population ./ 1000                    # thousands
outflows = nodes.outflows ./ 1000
productivity = nodes.gdp ./ population ./ 1e6            # per-capita GDP
productivity[population .<= 0] .= 0
population .+= (population .== 0) .* 1e-3                # avoid zero population
for i in eachindex(population)                           # port productivity boost
    if outflows[i] > 0
        productivity[i] += 2.1 * outflows[i] / population[i]
    end
end
# The study floors the whole Zjn matrix at 1e-3 so junction nodes with zero GDP
# still earn income (zero income -> -Inf utility at rho > 1 breaks the solver).
# The app's one-good-per-node format expresses this as an own-good floor:
productivity = max.(productivity, 1e-3)

r6(x) = round(x, sigdigits = 7)
nodes_out = DataFrame(
    node = 1:nrow(nodes),
    lon = nodes.lon,
    lat = nodes.lat,
    population = r6.(population),
    productivity = r6.(productivity),
    product = nodes.product,
    name = nodes.city_country)

# --- edges -------------------------------------------------------------------
dist_km = edges.distance ./ 1000
dur_h = edges.duration ./ 60
Ijk = dist_km ./ dur_h                                   # speed in km/h
@assert all(isfinite, Ijk) && all(Ijk .> 0)
total_cost = edges.ug_cost_km .* dist_km ./ 1e6          # millions USD
Iu = max.(Ijk, 90.0)
delta_i = total_cost ./ (Iu .- Ijk)
delta_i[(Iu .- Ijk) .< 1e-4 .|| .!isfinite.(delta_i)] .= 0.0
delta_tau = max.(0.1158826 .* log.(dist_km ./ 1.609), 0.0)

# Match WKT geometry to each edge by (from, to) — same node indexing, order-independent
geom_lookup = Dict((r.from, r.to) => r.geometry for r in eachrow(geom))
geometry = [get(geom_lookup, (f, t), missing) for (f, t) in zip(edges.from, edges.to)]
@assert !any(ismissing, geometry) "some edges have no matching geometry"

edges_out = DataFrame(
    from = edges.from,
    to = edges.to,
    delta_i = r6.(delta_i),
    delta_tau = r6.(delta_tau),
    Ijk = r6.(Ijk),
    Il = r6.(Ijk),                                       # no downgrading
    Iu = r6.(Iu),
    geometry = geometry)

# --- checks & write ----------------------------------------------------------
J = nrow(nodes_out)
@assert all(1 .<= edges_out.from .<= J) && all(1 .<= edges_out.to .<= J)
K_base = sum(edges_out.delta_i .* edges_out.Ijk)
K_max = sum(edges_out.delta_i .* edges_out.Iu)
println("nodes: $J, edges: $(nrow(edges_out)), goods: $(maximum(nodes_out.product))")
println("speeds (km/h): ", round.(extrema(edges_out.Ijk), digits = 1),
        ", edges already at ≥90 km/h (delta_i = 0): ", count(==(0), edges_out.delta_i))
println("K_base (existing network, millions USD) = ", round(K_base, digits = 1),
        ", K_max (all edges at 90 km/h) = ", round(K_max, digits = 1))

CSV.write(joinpath(@__DIR__, "nodes.csv"), nodes_out)
CSV.write(joinpath(@__DIR__, "edges.csv"), edges_out)
println("Written to $(@__DIR__)")
