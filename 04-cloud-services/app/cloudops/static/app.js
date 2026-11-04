// Minimal front-end: talks to the REST API with fetch(). No framework needed.
(function () {
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

  async function refreshStatus() {
    try {
      const info = await (await fetch('/api/info')).json();
      $('st-app').textContent = `ok (v${info.version}, ${info.app_env})`;
      $('st-app').className = 'ok';
      $('st-host').textContent = info.hostname;
    } catch (e) {
      $('st-app').textContent = 'unreachable'; $('st-app').className = 'bad';
    }
    try {
      const r = await fetch('/health/ready');
      const j = await r.json();
      $('st-db').textContent = r.ok ? `connected (${j.database.server_version || j.database.backend})` : `down: ${j.database.error}`;
      $('st-db').className = r.ok ? 'ok' : 'bad';
    } catch (e) {
      $('st-db').textContent = 'unknown'; $('st-db').className = 'bad';
    }
  }

  async function loadNotes() {
    const list = $('notes');
    try {
      const r = await fetch('/api/notes');
      if (!r.ok) throw new Error((await r.json()).error || r.statusText);
      const { notes } = await r.json();
      $('count').textContent = `(${notes.length})`;
      list.innerHTML = notes.length ? '' : '<li class="b">No notes yet.</li>';
      for (const n of notes) {
        const li = document.createElement('li');
        li.innerHTML = `<div><div class="t">${esc(n.title)}</div><div class="b">${esc(n.body)}</div>
          <div class="d">#${n.id} · ${new Date(n.created_at).toLocaleString()}</div></div>
          <button class="del" data-id="${n.id}" title="Delete">✕</button>`;
        list.appendChild(li);
      }
    } catch (e) {
      list.innerHTML = `<li class="bad">Could not load notes: ${esc(e.message)}</li>`;
    }
  }

  $('note-form').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const msg = $('form-msg');
    msg.textContent = 'saving…'; msg.className = 'msg';
    const r = await fetch('/api/notes', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: $('title').value, body: $('body').value })
    });
    if (r.status === 201) { msg.textContent = 'saved'; ev.target.reset(); loadNotes(); }
    else { const j = await r.json().catch(() => ({})); msg.textContent = j.error || `error ${r.status}`; msg.className = 'msg err'; }
  });

  $('notes').addEventListener('click', async (ev) => {
    const id = ev.target.dataset && ev.target.dataset.id;
    if (!id) return;
    const r = await fetch(`/api/notes/${id}`, { method: 'DELETE' });
    if (r.status === 204 || r.status === 404) loadNotes();
  });

  refreshStatus(); loadNotes();
  setInterval(refreshStatus, 15000);
})();
