const toggle = document.querySelector('.nav-toggle'), nav = document.querySelector('.site-nav');
if (toggle) toggle.addEventListener('click', () => toggle.setAttribute('aria-expanded', nav.classList.toggle('open')));
