(() => {
  "use strict";

  const els = {
    status: document.getElementById("status"),
    recordingSelect: document.getElementById("recordingSelect"),
    openButton: document.getElementById("openButton"),
    resetButton: document.getElementById("resetButton"),
    last10Button: document.getElementById("last10Button"),
    last30Button: document.getElementById("last30Button"),
    allButton: document.getElementById("allButton"),
    recordingInfo: document.getElementById("recordingInfo"),
    streamPanel: document.getElementById("streamPanel"),
    streamList: document.getElementById("streamList"),
    emptyState: document.getElementById("emptyState"),
    chart: document.getElementById("chart"),
    cursorReadout: document.getElementById("cursorReadout"),
  };

  const state = {
    recordings: [],
    recordingId: null,
    meta: null,
    selected: new Set(),
    data: null,
    viewStart: 0,
    viewEnd: 1,
    cursorMs: null,
    dragging: false,
    dragX: 0,
    dragStart: 0,
    dragEnd: 1,
    loadTimer: null,
    requestSerial: 0,
  };

  function setStatus(message, isError = false) {
    els.status.textContent = message;
    els.status.style.color = isError ? "var(--danger)" : "var(--muted)";
  }

  async function fetchJson(url) {
    const response = await fetch(url, {credentials: "same-origin"});
    if (!response.ok) {
      let detail = `${response.status} ${response.statusText}`;
      try {
        const body = await response.json();
        detail = body.detail || body.code || detail;
      } catch (_) {}
      throw new Error(detail);
    }
    return response.json();
  }

  function formatDuration(ms) {
    if (!Number.isFinite(ms)) return "—";
    const totalSeconds = Math.max(0, ms) / 1000;
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds - minutes * 60;
    return `${minutes}:${seconds.toFixed(3).padStart(6, "0")}`;
  }

  function formatStarted(value) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
  }

  async function loadRecordings() {
    try {
      const payload = await fetchJson("api/recordings");
      state.recordings = payload.recordings || [];
      els.recordingSelect.replaceChildren();
      for (const recording of state.recordings) {
        const option = document.createElement("option");
        option.value = recording.id;
        option.textContent =
          `${recording.dog} — ${formatStarted(recording.startedAtUtc)}` +
          `${recording.hasTimeline ? "" : " · no host timeline"}`;
        els.recordingSelect.append(option);
      }
      const any = state.recordings.length > 0;
      els.recordingSelect.disabled = !any;
      els.openButton.disabled = !any;
      setStatus(any ? `${state.recordings.length} recording(s) available` : "No packet recordings found");
    } catch (error) {
      setStatus(`Cannot load recordings: ${error.message}`, true);
    }
  }

  function enableViewButtons(enabled) {
    for (const button of [
      els.resetButton, els.last10Button, els.last30Button, els.allButton,
    ]) button.disabled = !enabled;
  }

  async function openSelected() {
    const id = els.recordingSelect.value;
    if (!id) return;
    state.recordingId = id;
    state.data = null;
    state.cursorMs = null;
    setStatus("Reading recording index…");
    try {
      const meta = await fetchJson(`api/recordings/${encodeURIComponent(id)}/meta`);
      state.meta = meta;
      state.viewStart = 0;
      state.viewEnd = Math.max(1, meta.durationMs || 1);
      state.selected = new Set(meta.streams.slice(0, 12).map(stream => stream.key));
      renderInfo();
      renderStreams();
      enableViewButtons(true);
      els.emptyState.classList.add("hidden");
      els.chart.classList.remove("hidden");
      await loadSignals();
    } catch (error) {
      setStatus(`Cannot open recording: ${error.message}`, true);
    }
  }

  function renderInfo() {
    const meta = state.meta;
    if (!meta) return;
    els.recordingInfo.innerHTML =
      `<span><strong>${escapeHtml(meta.dog)}</strong></span>` +
      `<span>${escapeHtml(formatStarted(meta.startedAtUtc))}</span>` +
      `<span>duration <strong>${formatDuration(meta.durationMs)}</strong></span>` +
      `<span>${meta.packetCount.toLocaleString()} packets</span>` +
      `<span>${meta.streams.length} streams</span>` +
      `<span>${meta.gapCount} counter gaps</span>` +
      `<span>time: ${escapeHtml(meta.timeBase)}</span>`;
    els.recordingInfo.classList.remove("hidden");
  }

  function escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;");
  }

  function renderStreams() {
    els.streamList.replaceChildren();
    for (const stream of state.meta.streams) {
      const label = document.createElement("label");
      label.className = "stream-item";
      const input = document.createElement("input");
      input.type = "checkbox";
      input.checked = state.selected.has(stream.key);
      input.addEventListener("change", () => {
        if (input.checked) state.selected.add(stream.key);
        else state.selected.delete(stream.key);
        scheduleLoad(0);
      });
      label.append(input, document.createTextNode(stream.label));
      els.streamList.append(label);
    }
    els.streamPanel.classList.remove("hidden");
  }

  function clampView(start, end) {
    const duration = Math.max(1, state.meta?.durationMs || 1);
    let width = Math.max(5, end - start);
    width = Math.min(duration, width);
    start = Math.max(0, Math.min(start, duration - width));
    return [start, start + width];
  }

  function setView(start, end, immediate = false) {
    [state.viewStart, state.viewEnd] = clampView(start, end);
    renderChart();
    scheduleLoad(immediate ? 0 : 120);
  }

  function scheduleLoad(delay = 120) {
    clearTimeout(state.loadTimer);
    state.loadTimer = setTimeout(loadSignals, delay);
  }

  async function loadSignals() {
    if (!state.recordingId || !state.meta) return;
    const serial = ++state.requestSerial;
    const params = new URLSearchParams({
      from_ms: String(state.viewStart),
      to_ms: String(state.viewEnd),
      max_points: String(Math.max(1000, Math.min(5000, Math.round(els.chart.clientWidth * 2)))),
    });
    if (state.selected.size) params.set("streams", [...state.selected].join(","));
    else params.set("streams", "255:255");
    setStatus(`Loading ${formatDuration(state.viewStart)} – ${formatDuration(state.viewEnd)}…`);
    try {
      const payload = await fetchJson(
        `api/recordings/${encodeURIComponent(state.recordingId)}/signals?${params}`,
      );
      if (serial !== state.requestSerial) return;
      state.data = payload;
      renderChart();
      const total = payload.signals.reduce((sum, signal) => sum + signal.rawCount, 0);
      setStatus(
        `${formatDuration(state.viewStart)} – ${formatDuration(state.viewEnd)} · ` +
        `${total.toLocaleString()} raw samples · ${payload.gaps.length} gap(s)`,
      );
    } catch (error) {
      if (serial !== state.requestSerial) return;
      setStatus(`Cannot load signals: ${error.message}`, true);
    }
  }

  function canvasMetrics() {
    const lanes = Math.max(1, state.data?.signals?.length || state.selected.size || 1);
    const cssWidth = Math.max(320, els.chart.clientWidth);
    const cssHeight = Math.max(260, lanes * 118 + 42);
    els.chart.style.height = `${cssHeight}px`;
    const dpr = Math.max(1, window.devicePixelRatio || 1);
    const width = Math.round(cssWidth * dpr);
    const height = Math.round(cssHeight * dpr);
    if (els.chart.width !== width || els.chart.height !== height) {
      els.chart.width = width;
      els.chart.height = height;
    }
    const ctx = els.chart.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return {ctx, width: cssWidth, height: cssHeight};
  }

  function css(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }

  function renderChart() {
    if (!state.meta || els.chart.classList.contains("hidden")) return;
    const {ctx, width, height} = canvasMetrics();
    const left = Math.min(150, Math.max(92, width * 0.12));
    const right = 18;
    const top = 18;
    const bottom = 24;
    const signals = state.data?.signals || [];
    const laneCount = Math.max(1, signals.length);
    const laneHeight = (height - top - bottom) / laneCount;
    const plotWidth = Math.max(1, width - left - right);
    const span = Math.max(1e-9, state.viewEnd - state.viewStart);

    ctx.clearRect(0, 0, width, height);
    ctx.font = "12px system-ui, sans-serif";
    ctx.textBaseline = "middle";

    const xFor = t => left + ((t - state.viewStart) / span) * plotWidth;

    for (let lane = 0; lane < laneCount; lane++) {
      const y0 = top + lane * laneHeight;
      const y1 = y0 + laneHeight;
      ctx.strokeStyle = css("--border");
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(left, y1);
      ctx.lineTo(width - right, y1);
      ctx.stroke();

      const signal = signals[lane];
      if (!signal) continue;
      const points = signal.points || [];
      let min = Infinity, max = -Infinity;
      for (const point of points) {
        if (point[1] < min) min = point[1];
        if (point[1] > max) max = point[1];
      }
      if (!Number.isFinite(min)) { min = -1; max = 1; }
      if (min === max) {
        const padding = Math.max(1, Math.abs(min) * 0.05);
        min -= padding; max += padding;
      }
      const pad = (max - min) * 0.08;
      min -= pad; max += pad;
      const yFor = value =>
        y1 - 12 - ((value - min) / (max - min)) * Math.max(1, laneHeight - 24);

      ctx.fillStyle = css("--text");
      ctx.fillText(signal.label, 10, y0 + 18);
      ctx.fillStyle = css("--muted");
      ctx.fillText(`${min.toFixed(1)} … ${max.toFixed(1)}`, 10, y0 + 36);

      if (points.length) {
        ctx.strokeStyle = css("--accent");
        ctx.lineWidth = 1.2;
        ctx.beginPath();
        points.forEach((point, index) => {
          const x = xFor(point[0]);
          const y = yFor(point[1]);
          if (index === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        });
        ctx.stroke();
      }
    }

    for (const gap of state.data?.gaps || []) {
      const x = xFor(gap.atMs);
      if (x < left || x > width - right) continue;
      ctx.strokeStyle = css("--danger");
      ctx.setLineDash([4, 4]);
      ctx.beginPath();
      ctx.moveTo(x, top);
      ctx.lineTo(x, height - bottom);
      ctx.stroke();
      ctx.setLineDash([]);
    }

    ctx.fillStyle = css("--muted");
    ctx.textAlign = "left";
    ctx.fillText(formatDuration(state.viewStart), left, height - 10);
    ctx.textAlign = "right";
    ctx.fillText(formatDuration(state.viewEnd), width - right, height - 10);
    ctx.textAlign = "left";

    if (state.cursorMs !== null && state.cursorMs >= state.viewStart && state.cursorMs <= state.viewEnd) {
      const x = xFor(state.cursorMs);
      ctx.strokeStyle = css("--text");
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(x, top);
      ctx.lineTo(x, height - bottom);
      ctx.stroke();
      renderCursorReadout(signals);
    } else {
      els.cursorReadout.classList.add("hidden");
    }
  }

  function nearestPoint(points, target) {
    if (!points?.length) return null;
    let lo = 0, hi = points.length - 1;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      if (points[mid][0] < target) lo = mid + 1;
      else hi = mid;
    }
    const a = points[lo];
    const b = lo > 0 ? points[lo - 1] : null;
    return b && Math.abs(b[0] - target) < Math.abs(a[0] - target) ? b : a;
  }

  function renderCursorReadout(signals) {
    const rows = [`t = ${formatDuration(state.cursorMs)}`];
    for (const signal of signals) {
      const point = nearestPoint(signal.points, state.cursorMs);
      if (point) rows.push(`${signal.label}: ${point[1]}`);
    }
    els.cursorReadout.textContent = rows.join("\n");
    els.cursorReadout.classList.remove("hidden");
  }

  function xToTime(clientX) {
    const rect = els.chart.getBoundingClientRect();
    const left = Math.min(150, Math.max(92, rect.width * 0.12));
    const right = 18;
    const plot = Math.max(1, rect.width - left - right);
    const ratio = Math.max(0, Math.min(1, (clientX - rect.left - left) / plot));
    return state.viewStart + ratio * (state.viewEnd - state.viewStart);
  }

  els.openButton.addEventListener("click", openSelected);
  els.recordingSelect.addEventListener("dblclick", openSelected);

  els.resetButton.addEventListener("click", () => setView(0, state.meta.durationMs, true));
  els.allButton.addEventListener("click", () => setView(0, state.meta.durationMs, true));
  els.last10Button.addEventListener("click", () => {
    const end = state.meta.durationMs;
    setView(Math.max(0, end - 10_000), end, true);
  });
  els.last30Button.addEventListener("click", () => {
    const end = state.meta.durationMs;
    setView(Math.max(0, end - 30_000), end, true);
  });

  els.chart.addEventListener("wheel", event => {
    if (!state.meta) return;
    event.preventDefault();
    const focus = xToTime(event.clientX);
    const factor = event.deltaY > 0 ? 1.35 : 0.74;
    const width = (state.viewEnd - state.viewStart) * factor;
    const ratio = (focus - state.viewStart) / (state.viewEnd - state.viewStart);
    setView(focus - width * ratio, focus + width * (1 - ratio));
  }, {passive: false});

  els.chart.addEventListener("pointerdown", event => {
    if (!state.meta) return;
    state.dragging = true;
    state.dragX = event.clientX;
    state.dragStart = state.viewStart;
    state.dragEnd = state.viewEnd;
    els.chart.setPointerCapture(event.pointerId);
  });

  els.chart.addEventListener("pointermove", event => {
    if (!state.meta) return;
    if (state.dragging) {
      const rect = els.chart.getBoundingClientRect();
      const span = state.dragEnd - state.dragStart;
      const shift = -((event.clientX - state.dragX) / Math.max(1, rect.width)) * span;
      [state.viewStart, state.viewEnd] = clampView(state.dragStart + shift, state.dragEnd + shift);
      renderChart();
      scheduleLoad(180);
    } else {
      state.cursorMs = xToTime(event.clientX);
      renderChart();
    }
  });

  function endDrag(event) {
    if (!state.dragging) return;
    state.dragging = false;
    try { els.chart.releasePointerCapture(event.pointerId); } catch (_) {}
    scheduleLoad(0);
  }
  els.chart.addEventListener("pointerup", endDrag);
  els.chart.addEventListener("pointercancel", endDrag);
  els.chart.addEventListener("pointerleave", () => {
    if (!state.dragging) {
      state.cursorMs = null;
      renderChart();
    }
  });
  els.chart.addEventListener("dblclick", () => {
    if (state.meta) setView(0, state.meta.durationMs, true);
  });

  window.addEventListener("resize", () => renderChart());
  loadRecordings();
})();
