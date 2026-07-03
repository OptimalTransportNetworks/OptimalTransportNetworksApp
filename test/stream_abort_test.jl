# Tests live console streaming and the abort mechanism on the (slow) CEMAC solve:
# 1. console lines must arrive continuously WHILE Ipopt runs (not only at the end)
# 2. clicking the Run button again (abort path) must stop the solver within seconds
#
# Run: julia -t auto,1 --project=. test/stream_abort_test.jl

ENV["OTN_NO_SERVER"] = "1"
include(joinpath(dirname(@__DIR__), "app.jl"))

macro check(cond, msg)
    quote
        if $(esc(cond))
            println(stderr, "PASS: ", $(esc(msg)))
        else
            println(stderr, "FAIL: ", $(esc(msg)))
            global FAILED = true
        end
    end
end
FAILED = false

model = Stipple.ReactiveTools.@init()
model.isready[] = true

model.load_cemac[] = true
sleep(0.5)
@check model.has_network[] "CEMAC network loaded"

model.solver_verbose[] = true # Ipopt log makes streaming observable within seconds
model.compute_baseline[] = false

# --- start the solve (button) --------------------------------------------------
model.run[] = true
sleep(2.0)
@check STATE.running "solve started"

# --- streaming: console must grow repeatedly during the solve -------------------
totals = Int[]
for i in 1:12
    sleep(2.5)
    push!(totals, console_since(0).total)
end
increments = count(i -> totals[i] > totals[i-1], 2:length(totals))
println(stderr, "console totals over 30 s: ", totals)
@check totals[end] > 10 "console received solver output during the solve ($(totals[end]) lines)"
@check increments >= 3 "console grew incrementally ($(increments) increments observed)"
@check any(l -> occursin("iter", lowercase(l)) || occursin("Ipopt", l), STATE.console_lines) "Ipopt iteration log visible in console"

# --- abort: press the button again ----------------------------------------------
@check STATE.running "still running before abort"
t_abort = time()
model.run[] = true # abort path
t0 = time()
while STATE.running && time() - t0 < 120
    sleep(0.5)
end
abort_latency = time() - t_abort
@check !STATE.running "solver stopped after abort (latency $(round(abort_latency, digits=1)) s)"
@check abort_latency < 60 "abort was responsive (< 60 s)"
sleep(1.0)
@check model.status_text[] == "Optimization aborted." "status shows aborted ($(model.status_text[]))"
@check !model.running[] "button state reset"
@check any(l -> occursin("Abort requested", l), STATE.console_lines) "abort noted in console"

println(stderr, FAILED ? "\n=== TEST FAILURES ===" : "\n=== ALL TESTS PASSED ===")
exit(FAILED ? 1 : 0)
