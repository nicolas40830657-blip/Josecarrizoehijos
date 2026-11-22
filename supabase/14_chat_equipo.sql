-- Chat grupal del equipo (todos los pileteros y coordinadores). Con @nombre le llega una notificación a esa persona; @todos a todos.
create table if not exists public.chat_equipo (
  id uuid primary key default gen_random_uuid(),
  autor_id uuid not null default auth.uid() references public.perfiles(id) on delete cascade,
  texto text check (texto is null or length(texto) <= 2000),
  foto text,
  menciones uuid[] not null default '{}',
  creado timestamptz not null default now(),
  check (texto is not null or foto is not null)
);
create index if not exists chat_equipo_creado on public.chat_equipo (creado desc);
alter table public.chat_equipo enable row level security;
drop policy if exists equipo_lee on public.chat_equipo;
create policy equipo_lee on public.chat_equipo for select to authenticated using (es_equipo());
drop policy if exists equipo_escribe on public.chat_equipo;
create policy equipo_escribe on public.chat_equipo for insert to authenticated with check (es_equipo() and autor_id = auth.uid());
drop policy if exists autor_borra on public.chat_equipo;
create policy autor_borra on public.chat_equipo for delete to authenticated using (autor_id = auth.uid() or es_gestor());
revoke all on public.chat_equipo from anon;
grant select, insert, delete on public.chat_equipo to authenticated;

drop trigger if exists push_chat_equipo on public.chat_equipo;
create trigger push_chat_equipo after insert on public.chat_equipo for each row
  when (cardinality(new.menciones) > 0) execute function avisar_push();
