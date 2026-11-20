/* ============================================================================
   51 · PRUEBAS · QUÉ DOMICILIARIO LLEVÓ CADA PEDIDO

   Usa la primera empresa que tenga un dueño, un usuario de caja, un
   domiciliario y un mesero, y una sede donde trabajen caja y domiciliario.
   Se deshace sola (ROLLBACK).

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/51_pruebas_domiciliario.sql

   Tiene que salir «TODAS LAS PRUEBAS DE DOMICILIARIO PASARON».
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);

CREATE FUNCTION pg_temp.como(p_usuario INT) RETURNS VOID LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', p_usuario,
         'empresa_id', (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario))::TEXT, TRUE); $$;

CREATE FUNCTION pg_temp.app(p_sql TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v JSONB;
BEGIN
  SET LOCAL ROLE taseca_app;
  EXECUTE p_sql INTO v;
  RESET ROLE;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RETURN jsonb_build_object('error', SQLERRM);
END $$;

CREATE FUNCTION pg_temp.anotar(p_ok BOOLEAN, p_que TEXT, p_detalle TEXT DEFAULT '') RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO resultados (ok, que, detalle) VALUES (COALESCE(p_ok, FALSE), p_que, p_detalle); $$;

CREATE FUNCTION pg_temp.de_rol(p_emp INT, p_rol TEXT) RETURNS INT LANGUAGE sql AS $$
  SELECT us.id FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = p_emp AND r.codigo = p_rol AND us.activo ORDER BY us.id LIMIT 1; $$;

DO $$
DECLARE
  v_emp INT; v_uni INT; v_dueno INT; v_caja INT; v_dom INT; v_mesero INT; v_prod INT; v_zona INT;
  v_r JSONB; p1 BIGINT; p2 BIGINT; p3 BIGINT; v_dom_nombre TEXT; i INT;
BEGIN
  SELECT e.id INTO v_emp FROM core.empresas e
   WHERE e.estado = 'activa' AND pg_temp.de_rol(e.id, 'admin') IS NOT NULL AND pg_temp.de_rol(e.id, 'caja') IS NOT NULL
     AND pg_temp.de_rol(e.id, 'domiciliario') IS NOT NULL AND pg_temp.de_rol(e.id, 'mesero') IS NOT NULL
   ORDER BY e.id LIMIT 1;
  IF v_emp IS NULL THEN RAISE EXCEPTION 'No hay una empresa con dueño, caja, domiciliario y mesero para probar.'; END IF;
  v_dueno := pg_temp.de_rol(v_emp, 'admin'); v_caja := pg_temp.de_rol(v_emp, 'caja');
  v_dom := pg_temp.de_rol(v_emp, 'domiciliario'); v_mesero := pg_temp.de_rol(v_emp, 'mesero');
  SELECT nombre INTO v_dom_nombre FROM core.usuarios WHERE id = v_dom;
  SELECT u.id INTO v_uni FROM core.unidades u
   WHERE u.empresa_id = v_emp AND u.estado = 'activa'
     AND core.fn_usuario_en_unidad(v_caja, u.id) AND core.fn_usuario_en_unidad(v_dom, u.id)
   ORDER BY u.id LIMIT 1;

  /* Un producto con precio vendible en esa sede y una zona de domicilio */
  SELECT p.id INTO v_prod FROM core.productos p JOIN core.categorias c ON c.id = p.categoria_id
   WHERE p.empresa_id = v_emp AND p.precio > 0 AND p.activo AND NOT p.solo_personal AND c.activa ORDER BY p.id LIMIT 1;
  INSERT INTO core.producto_unidades (producto_id, unidad_id) VALUES (v_prod, v_uni)
  ON CONFLICT (producto_id, unidad_id) DO UPDATE SET agotado = FALSE;
  INSERT INTO core.zonas_domicilio (unidad_id, nombre, costo, pedido_minimo, activa)
  VALUES (v_uni, 'Zona prueba 51', 3000, 0, TRUE) RETURNING id INTO v_zona;
  UPDATE core.empresa_metodos_pago SET activo = TRUE
   WHERE empresa_id = v_emp AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'efectivo');
  RAISE NOTICE 'Empresa %, sede %, dueño %, caja %, domiciliario % (%), mesero %', v_emp, v_uni, v_dueno, v_caja, v_dom, v_dom_nombre, v_mesero;

  /* Tres pedidos: dos domicilios y uno para recoger */
  PERFORM pg_temp.como(v_dueno);
  FOR i IN 1..2 LOOP
    v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
             p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb, p_cliente_nombre => 'Cliente 51', p_cliente_telefono => '3001112233',
             p_direccion => 'Cra 5 # 5-5', p_zona_id => %s, p_clave => %L)$s$, v_uni, v_prod, v_zona, 'p51-' || i || clock_timestamp()));
    IF i = 1 THEN p1 := (v_r ->> 'pedido_id')::BIGINT; ELSE p2 := (v_r ->> 'pedido_id')::BIGINT; END IF;
  END LOOP;
  v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'recoger', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb, p_cliente_nombre => 'Cliente 51', p_cliente_telefono => '3001112233',
           p_clave => %L)$s$, v_uni, v_prod, 'p51-r' || clock_timestamp()));
  p3 := (v_r ->> 'pedido_id')::BIGINT;
  PERFORM pg_temp.anotar(p1 IS NOT NULL AND p2 IS NOT NULL AND p3 IS NOT NULL, 'se crean los pedidos de prueba', COALESCE(v_r ->> 'error', ''));

  /* Cocina los deja listos (el dueño avanza dos pasos) */
  FOR i IN 1..2 LOOP
    PERFORM pg_temp.app(format('SELECT rest.avanzar_estado(%s)', p1));
    PERFORM pg_temp.app(format('SELECT rest.avanzar_estado(%s)', p2));
  END LOOP;
  PERFORM pg_temp.anotar((SELECT count(*) FROM api.v_pedidos WHERE pedido_id IN (p1, p2) AND estado = 'listo') = 2, 'los dos domicilios quedan listos');

  /* ---- 1 · El domiciliario sale con P1: queda a su nombre ---- */
  PERFORM pg_temp.como(v_dom);
  v_r := pg_temp.app(format('SELECT rest.avanzar_estado(%s)', p1));
  PERFORM pg_temp.anotar((SELECT domiciliario_id FROM core.pedidos WHERE id = p1) = v_dom,
                         'al salir el domiciliario, el pedido queda a su nombre', COALESCE(v_r ->> 'error', v_r ->> 'estado'));
  PERFORM pg_temp.anotar(v_r ->> 'domiciliario' = v_dom_nombre, 'el pedido que ve el panel trae el domiciliario', v_r ->> 'domiciliario');
  PERFORM pg_temp.anotar(EXISTS (SELECT 1 FROM core.pedido_historial WHERE pedido_id = p1 AND descripcion = 'Lo lleva: ' || v_dom_nombre),
                         'queda en el historial: «Lo lleva: …»');

  /* ---- 2 · Si lo despacha el dueño (no es domiciliario), queda sin asignar ---- */
  PERFORM pg_temp.como(v_dueno);
  v_r := pg_temp.app(format('SELECT rest.avanzar_estado(%s)', p2));
  PERFORM pg_temp.anotar((SELECT domiciliario_id FROM core.pedidos WHERE id = p2) IS NULL AND v_r ->> 'estado' = 'camino',
                         'despachado por quien no es domiciliario: queda sin asignar', COALESCE(v_r ->> 'error', ''));

  /* ---- 3 · La lista de domiciliarios: caja sí, mesero no ---- */
  PERFORM pg_temp.como(v_caja);
  v_r := pg_temp.app(format('SELECT to_jsonb(count(*)) FROM rest.domiciliarios WHERE usuario_id = %s', v_dom));
  PERFORM pg_temp.anotar(v_r = '1'::JSONB, 'caja ve la lista de domiciliarios', v_r::TEXT);
  v_r := pg_temp.app('SELECT to_jsonb(array_agg(DISTINCT k)) FROM rest.domiciliarios d, jsonb_object_keys(to_jsonb(d)) k');
  PERFORM pg_temp.anotar(NOT (v_r ? 'usuario') AND NOT (v_r ? 'pin_hash'), 'la lista no trae datos de acceso', v_r::TEXT);
  PERFORM pg_temp.como(v_mesero);
  v_r := pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.domiciliarios');
  PERFORM pg_temp.anotar(v_r = '0'::JSONB, 'el mesero no ve la lista', v_r::TEXT);

  /* ---- 4 · Caja asigna a mano ---- */
  PERFORM pg_temp.como(v_caja);
  v_r := pg_temp.app(format('SELECT rest.asignar_domiciliario(%s, %s)', p2, v_dom));
  PERFORM pg_temp.anotar((SELECT domiciliario_id FROM core.pedidos WHERE id = p2) = v_dom, 'caja asigna el domiciliario', COALESCE(v_r ->> 'error', ''));
  PERFORM pg_temp.anotar(EXISTS (SELECT 1 FROM core.pedido_historial WHERE pedido_id = p2 AND descripcion = 'Domiciliario: ' || v_dom_nombre),
                         'queda en el historial: «Domiciliario: …»');
  v_r := pg_temp.app(format('SELECT rest.asignar_domiciliario(%s, %s)', p2, v_mesero));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no es domiciliario%', 'no se asigna a quien no es domiciliario', v_r::TEXT);
  v_r := pg_temp.app(format('SELECT rest.asignar_domiciliario(%s, %s)', p3, v_dom));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no es un domicilio%', 'un pedido para recoger no lleva domiciliario', v_r::TEXT);
  v_r := pg_temp.app(format('SELECT rest.asignar_domiciliario(%s, NULL)', p2));
  PERFORM pg_temp.anotar((SELECT domiciliario_id FROM core.pedidos WHERE id = p2) IS NULL
                     AND EXISTS (SELECT 1 FROM core.pedido_historial WHERE pedido_id = p2 AND descripcion LIKE 'Domiciliario quitado%'),
                         'caja puede quitarlo', COALESCE(v_r ->> 'error', ''));
  PERFORM pg_temp.como(v_mesero);
  v_r := pg_temp.app(format('SELECT rest.asignar_domiciliario(%s, %s)', p2, v_dom));
  PERFORM pg_temp.anotar(v_r ? 'error', 'el mesero no asigna domiciliarios', v_r::TEXT);

  /* ---- 5 · Red de seguridad: nadie que no sea domiciliario, ni a mano ---- */
  BEGIN
    UPDATE core.pedidos SET domiciliario_id = v_dueno WHERE id = p2;
    PERFORM pg_temp.anotar(FALSE, 'un UPDATE directo con un no-domiciliario se bloquea', 'lo dejó pasar');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.anotar(SQLERRM LIKE '%no es domiciliario%', 'un UPDATE directo con un no-domiciliario se bloquea', SQLERRM);
  END;

  /* ---- 6 · Cobrarle al domiciliario: lo cobrado ya no cambia de dueño ---- */
  PERFORM pg_temp.como(v_caja);
  v_r := pg_temp.app(format($s$SELECT rest.confirmar_pagos(ARRAY[%s]::bigint[], %L)$s$, p1, 'Lo entregó ' || v_dom_nombre));
  PERFORM pg_temp.anotar((v_r ->> 'cobrados')::INT = 1, 'caja le cobra el efectivo al domiciliario', COALESCE(v_r ->> 'error', v_r::TEXT));
  v_r := pg_temp.app(format('SELECT rest.asignar_domiciliario(%s, NULL)', p1));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%ya se cobró%', 'un pago ya cobrado no cambia de domiciliario', v_r::TEXT);

  /* ---- 7 · Entregar no cambia quién lo llevó ---- */
  PERFORM pg_temp.como(v_dom);
  v_r := pg_temp.app(format('SELECT rest.avanzar_estado(%s)', p1));
  PERFORM pg_temp.anotar(v_r ->> 'estado' = 'entregado' AND (v_r ->> 'domiciliario_id')::INT = v_dom,
                         'al entregar sigue a su nombre', COALESCE(v_r ->> 'error', v_r ->> 'estado'));
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE DOMICILIARIO PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
