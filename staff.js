const $ = id => document.getElementById(id);
let me = null, cache = {};
const note = (t, cls = 'ok') => { const m = $('staff-msg'); m.textContent = t; m.className = 'msg ' + cls; m.hidden = !t; if (t) m.scrollIntoView({ block: 'nearest' }); };
const badge = s => `<span class="badge ${esc(s)}">${esc(s)}</span>`;
const td = (l, v) => `<td data-label="${l}">${v}</td>`;

$('auth-form').addEventListener('submit', async e => {
  e.preventDefault(); const f = e.target;
  const { error } = await sb.auth.signInWithPassword({ email: f.email.value.trim(), password: f.password.value });
  const m = $('auth-msg'); if (error) { m.textContent = error.message; m.className = 'msg err'; m.hidden = false; return; }
  start();
});
$('logout').onclick = async () => { await sb.auth.signOut(); location.reload(); };
document.querySelectorAll('#tabs button').forEach(b => b.onclick = () => {
  document.querySelectorAll('#tabs button').forEach(x => x.classList.toggle('active', x === b));
  document.querySelectorAll('[data-pane]').forEach(p => p.classList.toggle('hidden', p.dataset.pane !== b.dataset.tab));
  note('');
});
$('app-filter').onchange = renderApps;

async function start() {
  const { data: { session } } = await sb.auth.getSession(); if (!session) return;
  const { data: prof } = await sb.from('profiles').select('*').eq('id', session.user.id).maybeSingle();
  if (!prof || prof.role !== 'staff' || prof.status !== 'active') {
    const m = $('auth-msg'); m.textContent = 'This account is not an active staff account.'; m.className = 'msg err'; m.hidden = false;
    await sb.auth.signOut(); return;
  }
  me = prof; $('who').textContent = 'Signed in as ' + (prof.full_name || session.user.email);
  $('auth-view').classList.add('hidden'); $('staff-view').classList.remove('hidden');
  document.querySelector('#pay-form [name=paid_on]').valueAsDate = new Date();
  refresh();
}

async function refresh() {
  const [apps, docs, loans, pays, profs, crs] = await Promise.all([
    sb.from('applications').select('*').order('created_at', { ascending: false }),
    sb.from('documents').select('*'),
    sb.from('loans').select('*').order('created_at', { ascending: false }),
    sb.from('payments').select('*').order('created_at', { ascending: false }),
    sb.from('profiles').select('*'),
    sb.from('closure_requests').select('*').order('created_at', { ascending: false })]);
  for (const r of [apps, docs, loans, pays, profs, crs]) if (r.error) return note(r.error.message, 'err');
  cache = { apps: apps.data, docs: docs.data, loans: loans.data, pays: pays.data, profs: profs.data, crs: crs.data };
  const appById = Object.fromEntries(cache.apps.map(a => [a.id, a]));
  cache.loanName = l => (cache.profs.find(p => p.id === l.client_id)?.full_name) || appById[l.application_id]?.applicant_name || 'Unknown';
  const lent = cache.loans.reduce((s, l) => s + +l.principal, 0);
  const out = cache.loans.filter(l => l.status === 'active').reduce((s, l) => s + +l.balance, 0);
  const col = cache.pays.reduce((s, p) => s + +p.amount, 0);
  $('s-lent').textContent = nad(lent); $('s-out').textContent = nad(out); $('s-col').textContent = nad(col);
  $('s-pend').textContent = cache.apps.filter(a => a.status === 'pending').length;
  renderApps(); renderClients(); renderPays(); renderClosures();
}

