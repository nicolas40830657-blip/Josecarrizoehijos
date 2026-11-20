# José Carrizo e Hijos · App de gestión + portal de clientes

Uso interno de la empresa. Base de datos: Supabase `gqromisweyqvdeeahxnl`.

| Archivo | Para quién | Qué es |
|---|---|---|
| `index.html` | Equipo (José, coordinadores, pileteros, administración) | Mapa, clientes, calendario, inventario, ventas, ganancias, **pedidos y mensajes de clientes** |
| `cliente.html` | Clientes | Mi pileta: foto del estado actual, visitas, cobros, **tienda**, mensajes, historial |
| `supabase/02_portal_clientes_tienda.sql` | — | Código de cliente, mensajes, recomendaciones, pedidos y seguridad (ya aplicado) |
| `supabase/03_aprobar_equipo.sql` | — | Cuentas nuevas del equipo con aprobación (ya aplicado) |

Vista de prueba sin cuenta: `cliente.html?demo`

## Cómo funciona
1. En la ficha de cada cliente aparece su **código de 6 caracteres** y el botón “Enviar código por WhatsApp”.
   El link ya lleva el código (`cliente.html?c=CODIGO`): el cliente crea su cuenta y queda vinculado solo.
2. Al confirmar una visita, la última foto que sube el piletero es la que el cliente ve como “Estado actual”.
3. **Avisar que le faltan productos**: desde la ficha (“Avisar que le faltan productos”) o al guardar el registro de la visita.
   El cliente lo ve en su inicio (“Te estás quedando sin…”) con el botón para pedirlos.
4. **Tienda**: el cliente ve los productos y kits con precio y marcados “Se vende en la app de clientes”.
   Arma el pedido (paga con la visita, transferencia o efectivo) y el equipo lo ve arriba en *Clientes*.
5. **Entregar**: “Entregado: registrar la venta” crea la venta en la ficha del cliente y descuenta el stock
   (si no hay stock suficiente, avisa y no registra nada).
6. Cuentas nuevas del equipo: quedan pendientes hasta que un coordinador o la administración las habilita en *Mi perfil*.

## Publicar en Hostinger (subdominio nuevo)
1. hPanel → **Dominios → Subdominios**: crear `app` (queda `app.josecarrizoehijos.ar`).
2. hPanel → **Sitios web** → elegir el subdominio → **Avanzado → GIT**:
   - Repositorio: `https://github.com/nicolas40830657-blip/Josecarrizoehijos.git`
   - Rama: `portal-clientes` (o `main` cuando se una)
   - Directorio: dejar vacío (raíz del subdominio)
   - Activar **implementación automática** y copiar el webhook en GitHub (Settings → Webhooks).
3. hPanel → **Seguridad → SSL**: activar SSL para `app.josecarrizoehijos.ar`.
4. Supabase → **Authentication → URL Configuration**:
   - Site URL: `https://app.josecarrizoehijos.ar`
   - Redirect URLs: `https://app.josecarrizoehijos.ar/**`
5. Probar: `https://app.josecarrizoehijos.ar` (equipo) y `https://app.josecarrizoehijos.ar/cliente.html` (clientes).

## Pendiente / ideas
- Precios: los productos sueltos están en $0 (no aparecen en la tienda) y el kit “BÁSICO 90%” figura a $30.
- Notificaciones push de mensajes y pedidos.
- Pago online (Mobbex) cuando esté dado de alta.
