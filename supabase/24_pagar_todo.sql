-- "Pagar todo": el piletero le paga a la empresa, en un solo pago, el 30% de sus mantenimientos
-- y los productos que vendió y todavía no rindió (el total menos su comisión).
alter table public.ventas add column if not exists pago_id uuid references public.pagos(id) on delete set null;
alter table public.pagos add column if not exists productos numeric not null default 0;
alter table public.pagos add column if not exists ventas int not null default 0;

create or replace function public.pagar(empresa numeric default 0.3)
returns void language plpgsql security definer set search_path = public as $$
declare v_m numeric; v_n int; v_p numeric; v_nv int; v_id uuid; hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if not es_equipo() then raise exception 'No autorizado'; end if;
  select coalesce(sum(valor), 0) * 0.3, count(*) into v_m, v_n
    from realizadas where piletero_id = auth.uid() and pago_id is null and not abono;
  select round(coalesce(sum(total - total * coalesce(porc, 0) / 100), 0)), count(*) into v_p, v_nv
    from ventas where vendedor_id = auth.uid() and cobrado = false and not coalesce(anulada, false);
  if v_n = 0 and v_nv = 0 then return; end if;
  insert into pagos (piletero_id, monto, visitas, productos, ventas) values (auth.uid(), v_m + v_p, v_n, v_p, v_nv) returning id into v_id;
  update realizadas set pago_id = v_id where piletero_id = auth.uid() and pago_id is null and not abono;
  update ventas set cobrado = true, cobrado_fecha = hoy, pago_id = v_id
   where vendedor_id = auth.uid() and cobrado = false and not coalesce(anulada, false);
end $$;
