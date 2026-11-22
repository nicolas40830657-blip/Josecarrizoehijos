-- Limpieza automática del chat del equipo: todos los días a las 4 de la mañana (hora de Argentina = 07:00 UTC)
-- se borran los mensajes con más de 30 días y sus fotos (Edge Function limpiar-chat).
create extension if not exists pg_cron;

create or replace function public.limpiar_chat_equipo()
returns void language plpgsql security definer set search_path = public, vault, extensions as $$
declare s text;
begin
  select decrypted_secret into s from vault.decrypted_secrets where name = 'push_secreto';
  perform net.http_post(
    url := 'https://gqromisweyqvdeeahxnl.supabase.co/functions/v1/limpiar-chat',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-secreto', s),
    timeout_milliseconds := 60000);
end $$;
revoke execute on function public.limpiar_chat_equipo() from public, anon, authenticated;

select cron.unschedule('limpiar-chat-equipo') where exists (select 1 from cron.job where jobname = 'limpiar-chat-equipo');
select cron.schedule('limpiar-chat-equipo', '0 7 * * *', 'select public.limpiar_chat_equipo()');
