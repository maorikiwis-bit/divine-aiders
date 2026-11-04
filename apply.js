const f = document.getElementById('apply-form'), msg = document.getElementById('apply-msg');
const DOCS = ['id_copy', 'payslip', 'bank_statement_1', 'bank_statement_2', 'bank_statement_3'];
const OK_TYPES = ['application/pdf', 'image/jpeg', 'image/png'];
const show = (t, cls) => { msg.textContent = t; msg.className = 'msg ' + cls; msg.hidden = false; };

function calc() {
  const a = Number(f.amount_requested.value) || 0, m = Math.max(1, parseInt(f.term_months.value) || 1);
  const total = Math.round(a * (1 + DA_CONFIG.INTEREST_RATE) * 100) / 100;
  document.getElementById('c-int').textContent = nad(total - a);
  document.getElementById('c-total').textContent = nad(total);
  document.getElementById('c-month').textContent = nad(total / m);
}
f.amount_requested.addEventListener('input', calc); f.term_months.addEventListener('input', calc); calc();

f.addEventListener('submit', async e => {
  e.preventDefault();
  if (!f.checkValidity()) { f.reportValidity(); return; }
  for (const d of DOCS) {
    const file = f[d].files[0];
    if (!file) return show('Please attach all 5 documents.', 'err');
    if (!OK_TYPES.includes(file.type)) return show(`${file.name}: only PDF, JPG or PNG allowed.`, 'err');
    if (file.size > DA_CONFIG.MAX_FILE_MB * 1024 * 1024) return show(`${file.name} is larger than ${DA_CONFIG.MAX_FILE_MB} MB.`, 'err');
  }
  const btn = document.getElementById('submit-btn'); btn.disabled = true; show('Submitting… please keep this page open.', 'info');
  const id = crypto.randomUUID();
  try {
    // insert WITHOUT .select(): the public cannot read applications back
    const { error } = await sb.from('applications').insert({
      id, applicant_name: f.applicant_name.value.trim(), id_number: f.id_number.value.trim(),
      email: f.email.value.trim().toLowerCase(), phone: f.phone.value.trim(), employer: f.employer.value.trim() || null,
      amount_requested: Number(f.amount_requested.value), term_months: parseInt(f.term_months.value), consent: f.consent.checked
    });
    if (error) throw error;
    for (const d of DOCS) {
      const file = f[d].files[0], ext = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png' }[file.type];
      const path = `${id}/${d}.${ext}`;
      const up = await sb.storage.from('applicant-docs').upload(path, file, { contentType: file.type, upsert: false });
      if (up.error) throw up.error;
      const r = await sb.from('documents').insert({ application_id: id, doc_type: d, storage_path: path });
      if (r.error) throw r.error;
    }
    f.reset(); calc();
    show(`Thank you! Your application was received (reference ${id.slice(0, 8).toUpperCase()}). We will contact you by phone or WhatsApp.`, 'ok');
  } catch (err) {
    show('Sorry, something went wrong: ' + (err.message || err) + '. Please try again or call +264 81 358 0891.', 'err');
  } finally { btn.disabled = false; }
});
