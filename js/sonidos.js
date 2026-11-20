// Sonidos cortos de la interfaz, generados en el momento (sin archivos).
// JCSon.play('plin' | 'envio' | 'ok' | 'pedido' | 'tap' | 'error'), JCSon.activo(), JCSon.set(true/false)
window.JCSon = (() => {
  let ctx = null;
  const activo = () => { try { return localStorage.getItem('jch-sonido') !== '0'; } catch (e) { return true; } };
  const set = v => { try { localStorage.setItem('jch-sonido', v ? '1' : '0'); } catch (e) {} };
  function audio() {
    const A = window.AudioContext || window.webkitAudioContext;
    if (!A) return null;
    if (!ctx) ctx = new A();
    if (ctx.state === 'suspended') ctx.resume();
    return ctx;
  }
  // Los celulares solo dejan sonar después de un toque: lo "despertamos" en el primero
  const despertar = () => { try { audio(); } catch (e) {} };
  ['pointerdown', 'touchstart', 'keydown'].forEach(ev => document.addEventListener(ev, despertar, { once: true, passive: true }));

  function nota(c, f, t, dur, vol, tipo = 'sine', f2) {
    const o = c.createOscillator(), g = c.createGain(), t0 = c.currentTime + t;
    o.type = tipo; o.frequency.setValueAtTime(f, t0);
    if (f2) o.frequency.exponentialRampToValueAtTime(f2, t0 + dur);
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(vol, t0 + 0.012);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    o.connect(g).connect(c.destination);
    o.start(t0); o.stop(t0 + dur + 0.02);
  }
  const S = {
    plin: c => { nota(c, 1046, 0, 0.18, 0.12); nota(c, 1568, 0.09, 0.32, 0.10); },
    envio: c => nota(c, 520, 0, 0.14, 0.07, 'sine', 980),
    ok: c => { nota(c, 784, 0, 0.14, 0.09); nota(c, 988, 0.07, 0.14, 0.09); nota(c, 1318, 0.14, 0.28, 0.08); },
    pedido: c => { nota(c, 1318, 0, 0.12, 0.10, 'triangle'); nota(c, 1760, 0.1, 0.30, 0.09, 'triangle'); },
    tap: c => nota(c, 1400, 0, 0.035, 0.035, 'triangle'),
    error: c => { nota(c, 330, 0, 0.14, 0.08, 'triangle'); nota(c, 247, 0.11, 0.22, 0.08, 'triangle'); }
  };
  function play(n) {
    if (!activo() || !S[n]) return;
    try { const c = audio(); if (c) S[n](c); } catch (e) {}
  }
  return { play, activo, set };
})();
