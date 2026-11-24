-- "Cobrado" = el cliente le pagó al piletero. "Rendido" = el piletero ya se lo pagó a la empresa (ventas.pago_id).
-- Pagar todo suma los productos que el piletero todavía no rindió, estén cobrados al cliente o no.
create or replace function public.pagar(empresa numeric default 0.3)
returns void language plpgsql security definer set search_path = public as $$
declare v_m numeric; v_n int; v_p numeric; v_nv int; v_id uuid;
begin
  if not es_equipo() then raise exception 'No autorizado'; end if;
  select coalesce(sum(valor), 0) * 0.3, count(*) into v_m, v_n
    from realizadas where piletero_id = auth.uid() and pago_id is null and not abono;
  select round(coalesce(sum(total - total * coalesce(porc, 0) / 100), 0)), count(*) into v_p, v_nv
    from ventas where vendedor_id = auth.uid() and pago_id is null and not coalesce(anulada, false);
  if v_n = 0 and v_nv = 0 then return; end if;
  insert into pagos (piletero_id, monto, visitas, productos, ventas) values (auth.uid(), v_m + v_p, v_n, v_p, v_nv) returning id into v_id;
  update realizadas set pago_id = v_id where piletero_id = auth.uid() and pago_id is null and not abono;
  update ventas set pago_id = v_id where vendedor_id = auth.uid() and pago_id is null and not coalesce(anulada, false);
end $$;
