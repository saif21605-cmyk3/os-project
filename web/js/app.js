/* =========================
   System Monitor Dashboard
   - Live + Alerts + History chart/table
   - Fixed: canvas sizing (DPR), strong stroke, separate inFlight, better parsing
   ========================= */

let paused = false;

const HISTORY_LEN = 40;
const histCpu = [];
const histGpu = [];
const histCpuTemp = [];

let prevNet = null; // {rx, tx, t}
let timer = null;

let lastTimestamp = null;

// ✅ separate inFlight (otherwise history calls get skipped a lot)
let inFlightLatest = false;
let inFlightHistory = false;

function $(id) { return document.getElementById(id); }
function clamp(n, a, b) { return Math.max(a, Math.min(b, n)); }

function fmtBytes(n) {
  if (n == null || isNaN(n)) return "N/A";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0, v = Number(n);
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(i === 0 ? 0 : 2)} ${units[i]}`;
}

function fmtNum(n, digits = 1) {
  if (n == null || isNaN(n)) return "N/A";
  return Number(n).toFixed(digits);
}

function row(k, v) {
  return `<div class="row"><div class="k">${k}</div><div class="v">${v}</div></div>`;
}

function setBadge(el, text, level) {
  if (!el) return;
  el.textContent = text;
  el.classList.remove("good", "warn", "bad", "ghost");
  if (level) el.classList.add(level);
}

function healthColor(health) {
  const h = String(health || "").toUpperCase();
  if (h.includes("OK")) return "good";
  if (h.includes("POWER") || h.includes("LIMIT")) return "warn";
  if (h.includes("THERMAL") || h.includes("SLOW") || h.includes("BAD")) return "bad";
  return "";
}

function tempColor(temp) {
  const v = Number(temp);
  if (isNaN(v)) return "";
  if (v >= 90) return "bad";
  if (v >= 75) return "warn";
  return "good";
}

/* ---------- sparkline (summary) ---------- */
function spark(canvas, arr) {
  if (!canvas) return;
  const ctx = canvas.getContext("2d");

  // IMPORTANT: use actual canvas size (attributes) here
  const w = canvas.width, h = canvas.height;
  ctx.clearRect(0, 0, w, h);
  if (!arr.length) return;

  const max = 100, min = 0;
  const step = w / Math.max(1, arr.length - 1);

  // ✅ stronger fallback color
  const strokeVar = getComputedStyle(document.documentElement).getPropertyValue("--spark")?.trim();
  const stroke = strokeVar || "rgba(234,240,255,0.9)";

  ctx.lineWidth = 2;
  ctx.strokeStyle = stroke;

  // baseline
  ctx.globalAlpha = 0.25;
  ctx.beginPath();
  ctx.moveTo(0, h - 1);
  ctx.lineTo(w, h - 1);
  ctx.stroke();

  // line
  ctx.globalAlpha = 1;
  ctx.beginPath();
  arr.forEach((v, i) => {
    const x = i * step;
    const y = h - ((clamp(v, min, max) - min) / (max - min)) * (h - 6) - 3;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  });
  ctx.stroke();
}

/* ---------- API ---------- */
async function fetchJson(url, kind /* "latest"|"history" */) {
  const isLatest = kind === "latest";
  const inflight = isLatest ? inFlightLatest : inFlightHistory;
  if (inflight) return null;

  if (isLatest) inFlightLatest = true;
  else inFlightHistory = true;

  const ctrl = new AbortController();
  const timeout = setTimeout(() => ctrl.abort(), 2500);

  try {
    const res = await fetch(`${url}${url.includes("?") ? "&" : "?"}ts=${Date.now()}`, {
      cache: "no-store",
      signal: ctrl.signal
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(timeout);
    if (isLatest) inFlightLatest = false;
    else inFlightHistory = false;
  }
}

async function fetchLatest() {
  return await fetchJson("/api/latest", "latest");
}

async function fetchHistory(n = 50) {
  return await fetchJson(`/api/history?n=${encodeURIComponent(n)}`, "history");
}

/* ---------- helpers for weird types ---------- */
function toNum(v) {
  if (v == null) return NaN;
  if (typeof v === "string") {
    const s = v.trim().replace("%", "");
    const n = parseFloat(s);
    return Number.isFinite(n) ? n : NaN;
  }
  const n = Number(v);
  return Number.isFinite(n) ? n : NaN;
}

function pick(obj, keys) {
  for (const k of keys) {
    if (obj && obj[k] != null) return obj[k];
  }
  return null;
}

function normRec(x) {
  const cpu = toNum(pick(x, ["cpu_usage_percent", "cpu_percent", "cpu"]));
  const ram = toNum(pick(x, ["mem_used_percent", "ram_used_percent", "ram_percent"]));
  const disk = toNum(pick(x, ["disk_root_used_percent_num", "disk_used_percent_num", "disk_percent", "disk_root_used_percent"]));
  const gpu = toNum(pick(x, ["gpu_util_percent", "gpu_usage_percent", "gpu"]));

  return {
    timestamp: pick(x, ["timestamp", "time", "ts"]) ?? "—",
    cpu_usage_percent: cpu,
    mem_used_percent: ram,
    disk_root_used_percent_num: disk,
    gpu_util_percent: gpu
  };
}

/* ---------- network rate ---------- */
function computeNetRates(d) {
  const srx = Number(d.net_rx_bytes_per_sec);
  const stx = Number(d.net_tx_bytes_per_sec);

  if (!isNaN(srx) && !isNaN(stx)) {
    return { rxps: Math.max(0, srx), txps: Math.max(0, stx) };
  }

  const t = Date.now();
  const rx = Number(d.net_rx_bytes);
  const tx = Number(d.net_tx_bytes);

  if (!prevNet || isNaN(rx) || isNaN(tx)) {
    prevNet = { rx, tx, t };
    return { rxps: 0, txps: 0 };
  }

  const dt = (t - prevNet.t) / 1000;
  const rxps = dt > 0 ? (rx - prevNet.rx) / dt : 0;
  const txps = dt > 0 ? (tx - prevNet.tx) / dt : 0;

  prevNet = { rx, tx, t };
  return { rxps: Math.max(0, rxps), txps: Math.max(0, txps) };
}

/* ---------- Alerts ---------- */
function renderAlerts(d) {
  const box = $("alertsBox");
  const badge = $("alertsBadge");
  if (!box || !badge) return;

  const alerts = Array.isArray(d.alerts) ? d.alerts : [];
  const count = Number(d.alerts_count);
  const n = Number.isFinite(count) ? count : alerts.length;

  badge.textContent = `${n} alerts`;
  badge.classList.remove("good", "warn", "bad", "ghost");
  badge.classList.add(n > 0 ? "warn" : "good");

  if (alerts.length === 0) {
    box.innerHTML = row("Status", "No active alerts ✅");
    return;
  }

  const list = alerts.slice(-10).reverse();
  box.innerHTML = list.map((a, i) => row(`Alert #${i + 1}`, a)).join("");
}

