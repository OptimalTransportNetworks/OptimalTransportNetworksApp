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
 && git -C /OptimalTransportNetworks.jl checkout 993bd1c

WORKDIR /app

COPY Project.toml Manifest.toml ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

COPY . .

ENV OTN_HOST=0.0.0.0 \
    OTN_PORT=8080 \
    GKSwstype=100

EXPOSE 8080

# auto,1: default worker threads + one interactive thread so the web server
# stays responsive while a solve blocks a default-pool thread.
CMD ["julia", "-t", "auto,1", "--project=.", "app.jl"]
