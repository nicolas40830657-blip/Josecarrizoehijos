-- 1) Fotos en el almacenamiento de archivos (bucket "fotos"), no como texto dentro de la base.
--    Nombres al azar: solo las ve quien tiene el link (la app). No se pueden listar.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', true, 6291456, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists fotos_subir on storage.objects;
create policy fotos_subir on storage.objects for insert to authenticated with check (
  bucket_id = 'fotos' and (
    ((storage.foldername(name))[1] = 'visitas' and public.es_equipo())
    or ((storage.foldername(name))[1] = 'chat' and (public.es_equipo() or (storage.foldername(name))[2] = public.mi_cliente_id()::text))
  ));
drop policy if exists fotos_borrar on storage.objects;
create policy fotos_borrar on storage.objects for delete to authenticated using (bucket_id = 'fotos' and public.es_equipo());

-- 2) Foto de "antes" y "después" de cada visita
alter table public.fotos add column if not exists tipo text not null default 'despues' check (tipo in ('antes', 'despues'));

create or replace function public.mi_fotos(p_limite integer default 6)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x), '[]'::json) from (
    select f.id, f.realizada_id, f.data, f.creado, f.tipo,
           exists (select 1 from me_gusta g where g.foto_id = f.id) as gusta
      from fotos f
     where f.cliente_id = mi_cliente_id()
     order by f.creado desc limit least(coalesce(p_limite, 6), 100)) x;
$$;

-- 3) Avisos del cliente sobre la visita: "no vengas", "me voy de viaje", "la llave está con el vecino"
alter table public.mensajes add column if not exists aviso text check (aviso in ('saltear', 'viaje', 'llave'));
alter table public.mensajes add column if not exists aviso_desde date;
alter table public.mensajes add column if not exists aviso_hasta date;
alter table public.mensajes drop constraint if exists mensajes_aviso_fechas;
alter table public.mensajes add constraint mensajes_aviso_fechas check (
  aviso is null or (aviso_desde is not null and aviso_hasta is not null and aviso_hasta >= aviso_desde and aviso_hasta - aviso_desde <= 90));
create index if not exists mensajes_avisos on public.mensajes (aviso_hasta) where aviso is not null;
