-- Merch Festivalazo 2026: stock de prendas y ventas.
-- Cada fila de "prendas" es una variante (modelo + color + talle) con su stock cargado.
-- Lo que queda = cargado - vendido (ventas no anuladas, incluidos regalos).

create table if not exists public.prendas (
  id bigint generated always as identity primary key,
  categoria text not null,               -- Remeras, Buzos, Tops, Gorras, Shorts
  modelo text not null,                  -- nombre/diseño, ej. "Logo El Origen"
  color text not null default '',
  talle text not null default 'Único',
  precio numeric(12,2) not null default 0 check (precio >= 0),
  cargado integer not null default 0 check (cargado >= 0),
  foto_url text,
  activo boolean not null default true,
  orden integer not null default 0,
  creado timestamptz not null default now(),
  unique (categoria, modelo, color, talle)
);

create table if not exists public.ventas (
  id bigint generated always as identity primary key,
  prenda_id bigint not null references public.prendas(id) on delete restrict,
  cantidad integer not null check (cantidad > 0),
  forma_pago text not null check (forma_pago in ('efectivo','transferencia','regalo')),
  precio_unit numeric(12,2) not null,
  total numeric(12,2) not null,
  vendedor text not null default '',
  nota text,
  anulada boolean not null default false,
  creado timestamptz not null default now()
);
create index if not exists ventas_prenda_idx on public.ventas(prenda_id);
create index if not exists ventas_creado_idx on public.ventas(creado desc);

-- Stock con vendido y lo que queda
create or replace view public.stock with (security_invoker = true) as
select p.*,
  coalesce(sum(v.cantidad) filter (where not v.anulada), 0)::int as vendido,
  coalesce(sum(v.cantidad) filter (where not v.anulada and v.forma_pago = 'regalo'), 0)::int as regalado,
  (p.cargado - coalesce(sum(v.cantidad) filter (where not v.anulada), 0))::int as queda
from public.prendas p
left join public.ventas v on v.prenda_id = p.id
group by p.id;

-- Registrar una venta controlando stock (evita vender de más con 5 celus a la vez)
create or replace function public.vender(
  p_prenda bigint, p_cantidad int, p_forma text, p_vendedor text, p_nota text default null
) returns bigint
language plpgsql security invoker set search_path = public as $$
declare
  v_prenda public.prendas;
  v_queda int;
  v_id bigint;
begin
  select * into v_prenda from public.prendas where id = p_prenda for update;
  if not found then raise exception 'La prenda no existe'; end if;
  select v_prenda.cargado - coalesce(sum(cantidad), 0) into v_queda
    from public.ventas where prenda_id = p_prenda and not anulada;
  if p_cantidad > v_queda then
    raise exception 'Solo quedan % de esta prenda', v_queda;
  end if;
  insert into public.ventas (prenda_id, cantidad, forma_pago, precio_unit, total, vendedor, nota)
  values (p_prenda, p_cantidad, p_forma,
          case when p_forma = 'regalo' then 0 else v_prenda.precio end,
          case when p_forma = 'regalo' then 0 else v_prenda.precio * p_cantidad end,
          coalesce(p_vendedor, ''), nullif(trim(p_nota), ''))
  returning id into v_id;
  return v_id;
end $$;

-- Seguridad: solo usuarios logueados (la cuenta compartida) leen y escriben
alter table public.prendas enable row level security;
alter table public.ventas enable row level security;

drop policy if exists "logueados prendas" on public.prendas;
create policy "logueados prendas" on public.prendas for all to authenticated using (true) with check (true);
drop policy if exists "logueados ventas" on public.ventas;
create policy "logueados ventas" on public.ventas for all to authenticated using (true) with check (true);

revoke all on public.prendas, public.ventas, public.stock from anon;
grant select, insert, update, delete on public.prendas, public.ventas to authenticated;
grant select on public.stock to authenticated;
revoke execute on function public.vender(bigint,int,text,text,text) from public, anon;
grant execute on function public.vender(bigint,int,text,text,text) to authenticated;

-- Tiempo real: todos los celus ven los cambios al instante
do $$ begin
  begin alter publication supabase_realtime add table public.prendas; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ventas; exception when duplicate_object then null; end;
end $$;

-- Fotos: bucket público para ver, solo logueados suben
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "fotos subir" on storage.objects;
create policy "fotos subir" on storage.objects for insert to authenticated with check (bucket_id = 'fotos');
drop policy if exists "fotos cambiar" on storage.objects;
create policy "fotos cambiar" on storage.objects for update to authenticated using (bucket_id = 'fotos');
drop policy if exists "fotos borrar" on storage.objects;
create policy "fotos borrar" on storage.objects for delete to authenticated using (bucket_id = 'fotos');