function renderApps() {
  const f = $('app-filter').value, rows = cache.apps.filter(a => !f || a.status === f);
  $('applications').innerHTML = rows.length ? `<table class="stack"><thead><tr><th>Date</th><th>Applicant</th><th>Loan</th><th>Docs</th><th>Status</th><th></th></tr></thead><tbody>${rows.map(a => {
    const d = cache.docs.filter(x => x.application_id === a.id);
    return `<tr>${td('Date', new Date(a.created_at).toLocaleDateString('en-NA'))}
      ${td('Applicant', `<strong>${esc(a.applicant_name)}</strong><br><span class="hint">ID ${esc(a.id_number)} · ${esc(a.phone)}<br>${esc(a.email)}${a.employer ? '<br>' + esc(a.employer) : ''}</span>`)}
      ${td('Loan', `${nad(a.amount_requested)} × ${a.term_months}m<br><span class="hint">Total ${nad(a.total_repayable)} · ${nad(a.monthly_installment)}/m</span>`)}
      ${td('Docs', d.map(x => `<a href="#" data-doc="${esc(x.storage_path)}">${esc(x.doc_type.replace(/_/g, ' '))}</a>`).join('<br>') + (d.length < 5 ? `<br><span class="badge declined">${5 - d.length} missing</span>` : ''))}
      ${td('Status', badge(a.status) + (a.staff_notes ? `<br><span class="hint">${esc(a.staff_notes)}</span>` : ''))}
      ${td('', a.status === 'pending' ? `<div class="actions"><button class="btn btn-gold btn-xs" data-approve="${a.id}">Approve</button><button class="btn btn-light btn-xs" data-decline="${a.id}">Decline</button></div>`
        : a.status === 'approved' && !cache.loans.find(l => l.application_id === a.id)?.client_id ? `<button class="btn btn-light btn-xs" data-approve="${a.id}" data-renew="1">New access code</button>` : '')}</tr>`;
  }).join('')}</tbody></table>` : '<p>No applications.</p>';
  document.querySelectorAll('[data-doc]').forEach(a => a.onclick = async e => {
    e.preventDefault();
    const { data, error } = await sb.storage.from('applicant-docs').createSignedUrl(a.dataset.doc, 120);
    if (error) return note(error.message, 'err'); window.open(data.signedUrl, '_blank', 'noopener');
  });
  document.querySelectorAll('[data-approve]').forEach(b => b.onclick = async () => {
    const renew = b.dataset.renew;
    const notes = renew ? null : prompt('Approve this application? Optional note:', '');
    if (notes === null && !renew) return;
    if (renew && !confirm('Generate a new access code? The old one stops working.')) return;
    const { data, error } = await sb.rpc('approve_application', { p_application_id: b.dataset.approve, p_notes: notes || null });
    if (error) return note(error.message, 'err');
    showCode(cache.apps.find(a => a.id === b.dataset.approve), data); refresh();
  });
  document.querySelectorAll('[data-decline]').forEach(b => b.onclick = async () => {
    const notes = prompt('Reason for declining (internal note):', ''); if (notes === null) return;
    const { error } = await sb.rpc('decline_application', { p_application_id: b.dataset.decline, p_notes: notes || null });
    if (error) return note(error.message, 'err'); note('Application declined.'); refresh();
  });
}

function showCode(app, code) {
  const url = new URL('client.html', location.href).href;
  const text = `Hello ${app?.applicant_name || ''}, your Divine Aiders loan was approved. Activate your client account at ${url} using your email ${app?.email || ''} and access code ${code} (valid 14 days).`;
  $('dlg-body').innerHTML = `<h3>Access code created</h3><p>Give this code to the client <strong>privately</strong> (WhatsApp/SMS/in person). It is shown only once and expires in 14 days.</p>
    <div class="code-box">${esc(code)}</div><p class="hint" style="margin-top:.75rem">${esc(text)}</p>
    <div class="actions" style="margin-top:.75rem"><button class="btn btn-gold btn-xs" id="copy-msg">Copy message</button>
    ${app?.phone ? `<a class="btn btn-dark btn-xs" target="_blank" rel="noopener" href="https://wa.me/${esc(app.phone.replace(/\D/g, '').replace(/^0/, '264'))}?text=${encodeURIComponent(text)}">Open WhatsApp</a>` : ''}</div>`;
  $('copy-msg').onclick = () => navigator.clipboard.writeText(text);
  $('dlg').showModal();
}