/* ---------- History table ---------- */
function renderHistoryTable(items) {
  const tbody = $("histTable")?.querySelector("tbody");
  if (!tbody) return;

  tbody.innerHTML = "";
  const ordered = items.slice().reverse(); // newest first

  ordered.slice(0, 40).forEach(raw => {
    const x = normRec(raw);
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${x.timestamp ?? "—"}</td>
      <td>${Number.isFinite(x.cpu_usage_percent) ? fmtNum(x.cpu_usage_percent, 1) : "N/A"}</td>
      <td>${Number.isFinite(x.mem_used_percent) ? fmtNum(x.mem_used_percent, 0) : "N/A"}</td>
      <td>${Number.isFinite(x.disk_root_used_percent_num) ? fmtNum(x.disk_root_used_percent_num, 0) : "N/A"}</td>
      <td>${Number.isFinite(x.gpu_util_percent) ? fmtNum(x.gpu_util_percent, 0) : "N/A"}</td>
    `;
    tbody.appendChild(tr);
  });
}

/* ---------- Canvas sizing (CRITICAL FIX) ---------- */
function fitCanvas(canvas, minH = 220) {
  if (!canvas) return false;

  // ensure it has visible height even لو CSS ناسي
  if (!canvas.style.height) canvas.style.height = `${minH}px`;
  if (!canvas.style.width) canvas.style.width = "100%";

  const rect = canvas.getBoundingClientRect();
  if (rect.width < 10 || rect.height < 10) return false;

  const dpr = window.devicePixelRatio || 1;
  const w = Math.round(rect.width * dpr);
  const h = Math.round(rect.height * dpr);

  if (canvas.width !== w) canvas.width = w;
  if (canvas.height !== h) canvas.height = h;

  const ctx = canvas.getContext("2d");
  // draw using CSS pixels
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return true;
}

/* ---------- History chart ---------- */
function drawHistoryChart(canvas, items) {
  if (!canvas) return;
  const ok = fitCanvas(canvas, 240);
  if (!ok) return;

  const ctx = canvas.getContext("2d");
  const rect = canvas.getBoundingClientRect();
  const w = rect.width, h = rect.height;

  ctx.clearRect(0, 0, w, h);

  const norm = (items || []).map(normRec);
  if (norm.length < 2) {
    ctx.globalAlpha = 0.9;
    ctx.font = "12px ui-sans-serif, system-ui";
    ctx.fillText("Not enough history yet…", 12, 18);
    ctx.globalAlpha = 1;
    return;
  }

  // ✅ stronger stroke fallback
  const strokeVar = getComputedStyle(document.documentElement).getPropertyValue("--spark")?.trim();
  const stroke = strokeVar || "rgba(234,240,255,0.9)";

  const pad = 16;
  const innerW = w - pad * 2;
  const innerH = h - pad * 2;

  function xAt(i) { return pad + (i / (norm.length - 1)) * innerW; }
  function yAt(v) {
    const vv = clamp(Number.isFinite(v) ? v : 0, 0, 100);
    return pad + (1 - vv / 100) * innerH;
  }

  // grid
  ctx.globalAlpha = 0.18;
  ctx.lineWidth = 1;
  ctx.strokeStyle = stroke;
  for (let p = 0; p <= 100; p += 25) {
    const y = yAt(p);
    ctx.beginPath();
    ctx.moveTo(pad, y);
    ctx.lineTo(pad + innerW, y);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;

  const cpu = norm.map(x => x.cpu_usage_percent);
  const ram = norm.map(x => x.mem_used_percent);
  const disk = norm.map(x => x.disk_root_used_percent_num);
  const gpu = norm.map(x => x.gpu_util_percent);

  function drawSeries(arr, alpha = 1, dash = []) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.setLineDash(dash);
    ctx.lineWidth = 2;
    ctx.strokeStyle = stroke;
    ctx.beginPath();
    arr.forEach((v, i) => {
      const x = xAt(i);
      const y = yAt(v);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.stroke();
    ctx.restore();
  }

  // series
  drawSeries(cpu, 1.0, []);        // CPU solid
  drawSeries(ram, 0.80, [6, 4]);    // RAM dashed
  drawSeries(disk, 0.65, [2, 4]);    // Disk dotted
  drawSeries(gpu, 0.55, [10, 6]);   // GPU long dash

  // legend
  ctx.globalAlpha = 0.85;
  ctx.font = "12px ui-sans-serif, system-ui";
  ctx.fillText("CPU (solid)  RAM (dash)  Disk (dot)  GPU (long-dash)", pad, h - 10);
  ctx.globalAlpha = 1;
}

/* ---------- Main render (latest) ---------- */
function render(d) {
  // avoid repaint if same timestamp
  if (d?.timestamp && d.timestamp === lastTimestamp) {
    $("pillStatus").textContent = paused ? "Paused" : "Live (no change)";
    $("pillStatus").style.borderColor = paused
      ? "rgba(148,163,184,0.25)"
      : "rgba(45,212,191,0.35)";
    return;
  }
  lastTimestamp = d?.timestamp ?? lastTimestamp;

  $("pillStatus").textContent = paused ? "Paused" : "Live";
  $("pillStatus").style.borderColor = paused
    ? "rgba(148,163,184,0.25)"
    : "rgba(45,212,191,0.35)";

  $("subtitle").textContent = `Last update: ${d.timestamp || "—"}`;

  // CPU summary
  const cpu = Number(d.cpu_usage_percent);
  $("sumCpu").textContent = isNaN(cpu) ? "—" : fmtNum(cpu, 1);

  histCpu.push(isNaN(cpu) ? 0 : clamp(cpu, 0, 100));
  while (histCpu.length > HISTORY_LEN) histCpu.shift();
  spark($("sparkCpu"), histCpu);

  // GPU summary
  const gpu = Number(d.gpu_util_percent);
  $("sumGpu").textContent = isNaN(gpu) ? "—" : fmtNum(gpu, 0);

  histGpu.push(isNaN(gpu) ? 0 : clamp(gpu, 0, 100));
  while (histGpu.length > HISTORY_LEN) histGpu.shift();
  spark($("sparkGpu"), histGpu);

  // RAM summary
  $("sumRam").textContent = d.mem_used_mb ?? "—";
  $("sumRamHint").textContent = `of ${d.mem_total_mb ?? "—"} MB`;

  // NET summary
  const rates = computeNetRates(d);
  $("sumNet").textContent = `${fmtBytes(rates.rxps)}/s`;
  $("sumNetHint").textContent = `RX ${fmtBytes(rates.rxps)}/s • TX ${fmtBytes(rates.txps)}/s`;

  // CPU card
  setBadge($("cpuTempBadge"), `Temp ${d.cpu_temp_c ?? "N/A"}°C`, tempColor(d.cpu_temp_c));
  setBadge($("cpuCoresBadge"), `${d.cpu_cores ?? "—"} cores`, "ghost");

  $("cpuBox").innerHTML =
    row("Usage", `${fmtNum(d.cpu_usage_percent, 1)} %`) +
    row("Load (1m)", d.cpu_load_1m ?? "—") +
    row("Load (5m)", d.cpu_load_5m ?? "—") +
    row("Load (15m)", d.cpu_load_15m ?? "—") +
    row("Freq", `${d.cpu_freq_ghz ?? "—"} GHz`);

  $("cpuModel").textContent = d.cpu_model ?? "—";

  // CPU Temp Chart
  const ctemp = Number(d.cpu_temp_c);
  histCpuTemp.push(isNaN(ctemp) ? 0 : ctemp);
  while (histCpuTemp.length > HISTORY_LEN) histCpuTemp.shift();
  spark($("chartCpuTemp"), histCpuTemp);

  // GPU card
  const gHealth = d.gpu_health ?? "unavailable";
  setBadge($("gpuHealthBadge"), gHealth, healthColor(gHealth));
  setBadge($("gpuHealthBadge"), gHealth, healthColor(gHealth));
  setBadge($("gpuPstateBadge"), d.gpu_pstate ?? "N/A", "ghost");
  $("gpuName").textContent = d.gpu_name ?? "—";

  $("gpuBox").innerHTML =
    row("Util", `${d.gpu_util_percent ?? "N/A"} %`) +
    row("Temp", `${d.gpu_temp_c ?? "N/A"} °C`) +
    row("Power", `${d.gpu_power_w ?? "N/A"} W`) +
    row("Fan", d.gpu_fan_percent ?? "N/A");

  $("gpuThrottle").textContent =
    `Thermal: ${d.gpu_throttle_thermal ?? "N/A"} • PowerCap: ${d.gpu_throttle_power_cap ?? "N/A"} • HW: ${d.gpu_throttle_hw_slowdown ?? "N/A"}`;

  // Memory card
  const total = Number(d.mem_total_mb);
  const used = Number(d.mem_used_mb);
  const pct = (total > 0 && !isNaN(used)) ? (used / total) * 100 : 0;
  $("memBar").style.width = `${clamp(pct, 0, 100)}%`;
  setBadge($("memBadge"), `${fmtNum(pct, 0)}% used`, pct >= 85 ? "bad" : (pct >= 70 ? "warn" : "good"));

  $("memBox").innerHTML =
    row("Total", `${d.mem_total_mb ?? "—"} MB`) +
    row("Used", `${d.mem_used_mb ?? "—"} MB`) +
    row("Available", `${d.mem_available_mb ?? "—"} MB`);

  // Disk card
  const smart = d.disk_smart_health ?? "N/A";
  setBadge($("diskSmartBadge"), smart === "N/A" ? "SMART N/A" : "SMART OK", smart === "N/A" ? "warn" : "good");
  setBadge($("diskRootBadge"), `Root ${d.disk_root_used_percent ?? "—"}`, "ghost");

  $("diskBox").innerHTML =
    row("Root Used", d.disk_root_used ?? "—") +
    row("Root Total", d.disk_root_total ?? "—") +
    row("Root %", d.disk_root_used_percent ?? "—") +
    row("SMART", smart);

  // Disk table
  const tbody = $("diskTable")?.querySelector("tbody");
  if (tbody) {
    tbody.innerHTML = "";
    const disks = Array.isArray(d.disks) ? d.disks : [];
    disks.forEach(x => {
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td title="${x.filesystem ?? ""}">${x.filesystem ?? "—"}</td>
        <td>${x.type ?? "—"}</td>
        <td title="${x.mount ?? ""}">${x.mount ?? "—"}</td>
        <td>${x.used ?? "—"}</td>
        <td>${x.size ?? "—"}</td>
        <td>${x.used_percent ?? "—"}</td>
      `;
      tbody.appendChild(tr);
    });
  }

  // Network card
  setBadge($("netIfaceBadge"), d.net_iface ?? "—", "ghost");
  $("netBox").innerHTML =
    row("Iface", d.net_iface ?? "—") +
    row("RX bytes", d.net_rx_bytes ?? "—") +
    row("TX bytes", d.net_tx_bytes ?? "—") +
    row("RX rate", `${fmtBytes(rates.rxps)}/s`) +
    row("TX rate", `${fmtBytes(rates.txps)}/s`);

  // Alerts
  renderAlerts(d);

  // Status card
  $("tsBadge").textContent = "Timestamp";
  $("statusBox").innerHTML =
    row("Timestamp", d.timestamp ?? "—") +
    row("CPU Model", d.cpu_model ?? "—") +
    row("GPU Health", d.gpu_health ?? "—") +
    row("Alerts Count", d.alerts_count ?? 0);

  $("uptime").textContent = `Uptime: ${d.uptime ?? "—"}`;
}

