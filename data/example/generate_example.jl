# Generates the bundled example network: a synthetic 30-node road network over a
# Central-Africa-like region. Deterministic (seeded). Uses only the standard library.
#
# Run: julia data/example/generate_example.jl

using Random

rng = MersenneTwister(42)

function hav(lon1, lat1, lon2, lat2) # great-circle distance in km
    R = 6371.0
    dlat = deg2rad(lat2 - lat1)
    dlon = deg2rad(lon2 - lon1)
    h = sin(dlat / 2)^2 + cos(deg2rad(lat1)) * cos(deg2rad(lat2)) * sin(dlon / 2)^2
    return 2R * asin(sqrt(h))
end

ncol, nrow = 6, 5
lon_grid = range(9.5, 15.5, length = ncol)
lat_grid = range(2.0, 7.0, length = nrow)

lons = Float64[]; lats = Float64[]
for la in lat_grid, lo in lon_grid
    push!(lons, round(lo + 0.5 * (rand(rng) - 0.5), digits = 4))
    push!(lats, round(la + 0.4 * (rand(rng) - 0.5), digits = 4))
end
J = ncol * nrow

# Populations in thousands: mostly small cities, a few large ones, one port city
population = [round(exp(randn(rng) * 0.8 + 4.6), digits = 1) for _ in 1:J]
population[3]  = 2400.0
population[15] = 1600.0
population[26] = 900.0
port = 7
population[port] = 1900.0

productivity = [round(2.0 + 2.0 * rand(rng) + 1.2 * log10(population[j] / 100 + 1), digits = 3) for j in 1:J]
productivity[port] += 4.0 # port productivity premium

housing = round.(population .* 0.3, digits = 2)

# Edges: rook grid plus some diagonals
idx(r, c) = (r - 1) * ncol + c
edge_pairs = Tuple{Int, Int}[]
for r in 1:nrow, c in 1:ncol
    c < ncol && push!(edge_pairs, (idx(r, c), idx(r, c + 1)))
    r < nrow && push!(edge_pairs, (idx(r, c), idx(r + 1, c)))
    r < nrow && c < ncol && rand(rng) < 0.25 && push!(edge_pairs, (idx(r, c), idx(r + 1, c + 1)))
end

speeds = [20.0, 30.0, 40.0, 50.0, 60.0, 80.0]
cw = cumsum([0.22, 0.22, 0.2, 0.16, 0.12, 0.08])
sample_speed(rng) = speeds[something(findfirst(>=(rand(rng)), cw), length(speeds))]

open(joinpath(@__DIR__, "nodes.csv"), "w") do io
    println(io, "node,lon,lat,population,productivity,housing,name")
    for j in 1:J
        name = j == port ? "Port City" : "City-$(lpad(j, 2, '0'))"
        println(io, "$j,$(lons[j]),$(lats[j]),$(population[j]),$(productivity[j]),$(housing[j]),$name")
    end
end

open(joinpath(@__DIR__, "edges.csv"), "w") do io
    println(io, "from,to,delta_i,delta_tau,Ijk,Il,Iu,geometry")
    for (f, t) in edge_pairs
        dist = hav(lons[f], lats[f], lons[t], lats[t])
        Ijk = sample_speed(rng)
        delta_i = round(dist * 0.03 * (0.8 + 0.4 * rand(rng)), digits = 4)
        delta_tau = round(max(0.1158826 * log(dist / 1.609), 0.005), digits = 5)
        # slightly curved LINESTRING so the WKT parser and map rendering are exercised
        mx, my = (lons[f] + lons[t]) / 2, (lats[f] + lats[t]) / 2
        dx, dy = lons[t] - lons[f], lats[t] - lats[f]
        nrm = max(sqrt(dx^2 + dy^2), 1e-9)
        off = 0.15 * (rand(rng) - 0.5)
        px = round(mx - off * dy / nrm, digits = 4)
        py = round(my + off * dx / nrm, digits = 4)
        geom = "LINESTRING ($(lons[f]) $(lats[f]), $px $py, $(lons[t]) $(lats[t]))"
        println(io, "$f,$t,$delta_i,$delta_tau,$Ijk,$Ijk,100,\"$geom\"")
    end
end

println("Wrote $J nodes and $(length(edge_pairs)) edges to $(@__DIR__)")
