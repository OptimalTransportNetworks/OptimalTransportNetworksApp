FROM julia:1.12

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# The app Manifest pins OptimalTransportNetworks as a path dep at
# ../OptimalTransportNetworks.jl, so it must live next to /app.
# Pinned to the development-branch commit the app was built against
# (ABORT_SOLVE support); bump the SHA when the package advances.
RUN git clone https://github.com/OptimalTransportNetworks/OptimalTransportNetworks.jl \
      /OptimalTransportNetworks.jl \
 && git -C /OptimalTransportNetworks.jl checkout 808899d

WORKDIR /app

COPY Project.toml Manifest.toml ./

# Cap parallel precompile jobs: the remote builder OOM-kills workers when ~10
# heavy packages (JuMP, Stipple, Plots, ...) compile at once, leaving silent
# cache gaps (DataFrames failed this way) that the machine then has to
# recompile on every cold boot.
ENV JULIA_NUM_PRECOMPILE_TASKS=4

# Without this, pkgimages are compiled for the BUILDER's native CPU; the Fly
# machine (different microarch) then rejects every cache and recompiles all
# ~290 packages on boot. This is the portable multi-target string the official
# Julia x86_64 binaries use — set for build AND runtime so caches match.
ENV JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
# Load the full stack once: retries any precompile that failed above (serially,
# low memory) and FAILS THE BUILD if the app's packages cannot actually load.
RUN julia --project=. -e 'using GenieFramework, Genie, DataFrames, CSV, JSON3, OptimalTransportNetworks; println("LOAD-OK")'

COPY . .

ENV OTN_HOST=0.0.0.0 \
    OTN_PORT=8080 \
    GKSwstype=100

EXPOSE 8080

# auto,1: default worker threads + one interactive thread so the web server
# stays responsive while a solve blocks a default-pool thread.
CMD ["julia", "-t", "auto,1", "--project=.", "app.jl"]
