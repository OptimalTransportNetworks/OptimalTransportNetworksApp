# Translation of the uploaded network + UI parameters into the
# OptimalTransportNetworks.jl `param` / `graph` objects and J×J matrices.
#
# Conventions verified against the package source:
# - delta_i / delta_tau / I0 / Il / Iu are symmetric J×J matrices.
# - The budget constraint sums the FULL symmetric matrix (`sum(delta_i .* I)` in
#   `rescale_network!`), i.e. every undirected edge is counted twice. The sidebar
#   budget K is in undirected (per-edge-list) units, so we pass `param.K = 2K`.
# - `optimal_network` rescales I0 to exhaust param.K at entry, so the baseline
#   allocation run must use K = sum(delta_i .* I0) exactly (see Solver.jl).

"Build the symmetric J×J matrices from the edge list."
function build_matrices(nodes::DataFrame, edges::DataFrame; allow_downgrade::Bool = false)
    J = nrow(nodes)
    adj = falses(J, J)
    delta_i = zeros(J, J)
    delta_tau = zeros(J, J)
    I0 = zeros(J, J)
    Il = zeros(J, J)
    Iu = fill(Inf, J, J)
    has_Il = hasproperty(edges, :Il)
    has_Iu = hasproperty(edges, :Iu)
    for r in eachrow(edges)
        f, t = r.from, r.to
        adj[f, t] = adj[t, f] = true
        delta_i[f, t] = delta_i[t, f] = r.delta_i
        delta_tau[f, t] = delta_tau[t, f] = r.delta_tau
        I0[f, t] = I0[t, f] = r.Ijk
        il = has_Il && !ismissing(r.Il) ? min(Float64(r.Il), r.Ijk) : (allow_downgrade ? 0.0 : Float64(r.Ijk))
        iu = has_Iu && !ismissing(r.Iu) ? max(Float64(r.Iu), r.Ijk) : Inf
        Il[f, t] = Il[t, f] = il
        Iu[f, t] = Iu[t, f] = iu
    end
    return (adj = adj, delta_i = delta_i, delta_tau = delta_tau, I0 = I0, Il = Il, Iu = Iu)
end

"Productivity matrix: J×1, or J×N if a `product` column assigns each node a good."
function build_Zjn(nodes::DataFrame)
    J = nrow(nodes)
    if hasproperty(nodes, :product)
        N = maximum(nodes.product)
        Zjn = zeros(J, N)
        for (j, r) in enumerate(eachrow(nodes))
            Zjn[j, r.product] = r.productivity
        end
        return Zjn, Int(N)
    end
    return reshape(Float64.(nodes.productivity), J, 1), 1
end

"Budget anchors in user (undirected) units, straight from the edge list."
function budget_stats(edges::DataFrame)
    K_base = sum(edges.delta_i .* edges.Ijk)
    K_max = NaN
    if hasproperty(edges, :Iu) && !any(ismissing, edges.Iu) && all(isfinite, edges.Iu)
        K_max = sum(edges.delta_i .* max.(edges.Iu, edges.Ijk))
    end
    return (K_base = K_base, K_max = K_max)
end

"Locate a usable (non-stub) HSL library for Ipopt's ma57/ma86 linear solvers."
function find_hsl_lib()
    candidates = String[]
    haskey(ENV, "OTN_HSL_LIB") && push!(candidates, ENV["OTN_HSL_LIB"])
    push!(candidates, "/usr/local/lib/libhsl.dylib", "/opt/homebrew/lib/libhsl.dylib")
    artifacts = joinpath(homedir(), ".julia", "artifacts")
    if isdir(artifacts)
        for d in readdir(artifacts; join = true)
            f = joinpath(d, "lib", "libhsl.dylib")
            isfile(f) && push!(candidates, f)
        end
    end
    for f in candidates
        # the LibHSL fallback stub is ~30 KB and exports no solvers
        isfile(f) && filesize(f) > 1_000_000 && return f
    end
    return nothing
end

"""
Build (param, graph, mats) from the loaded network and UI parameters `p`
(a NamedTuple; see the Run handler in app.jl for the fields).
"""
function build_model(nodes::DataFrame, edges::DataFrame, p::NamedTuple)
    mats = build_matrices(nodes, edges; allow_downgrade = p.allow_downgrade)
    Zjn, N = build_Zjn(nodes)
    if get(p, :productivity_floor, false)
        # CEMAC-study regularization: every node can produce a little of every
        # good; keeps dual prices of scarce goods bounded
        Zjn = max.(Zjn, 1e-3)
    end

    param = init_parameters(
        alpha = p.alpha, beta = p.beta, gamma = p.gamma, rho = p.rho,
        sigma = p.sigma, a = p.a, N = N,
        K = 2 * p.K, # undirected budget -> full-symmetric-matrix convention
        labor_mobility = p.labor_mobility,
        cross_good_congestion = p.cross_good_congestion,
        nu = p.nu,
        annealing = p.annealing,
        duality = p.duality,
        tol = p.tol,
        min_iter = Int(round(p.min_iter)),
        max_iter = Int(round(p.max_iter)),
        verbose = true) # iteration lines always on; Ipopt output is governed by the solve's verbose kwarg

    Lj = Float64.(nodes.population)
    Hj = hasproperty(nodes, :housing) ? Float64.(nodes.housing) : Lj .* (1 - p.alpha)

    solver = get(p, :linear_solver, "mumps")
    if solver != "mumps"
        lib = find_hsl_lib()
        if lib === nothing
            println("[app] HSL library not found — falling back to MUMPS. ",
                    "Set OTN_HSL_LIB or install libhsl to use $solver.")
        else
            println("[app] Using HSL $solver via $lib")
            param[:optimizer_attr] = Dict(:hsllib => lib, :linear_solver => solver)
        end
    end

    graph = create_graph(param, type = "custom",
                         x = Float64.(nodes.lon), y = Float64.(nodes.lat),
                         adjacency = mats.adj,
                         Lj = Lj, Zjn = Zjn, Hj = Hj)
    graph[:delta_i] = mats.delta_i
    graph[:delta_tau] = mats.delta_tau

    return param, graph, mats
end
