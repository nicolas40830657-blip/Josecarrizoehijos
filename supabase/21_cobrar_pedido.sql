-- Cobrar un pedido entero de una vez (todas las ventas que generó al entregarlo)
create or replace function public.cobrar_pedido(p_id uuid, p_cobrado boolean)
returns void language plpgsql security definer set search_path = public as $$
declare pe pedidos; hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  select * into pe from pedidos where id = p_id;
  if not found then raise exception 'El pedido no existe'; end if;
  if pe.estado <> 'entregado' or coalesce(array_length(pe.venta_ids, 1), 0) = 0 then raise exception 'El pedido todavía no se entregó'; end if;
  if not (es_gestor() or not exists (select 1 from ventas where id = any(pe.venta_ids) and vendedor_id is distinct from auth.uid())) then
    raise exception 'No podés cambiar el cobro de este pedido';
  end if;
  update ventas set cobrado = p_cobrado, cobrado_fecha = case when p_cobrado then hoy end where id = any(pe.venta_ids);
end $$;
revoke execute on function public.cobrar_pedido(uuid, boolean) from public, anon;
grant execute on function public.cobrar_pedido(uuid, boolean) to authenticated;