/* ---------- loops ---------- */
async function tick() {
  if (paused) return;

  try {
    const d = await fetchLatest();
    if (!d) return;

    if (d.error) {
      $("pillStatus").textContent = d.error;
      $("pillStatus").style.borderColor = "rgba(251,191,36,0.35)";
      return;
    }
    render(d);
  } catch (e) {
    $("pillStatus").textContent = "Waiting for /api/latest…";
    $("pillStatus").style.borderColor = "rgba(251,191,36,0.35)";
  }
}

async function updateHistory() {
  const n = Number($("selHistoryN")?.value || 50);

  try {
    const resp = await fetchHistory(n);
    if (!resp) return;

    const items = Array.isArray(resp.items) ? resp.items : [];
    const pill = $("histPill");
    if (pill) pill.textContent = `${items.length} records`;

    const chart = $("histChart");
    drawHistoryChart(chart, items);
    renderHistoryTable(items);

    // download JSONL
    const a = $("btnDownloadJsonl");
    if (a) a.href = `/api/history.jsonl?n=${encodeURIComponent(n)}`;

    // store for resize redraw
    window.__lastHistoryItems = items;

  } catch (e) {
    const pill = $("histPill");
    if (pill) pill.textContent = "History unavailable";
  }
}

function startTimer(ms) {
  if (timer) clearInterval(timer);
  timer = setInterval(tick, ms);
}

function setUp() {
  $("btnRefresh")?.addEventListener("click", () => tick());

  $("btnPause")?.addEventListener("click", () => {
    paused = !paused;
    $("btnPause").textContent = paused ? "Resume" : "Pause";
    $("pillStatus").textContent = paused ? "Paused" : "Live";
    if (!paused) tick();
  });

  $("selInterval")?.addEventListener("change", (e) => {
    const ms = Number(e.target.value || 1500);
    startTimer(ms);
  });

  $("selHistoryN")?.addEventListener("change", () => updateHistory());

  // ✅ redraw history on resize (graph will appear correctly)
  window.addEventListener("resize", () => {
    const chart = $("histChart");
    const items = window.__lastHistoryItems;
    if (chart && items) drawHistoryChart(chart, items);
  });

  // first load
  tick();
  startTimer(Number($("selInterval")?.value || 1500));

  // history refresh (independent)
  updateHistory();
  setInterval(updateHistory, 3000);
}

setUp();
