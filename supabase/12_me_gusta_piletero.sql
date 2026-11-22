-- Cada "me gusta" guarda a qué piletero le corresponde (el que hizo esa visita, o el del cliente)
alter table public.me_gusta add column if not exists piletero_id uuid;
create index if not exists me_gusta_piletero on public.me_gusta (piletero_id, creado desc);

create or replace function public.me_gusta_piletero()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select coalesce(r.piletero_id, c.piletero_id) into new.piletero_id
    from fotos f
    left join realizadas r on r.id = f.realizada_id
    left join clientes c on c.id = f.cliente_id
   where f.id = new.foto_id;
  return new;
end $$;
revoke execute on function public.me_gusta_piletero() from public, anon, authenticated;
drop trigger if exists t_me_gusta_piletero on public.me_gusta;
create trigger t_me_gusta_piletero before insert on public.me_gusta for each row execute function me_gusta_piletero();

update public.me_gusta g set piletero_id = coalesce(r.piletero_id, c.piletero_id)
  from fotos f left join realizadas r on r.id = f.realizada_id left join clientes c on c.id = f.cliente_id
 where f.id = g.foto_id and g.piletero_id is null;
