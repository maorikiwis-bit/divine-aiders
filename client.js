let mode = 'login';
const $ = id => document.getElementById(id);
const form = $('auth-form');
const say = (t, cls = 'err') => { const m = $('auth-msg'); m.textContent = t; m.className = 'msg ' + cls; m.hidden = !t; };
$('bank').textContent = DA_CONFIG.BANK_DETAILS;

document.querySelectorAll('[data-mode]').forEach(b => b.onclick = () => {
  mode = b.dataset.mode;
  document.querySelectorAll('[data-mode]').forEach(x => x.classList.toggle('active', x === b));
  $('code-field').classList.toggle('hidden', mode !== 'activate');
  $('activate-hint').classList.toggle('hidden', mode !== 'activate');
  form.code.required = mode === 'activate';
  form.password.autocomplete = mode === 'activate' ? 'new-password' : 'current-password';
  $('auth-btn').textContent = mode === 'activate' ? 'Activate my account' : 'Sign in';
  say('');
});

form.addEventListener('submit', async e => {
  e.preventDefault();
  if (!form.checkValidity()) return form.reportValidity();
  const email = form.email.value.trim().toLowerCase(), password = form.password.value;
  say('Please wait…', 'info');
  if (mode === 'activate') {
    let { data, error } = await sb.auth.signUp({ email, password });
    if (error && /already registered/i.test(error.message)) ({ data, error } = await sb.auth.signInWithPassword({ email, password }));
    if (error) return say(error.message);
    if (!data.session) return say('Account created but email confirmation is switched on. Please contact Divine Aiders (staff must disable "Confirm email" in Supabase, see README).');
    const r = await sb.rpc('redeem_access_code', { p_code: form.code.value });
    if (r.error) return say(r.error.message);
  } else {
    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) return say(error.message);
  }
  say(''); load();
});

$('logout').onclick = async () => { await sb.auth.signOut(); location.reload(); };

async function load() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return;
  const { data: prof } = await sb.from('profiles').select('*').maybeSingle();
  if (!prof || prof.role !== 'client') {
    say(prof?.role === 'staff' ? 'This is a staff account. Use the staff page.' : 'No active client account found. If you have an access code, use "Activate account". If your account was blocked or closed, please contact us.');
    return;
  }
  $('auth-view').classList.add('hidden'); $('client-view').classList.remove('hidden');
  $('hello').textContent = 'Welcome, ' + prof.full_name;
  const [{ data: loans }, { data: pays }, { data: crs }] = await Promise.all([
    sb.from('loans').select('*').order('created_at', { ascending: false }),
    sb.from('payments').select('*').order('paid_on', { ascending: false }),
    sb.from('closure_requests').select('*')]);
  $('loans').innerHTML = (loans || []).map(l => {
    const paid = l.total - l.balance, pct = l.total > 0 ? Math.round(paid / l.total * 100) : 0;
    const cr = (crs || []).find(c => c.loan_id === l.id && c.status === 'pending');
    return `<div style="margin:1rem 0;padding-top:1rem;border-top:1px solid #eee">
      <p><span class="badge ${l.status}">${l.status}</span> Loan of ${nad(l.principal)} · ${l.term_months || '-'} months · ${nad(l.monthly_installment)}/month</p>
      <div class="stats" style="margin:.75rem 0"><div class="stat"><small>Balance</small><strong>${nad(l.balance)}</strong></div>
      <div class="stat"><small>Paid</small><strong>${nad(paid)}</strong></div><div class="stat"><small>Total repayable</small><strong>${nad(l.total)}</strong></div></div>
      <div class="progress" aria-label="${pct}% repaid"><span style="width:${pct}%"></span></div><p class="hint">${pct}% repaid</p>
      ${l.status === 'closed' ? '' : cr ? '<p class="msg info">Closure request pending review.</p>'
        : `<button class="btn btn-light btn-xs" data-close="${l.id}">Request account closure</button>
           ${l.balance > 0 ? '<span class="hint"> (closure can only be approved once the balance is N$ 0)</span>' : ''}`}
    </div>`;
  }).join('') || '<p>No loans found.</p>';
  document.querySelectorAll('[data-close]').forEach(b => b.onclick = async () => {
    if (!confirm('Request closure of this loan account?')) return;
    const { error } = await sb.from('closure_requests').insert({ client_id: prof.id, loan_id: b.dataset.close });
    if (error) alert(error.message); else load();
  });
  $('payments').innerHTML = pays?.length ? `<table class="stack"><thead><tr><th>Date</th><th>Amount</th><th>Method</th><th>Reference</th></tr></thead><tbody>${
    pays.map(p => `<tr><td data-label="Date">${esc(p.paid_on)}</td><td data-label="Amount">${nad(p.amount)}</td><td data-label="Method">${esc(p.method.replace('_', ' '))}</td><td data-label="Ref">${esc(p.reference || '')}</td></tr>`).join('')}</tbody></table>` : '<p>No payments yet.</p>';
}
load();
