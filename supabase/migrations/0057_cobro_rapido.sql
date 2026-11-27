-- 0057 · Cobro más rápido: menos viajes al servidor. No cambia ninguna comprobación.
--  1. guardar_ronda_barra: en Barra, crear la cuenta (si es nueva), añadir los platos y devolver la
--     cuenta con los precios que pone la base, en UN viaje (antes, tres). Corre con los permisos de
--     quien llama (security invoker): las mismas reglas, políticas y triggers que antes
--     (precio de la base, permisos del camarero, cocina…).
--  2. tbai_contexto_registro: lo que la función ticketbai necesita para guardar una factura (quién
--     llama, su rol, los datos fiscales, la última factura de la cadena, el último número, el pedido y
--     si ya tiene factura) en UNA consulta (antes, cinco). No devuelve datos de clientes ni ficheros.
-- Ejecutar entero en el SQL Editor ANTES de desplegar la función ticketbai nueva. Se puede ejecutar
-- más de una vez.

-- =====================================================================
-- 1 · Barra: guardar la ronda y devolver la cuenta
-- =====================================================================
create or replace function public.guardar_ronda_barra(p_pedido uuid, p_nombre text, p_lineas jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v uuid := p_pedido;
begin
  if v is null then
    insert into public.pedidos (tipo, nombre_llevar, camarero_id)
    values ('barra', p_nombre, auth.uid())
    returning id into v;
  end if;
  if jsonb_typeof(p_lineas) = 'array' and jsonb_array_length(p_lineas) > 0 then
    -- El precio que manda la app no vale: lo pone la base (precio_de_linea, 0049)
    insert into public.pedido_detalle (pedido_id, producto_id, area_id, descripcion, cantidad, precio_unitario,
                                       modificadores, estado_cocina, curso)
    select v, (x->>'producto_id')::uuid, nullif(x->>'area_id', '')::uuid, x->>'descripcion',
           (x->>'cantidad')::numeric, coalesce((x->>'precio_unitario')::numeric, 0),
           coalesce((select array_agg(m::uuid) from jsonb_array_elements_text(coalesce(x->'modificadores', '[]'::jsonb)) m),
                    '{}'::uuid[]),
           coalesce(x->>'estado_cocina', 'pendiente'), coalesce(x->>'curso', 'ya')
      from jsonb_array_elements(p_lineas) x;
  end if;
  -- La cuenta como la leía la app después (el total ya recalculado por la base)
  return (
    select jsonb_build_object(
      'id', p.id, 'total', p.total,
      'pedido_detalle', coalesce((
        select jsonb_agg(jsonb_build_object('id', d.id, 'descripcion', d.descripcion, 'cantidad', d.cantidad,
                                            'precio_unitario', d.precio_unitario, 'tipo_iva', d.tipo_iva,
                                            'estado_cocina', d.estado_cocina) order by d.creado_en)
          from public.pedido_detalle d where d.pedido_id = p.id), '[]'::jsonb))
      from public.pedidos p where p.id = v);
end $$;
revoke all on function public.guardar_ronda_barra(uuid, text, jsonb) from public, anon;
grant execute on function public.guardar_ronda_barra(uuid, text, jsonb) to authenticated;

-- =====================================================================
-- 2 · Lo que necesita ticketbai para guardar una factura, en una consulta
-- =====================================================================
create or replace function public.tbai_contexto_registro(p_cadena text, p_serie text, p_pedido uuid, p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := public.empresa_actual();
  v_rol text := public.mi_rol();
  v_cfg record;
  v_ultima jsonb;
  v_ped record;
begin
  if auth.uid() is null then
    raise exception 'Sin sesión';
  end if;
  select t.empresa_id, t.entorno, t.nif into v_cfg from public.tbai_config t where t.empresa_id = v_empresa;
  -- Lo mismo que tbai_ultima_factura (0050): sin datos del cliente ni fichero
  select to_jsonb(u) into v_ultima from public.tbai_ultima_factura(p_cadena) u limit 1;
  -- Siempre (sin pedido no hay fila y queda vacío); solo uno de este bar
  select pe.id, pe.empresa_id, pe.total into v_ped from public.pedidos pe where pe.id = p_pedido and pe.empresa_id = v_empresa;
  return jsonb_build_object(
    'usuario', auth.uid(),
    'rol', v_rol,
    'config', case when v_cfg.empresa_id is null then null
                   else jsonb_build_object('empresa_id', v_cfg.empresa_id, 'entorno', v_cfg.entorno, 'nif', v_cfg.nif) end,
    -- Solo para quien cobra: a los demás (cocina) no se les da nada de las facturas
    'ultima', case when v_rol in ('admin', 'camarero') then v_ultima end,
    'ultimo_numero', case when v_rol in ('admin', 'camarero') then public.tbai_ultimo_numero(p_serie) end,
    'pedido', case when v_ped.id is not null and v_rol in ('admin', 'camarero')
                   then jsonb_build_object('id', v_ped.id, 'empresa_id', v_ped.empresa_id, 'total', v_ped.total) end,
    -- Solo si existen (sí o no): la fila entera la lee la función con la clave de servicio
    'pedido_con_factura', p_pedido is not null and v_rol in ('admin', 'camarero')
                          and exists (select 1 from public.facturas f where f.pedido_id = p_pedido and f.empresa_id = v_empresa),
    'ya_guardada', p_id is not null and v_rol in ('admin', 'camarero')
                   and exists (select 1 from public.facturas f where f.id = p_id and f.empresa_id = v_empresa)
  );
end $$;
revoke all on function public.tbai_contexto_registro(text, text, uuid, uuid) from public, anon;
grant execute on function public.tbai_contexto_registro(text, text, uuid, uuid) to authenticated;
