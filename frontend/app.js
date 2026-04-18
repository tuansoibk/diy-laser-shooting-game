'use strict';

// ── Board constants (must match backend/cv_pipeline.py) ──────────────
const BOARD = { SIZE: 800, NUM_RINGS: 10, MAX_RADIUS: 280, RING_WIDTH: 28 };

// Ring fills from outermost (index 0, score 1) to innermost (index 9, score 10)
// Muted ISSF palette so shot dots remain legible on every ring
const RING_FILLS = [
  '#cccccc', '#b0b0b0',  // score 1-2: light grey
  '#333333', '#1e1e1e',  // score 3-4: near-black
  '#4a72a8', '#2c5490',  // score 5-6: muted blue
  '#b84040', '#8f2c2c',  // score 7-8: muted red
  '#b8841e', '#906412',  // score 9-10: muted gold
];

const RING_LABEL_COLORS = [
  '#444', '#444',  // grey rings  → dark label
  '#aaa', '#aaa',  // black rings → light label
  '#cde', '#cde',  // blue rings  → pale blue-white
  '#fcc', '#fcc',  // red rings   → pale red-white
  '#fde', '#fde',  // gold rings  → pale warm-white
];

// Shot dot colour used in the list only (dots on canvas are always white)
function scoreColor(score) {
  if (score >= 9) return '#f5c542';
  if (score >= 7) return '#e06060';
  if (score >= 5) return '#6090d8';
  if (score >= 1) return '#a0a0a0';
  return '#505050';
}

// ── State ─────────────────────────────────────────────────────────────

const state = {
  backendURL:  localStorage.getItem('backendURL') || window.location.origin,
  gameId:      null,
  roundId:     null,
  shots:       [],
  lastCount:   0,
  roundEnded:  false,
  pollTimer:   null,
};

// ── DOM refs ──────────────────────────────────────────────────────────

const $ = id => document.getElementById(id);

const setupEl = $('setup');
const mainEl  = $('main');
const canvas  = $('canvas');
const ctx     = canvas.getContext('2d');

// ── Boot ──────────────────────────────────────────────────────────────

function init() {
  $('s-backend').value = localStorage.getItem('backendURL') || '';
  $('s-connect').addEventListener('click', onConnect);
  $('m-change').addEventListener('click', onChangeSession);
  $('c-new-game').addEventListener('click', newGame);
  $('c-new-round').addEventListener('click', newRound);
  $('c-end-round').addEventListener('click', endRound);
  window.addEventListener('resize', () => { resizeCanvas(); renderCanvas(); });

  // Auto-connect: use saved URL or, if served from FastAPI, use same origin
  const saved = localStorage.getItem('backendURL');
  if (saved) {
    connect(saved);
  } else if (window.location.protocol !== 'file:') {
    connect(window.location.origin);
  } else {
    resizeCanvas();
  }
}

// ── Setup actions ─────────────────────────────────────────────────────

function onConnect() {
  const backend = $('s-backend').value.trim().replace(/\/$/, '');
  if (!backend) { showError('Please enter the backend URL.'); return; }
  hideError();
  connect(backend);
}

function onChangeSession() {
  stopPolling();
  mainEl.classList.add('hidden');
  setupEl.classList.remove('hidden');
}

// ── Connect: fetch /current and start session ─────────────────────────

async function connect(backendURL) {
  state.backendURL = backendURL;
  localStorage.setItem('backendURL', backendURL);

  let session = null;
  try {
    session = await fetchJSON('/current');
  } catch (e) {
    if (!e.message.includes('404')) {
      showError(`Cannot reach backend: ${e.message}`);
      return;
    }
    // 404 = no games yet; still proceed to main screen
  }

  applySession(session);

  setupEl.classList.add('hidden');
  mainEl.classList.remove('hidden');

  resizeCanvas();
  renderCanvas();
  startPolling();
}

function applySession(session) {
  const prevGameId  = state.gameId;
  const prevRoundId = state.roundId;

  state.gameId     = session ? session.game_id   : null;
  state.roundId    = session ? session.round_id  : null;
  state.roundEnded = session ? session.round_ended : null;

  if (state.gameId !== prevGameId || state.roundId !== prevRoundId) {
    state.shots     = [];
    state.lastCount = 0;
  }

  if (session) {
    $('m-player').textContent   = session.player_name;
    $('m-subtitle').textContent = `Game #${session.game_id}` +
      (session.round_number != null ? ` · Round #${session.round_number}` : '');
    $('c-player').value = session.player_name;
  } else {
    $('m-player').textContent   = 'No active game';
    $('m-subtitle').textContent = 'Create a new game to start';
  }

  const badge = $('m-round-badge');
  if (session && session.round_ended) {
    badge.textContent = 'Round ended';
    badge.classList.remove('hidden');
  } else {
    badge.classList.add('hidden');
  }

  updateControlButtons();
}

