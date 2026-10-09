-- Pre venta: algunas prendas tienen un precio especial de pre venta.
-- Se descuenta del mismo stock, se anota a nombre de quién y si ya se entregó.

alter table public.prendas add column if not exists precio_preventa numeric(12,2) check (precio_preventa >= 0);
alter table public.ventas add column if not exists preventa boolean not null default false;
alter table public.ventas add column if not exists cliente text;
alter table public.ventas add column if not exists entregada boolean not null default false;

update public.prendas set precio_preventa = 30000 where modelo = 'Remera over · nueva edición';

-- Nueva firma con p_preventa y p_cliente (se borra la anterior para que no haya dos versiones)
drop function if exists public.vender_compra(jsonb,text,numeric,text,text);

create or replace function public.vender_compra(
  p_items jsonb, p_forma text, p_efectivo numeric default 0, p_vendedor text default '', p_nota text default null,
  p_preventa boolean default false, p_cliente text default null
) returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_compra uuid := gen_random_uuid();
  v_forma text := p_forma;
  v_total numeric := 0;
  v_resto_ef numeric;
  v_precio numeric;
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
  if p_preventa and p_forma = 'regalo' then
    raise exception 'Una pre venta no puede ser regalo';
  end if;
  if p_preventa and coalesce(trim(p_cliente), '') = '' then
    raise exception 'Poné a nombre de quién es la pre venta';
  end if;

  perform 1 from public.prendas
    where id in (select (e->>'prenda')::bigint from jsonb_array_elements(p_items) e)
    order by id for update;

  for r in
    select p.id, p.modelo, p.talle, p.precio, p.precio_preventa, p.cargado, sum((e->>'cantidad')::int) as cant
    from jsonb_array_elements(p_items) e
    join public.prendas p on p.id = (e->>'prenda')::bigint
    group by p.id
  loop
    if r.cant <= 0 then raise exception 'Cantidad inválida'; end if;
    if p_preventa and r.precio_preventa is null then
      raise exception '% no tiene precio de pre venta', r.modelo;
    end if;
    if r.cant > r.cargado - coalesce((select sum(cantidad) from public.ventas where prenda_id = r.id and not anulada), 0) then
      raise exception 'No alcanza el stock de % %', r.modelo, r.talle;
    end if;
    v_precio := case when p_forma = 'regalo' then 0 when p_preventa then r.precio_preventa else r.precio end;
    v_total := v_total + v_precio * r.cant;
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

  for r in
    select p.id, p.precio, p.precio_preventa, sum((e->>'cantidad')::int) as cant
    from jsonb_array_elements(p_items) e
    join public.prendas p on p.id = (e->>'prenda')::bigint
    group by p.id order by p.id
  loop
    v_precio := case when p_forma = 'regalo' then 0 when p_preventa then r.precio_preventa else r.precio end;
    v_linea := v_precio * r.cant;
    v_ef := least(v_resto_ef, v_linea);
    v_resto_ef := v_resto_ef - v_ef;
    insert into public.ventas (compra_id, prenda_id, cantidad, forma_pago, precio_unit, total, efectivo, transferencia,
                               vendedor, nota, preventa, cliente)
    values (v_compra, r.id, r.cant, v_forma, v_precio, v_linea, v_ef, v_linea - v_ef,
            coalesce(p_vendedor, ''), nullif(trim(p_nota), ''), p_preventa, nullif(trim(p_cliente), ''));
  end loop;

  return v_compra;
end $$;

revoke execute on function public.vender_compra(jsonb,text,numeric,text,text,boolean,text) from public, anon;
grant execute on function public.vender_compra(jsonb,text,numeric,text,text,boolean,text) to authenticated;
