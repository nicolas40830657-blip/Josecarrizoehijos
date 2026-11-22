-- Reparto de cada trabajo, fijado a mano al programarlo: en % o en $ (piletero y empresa; el resto queda para materiales u otros gastos)
alter table public.trabajos add column if not exists empresa numeric check (empresa is null or empresa >= 0);
alter table public.trabajos add column if not exists reparto text not null default 'pct' check (reparto in ('pct', 'monto'));
