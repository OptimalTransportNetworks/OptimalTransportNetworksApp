# Deploying on a Hostinger VPS (KVM 4)

This app is a single-user, single-solve-at-a-time Genie/Stipple server (see
[README.md](README.md#architecture)) packaged by the existing [Dockerfile](Dockerfile).
A Hostinger KVM plan is a plain root-access VPS, not a PaaS, so this guide adds
the two things Fly/Cloud Run give you for free: a process supervisor
(Docker's own restart policy) and TLS termination (Caddy, with automatic
Let's Encrypt certificates). Nothing in the app or the Dockerfile changes —
the same image runs anywhere.

## 1. Provision the VPS

- Plan: **KVM 4** (4 vCPU / 16 GB RAM / 200 GB NVMe) — comfortably more headroom
  than the app needs for CEMAC-scale solves.
- OS: pick Ubuntu 24.04 LTS. If Hostinger's template list offers a "Docker"
  application template, use it — it's Ubuntu with Docker preinstalled and
  saves step 2. Confirm the plan is **x86_64** (it is by default for KVM
  plans) — that has to match the architecture of the HSL binary in step 4.
- Point your domain's DNS **A record** at the VPS's public IPv4 address before
  step 6, so the certificate request in step 6 doesn't fail on propagation.

## 2. Server setup

SSH in as root, then:

```bash
apt-get update && apt-get upgrade -y

# Docker (skip if you used the Docker template)
curl -fsSL https://get.docker.com | sh

# Firewall: only SSH, HTTP, HTTPS
apt-get install -y ufw
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

Docker's daemon is enabled via systemd by default, so it — and any container
with `restart: unless-stopped` — comes back up automatically after a reboot.
No extra systemd unit is needed.

16 GB RAM is generous for this app, but a small swapfile is cheap insurance
against an OOM kill mid-solve on the largest networks:

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

## 3. Get the app onto the server

```bash
git clone https://github.com/<your-org>/OptimalTransportNetworksApp.git /opt/otn
cd /opt/otn
```

The `OptimalTransportNetworks.jl` package dependency is cloned automatically
*inside* the Docker build (see `Dockerfile`) — you don't need to check it out
on the host.

## 4. Licensed HSL library (do not commit this)

The app looks for HSL's `ma27`/`ma57`/... solvers at the path in `OTN_HSL_LIB`
and falls back to MUMPS if it's missing (see
[README.md](README.md#ipopt-linear-solver-hsl)). If you already built the
Linux x86_64 libHSL bundle for the Fly deployment
(`libHSL_binaries.v2025.7.21.x86_64-linux-gnu-libgfortran5.tar.gz` per that
setup), reuse the exact same archive here — same architecture, same build.

```bash
mkdir -p /opt/otn/hsl
# copy the whole extracted lib/ directory (the .so has sibling libs it
# needs via its $ORIGIN rpath — don't cherry-pick just one file)
scp -r libHSL_binaries/lib/* youruser@vps-ip:/opt/otn/hsl/
```

`hsl/` is git-ignored — the licence is personal, never push it to the repo or
bake it into the image.

## 5. Configure

```bash
cp .env.example .env
# edit .env: set DOMAIN to your real domain, and OTN_HSL_LIB_FILE if the
# .so filename differs from libhsl_subset.so
```

## 6. First deploy

```bash
docker compose up -d --build
```

First build takes a few minutes (package precompilation — see the
`Dockerfile` comments); Caddy will request its Let's Encrypt certificate on
first request to your domain once the `app` container is healthy.

## 7. Verify

```bash
docker compose ps
docker compose logs -f app     # watch for "Optimal Transport Networks app →" and
                                # "[app] Using HSL ma57 via ..." (confirms the
                                # licensed solver loaded, not the MUMPS fallback)
curl -I https://your-domain.com
```

Open the domain in a browser and run the small synthetic network example to
confirm the solver, console streaming, and map all work end-to-end.

## 8. Updating / redeploying

```bash
cd /opt/otn
git pull
docker compose up -d --build
```

Docker layer caching means only changed layers (usually just the final
`COPY . .` layer) rebuild — a routine app-code change redeploys in seconds,
not the full precompile.

## 9. Monitoring

```bash
docker stats           # live CPU/RAM per container
docker compose logs --tail=200 app
```

## Troubleshooting

- **Console shows MUMPS instead of the chosen HSL solver**: `OTN_HSL_LIB`
  doesn't point to a real library, or the file is the ~30 KB LibHSL stub, not
  the licensed binary. Check `docker compose exec app ls -la /data/lib`.
- **Certificate not issued**: DNS hasn't propagated yet, or port 80/443 isn't
  reachable (check `ufw status` and Hostinger's hPanel firewall — some plans
  layer a panel-level firewall on top of the VPS's own `ufw`).
- **WebSocket (solver console) not updating**: Caddy's `reverse_proxy` passes
  `Upgrade`/`Connection` headers through automatically in v2 — this is only
  ever a symptom of a different reverse proxy/config in front, not Caddy.
