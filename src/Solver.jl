# Background execution of optimal_network() with fd-level stdout capture.
#
# The redirect captures both the Julia iteration lines
# ("Iteration No. <n> distance=<d> duration=<s> secs. Welfare=<w>") and Ipopt's
# C-level log. It is process-global, so only one solve runs at a time.

const ORIGINAL_STDOUT = stdout

# NOTE: these files are `include`d into Main alongside `using GenieFramework`,
# which exports (but never defines) `time`, `view`, `mark`, `summary`, `select`
# and `metadata`. On Julia >= 1.12 that makes the bare name ambiguous with Base
# and every use throws UndefVarError at runtime. Always qualify: `Base.time()`.

const PROGRESS_RE = r"Iteration No\. (\d+) distance=([0-9.eE+-]+)"

"""
    start_solve!(p; on_progress, on_done, on_error) -> Bool

Launch the solve on a default-pool thread. `p` is the NamedTuple of UI parameters.
Callbacks fire from background tasks:
- `on_progress(iter::Int, distance::Float64)`
- `on_done(results, baseline, param, mats, elapsed)`
- `on_error(msg::String)`
"""
function start_solve!(p::NamedTuple; on_progress::Function, on_done::Function, on_error::Function)
    if STATE.running
        on_error("A solve is already running.")
        return false
    end
    if STATE.nodes === nothing || STATE.edges === nothing
        on_error("No network loaded — upload the nodes and edges CSVs first.")
        return false
    end
    nodes, edges = STATE.nodes, STATE.edges
    lock(STATE_LOCK) do
        STATE.running = true
    end
    OptimalTransportNetworks.ABORT_SOLVE[] = false
    console_clear!()
    console_push!("[app] Building model: $(nrow(nodes)) nodes, $(nrow(edges)) edges, K = $(p.K) (internal 2K = $(2 * p.K)).")

    # Nobody waits on this task, so an exception escaping _solve_task would be
    # swallowed: STATE.running would stay true forever and the UI would sit at
    # "Solving..." with a dead console and an abort button that does nothing.
    # Catch everything here and surface it through the normal error path.
    Threads.@spawn :default begin
        try
            _solve_task(nodes, edges, p, on_progress, on_done, on_error)
        catch e
            msg = sprint(showerror, e)
            # _solve_task may have died before its own finally restored stdout;
            # leaving it pointed at a dead pipe would break every later solve.
            try
                redirect_stdout(ORIGINAL_STDOUT)
            catch
            end
            lock(STATE_LOCK) do
                STATE.running = false
            end
            try
                Base.println(ORIGINAL_STDOUT, "[app] solve task died: ", msg)
                console_push!("[app] Solve FAILED — internal error: $msg")
                on_error(msg)
            catch
            end
        end
    end
    return true
end

"Request a cooperative abort: Ipopt stops at its next iteration via the package's intermediate callback."
function abort_solve!()
    STATE.running || return false
    OptimalTransportNetworks.ABORT_SOLVE[] = true
    console_push!("[app] Abort requested — stopping the solver at the next Ipopt iteration...")
    return true
end

function _solve_task(nodes, edges, p, on_progress, on_done, on_error)
    t_start = Base.time()
    pending = String[]
    plock = ReentrantLock()

    rd, wr = redirect_stdout()
    # The reader must live on its OWN thread: an @async task would be sticky to
    # this thread, which blocks inside Ipopt's C code for the whole solve — the
    # console would only update after convergence.
    reader = Threads.@spawn :default begin
        try
            for line in eachline(rd)
                lock(plock) do
                    push!(pending, line)
                end
            end
        catch
        end
    end
    flusher = Timer(0.25; interval = 0.25) do _
        drain_console!(pending, plock, on_progress)
    end

    ok = false
    err_msg = ""
    results = nothing
    baseline = nothing
    param = nothing
    mats = nothing
    try
        param, graph, mats = build_model(nodes, edges, p)
        if p.compute_baseline
            println("========== Baseline allocation on the existing network ==========")
            bparam = deepcopy(param)
            # Exact cost of the existing network so optimal_network's entry rescale of I0 is a no-op
            bparam[:K] = sum(mats.delta_i .* mats.I0)
            baseline = optimal_network(bparam, deepcopy(graph); I0 = copy(mats.I0),
                                       solve_allocation = true, verbose = p.solver_verbose)
            println("Baseline welfare: $(baseline[:welfare])")
        end
        println("========== Network optimization ==========")
        results = optimal_network(param, graph; I0 = copy(mats.I0), Il = mats.Il, Iu = mats.Iu,
                                  verbose = p.solver_verbose)
        ok = true
    catch e
        err_msg = sprint(showerror, e)
        println("ERROR: ", err_msg)
    finally
        try
            Libc.flush_cstdio() # flush Ipopt's C-level stdio buffers into the pipe
        catch
        end
        redirect_stdout(ORIGINAL_STDOUT)
        close(wr)
    end

    try
        wait(reader)
    catch
    end
    close(flusher)
    drain_console!(pending, plock, on_progress) # final drain

    elapsed = Base.time() - t_start
    lock(STATE_LOCK) do
        STATE.running = false
    end

    if ok
        console_push!("[app] Solve finished in $(round(elapsed, digits = 1)) s.")
        try
            on_done(results, baseline, param, mats, elapsed)
        catch e
            msg = sprint(showerror, e)
            console_push!("[app] ERROR while post-processing results: $msg")
            on_error("Post-processing failed: $msg")
        end
    else
        console_push!("[app] Solve FAILED after $(round(elapsed, digits = 1)) s.")
        on_error(err_msg)
    end
    return nothing
end

function drain_console!(pending::Vector{String}, plock::ReentrantLock, on_progress::Function)
    try
        Libc.flush_cstdio() # push Ipopt's block-buffered C output into the pipe
    catch
    end
    batch = lock(plock) do
        isempty(pending) && return nothing
        b = copy(pending)
        empty!(pending)
        b
    end
    batch === nothing && return nothing
    console_push!(batch)
    for line in batch
        m = match(PROGRESS_RE, line)
        if m !== nothing
            it = tryparse(Int, m.captures[1])
            dist = tryparse(Float64, m.captures[2])
            if it !== nothing && dist !== nothing
                try
                    on_progress(it, dist)
                catch
                end
            end
        end
    end
    return nothing
end
