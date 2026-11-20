// Sube una foto (ya achicada, como data URL) al almacenamiento "fotos" de Supabase y devuelve su link.
// Si algo falla, devuelve la foto tal cual para que nunca se pierda.
window.JCFotos = (() => {
  const blob = d => { const [h, b] = d.split(','), t = (h.match(/data:([^;]+)/) || [])[1] || 'image/jpeg', s = atob(b); const u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return new Blob([u], { type: t }); };
  async function subir(sb, dataUrl, carpeta) {
    if (!sb || !dataUrl || !dataUrl.startsWith('data:')) return dataUrl;
    try {
      const b = blob(dataUrl), ext = b.type === 'image/png' ? 'png' : b.type === 'image/webp' ? 'webp' : 'jpg';
      const ruta = `${carpeta}/${crypto.randomUUID()}.${ext}`;
      const x = await sb.storage.from('fotos').upload(ruta, b, { contentType: b.type, cacheControl: '31536000', upsert: false });
      if (x.error) throw x.error;
      return sb.storage.from('fotos').getPublicUrl(ruta).data.publicUrl;
    } catch (e) {
      console.warn('No se pudo subir la foto al almacenamiento, se guarda en la base', e);
      return dataUrl;
    }
  }
  return { subir };
})();
