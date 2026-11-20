// Notificaciones push compartidas por la app del equipo (app 'equipo') y la de clientes (app 'cliente').
window.JCPush = (() => {
  const CLAVE = 'BAPb4UfROT79VU3jruVwpRwaeaVAGXxD86YcW8PGakmNpZ-JfeaAZJssXe_tUV5Eqja2TaBRRjC02R2ffe1L6wo';
  const soporta = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const ios = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const instalada = matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  const LS = { get: (k, d) => { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }, set: (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} } };
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  let reg = null, ultimo = null;

  const b64 = s => { const p = '='.repeat((4 - s.length % 4) % 4), r = atob((s + p).replace(/-/g, '+').replace(/_/g, '/')); return Uint8Array.from(r, c => c.charCodeAt(0)); };
  async function registrar() {
    if (!('serviceWorker' in navigator)) return null;
    try { reg = reg || await navigator.serviceWorker.register('sw.js'); } catch (e) { return null; }
    return reg;
  }
  registrar();
  async function suscripcion() { const r = await registrar(); return r && r.pushManager ? r.pushManager.getSubscription() : null; }
  async function estado() {
    if (!soporta) return ios && !instalada ? 'instalar' : 'nosoporta';
    if (Notification.permission === 'denied') return 'bloqueadas';
    const s = await suscripcion().catch(() => null);
    return s && Notification.permission === 'granted' && LS.get('jch-push-on', false) ? 'activas' : 'apagadas';
  }
  const prefs = () => LS.get('jch-push-prefs', {});
  async function guardar(sb, app, s) {
    const j = s.toJSON();
    const x = await sb.rpc('guardar_push', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_app: app, p_prefs: prefs() });
    if (x.error) throw new Error(x.error.message);
  }
  async function activar(sb, app) {
    if (!sb) throw new Error('En la demo no se pueden activar');
    const p = await Notification.requestPermission();
    if (p !== 'granted') throw new Error(p === 'denied' ? 'Quedaron bloqueadas. Habilitalas desde la configuración del celular.' : 'No se activaron');
    const r = await registrar();
    await navigator.serviceWorker.ready;
    let s = await r.pushManager.getSubscription();
    if (!s) s = await r.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64(CLAVE) });
    await guardar(sb, app, s);
    LS.set('jch-push-on', true);
  }
  async function apagar(sb) {
    const s = await suscripcion();
    if (s) { if (sb) await sb.from('push_subs').delete().eq('endpoint', s.endpoint); await s.unsubscribe().catch(() => {}); }
    LS.set('jch-push-on', false);
  }
  // Al entrar: deja este celular a nombre de la cuenta que está usando
  async function sincronizar(sb, app) {
    try {
      if (!sb || !soporta || Notification.permission !== 'granted' || !LS.get('jch-push-on', false)) return;
      const s = await suscripcion(); if (s) await guardar(sb, app, s);
    } catch (e) {}
  }
  // Al cerrar sesión: deja de mandar a este celular (sin desactivar el permiso)
  async function olvidar(sb) {
    try { const s = await suscripcion(); if (s && sb) await sb.from('push_subs').delete().eq('endpoint', s.endpoint); } catch (e) {}
  }
  async function setPref(sb, k, v) {
    const p = { ...prefs(), [k]: v }; LS.set('jch-push-prefs', p);
    const s = await suscripcion().catch(() => null);
    if (s && sb) await sb.rpc('prefs_push', { p_endpoint: s.endpoint, p_prefs: p });
  }
  function onAbrir(fn) {
    if ('serviceWorker' in navigator) navigator.serviceWorker.addEventListener('message', e => { if (e.data && e.data.tipo === 'abrir') fn(e.data.url); });
  }

  // Estilos propios (se agregan una sola vez)
  const css = document.createElement('style');
  css.textContent = `.jp-sw{position:relative;width:46px;height:28px;border-radius:99px;border:0;background:#cfd8e3;flex:0 0 auto;cursor:pointer;transition:background .2s}.jp-sw::after{content:"";position:absolute;top:3px;left:3px;width:22px;height:22px;border-radius:50%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.25);transition:transform .2s}.jp-sw.on{background:#1f7a4d}.jp-sw.on::after{transform:translateX(18px)}.jp-ok{display:inline-flex;align-items:center;gap:6px;font-weight:700;color:#1f7a4d}.jp-av{display:flex;gap:12px;align-items:center;background:#fff;border-radius:18px;padding:12px 14px;box-shadow:0 6px 20px rgba(11,37,69,.14);margin:0 0 12px}.jp-av .ic{font-size:22px}.jp-av b{display:block;font-size:16px;line-height:1.25}.jp-av small{font-size:14px}.jp-av small{display:block;color:#5b6b80;line-height:1.35}.jp-av .x{border:0;background:none;font-size:18px;color:#8a97a8;padding:4px 6px;cursor:pointer}.jp-pasos{margin:8px 0 0;padding-left:20px;line-height:1.5}`;
  document.head.appendChild(css);

  const sw = (k, on, label, sub) => `<div class="row"><div class="grow"><b>${esc(label)}</b>${sub ? `<small>${esc(sub)}</small>` : ''}</div><button class="jp-sw ${on ? 'on' : ''}" data-jp="pref" data-k="${k}" aria-pressed="${on}" aria-label="${esc(label)}"></button></div>`;
  const pasosIOS = `<ol class="jp-pasos"><li>Tocá el botón Compartir (el cuadrado con la flecha ⬆️).</li><li>Elegí “Agregar a inicio”.</li><li>Abrí la app desde ese ícono nuevo y activá las notificaciones acá.</li></ol>`;
  function bloque(e, o) {
    const p = prefs();
    const son = sw('_sonido', window.JCSon ? JCSon.activo() : false, 'Sonidos de la app', 'Un aviso suave cuando llega algo con la app abierta');
    if (e === 'activas') return `<p class="jp-ok">🔔 Activadas en este celular</p>${o.opciones.map(([k, l, s]) => sw(k, p[k] !== false, l, s)).join('')}${son}<button class="btn sec" data-jp="probar">Probar notificación</button><button class="btn sec" data-jp="apagar">Apagar en este celular</button>`;
    if (e === 'apagadas') return `<p class="note" style="margin-top:0">${esc(o.texto)}</p><button class="btn" data-jp="activar">🔔 Activar notificaciones</button>${son}`;
    if (e === 'bloqueadas') return `<p class="note" style="margin-top:0">Las notificaciones están bloqueadas para esta app. Para habilitarlas: ${ios ? 'Configuración del iPhone → Notificaciones → esta app → Permitir.' : 'tocá el candado o los tres puntos del navegador → Configuración del sitio → Notificaciones → Permitir.'} Después volvé y tocá Activar.</p><button class="btn sec" data-jp="activar">Ya las habilité</button>${son}`;
    if (e === 'instalar') return `<p class="note" style="margin-top:0">En iPhone, las notificaciones llegan solo si la app está en tu pantalla de inicio:</p>${pasosIOS}${son}`;
    return `<p class="note" style="margin-top:0">Este navegador no permite notificaciones. Probá abriendo la app con Chrome o instalándola en el celular.</p>${son}`;
  }
  async function accion(t, o, rehacer) {
    const a = t.dataset.jp, avisar = o.toast || (m => alert(m));
    try {
      if (a === 'pref') {
        const v = !t.classList.contains('on');
        t.classList.toggle('on', v); t.setAttribute('aria-pressed', v);
        if (t.dataset.k === '_sonido') { JCSon.set(v); if (v) JCSon.play('tap'); return; }
        return setPref(o.sb, t.dataset.k, v);
      }
      t.disabled = true;
      if (a === 'activar') { await activar(o.sb, o.app); window.JCSon && JCSon.play('ok'); avisar('¡Listo! Vas a recibir las notificaciones en este celular'); }
      if (a === 'apagar') { await apagar(o.sb); avisar('Notificaciones apagadas en este celular'); }
      if (a === 'probar') { if (!o.sb) throw new Error('En la demo no se mandan'); const x = await o.sb.rpc('probar_push'); if (x.error) throw new Error(x.error.message); avisar('Te mandamos una de prueba. Llega en unos segundos.'); }
    } catch (err) { window.JCSon && JCSon.play('error'); avisar(err.message || 'No se pudo'); }
    t.disabled = false;
    rehacer();
  }
  // Bloque completo para Mi perfil / Cuenta
  function montar(el, o) {
    if (!el) return;
    if (ultimo) el.innerHTML = bloque(ultimo, o);
    const rehacer = () => estado().then(e => { ultimo = e; if (el.isConnected) el.innerHTML = bloque(e, o); });
    el.onclick = ev => { const t = ev.target.closest('[data-jp]'); if (t) accion(t, o, () => { rehacer(); o.cambio && o.cambio(); }); };
    rehacer();
  }
  // Tarjeta que invita a activarlas (se puede cerrar)
  function montarAviso(el, o) {
    if (!el) return;
    const k = 'jch-push-aviso-' + o.app;
    const pintar = e => {
      if (LS.get(k, false) || !['apagadas', 'instalar'].includes(e)) { el.innerHTML = ''; return; }
      el.innerHTML = `<div class="jp-av"><span class="ic">🔔</span><div class="grow"><b>${esc(o.titulo)}</b><small>${e === 'instalar' ? 'En iPhone, primero agregá la app a tu pantalla de inicio.' : esc(o.corto || o.texto)}</small></div><button class="btn sm" data-jp="${e === 'instalar' ? 'como' : 'activar'}" style="margin:0;width:auto">${e === 'instalar' ? 'Cómo' : 'Activar'}</button><button class="x" data-jp="cerrar" aria-label="Cerrar">✕</button></div>`;
    };
    if (ultimo) pintar(ultimo);
    estado().then(e => { ultimo = e; if (el.isConnected) pintar(e); });
    el.onclick = ev => {
      const t = ev.target.closest('[data-jp]'); if (!t) return;
      if (t.dataset.jp === 'cerrar') { LS.set(k, true); el.innerHTML = ''; return; }
      if (t.dataset.jp === 'como') { o.como ? o.como() : alert('Tocá Compartir ⬆️ y elegí “Agregar a inicio”. Después abrí la app desde ese ícono.'); return; }
      accion(t, o, () => { montarAviso(el, o); o.cambio && o.cambio(); });
    };
  }
  return { estado, activar, apagar, sincronizar, olvidar, onAbrir, montar, montarAviso, pasosIOS, ios, instalada };
})();
