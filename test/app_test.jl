# In-process test of the reactive app: instantiates the Stipple model and
# simulates the button clicks (Load example -> Run Optimization), verifying the
# full handler path the browser would trigger.
#
# Run: julia -t auto,1 --project=. test/app_test.jl

ENV["OTN_NO_SERVER"] = "1"

include(joinpath(dirname(@__DIR__), "app.jl"))

macro check(cond, msg)
    quote
        if $(esc(cond))
            println("PASS: ", $(esc(msg)))
        else
            println("FAIL: ", $(esc(msg)))
            global FAILED = true
        end
    end
end
FAILED = false

model = Stipple.ReactiveTools.@init()
model.isready[] = true # fires the isready handler -> registers MODEL_REF

@check MODEL_REF[] === model "model registered on isready"

# --- Load CEMAC network (button): load + calibration only, no solve (see
# test/cemac_solve_test.jl for the research-scale solve) -------------------------
model.load_cemac[] = true
sleep(0.5)
@check model.has_network[] "CEMAC network loaded via button handler"
@check model.K[] > 0 "budget K prefilled ($(model.K[]))"
@check occursin("196 nodes", model.net_summary[]) "CEMAC summary pushed ($(model.net_summary[]))"
# cross_good_congestion stays FALSE by default — it is what keeps the solve fast
@check model.alpha[] == 0.7 && model.sigma[] == 3.8 && !model.cross_good_congestion[] "CEMAC calibration applied on load"

# --- Load example network (button) -------------------------------------------
model.load_example[] = true
sleep(0.5)
@check model.has_network[] "example network loaded via button handler"
@check occursin("30 nodes", model.net_summary[]) "example summary pushed ($(model.net_summary[]))"
@check STATE.network_valid "STATE marked valid"

# --- Run optimization (button) on the small synthetic network ------------------
model.alpha[] = 0.5
model.gamma[] = 1.0
model.sigma[] = 5.0
model.a[] = 0.8
model.cross_good_congestion[] = false
model.annealing[] = false
model.min_iter[] = 3
model.max_iter[] = 12
model.tol[] = 4 # tolerance digits: 1e-4

model.run[] = true
sleep(1.0)
@check model.running[] || !STATE.running "run handler started the solve"

t0 = Base.time()
while (STATE.running || model.running[]) && Base.time() - t0 < 600
    sleep(0.5)
end
sleep(1.0)

@check !STATE.running "solve finished"
@check model.has_results[] "model has_results set"
@check !isempty(model.results_text[]) "results summary pushed: $(model.results_text[])"
@check occursin("Iteration", model.status_text[]) || model.status_text[] == "Done — select outputs on the map." "status text updated ($(model.status_text[]))"
@check STATE.results !== nothing "results stored in STATE"
@check STATE.version >= 2 "map version bumped ($(STATE.version))"

d = JSON3.read(STATE.mapdata_json)
@check d.has_results == true "mapdata rebuilt with results"

println(FAILED ? "\n=== TEST FAILURES ===" : "\n=== ALL TESTS PASSED ===")
exit(FAILED ? 1 : 0)
