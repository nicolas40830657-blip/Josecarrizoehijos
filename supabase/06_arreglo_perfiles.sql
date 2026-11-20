-- Arreglo: guardar el propio perfil (foto, color, datos de cobro) dejaba al coordinador como pendiente.
-- La app ahora usa update (no upsert) y la base impide que alguien se desactive a sí mismo.
create or replace function public.proteger_rol()
returns trigger language plpgsql set search_path to 'public' as $function$
begin
  if auth.uid() is not null then
    if tg_op = 'INSERT' then
      new.rol := 'piletero'; new.porc_productos := 0; new.activo := false;
    else
      new.rol := old.rol;
      if not es_gestor() then new.porc_productos := old.porc_productos; new.activo := old.activo;
      elsif new.id = auth.uid() then new.activo := old.activo; -- nadie se desactiva a sí mismo
      end if;
    end if;
  end if;
  return new;
end $function$;
