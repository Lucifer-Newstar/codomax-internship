// CloudOps board — vanilla JS. Same-origin calls; nginx proxies /api, /health, /metrics to the backend.
(() => {
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const api = async (path, opts = {}) => {
    const r = await fetch(path, { headers: { 'Content-Type': 'application/json' }, ...opts });
    if (r.status === 204) return null;
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || `${r.status} ${r.statusText}`);
    return body;
  };

  async function status() {
    try {
      const i = await api('/api/info');
      $('s-api').textContent = 'healthy'; $('s-api').className = 'val ok';
      $('s-host').textContent = `${i.hostname} · ${i.app_env}`;
      $('s-ver').textContent = `v${i.version}`; $('s-sha').textContent = `sha ${i.git_sha}`;
      $('s-req').textContent = `${i.metrics.requests} / ${i.metrics.errors_5xx}`;
      $('s-up').textContent = `up ${Math.round(i.uptime_seconds / 60)} min (this worker)`;
    } catch (e) { $('s-api').textContent = 'unreachable'; $('s-api').className = 'val bad'; }
    try {
      const r = await fetch('/health/ready'); const j = await r.json();
      $('s-db').textContent = r.ok ? 'connected' : 'down'; $('s-db').className = r.ok ? 'val ok' : 'val bad';
      $('s-dbv').textContent = r.ok ? (j.database.server_version || j.database.backend) : j.database.error;
    } catch (e) { $('s-db').textContent = 'unknown'; $('s-db').className = 'val bad'; }
  }

  async function board() {
    let tasks = [], stats;
    try { ({ tasks } = await api('/api/tasks')); stats = await api('/api/stats'); }
    catch (e) { $('msg').textContent = `Cannot load tasks: ${e.message}`; $('msg').className = 'msg err'; return; }
    for (const s of ['todo', 'doing', 'done']) {
      const ul = $(`l-${s}`); ul.innerHTML = '';
      $(`n-${s}`).textContent = stats.tasks[s] ? `(${stats.tasks[s]})` : '';
      for (const t of tasks.filter((x) => x.status === s)) {
        const li = document.createElement('li'); li.className = `p${t.priority}`;
        const next = s === 'todo' ? 'doing' : s === 'doing' ? 'done' : null;
        const prev = s === 'done' ? 'doing' : s === 'doing' ? 'todo' : null;
        li.innerHTML = `<div><div class="t">${esc(t.title)}</div><div class="d">#${t.id} · ${new Date(t.updated_at).toLocaleString()}</div></div>
          <div class="act">${prev ? `<button class="sm" data-id="${t.id}" data-to="${prev}">◀</button>` : ''}
          ${next ? `<button class="sm" data-id="${t.id}" data-to="${next}">▶</button>` : ''}
          <button class="sm del" data-id="${t.id}" data-del="1" title="Delete">✕</button></div>`;
        ul.appendChild(li);
      }
    }
    const d = stats.last_deployment;
    $('deploy').textContent = d ? `${d.version} @ ${d.git_sha} → ${d.hostname} (${d.environment}) at ${new Date(d.deployed_at).toLocaleString()}` : 'no deployment recorded yet';
  }

  $('f').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const m = $('msg'); m.className = 'msg'; m.textContent = 'saving…';
    try {
      await api('/api/tasks', { method: 'POST', body: JSON.stringify({ title: $('title').value, priority: Number($('priority').value) }) });
      m.textContent = 'added'; ev.target.reset(); board();
    } catch (e) { m.textContent = e.message; m.className = 'msg err'; }
  });

  document.querySelector('.board').addEventListener('click', async (ev) => {
    const b = ev.target.closest('button'); if (!b) return;
    try {
      if (b.dataset.del) await api(`/api/tasks/${b.dataset.id}`, { method: 'DELETE' });
      else await api(`/api/tasks/${b.dataset.id}`, { method: 'PATCH', body: JSON.stringify({ status: b.dataset.to }) });
      board();
    } catch (e) { $('msg').textContent = e.message; $('msg').className = 'msg err'; }
  });

  status(); board();
  setInterval(status, 15000); setInterval(board, 30000);
})();
