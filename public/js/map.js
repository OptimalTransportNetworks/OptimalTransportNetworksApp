/* Leaflet map + custom UI chrome for the Optimal Transport Networks app.
 *
 * Lives entirely outside the Vue/Stipple-managed DOM (except delegated clicks
 * on .info-icon elements rendered inside the sidebar). Backend endpoints:
 *   GET /api/version  -> { version, running }   (polled)
 *   GET /api/mapdata  -> network + results GeoJSON with metric metadata
 *   GET /api/console?after=N -> incremental solver console lines
 */
(function () {
  'use strict';

  var S = {
    map: null,
    edgeLayer: null,
    nodeLayer: null,
    renderer: null,
    baseLayers: {},
    currentBase: null,
    data: null,
    version: -1,
    bboxKey: '',
    edgeMetric: null,
    nodeMetric: 'none',
    edgesVisible: true,
    nodesVisible: true,
    consoleCursor: 0,
    consoleOpen: false,
    running: false,
    maxPop: 1
  };

  var PALETTES = {
    viridis: ['#440154', '#482878', '#3e4a89', '#31688e', '#26828e', '#1f9e89',
              '#35b779', '#6ece58', '#b5de2b', '#fde725'],
    inferno: ['#000004', '#1b0c42', '#4b0c6b', '#781c6d', '#a52c60', '#cf4446',
              '#ed6925', '#fb9a06', '#f7d03c', '#fcffa4'],
    ylorrd: ['#ffffcc', '#ffeda0', '#fed976', '#feb24c', '#fd8d3c', '#fc4e2a',
             '#e31a1c', '#bd0026', '#800026'],
    rdbu: ['#b2182b', '#d6604d', '#f4a582', '#fddbc7', '#f7f7f7', '#d1e5f0',
           '#92c5de', '#4393c3', '#2166ac']
  };

  /* ------------------------------------------------------------ info modal */

  var INFO = {
    guide: {
      title: 'How to use this app',
      html: '<p>This app computes welfare-maximizing transport networks with ' +
        '<code>OptimalTransportNetworks.jl</code> (Fajgelbaum &amp; Schaal 2020, <i>Econometrica</i>).</p>' +
        '<h4>1 — Upload a network</h4>' +
        '<p>Upload a nodes CSV and an edges CSV (see the ⓘ icons next to the upload fields for the ' +
        'required columns), or click <b>Load example</b>.</p>' +
        '<h4>2 — Set parameters</h4>' +
        '<p>Adjust the model parameters, the infrastructure budget K, and the solver controls. ' +
        'Every section has an ⓘ icon explaining its fields.</p>' +
        '<h4>3 — Run</h4>' +
        '<p>Click <b>Run Optimization</b>. The live solver output appears in a console at the bottom ' +
        'of the map. When it finishes, choose the edge and node outputs to visualize in the layers ' +
        'panel (top right) and download the result CSVs from the sidebar.</p>' +
        '<div class="note">One solve runs at a time. The problem is non-convex when gamma &gt; beta — ' +
        'enable simulated annealing in that case.</div>'
    },
    'nodes-csv': {
      title: 'Nodes CSV format',
      html: '<table><tr><th>column</th><th>required</th><th>description</th></tr>' +
        '<tr><td><code>node</code></td><td>yes</td><td>integer id, consecutive 1..J</td></tr>' +
        '<tr><td><code>lon</code>, <code>lat</code></td><td>yes</td><td>WGS84 coordinates</td></tr>' +
        '<tr><td><code>population</code></td><td>yes</td><td>population / labor L<sub>j</sub></td></tr>' +
        '<tr><td><code>productivity</code></td><td>yes</td><td>productivity Z<sub>j</sub> of the node’s good</td></tr>' +
        '<tr><td><code>housing</code></td><td>no</td><td>housing supply H<sub>j</sub>; default population × (1 − alpha)</td></tr>' +
        '<tr><td><code>product</code></td><td>no</td><td>integer good index 1..N for multi-good economies (one good per node)</td></tr>' +
        '<tr><td><code>name</code></td><td>no</td><td>label shown in map popups</td></tr></table>' +
        '<div class="note">Column names are case-sensitive. Extra columns are kept and shown in popups.</div>'
    },
    'edges-csv': {
      title: 'Edges CSV format',
      html: '<p>One row per <b>undirected</b> edge:</p>' +
        '<table><tr><th>column</th><th>required</th><th>description</th></tr>' +
        '<tr><td><code>from</code>, <code>to</code></td><td>yes</td><td>node ids</td></tr>' +
        '<tr><td><code>delta_i</code></td><td>yes</td><td>building cost per unit of infrastructure I</td></tr>' +
        '<tr><td><code>delta_tau</code></td><td>yes</td><td>iceberg transport friction</td></tr>' +
        '<tr><td><code>Ijk</code></td><td>yes</td><td>existing infrastructure (e.g. speed in km/h)</td></tr>' +
        '<tr><td><code>Il</code></td><td>no</td><td>lower bound on I (default: Ijk, i.e. no downgrading)</td></tr>' +
        '<tr><td><code>Iu</code></td><td>no</td><td>upper bound on I (default: unbounded); also the cap in the percent-upgraded output</td></tr>' +
        '<tr><td><code>geometry</code></td><td>no</td><td>WKT <code>LINESTRING (lon lat, lon lat, ...)</code> used to draw the edge</td></tr></table>' +
        '<div class="note">Each edge should be listed once; both directions are treated symmetrically.</div>'
    },
    params: {
      title: 'Model parameters',
      html: '<p>Per-capita utility from traded goods c and housing h:</p>' +
        '<div class="eq">u(c<sub>j</sub>, h<sub>j</sub>) = ' +
        '( c<sub>j</sub><sup>α</sup> h<sub>j</sub><sup>1−α</sup> )<sup>1−ρ</sup> / (1 − ρ)</div>' +
        '<p>Per-unit transport cost of shipping the flow Q<sub>jk</sub> over a link with ' +
        'infrastructure I<sub>jk</sub> (iceberg, paid in goods):</p>' +
        '<div class="eq">τ<sub>jk</sub> = δ<sup>τ</sup><sub>jk</sub> · ' +
        'Q<sub>jk</sub><sup>β</sup> / I<sub>jk</sub><sup>γ</sup></div>' +
        '<h4>alpha (α)</h4><p>Cobb-Douglas share of traded goods in utility (vs. housing), in (0, 1).</p>' +
        '<h4>beta (β)</h4><p>Congestion elasticity: transport costs rise with the flow Q<sup>β</sup>.</p>' +
        '<h4>gamma (γ)</h4><p>Elasticity of transport costs with respect to infrastructure. ' +
        'If γ &gt; β the planner’s problem is non-convex (increasing returns to networks) — ' +
        'enable annealing.</p>' +
        '<h4>rho (ρ)</h4><p>Curvature of utility (inequality aversion). 0 = utilitarian planner; ' +
        'larger values favor equalizing consumption across locations. Note: with ρ &gt; 1 utility ' +
        'levels are negative — gains are still computed correctly.</p>'
    },
    budget: {
      title: 'Infrastructure budget K',
      html: '<p>The planner builds the network subject to the resource constraint</p>' +
        '<div class="eq">Σ<sub>jk</sub> δ<sup>I</sup><sub>jk</sub> · I<sub>jk</sub> ≤ K</div>' +
        '<p>summed over the (undirected) edge list, with <code>delta_i</code> = δ<sup>I</sup> ' +
        'in the units of your edges CSV.</p>' +
        '<p>After loading a network the sidebar shows K₀, the cost of the <i>existing</i> network, ' +
        'and prefills K with 1.2 × K₀ (i.e. 20% new investment).</p>' +
        '<div class="note">With the default no-downgrading bounds, K = K₀ leaves the network ' +
        'unchanged — only the budget above K₀ is effectively invested. Internally the package uses ' +
        'the symmetric-matrix convention (2K); the app converts automatically.</div>'
    },
    solver: {
      title: 'Solver controls',
      html: '<h4>tol</h4><p>Convergence tolerance of the outer fixed-point iteration on the ' +
        'infrastructure matrix.</p>' +
        '<h4>min_iter / max_iter</h4><p>Minimum and maximum number of outer iterations. Each ' +
        'iteration solves the full trade equilibrium on the current network, then updates the ' +
        'network from the optimality condition.</p>' +
        '<div class="note">Progress appears in the console and next to the Run button.</div>'
    },
    advanced: {
      title: 'Advanced options',
      html: '<h4>sigma (σ)</h4><p>Elasticity of substitution across goods in the CES ' +
        'consumption aggregate:</p>' +
        '<div class="eq">c<sub>j</sub> = ( Σ<sub>n</sub> (c<sub>j</sub><sup>n</sup>)' +
        '<sup>(σ−1)/σ</sup> )<sup>σ/(σ−1)</sup></div>' +
        '<h4>a</h4><p>Labor curvature in production (must be ≤ 1 for convexity):</p>' +
        '<div class="eq">Y<sub>j</sub><sup>n</sup> = Z<sub>j</sub><sup>n</sup> · ' +
        '(L<sub>j</sub><sup>n</sup>)<sup>a</sup></div>' +
        '<h4>nu (ν)</h4><p>Substitution elasticity between goods in the congestion cost ' +
        '(cross-good congestion only; must be ≥ 1) — transport costs then depend on the ' +
        'aggregate flow</p>' +
        '<div class="eq">( Σ<sub>n</sub> m<sub>n</sub> (Q<sub>jk</sub><sup>n</sup>)<sup>ν</sup> )<sup>1/ν</sup></div>' +
        '<h4>Labor mobility</h4><p>If on, labor relocates freely to equalize utility.</p>' +
        '<h4>Cross-good congestion</h4><p>Goods share road capacity (congest each other).</p>' +
        '<h4>Simulated annealing</h4><p>Refines the non-convex case (gamma &gt; beta) by perturbing ' +
        'the network topology.</p>' +
        '<h4>Duality solver</h4><p>Fastest inner solver; used automatically when labor is fixed ' +
        'and beta ≤ 1.</p>' +
        '<h4>Baseline comparison run</h4><p>First solves the allocation on the <i>existing</i> ' +
        'network, enabling welfare/consumption gain outputs.</p>' +
        '<h4>Full Ipopt output</h4><p>Streams the complete Ipopt log to the console instead of ' +
        'only the outer iterations.</p>' +
        '<h4>Allow downgrading</h4><p>Sets the default lower bound to 0 instead of the current ' +
        'Ijk, letting the planner move existing infrastructure elsewhere.</p>' +
        '<h4>Productivity floor</h4><p>Floors the whole productivity matrix at ' +
        'Z<sub>jn</sub> ≥ 10<sup>−3</sup>, so every node can produce a little of every good ' +
        '(the CEMAC study\'s regularization — keeps prices of scarce goods bounded and helps ' +
        'the solver converge on large multi-good networks).</p>' +
        '<h4>Ipopt linear solver</h4><p>MUMPS is bundled; <code>ma57</code>/<code>ma86</code> ' +
        'are substantially faster and more robust on large problems but require a licensed HSL ' +
        'library (auto-detected from <code>OTN_HSL_LIB</code>, <code>/usr/local/lib</code>, or ' +
        'Julia artifacts; silently falls back to MUMPS if not found).</p>'
    },
    outputs: {
      title: 'Outputs',
      html: '<h4>Edge outputs</h4>' +
        '<ul><li><b>Final infrastructure (Ijk)</b> — the optimized network.</li>' +
        '<li><b>Infrastructure increase</b> — max(Ijk − initial, 0).</li>' +
        '<li><b>Percent upgraded</b> — (Ijk − initial)/(Iu − initial) × 100, clamped to [0, 100].</li>' +
        '<li><b>Flows</b> — goods shipped over each edge (total and per good).</li></ul>' +
        '<h4>Node outputs</h4>' +
        '<ul><li>Utility u<sub>j</sub>, consumption c<sub>j</sub>/C<sub>j</sub>, price index PC<sub>j</sub>, ' +
        'labor L<sub>j</sub>, production Y<sub>j</sub>.</li>' +
        '<li>With a baseline run: percentage gains vs. the existing network.</li></ul>' +
        '<div class="note">Edge values symmetrize both directions as (M[i,j] + M[j,i])/2, matching ' +
        'the research-code convention. Results are downloadable as CSVs from the sidebar.</div>'
    }
  };

  function openInfo(key) {
    var item = INFO[key];
    if (!item) return;
    document.getElementById('info-title').textContent = item.title;
    document.getElementById('info-body').innerHTML = item.html;
    document.getElementById('info-modal').classList.remove('hidden');
  }

  function closeInfo() {
    document.getElementById('info-modal').classList.add('hidden');
  }

  /* ------------------------------------------------------------------ map */

  function googleLayer(lyrs) {
    return L.tileLayer('https://mt{s}.google.com/vt/lyrs=' + lyrs + '&x={x}&y={y}&z={z}', {
      subdomains: '0123',
      maxZoom: 20,
      attribution: '&copy; Google'
    });
  }

  function initMap() {
    S.renderer = L.canvas({ padding: 0.4 });
    S.map = L.map('map', { zoomControl: false, preferCanvas: true })
      .setView([4.5, 12.5], 5);

    var P = function (name) { return L.tileLayer.provider(name); };
    S.baseLayers = {
      'CartoDB Positron': P('CartoDB.Positron'),
      'CartoDB DarkMatter': P('CartoDB.DarkMatter'),
      'OpenStreetMap': P('OpenStreetMap.Mapnik'),
      'OpenTopoMap': P('OpenTopoMap'),
      'Esri WorldStreetMap': P('Esri.WorldStreetMap'),
      'Esri WorldTopoMap': P('Esri.WorldTopoMap'),
      'Esri WorldImagery': P('Esri.WorldImagery'),
      'Google Maps': googleLayer('m'),
      'Google Terrain': googleLayer('p')
    };
    S.currentBase = S.baseLayers['CartoDB Positron'].addTo(S.map);
    L.control.scale({ metric: true, imperial: false, position: 'bottomleft' }).addTo(S.map);

    var sel = document.getElementById('basemap-select');
    Object.keys(S.baseLayers).forEach(function (name) {
      var o = document.createElement('option');
      o.value = name;
      o.textContent = name;
      sel.appendChild(o);
    });
    sel.addEventListener('change', function (e) {
      S.map.removeLayer(S.currentBase);
      S.currentBase = S.baseLayers[e.target.value].addTo(S.map);
    });
  }

  /* --------------------------------------------------------------- scales */

  function metricByKey(list, key) {
    if (!list) return null;
    for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i];
    return null;
  }

  function makeScale(metric) {
    var lo = metric.min, hi = metric.max;
    if (metric.key === 'perc_upgraded') { lo = 0; hi = 100; }
    if (metric.diverging) {
      var m = Math.max(Math.abs(lo), Math.abs(hi));
      lo = -m; hi = m;
    }
    if (!(hi > lo)) hi = lo + 1e-9;
    var pal = PALETTES[metric.palette] || PALETTES.viridis;
    return { scale: chroma.scale(pal).domain([lo, hi]), lo: lo, hi: hi, pal: pal };
  }

  function norm(v, lo, hi) {
    var t = (v - lo) / (hi - lo);
    return t < 0 ? 0 : (t > 1 ? 1 : t);
  }

  /* ------------------------------------------------------------ rendering */

  function fmt(v) {
    if (v === null || v === undefined) return '–';
    if (typeof v !== 'number') return String(v);
    if (v === 0) return '0';
    var av = Math.abs(v);
    if (av >= 1e6 || av < 1e-3) return v.toExponential(2);
    return String(parseFloat(v.toPrecision(4)));
  }

  function popupHtml(props, title) {
    var rows = '';
    Object.keys(props).forEach(function (k) {
      if (props[k] === null || props[k] === undefined) return;
      rows += '<tr><td>' + k + '</td><td>' + fmt(props[k]) + '</td></tr>';
    });
    return '<div class="otn-popup"><b>' + title + '</b><table>' + rows + '</table></div>';
  }

  function renderEdges() {
    if (S.edgeLayer) { S.map.removeLayer(S.edgeLayer); S.edgeLayer = null; }
    if (!S.data || !S.data.edges || !S.edgesVisible) return;
    var metric = metricByKey(S.data.edge_metrics, S.edgeMetric);
    var sc = metric ? makeScale(metric) : null;

    S.edgeLayer = L.geoJSON(S.data.edges, {
      renderer: S.renderer,
      style: function (f) {
        var st = { color: '#888', weight: 2, opacity: 0.9 };
        if (sc) {
          var v = f.properties[metric.key];
          if (typeof v === 'number') {
            st.color = sc.scale(v).hex();
            st.weight = 1.5 + 5 * norm(v, sc.lo, sc.hi);
          } else {
            st.color = '#bbb'; st.weight = 1; st.dashArray = '3,4';
          }
        }
        return st;
      },
      onEachFeature: function (f, layer) {
        layer.bindPopup(function () {
          return popupHtml(f.properties, 'Edge ' + f.properties.from + ' — ' + f.properties.to);
        }, { maxWidth: 340 });
      }
    }).addTo(S.map);
  }

  function renderNodes() {
    if (S.nodeLayer) { S.map.removeLayer(S.nodeLayer); S.nodeLayer = null; }
    if (!S.data || !S.data.nodes || !S.nodesVisible) return;
    var metric = S.nodeMetric === 'none' ? null : metricByKey(S.data.node_metrics, S.nodeMetric);
    var sc = metric ? makeScale(metric) : null;

    S.maxPop = 1;
    S.data.nodes.features.forEach(function (f) {
      var p = f.properties.population;
      if (typeof p === 'number' && p > S.maxPop) S.maxPop = p;
    });

    S.nodeLayer = L.geoJSON(S.data.nodes, {
      pointToLayer: function (f, latlng) {
        var p = f.properties.population || 0;
        var r = 3 + 11 * Math.sqrt(p / S.maxPop);
        var color = '#3a6ea5';
        if (sc) {
          var v = f.properties[metric.key];
          color = (typeof v === 'number') ? sc.scale(v).hex() : '#bbb';
        }
        return L.circleMarker(latlng, {
          renderer: S.renderer,
          radius: r,
          fillColor: color,
          fillOpacity: 0.85,
          color: '#ffffff',
          weight: 1.2
        });
      },
      onEachFeature: function (f, layer) {
        var title = f.properties.name ? f.properties.name : 'Node ' + f.properties.node;
        layer.bindPopup(function () { return popupHtml(f.properties, title); }, { maxWidth: 340 });
      }
    }).addTo(S.map);
  }

  /* ----------------------------------------------------- selectors/legend */

  function fillSelect(sel, metrics, current, withNone) {
    sel.innerHTML = '';
    if (withNone) {
      var o = document.createElement('option');
      o.value = 'none'; o.textContent = '— size by population —';
      sel.appendChild(o);
    }
    (metrics || []).forEach(function (m) {
      var o = document.createElement('option');
      o.value = m.key; o.textContent = m.label;
      sel.appendChild(o);
    });
    var values = Array.prototype.map.call(sel.options, function (o) { return o.value; });
    sel.value = values.indexOf(current) >= 0 ? current : (values[0] || '');
    return sel.value;
  }

  function updateSelectors() {
    var card = document.getElementById('layers-card');
    if (!S.data || !S.data.has_network) { card.classList.add('hidden'); return; }
    card.classList.remove('hidden');
    S.edgeMetric = fillSelect(document.getElementById('edge-metric'), S.data.edge_metrics, S.edgeMetric, false);
    S.nodeMetric = fillSelect(document.getElementById('node-metric'), S.data.node_metrics, S.nodeMetric, true);

    var sm = document.getElementById('map-summary');
    var s = S.data.summary || {};
    var parts = [];
    if (s.welfare !== undefined && s.welfare !== null) parts.push('Welfare ' + fmt(s.welfare));
    if (s.welfare_gain_pct !== undefined && s.welfare_gain_pct !== null) parts.push('gain ' + fmt(s.welfare_gain_pct) + '%');
    sm.textContent = parts.join(' · ');
  }

  function legendBlock(metric) {
    var sc = makeScale(metric);
    var stops = sc.pal.map(function (c, i) {
      return c + ' ' + (i / (sc.pal.length - 1) * 100).toFixed(0) + '%';
    });
    var ticks = [0, 0.25, 0.5, 0.75, 1].map(function (p) {
      return '<span style="left:' + (p * 100) + '%">' + fmt(sc.lo + p * (sc.hi - sc.lo)) + '</span>';
    }).join('');
    return '<div class="legend-block">' +
      '<div class="legend-label">' + metric.label + '</div>' +
      '<div class="legend-bar" style="background:linear-gradient(to right,' + stops.join(',') + ')"></div>' +
      '<div class="legend-ticks">' + ticks + '</div>' +
      '</div>';
  }

  function updateLegend() {
    var el = document.getElementById('legend');
    var html = '';
    var em = S.edgesVisible ? metricByKey(S.data && S.data.edge_metrics, S.edgeMetric) : null;
    if (em) html += legendBlock(em);
    var nm = (S.nodesVisible && S.nodeMetric !== 'none') ?
      metricByKey(S.data && S.data.node_metrics, S.nodeMetric) : null;
    if (nm) html += legendBlock(nm);
    el.innerHTML = html;
    el.classList.toggle('hidden', html === '');
  }

  function redraw() {
    renderEdges();
    renderNodes();
    updateLegend();
  }

  /* -------------------------------------------------------------- console */

  function setConsoleOpen(open) {
    S.consoleOpen = open;
    document.getElementById('console-panel').classList.toggle('hidden', !open);
    document.getElementById('console-reopen').classList.toggle('hidden', open || S.consoleCursor === 0);
  }

  function appendConsole(lines) {
    if (!lines.length) return;
    var body = document.getElementById('console-body');
    var nearBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 60;
    body.textContent += lines.join('\n') + '\n';
    var txt = body.textContent;
    var cnt = 0, idx = txt.length;
    for (var i = txt.length - 1; i >= 0 && cnt < 4000; i--) if (txt[i] === '\n') { cnt++; idx = i; }
    if (cnt >= 4000) body.textContent = txt.slice(idx + 1);
    if (nearBottom) body.scrollTop = body.scrollHeight;
  }

  function pollConsole() {
    fetch('/api/console?after=' + S.consoleCursor)
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (d.total < S.consoleCursor) { // server restarted numbering (new run)
          S.consoleCursor = 0;
          document.getElementById('console-body').textContent = '';
          return;
        }
        appendConsole(d.lines || []);
        S.consoleCursor = d.total;
        document.getElementById('console-status').textContent = d.running ? 'running…' : '';
      })
      .catch(function () {});
  }

  /* -------------------------------------------------------------- polling */

  function fetchData() {
    fetch('/api/mapdata')
      .then(function (r) { return r.json(); })
      .then(function (d) {
        S.data = d;
        S.version = d.version;
        updateSelectors();
        redraw();
        if (d.has_network && d.nodes && d.nodes.features.length) {
          var latlngs = d.nodes.features.map(function (f) {
            return [f.geometry.coordinates[1], f.geometry.coordinates[0]];
          });
          var key = JSON.stringify([latlngs.length, latlngs[0], latlngs[latlngs.length - 1]]);
          if (key !== S.bboxKey) {
            S.bboxKey = key;
            S.map.fitBounds(L.latLngBounds(latlngs).pad(0.15));
          }
        }
      })
      .catch(function () {});
  }

  function tick() {
    fetch('/api/version')
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (d.running && !S.running) { // solve just started
          document.getElementById('console-body').textContent = '';
          S.consoleCursor = 0;
          setConsoleOpen(true);
        }
        S.running = d.running;
        if (d.running || S.consoleOpen) pollConsole();
        if (d.version !== S.version) fetchData();
      })
      .catch(function () {});
  }

  /* ----------------------------------------------------------------- init */

  function on(id, ev, fn) { document.getElementById(id).addEventListener(ev, fn); }

  function init() {
    initMap();

    on('edge-metric', 'change', function (e) { S.edgeMetric = e.target.value; redraw(); });
    on('node-metric', 'change', function (e) { S.nodeMetric = e.target.value; redraw(); });
    on('edges-visible', 'change', function (e) { S.edgesVisible = e.target.checked; redraw(); });
    on('nodes-visible', 'change', function (e) { S.nodesVisible = e.target.checked; redraw(); });
    on('zoom-in', 'click', function () { S.map.zoomIn(); });
    on('zoom-out', 'click', function () { S.map.zoomOut(); });

    // sidebar collapse
    var shell = document.getElementById('otn-shell');
    function setSidebar(open) {
      shell.classList.toggle('sb-collapsed', !open);
      document.getElementById('sidebar-reopen').classList.toggle('hidden', open);
      setTimeout(function () { S.map.invalidateSize(); }, 330);
    }
    on('sidebar-collapse', 'click', function () { setSidebar(false); });
    on('sidebar-reopen', 'click', function () { setSidebar(true); });

    // console
    on('console-close', 'click', function () { setConsoleOpen(false); });
    on('console-reopen', 'click', function () { setConsoleOpen(true); });
    on('console-copy', 'click', function () {
      var txt = document.getElementById('console-body').textContent;
      if (navigator.clipboard) navigator.clipboard.writeText(txt);
    });

    // info modals: delegated so it works for icons inside the Vue-managed sidebar
    document.addEventListener('click', function (e) {
      var t = e.target.closest ? e.target.closest('.info-icon') : null;
      if (t && t.dataset.info) openInfo(t.dataset.info);
    });
    on('info-close', 'click', closeInfo);
    on('info-overlay', 'click', closeInfo);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeInfo();
    });

    // file uploads: the inputs live inside the Vue-managed sidebar and are
    // conditionally rendered, so use a delegated change handler
    document.addEventListener('change', function (e) {
      var t = e.target;
      if (!t || !t.matches || !t.matches('#nodes-file, #edges-file')) return;
      if (!t.files || !t.files.length) return;
      var endpoint = t.id === 'nodes-file' ? '/api/upload/nodes' : '/api/upload/edges';
      var fd = new FormData();
      fd.append('file', t.files[0], t.files[0].name);
      fetch(endpoint, { method: 'POST', body: fd }).catch(function () {});
      t.value = '';
    });

    fetchData();
    setInterval(tick, 600);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
