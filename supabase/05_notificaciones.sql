-- Notificaciones push (app del equipo y app de clientes)
-- Las claves VAPID y el secreto compartido están guardados en Supabase Vault
-- (push_vapid_publica, push_vapid_privada, push_secreto). No van en el repo.

create extension if not exists pg_net with schema extensions;

-- Un registro por celular/navegador donde se activaron las notificaciones
create table if not exists public.push_subs (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null default auth.uid() references auth.users on delete cascade,
  app text not null check (app in ('equipo', 'cliente')),
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  prefs jsonb not null default '{}',
  creado timestamptz not null default now(),
  usado timestamptz
);
create index if not exists push_subs_usuario on public.push_subs (usuario_id);
alter table public.push_subs enable row level security;
drop policy if exists propias_ver on public.push_subs;
create policy propias_ver on public.push_subs for select to authenticated using (usuario_id = auth.uid());
drop policy if exists propias_borrar on public.push_subs;
create policy propias_borrar on public.push_subs for delete to authenticated using (usuario_id = auth.uid());
revoke all on public.push_subs from anon;
grant select, delete on public.push_subs to authenticated;

-- Activar en este dispositivo (si el celular era de otra cuenta, pasa a esta)
create or replace function public.guardar_push(p_endpoint text, p_p256dh text, p_auth text, p_app text, p_prefs jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Tenés que iniciar sesión'; end if;
  if p_app = 'equipo' and not es_equipo() then raise exception 'Cuenta no habilitada'; end if;
  if p_app = 'cliente' and mi_cliente_id() is null then raise exception 'Primero vinculá tu pileta'; end if;
  if p_app not in ('equipo', 'cliente') or coalesce(p_endpoint, '') !~ '^https://' then raise exception 'Datos inválidos'; end if;
  delete from push_subs where endpoint = p_endpoint;
  insert into push_subs (usuario_id, app, endpoint, p256dh, auth, prefs)
  values (auth.uid(), p_app, p_endpoint, p_p256dh, p_auth, coalesce(p_prefs, '{}'));
end $$;

create or replace function public.prefs_push(p_endpoint text, p_prefs jsonb)
returns void language sql security definer set search_path = public as $$
  update push_subs set prefs = coalesce(p_prefs, '{}') where endpoint = p_endpoint and usuario_id = auth.uid();
$$;

-- Configuración que solo lee la función enviar-push (con la clave de servicio)
create or replace function public.push_config()
returns jsonb language sql security definer set search_path = public, vault as $$
  select jsonb_object_agg(replace(name, 'push_', ''), decrypted_secret)
  from vault.decrypted_secrets where name in ('push_vapid_publica', 'push_vapid_privada', 'push_secreto');
$$;
revoke execute on function public.push_config() from public, anon, authenticated;
grant execute on function public.push_config() to service_role;

-- Llama a la función enviar-push. Nunca frena el guardado si algo falla.
create or replace function public.llamar_push(p_body jsonb)
returns void language plpgsql security definer set search_path = public, vault, extensions as $$
declare s text;
begin
  select decrypted_secret into s from vault.decrypted_secrets where name = 'push_secreto';
  perform net.http_post(
    url := 'https://gqromisweyqvdeeahxnl.supabase.co/functions/v1/enviar-push',
    body := p_body || jsonb_build_object('quien', auth.uid()),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-secreto', s),
    timeout_milliseconds := 8000);
exception when others then null;
end $$;
revoke execute on function public.llamar_push(jsonb) from public, anon, authenticated;

create or replace function public.avisar_push()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform llamar_push(jsonb_build_object('tabla', TG_TABLE_NAME, 'id', NEW.id, 'op', TG_OP));
  return null;
exception when others then return null;
end $$;
revoke execute on function public.avisar_push() from public, anon, authenticated;

-- Botón "Probar notificación"
create or replace function public.probar_push()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Tenés que iniciar sesión'; end if;
  perform llamar_push(jsonb_build_object('tabla', 'prueba', 'id', auth.uid(), 'op', 'TEST'));
end $$;

revoke execute on function public.probar_push() from public, anon;
revoke execute on function public.guardar_push(text,text,text,text,jsonb) from public, anon;
revoke execute on function public.prefs_push(text,jsonb) from public, anon;
grant execute on function public.probar_push(), public.guardar_push(text,text,text,text,jsonb), public.prefs_push(text,jsonb) to authenticated;

drop trigger if exists push_mensajes on public.mensajes;
create trigger push_mensajes after insert on public.mensajes for each row execute function avisar_push();
drop trigger if exists push_pedidos_nuevo on public.pedidos;
create trigger push_pedidos_nuevo after insert on public.pedidos for each row execute function avisar_push();
drop trigger if exists push_pedidos_estado on public.pedidos;
create trigger push_pedidos_estado after update of estado on public.pedidos for each row
  when (old.estado is distinct from new.estado) execute function avisar_push();
drop trigger if exists push_realizadas on public.realizadas;
create trigger push_realizadas after insert on public.realizadas for each row execute function avisar_push();
drop trigger if exists push_recomendaciones on public.recomendaciones;
create trigger push_recomendaciones after insert on public.recomendaciones for each row
  when (new.estado = 'activa') execute function avisar_push();
