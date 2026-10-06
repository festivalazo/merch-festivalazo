-- Compras con varias prendas y pago mixto (parte efectivo, parte transferencia).
-- Cada fila de ventas sigue siendo una prenda; las de una misma compra comparten compra_id.
-- efectivo + transferencia = total de la fila (0 y 0 en regalos).

alter table public.ventas add column if not exists compra_id uuid;
alter table public.ventas add column if not exists efectivo numeric(12,2) not null default 0;
alter table public.ventas add column if not exists transferencia numeric(12,2) not null default 0;

update public.ventas set efectivo = total where forma_pago = 'efectivo' and efectivo = 0 and transferencia = 0;
update public.ventas set transferencia = total where forma_pago = 'transferencia' and efectivo = 0 and transferencia = 0;
update public.ventas set compra_id = gen_random_uuid() where compra_id is null;
alter table public.ventas alter column compra_id set default gen_random_uuid();
alter table public.ventas alter column compra_id set not null;
create index if not exists ventas_compra_idx on public.ventas(compra_id);

alter table public.ventas drop constraint if exists ventas_forma_pago_check;
alter table public.ventas add constraint ventas_forma_pago_check
  check (forma_pago in ('efectivo','transferencia','mixto','regalo'));

-- Registra una compra completa de una vez, controlando el stock de todas las prendas.
-- p_items: [{"prenda": 12, "cantidad": 2}, ...]
-- p_efectivo: solo para 'mixto' (cuánto pagó en efectivo; el resto es transferencia).
create or replace function public.vender_compra(
  p_items jsonb, p_forma text, p_efectivo numeric default 0, p_vendedor text default '', p_nota text default null
) returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_compra uuid := gen_random_uuid();
  v_forma text := p_forma;
  v_total numeric := 0;
  v_resto_ef numeric;
  v_linea numeric;
  v_ef numeric;
  r record;
begin
  if p_forma not in ('efectivo','transferencia','mixto','regalo') then
    raise exception 'Forma de pago inválida';
  end if;
  if jsonb_array_length(coalesce(p_items, '[]'::jsonb)) = 0 then
    raise exception 'La compra no tiene prendas';
  end if;

  -- Bloquea las prendas (en orden, para que dos celus no se traben) y controla stock
  perform 1 from public.prendas
    where id in (select (e->>'prenda')::bigint from jsonb_array_elements(p_items) e)
    order by id for update;

  for r in
    select p.id, p.modelo, p.talle, p.precio, p.cargado, sum((e->>'cantidad')::int) as cant
    from jsonb_array_elements(p_items) e
    join public.prendas p on p.id = (e->>'prenda')::bigint
    group by p.id
  loop
    if r.cant <= 0 then raise exception 'Cantidad inválida'; end if;
    if r.cant > r.cargado - coalesce((select sum(cantidad) from public.ventas where prenda_id = r.id and not anulada), 0) then
      raise exception 'No alcanza el stock de % %', r.modelo, r.talle;
    end if;
    v_total := v_total + case when p_forma = 'regalo' then 0 else r.precio * r.cant end;
  end loop;

  if p_forma = 'mixto' then
    if p_efectivo is null or p_efectivo < 0 or p_efectivo > v_total then
      raise exception 'El efectivo tiene que estar entre 0 y %', v_total;
    end if;
    v_resto_ef := p_efectivo;
    if p_efectivo = 0 then v_forma := 'transferencia'; elsif p_efectivo = v_total then v_forma := 'efectivo'; end if;
  elsif p_forma = 'efectivo' then
    v_resto_ef := v_total;
  else
    v_resto_ef := 0;
  end if;

  -- Una fila por prenda; el efectivo se reparte entre las filas y el resto va a transferencia
  for r in
    select p.id, p.precio, sum((e->>'cantidad')::int) as cant
    from jsonb_array_elements(p_items) e
    join public.prendas p on p.id = (e->>'prenda')::bigint
    group by p.id order by p.id
  loop
    v_linea := case when p_forma = 'regalo' then 0 else r.precio * r.cant end;
    v_ef := least(v_resto_ef, v_linea);
    v_resto_ef := v_resto_ef - v_ef;
    insert into public.ventas (compra_id, prenda_id, cantidad, forma_pago, precio_unit, total, efectivo, transferencia, vendedor, nota)
    values (v_compra, r.id, r.cant, v_forma,
            case when p_forma = 'regalo' then 0 else r.precio end,
            v_linea, v_ef, v_linea - v_ef, coalesce(p_vendedor, ''), nullif(trim(p_nota), ''));
  end loop;

  return v_compra;
end $$;

revoke execute on function public.vender_compra(jsonb,text,numeric,text,text) from public, anon;
grant execute on function public.vender_compra(jsonb,text,numeric,text,text) to authenticated;

-- La función vieja (una prenda) sigue andando por si algún celu tiene la versión anterior abierta
create or replace function public.vender(
  p_prenda bigint, p_cantidad int, p_forma text, p_vendedor text, p_nota text default null
) returns bigint
language plpgsql security invoker set search_path = public as $$
declare v_compra uuid; v_id bigint;
begin
  v_compra := public.vender_compra(jsonb_build_array(jsonb_build_object('prenda', p_prenda, 'cantidad', p_cantidad)),
                                   p_forma, 0, p_vendedor, p_nota);
  select id into v_id from public.ventas where compra_id = v_compra limit 1;
  return v_id;
end $$;
