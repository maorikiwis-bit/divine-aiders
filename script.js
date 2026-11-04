// ==========================================================
// script.js — small bits of interactivity.
// ==========================================================

// 1) Mobile menu: clicking the hamburger toggles the "open" class.
const toggle = document.querySelector('.nav-toggle');
const nav = document.querySelector('.site-nav');
toggle.addEventListener('click', () => {
  const isOpen = nav.classList.toggle('open');
  toggle.setAttribute('aria-expanded', isOpen);
});
// Close the menu after a link is tapped
nav.querySelectorAll('a').forEach(a => a.addEventListener('click', () => nav.classList.remove('open')));

// 2) Enquiry form: this is a PREVIEW. We stop the real submit and
//    show a notice. Nothing is sent anywhere. To make it work later,
//    connect it to a form service or a back-end.
const form = document.getElementById('enquiry-form');
const notice = document.getElementById('form-notice');
form.addEventListener('submit', (event) => {
  event.preventDefault(); // stops the browser from submitting
  notice.textContent = 'Thank you for trying the form. This is a website preview and the form is not yet connected, so your enquiry has NOT been sent. Please contact us on +264 81 358 0891 or +264 81 309 3182 (calls or WhatsApp).';
  notice.hidden = false;
});

// 3) Footer year updates automatically
document.getElementById('year').textContent = new Date().getFullYear();