function renderClients() {
  const loans = cache.loans;
  $('clients').innerHTML = loans.length ? `<table class="stack"><thead><tr><th>Client</th><th>Account</th><th>Loan</th><th>Balance</th><th></th></tr></thead><tbody>${loans.map(l => {
    const p = cache.profs.find(x => x.id === l.client_id);
    return `<tr>${td('Client', `<strong>${esc(cache.loanName(l))}</strong>${p ? `<br><span class="hint">${esc(p.phone || '')} ${esc(p.email || '')}</span>` : ''}`)}
      ${td('Account', p ? badge(p.status) : '<span class="badge pending">not activated</span>')}
      ${td('Loan', `${badge(l.status)} ${nad(l.principal)} → ${nad(l.total)}`)}
      ${td('Balance', nad(l.balance))}
      ${td('', p ? `<div class="actions">${p.status === 'active' ? `<button class="btn btn-light btn-xs" data-st="blocked" data-id="${p.id}">Block</button>` : `<button class="btn btn-light btn-xs" data-st="active" data-id="${p.id}">Unblock</button>`}
        ${p.status !== 'closed' ? `<button class="btn btn-light btn-xs" data-st="closed" data-id="${p.id}">Remove</button>` : ''}</div>` : '')}</tr>`;
  }).join('')}</tbody></table>` : '<p>No clients yet.</p>';
  document.querySelectorAll('[data-st]').forEach(b => b.onclick = async () => {
    const st = b.dataset.st;
    if (st === 'closed' && !confirm('Remove this client? (soft delete: account is closed and hidden from the client; records are kept)')) return;
    const { error } = await sb.from('profiles').update({ status: st, deleted_at: st === 'closed' ? new Date().toISOString() : null }).eq('id', b.dataset.id);
    if (error) return note(error.message, 'err'); note('Client updated.'); refresh();
  });
  $('pay-loan').innerHTML = cache.loans.filter(l => l.status === 'active').map(l => `<option value="${l.id}">${esc(cache.loanName(l))} — balance ${nad(l.balance)}</option>`).join('') || '<option value="">No active loans</option>';
}

$('add-client-btn').onclick = () => $('add-dlg').showModal();
$('add-form').addEventListener('submit', async e => {
  e.preventDefault(); const f = e.target;
  const args = Object.fromEntries(new FormData(f)); args.p_amount = Number(args.p_amount); args.p_months = parseInt(args.p_months);
  args.p_email = args.p_email.trim().toLowerCase(); args.p_employer = args.p_employer || null;
  const { data, error } = await sb.rpc('staff_add_client', args);
  if (error) return alert(error.message);
  $('add-dlg').close(); f.reset(); showCode({ applicant_name: args.p_name, email: args.p_email, phone: args.p_phone }, data); refresh();
});

$('pay-form').addEventListener('submit', async e => {
  e.preventDefault(); const f = e.target; if (!f.loan_id.value) return;
  const { error } = await sb.from('payments').insert({ loan_id: f.loan_id.value, amount: Number(f.amount.value), paid_on: f.paid_on.value, method: f.method.value, reference: f.reference.value || null, recorded_by: me.id });
  if (error) return note(error.message, 'err'); f.amount.value = ''; f.reference.value = ''; note('Payment recorded.'); refresh();
});

function renderPays() {
  const name = id => { const l = cache.loans.find(x => x.id === id); return l ? cache.loanName(l) : ''; };
  $('payments').innerHTML = cache.pays.length ? `<table class="stack"><thead><tr><th>Date</th><th>Client</th><th>Amount</th><th>Method</th><th>Ref</th></tr></thead><tbody>${cache.pays.slice(0, 100).map(p =>
    `<tr>${td('Date', esc(p.paid_on))}${td('Client', esc(name(p.loan_id)))}${td('Amount', nad(p.amount))}${td('Method', esc(p.method))}${td('Ref', esc(p.reference || ''))}</tr>`).join('')}</tbody></table>` : '<p>No payments yet.</p>';
}

function renderClosures() {
  $('closures').innerHTML = cache.crs.length ? `<table class="stack"><thead><tr><th>Date</th><th>Client</th><th>Balance</th><th>Status</th><th></th></tr></thead><tbody>${cache.crs.map(c => {
    const l = cache.loans.find(x => x.id === c.loan_id), bal = l ? +l.balance : 0;
    return `<tr>${td('Date', new Date(c.created_at).toLocaleDateString('en-NA'))}${td('Client', esc(l ? cache.loanName(l) : ''))}${td('Balance', nad(bal))}${td('Status', badge(c.status))}
      ${td('', c.status === 'pending' ? `<div class="actions"><button class="btn btn-gold btn-xs" data-cr="approved" data-id="${c.id}" ${bal > 0 ? 'disabled title="Balance must be N$ 0"' : ''}>Approve</button><button class="btn btn-light btn-xs" data-cr="rejected" data-id="${c.id}">Reject</button></div>` : '')}</tr>`;
  }).join('')}</tbody></table>` : '<p>No closure requests.</p>';
  document.querySelectorAll('[data-cr]').forEach(b => b.onclick = async () => {
    const { error } = await sb.from('closure_requests').update({ status: b.dataset.cr }).eq('id', b.dataset.id);
    if (error) return note(error.message, 'err'); note('Closure request ' + b.dataset.cr + '.'); refresh();
  });
}
start();
