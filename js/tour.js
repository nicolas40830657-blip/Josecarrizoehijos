// Recorrido de bienvenida: resalta partes de la pantalla con una tarjetita explicativa.
// JCTour.start(pasos, { alTerminar }) — paso: { el: selector | null, titulo, texto, antes: fn }
window.JCTour = (() => {
  let raiz = null;
  const css = document.createElement('style');
  css.textContent = `
#jcTour{position:fixed;inset:0;z-index:9000;font-family:inherit}
#jcTour .tapa{position:absolute;inset:0}
#jcTour .aro{position:absolute;border-radius:18px;box-shadow:0 0 0 9999px rgba(6,20,40,.66),0 0 0 3px #fff;transition:all .35s cubic-bezier(.3,.9,.3,1);pointer-events:none}
#jcTour .aro.sin{width:0!important;height:0!important;left:50%!important;top:45%!important;box-shadow:0 0 0 9999px rgba(6,20,40,.72)}
#jcTour .tj{position:absolute;width:min(340px,calc(100vw - 32px));background:#fff;color:#0b2545;border-radius:22px;padding:18px 18px 14px;box-shadow:0 18px 50px rgba(0,0,0,.3);transition:top .35s cubic-bezier(.3,.9,.3,1),left .35s cubic-bezier(.3,.9,.3,1),opacity .2s;opacity:0}
#jcTour .tj.ok{opacity:1}
#jcTour .tj h4{margin:0 0 6px;font-size:18px;letter-spacing:-.3px}
#jcTour .tj p{margin:0;font-size:15px;line-height:1.45;color:#3d4e63}
#jcTour .pie{display:flex;align-items:center;gap:8px;margin-top:14px}
#jcTour .pts{display:flex;gap:5px;flex:1}
#jcTour .pts i{width:7px;height:7px;border-radius:4px;background:#d3dbe6;transition:all .25s}
#jcTour .pts i.on{width:18px;background:#1F63E8}
#jcTour button{font:inherit;border:0;cursor:pointer;border-radius:999px;font-weight:600;font-size:15px}
#jcTour .saltar{background:none;color:#6b7a8f;padding:10px 8px}
#jcTour .sig{background:linear-gradient(135deg,#0B2545,#1b4a86);color:#fff;padding:10px 18px}
#jcTour .flecha{position:absolute;width:16px;height:16px;background:#fff;transform:rotate(45deg);border-radius:3px}`;
  document.head.appendChild(css);

  // el puede ser un selector o una lista de selectores (usa el primero que exista)
  const buscar = el => !el ? null : Array.isArray(el) ? el.map(q => document.querySelector(q)).find(Boolean) || null : document.querySelector(el);
  function start(pasos, o = {}) {
    if (raiz) raiz.remove();
    pasos = pasos.filter(p => !p.el || p.antes || buscar(p.el));
    let i = 0;
    raiz = document.createElement('div'); raiz.id = 'jcTour';
    raiz.innerHTML = `<div class="tapa"></div><div class="aro sin"></div><div class="tj" role="dialog" aria-live="polite"><span class="flecha"></span><h4></h4><p></p><div class="pie"><div class="pts">${pasos.map(() => '<i></i>').join('')}</div><button class="saltar">Omitir</button><button class="sig">Siguiente</button></div></div>`;
    document.body.appendChild(raiz);
    const aro = raiz.querySelector('.aro'), tj = raiz.querySelector('.tj'), fl = raiz.querySelector('.flecha');
    const fin = completo => { raiz && raiz.remove(); raiz = null; window.removeEventListener('resize', ubicar); o.alTerminar && o.alTerminar(completo); };
    raiz.querySelector('.saltar').onclick = () => fin(false);
    raiz.querySelector('.sig').onclick = () => (i < pasos.length - 1 ? (i++, mostrar()) : fin(true));
    raiz.querySelector('.tapa').onclick = () => raiz.querySelector('.sig').click();

    function ubicar() {
      const p = pasos[i], el = buscar(p.el), W = innerWidth, H = innerHeight, w = Math.min(340, W - 32);
      if (!el) {
        aro.classList.add('sin');
        tj.style.left = (W - w) / 2 + 'px'; tj.style.top = Math.max(16, H * 0.42 - tj.offsetHeight / 2) + 'px'; fl.style.display = 'none';
        return;
      }
      const r = el.getBoundingClientRect(), pad = p.pad ?? 8;
      aro.classList.remove('sin');
      Object.assign(aro.style, { left: r.left - pad + 'px', top: r.top - pad + 'px', width: r.width + pad * 2 + 'px', height: r.height + pad * 2 + 'px', borderRadius: (p.radio ?? 20) + 'px' });
      const abajo = r.bottom + pad + 14 + tj.offsetHeight < H - 8 && r.top < H * 0.6;
      const x = Math.min(W - w - 16, Math.max(16, r.left + r.width / 2 - w / 2));
      const y = abajo ? r.bottom + pad + 14 : Math.max(12, r.top - pad - 14 - tj.offsetHeight);
      tj.style.left = x + 'px'; tj.style.top = y + 'px';
      fl.style.display = 'block'; fl.style.left = Math.min(w - 28, Math.max(12, r.left + r.width / 2 - x - 8)) + 'px';
      fl.style.top = abajo ? '-7px' : ''; fl.style.bottom = abajo ? '' : '-7px';
    }
    async function mostrar() {
      const p = pasos[i];
      tj.classList.remove('ok');
      if (p.antes) await p.antes();
      tj.querySelector('h4').textContent = p.titulo;
      tj.querySelector('p').textContent = p.texto;
      raiz.querySelectorAll('.pts i').forEach((d, k) => d.classList.toggle('on', k === i));
      raiz.querySelector('.sig').textContent = i === pasos.length - 1 ? (o.ultimo || '¡Listo!') : 'Siguiente';
      raiz.querySelector('.saltar').style.visibility = i === pasos.length - 1 ? 'hidden' : '';
      const el = buscar(p.el);
      if (el) {
        const r = el.getBoundingClientRect();
        if (r.top < 70 || r.bottom > innerHeight - 110) { el.scrollIntoView({ block: 'center', behavior: 'smooth' }); await new Promise(z => setTimeout(z, 380)); }
      }
      ubicar(); requestAnimationFrame(() => tj.classList.add('ok'));
    }
    window.addEventListener('resize', ubicar);
    mostrar();
  }
  return { start, activo: () => !!raiz };
})();
