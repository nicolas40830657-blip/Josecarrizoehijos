-- 29: la empresa le paga al piletero el 70% del abono de los edificios de administraciones
create table if not exists abono_pil (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  mes text not null check (mes ~ '^\d{4}-\d{2}$'),
  piletero_id uuid not null references perfiles(id),
  monto numeric not null check (monto >= 0),
  fecha date not null default ((now() at time zone 'America/Argentina/Buenos_Aires')::date),
  creado timestamptz not null default now(),
  unique (cliente_id, mes)
);
alter table abono_pil enable row level security;
create policy solo_equipo on abono_pil as restrictive for all to authenticated using (es_equipo()) with check (es_equipo());
create policy gestores on abono_pil for all to authenticated using (es_gestor()) with check (es_gestor());
create policy propio on abono_pil for select to authenticated using (piletero_id = auth.uid());
