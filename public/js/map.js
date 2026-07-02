/* Leaflet map module for the Optimal Transport Networks app.
 *
 * Lives entirely outside the Vue/Stipple-managed DOM. Talks to the backend via:
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
    data: null,
    version: -1,
    bboxKey: '',
    edgeMetric: null,
    nodeMetric: 'none',
    consoleCursor: 0,
    consoleOpen: false,
    consoleUserClosed: false,
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
    S.map = L.map('map', { zoomControl: true, preferCanvas: true })
      .setView([4.5, 12.5], 5);

    var P = function (name) { return L.tileLayer.provider(name); };
    var bases = {
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
    bases['CartoDB Positron'].addTo(S.map);
    L.control.layers(bases, {}, { position: 'topright', collapsed: true }).addTo(S.map);
    L.control.scale({ metric: true, imperial: false, position: 'bottomleft' }).addTo(S.map);
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
    if (av >= 1e6 || av < 1e-3) return v.toExponential(3);
    return String(parseFloat(v.toPrecision(5)));
  }

  function labelFor(key) {
    var m = metricByKey(S.data && S.data.edge_metrics, key) ||
            metricByKey(S.data && S.data.node_metrics, key);
    return m ? m.label : key;
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
    if (!S.data || !S.data.edges) return;
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
    if (!S.data || !S.data.nodes) return;
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
          if (typeof v === 'number') color = sc.scale(v).hex();
          else color = '#bbb';
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
      o.value = 'none'; o.textContent = '— none —';
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
    var card = document.getElementById('output-card');
    if (!S.data || !S.data.has_network) { card.classList.add('hidden'); return; }
    card.classList.remove('hidden');
    var es = document.getElementById('edge-metric');
    var ns = document.getElementById('node-metric');
    S.edgeMetric = fillSelect(es, S.data.edge_metrics, S.edgeMetric, false);
    S.nodeMetric = fillSelect(ns, S.data.node_metrics, S.nodeMetric, true);

    var sm = document.getElementById('map-summary');
    var s = S.data.summary || {};
    var parts = [];
    if (s.welfare !== undefined && s.welfare !== null) parts.push('Welfare ' + fmt(s.welfare));
    if (s.welfare_gain_pct !== undefined && s.welfare_gain_pct !== null) parts.push('gain ' + fmt(s.welfare_gain_pct) + '%');
    sm.textContent = parts.join(' · ');
  }

  function legendBlock(metric) {
    var sc = makeScale(metric);
    var grad = 'linear-gradient(to right, ' + sc.pal.join(', ') + ')';
    return '<div class="legend-block">' +
      '<div class="legend-label">' + metric.label + '</div>' +
      '<div class="legend-bar" style="background:' + grad + '"></div>' +
      '<div class="legend-ticks"><span>' + fmt(sc.lo) + '</span><span>' + fmt(sc.hi) + '</span></div>' +
      '</div>';
  }

  function updateLegend() {
    var el = document.getElementById('legend');
    var html = '';
    var em = metricByKey(S.data && S.data.edge_metrics, S.edgeMetric);
    if (em) html += legendBlock(em);
    var nm = S.nodeMetric === 'none' ? null : metricByKey(S.data && S.data.node_metrics, S.nodeMetric);
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
    // trim the DOM copy to ~4000 lines
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
          S.consoleUserClosed = false;
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

  function init() {
    initMap();

    document.getElementById('edge-metric').addEventListener('change', function (e) {
      S.edgeMetric = e.target.value; redraw();
    });
    document.getElementById('node-metric').addEventListener('change', function (e) {
      S.nodeMetric = e.target.value; redraw();
    });
    document.getElementById('console-close').addEventListener('click', function () {
      S.consoleUserClosed = true; setConsoleOpen(false);
    });
    document.getElementById('console-reopen').addEventListener('click', function () {
      setConsoleOpen(true);
    });
    document.getElementById('console-copy').addEventListener('click', function () {
      var txt = document.getElementById('console-body').textContent;
      if (navigator.clipboard) navigator.clipboard.writeText(txt);
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
