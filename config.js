// Public Supabase settings. The publishable key is SAFE to expose: Row Level Security protects the data.
// NEVER put the service_role / secret key in any file on this site.
window.DA_CONFIG = {
  SUPABASE_URL: 'https://qqgzoajzhysnjformphz.supabase.co',
  SUPABASE_KEY: 'sb_publishable_36gKlflcat_qVtqlenn2VA_bcnTgRUd',
  INTEREST_RATE: 0.30,
  MAX_FILE_MB: 5,
  BANK_DETAILS: '[Bank name] · [Account name: Divine Aiders Cashloan CC] · [Account no.] · [Branch code] · Reference: your ID number'
};
window.sb = supabase.createClient(DA_CONFIG.SUPABASE_URL, DA_CONFIG.SUPABASE_KEY);
window.nad = n => 'N$ ' + Number(n || 0).toLocaleString('en-NA', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
window.esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