// ── Polling ───────────────────────────────────────────────────────────

function startPolling() {
  poll();
  state.pollTimer = setInterval(poll, 1500);
}

function stopPolling() {
  if (state.pollTimer) { clearInterval(state.pollTimer); state.pollTimer = null; }
}

async function poll() {
  const dot = $('m-status');
  try {
    let session = null;
    try {
      session = await fetchJSON('/current');
    } catch (e) {
      if (!e.message.includes('404')) throw e;
    }
    applySession(session);

    if (state.roundId) {
      const shots  = await fetchJSON(`/rounds/${state.roundId}/shots`);
      const hasNew = shots.length > state.lastCount;
      state.shots  = shots;
      renderCanvas();
      renderStats();
      renderShotList(hasNew);
      state.lastCount = shots.length;
    } else {
      renderCanvas();
      renderStats();
      renderShotList(false);
    }
    dot.className = 'status-dot live';
  } catch (e) {
    dot.className = 'status-dot error';
    console.warn('Poll error:', e.message);
  }
}

// ── Fetch helpers ─────────────────────────────────────────────────────

async function fetchJSON(path) {
  const res = await fetch(state.backendURL + path);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

async function postJSON(path, body) {
  const res = await fetch(state.backendURL + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

async function patchJSON(path) {
  const res = await fetch(state.backendURL + path, { method: 'PATCH' });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

// ── Game controls ─────────────────────────────────────────────────────

function updateControlButtons() {
  const hasGame   = state.gameId !== null;
  const roundLive = state.roundId !== null && !state.roundEnded;

  $('c-new-round').disabled = !hasGame;
  $('c-end-round').disabled = !roundLive;
}

async function newGame() {
  const name = $('c-player').value.trim() || 'Player';
  $('c-new-game').disabled = true;
  try {
    await postJSON('/games', { player_name: name });
    await poll();
  } catch (e) {
    console.error('New game error:', e);
  } finally {
    $('c-new-game').disabled = false;
  }
}

async function newRound() {
  if (!state.gameId) return;
  $('c-new-round').disabled = true;
  try {
    await postJSON(`/games/${state.gameId}/rounds`, {});
    await poll();
  } catch (e) {
    console.error('New round error:', e);
  } finally {
    updateControlButtons();
  }
}

async function endRound() {
  if (!state.roundId) return;
  $('c-end-round').disabled = true;
  try {
    await patchJSON(`/rounds/${state.roundId}/end`);
    await poll();
  } catch (e) {
    console.error('End round error:', e);
    updateControlButtons();
  }
}

// ── Canvas ────────────────────────────────────────────────────────────

function resizeCanvas() {
  const wrap = canvas.parentElement;
  if (!wrap) return;
  const size = Math.min(wrap.clientWidth - 40, wrap.clientHeight - 40, 520);
  if (size < 80) return;
  canvas.width  = size;
  canvas.height = size;
}

function renderCanvas() {
  const S  = canvas.width || 400;
  const cx = S / 2;
  const cy = S / 2;
  const scale = (S * 0.44) / BOARD.MAX_RADIUS;

  ctx.clearRect(0, 0, S, S);
  ctx.fillStyle = '#1c1c1e';
  ctx.fillRect(0, 0, S, S);

  // Rings — outermost to innermost
  for (let i = BOARD.NUM_RINGS - 1; i >= 0; i--) {
    const r = (i + 1) * BOARD.RING_WIDTH * scale;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.fillStyle = RING_FILLS[i];
    ctx.fill();
    ctx.strokeStyle = 'rgba(0,0,0,0.18)';
    ctx.lineWidth = 0.75;
    ctx.stroke();
  }

  // Score labels in upper-right quadrant of each ring
  ctx.textAlign    = 'center';
  ctx.textBaseline = 'middle';
  const labelAngle = -Math.PI / 4;
  for (let i = 0; i < BOARD.NUM_RINGS; i++) {
    const score = BOARD.NUM_RINGS - i;
    const midR  = (i + 0.5) * BOARD.RING_WIDTH * scale;
    const lx    = cx + Math.cos(labelAngle) * midR;
    const ly    = cy + Math.sin(labelAngle) * midR;
    const fs    = Math.max(7, Math.min(13, BOARD.RING_WIDTH * scale * 0.44));
    ctx.font      = `bold ${fs}px system-ui`;
    ctx.fillStyle = RING_LABEL_COLORS[i];
    ctx.fillText(score, lx, ly);
  }

  // Subtle crosshair
  const cr = BOARD.MAX_RADIUS * scale;
  ctx.strokeStyle = 'rgba(0,0,0,0.15)';
  ctx.lineWidth = 0.5;
  ctx.beginPath();
  ctx.moveTo(cx - cr, cy); ctx.lineTo(cx + cr, cy);
  ctx.moveTo(cx, cy - cr); ctx.lineTo(cx, cy + cr);
  ctx.stroke();

  // Shots — white fill + black outline so they're visible on every ring colour
  for (let idx = 0; idx < state.shots.length; idx++) {
    const shot = state.shots[idx];
    const sx = cx + (shot.x - 0.5) * BOARD.SIZE * scale;
    const sy = cy + (shot.y - 0.5) * BOARD.SIZE * scale;
    const r  = 7;

    // Outer dark halo for extra contrast
    ctx.beginPath();
    ctx.arc(sx, sy, r + 2, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fill();

    // White dot
    ctx.beginPath();
    ctx.arc(sx, sy, r, 0, Math.PI * 2);
    ctx.fillStyle   = '#ffffff';
    ctx.strokeStyle = '#222222';
    ctx.lineWidth   = 1.5;
    ctx.fill();
    ctx.stroke();

    // Shot number
    ctx.fillStyle    = '#111111';
    ctx.font         = `bold ${Math.max(7, r - 1)}px system-ui`;
    ctx.textAlign    = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(idx + 1, sx, sy);
  }

  if (state.shots.length === 0) {
    ctx.font         = '13px system-ui';
    ctx.fillStyle    = 'rgba(255,255,255,0.2)';
    ctx.textAlign    = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText('Waiting for shots…', cx, cy + BOARD.MAX_RADIUS * scale + 18);
  }
}

// ── Stats ─────────────────────────────────────────────────────────────

function renderStats() {
  const shots = state.shots;
  if (shots.length === 0) {
    $('m-total').textContent = '—';
    $('m-count').textContent = '0';
    $('m-best').textContent  = '—';
    $('m-avg').textContent   = '—';
    return;
  }
  const total = shots.reduce((s, r) => s + r.score, 0);
  const best  = Math.max(...shots.map(r => r.score));
  const avg   = (total / shots.length).toFixed(1);
  $('m-total').textContent = total;
  $('m-count').textContent = shots.length;
  $('m-best').textContent  = best;
  $('m-avg').textContent   = avg;
}

// ── Shot list ─────────────────────────────────────────────────────────

function renderShotList(hasNew) {
  const list  = $('shot-list');
  const shots = state.shots;

  if (shots.length === 0) {
    list.innerHTML = '<div class="empty-hint">No shots yet</div>';
    return;
  }

  const html = [...shots].reverse().map((shot, revIdx) => {
    const num   = shots.length - revIdx;
    const isNew = hasNew && revIdx === 0;
    const color = scoreColor(shot.score);
    const time  = parseTime(shot.created_at);
    return `<div class="shot-row${isNew ? ' new' : ''}">
      <span class="shot-num">#${num}</span>
      <span class="shot-dot" style="background:${color}"></span>
      <span class="shot-score" style="color:${color}">${shot.score}</span>
      <span class="shot-dist">${shot.distance_px.toFixed(1)} px</span>
      <span class="shot-time">${time}</span>
    </div>`;
  }).join('');

  list.innerHTML = html;
}

// SQLite CURRENT_TIMESTAMP: "YYYY-MM-DD HH:MM:SS" (UTC, no tz suffix)
function parseTime(str) {
  if (!str) return '';
  try {
    return new Date(str.replace(' ', 'T') + 'Z')
      .toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  } catch { return str.slice(11, 19); }
}

// ── Helpers ───────────────────────────────────────────────────────────

function showError(msg) {
  const el = $('s-error');
  el.textContent = msg;
  el.classList.remove('hidden');
}

function hideError() { $('s-error').classList.add('hidden'); }

// ── Start ─────────────────────────────────────────────────────────────

init();
