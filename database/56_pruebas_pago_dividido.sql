/* ============================================================================
   56 · PRUEBAS · PAGO DIVIDIDO

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/56_pruebas_pago_dividido.sql

   Se deshace sola. Tiene que salir «TODAS LAS PRUEBAS DE PAGO DIVIDIDO PASARON».
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);

CREATE FUNCTION pg_temp.app(p_sql TEXT, p_rol TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v JSONB;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  EXECUTE p_sql INTO v;
  RESET ROLE;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RETURN jsonb_build_object('error', SQLERRM);
END $$;

CREATE FUNCTION pg_temp.anotar(p_ok BOOLEAN, p_que TEXT, p_detalle TEXT DEFAULT '') RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO resultados (ok, que, detalle) VALUES (COALESCE(p_ok, FALSE), p_que, p_detalle); $$;

-- Lo cobrado de un método en el informe de caja (0 si no aparece)
CREATE FUNCTION pg_temp.cobrado(p_inf JSONB, p_metodo TEXT) RETURNS NUMERIC LANGUAGE sql AS $$
  SELECT COALESCE((p_inf -> 'ventas' -> p_metodo ->> 'cobrado')::NUMERIC, 0) $$;

DO $$
DECLARE
  v_emp INT; v_uni INT; v_dueno INT; v_prod INT; v_precio NUMERIC; v_r JSONB; v_id BIGINT;
  v_cuenta NUMERIC; v_ef NUMERIC; v_antes JSONB; v_despues JSONB; v_fecha DATE;
  v_mal_antes BIGINT; v_mal_despues BIGINT; v_clave TEXT; v_n INT;
BEGIN
  SELECT pu.unidad_id, pu.producto_id, u.empresa_id, pr.precio INTO v_uni, v_prod, v_emp, v_precio
    FROM core.producto_unidades pu JOIN core.productos pr ON pr.id = pu.producto_id
    JOIN core.categorias c ON c.id = pr.categoria_id JOIN core.unidades u ON u.id = pu.unidad_id
   WHERE pr.precio >= 2000 AND pr.activo AND NOT pr.solo_personal AND c.activa AND NOT pu.agotado AND u.estado = 'activa'
   ORDER BY pu.unidad_id, pu.producto_id LIMIT 1;
  SELECT us.id INTO v_dueno FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = v_emp AND r.codigo = 'admin' AND us.activo ORDER BY us.id LIMIT 1;

  -- Efectivo sin recargo y Nequi con $500 fijos
  UPDATE core.empresa_metodos_pago SET activo = TRUE WHERE empresa_id = v_emp
     AND metodo_pago_id IN (core.fn_id_catalogo('metodos_pago', 'efectivo'), core.fn_id_catalogo('metodos_pago', 'nequi'));
  UPDATE core.empresa_metodos_pago SET recargo = 0 WHERE empresa_id = v_emp
     AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'efectivo');
  UPDATE core.empresa_metodos_pago SET recargo = 500, recargo_tipo = 'fijo' WHERE empresa_id = v_emp
     AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'nequi');

  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_dueno, 'empresa_id', v_emp)::TEXT, TRUE);

  SELECT COALESCE(sum(filas), 0) INTO v_mal_antes FROM api.fn_chequeo_integridad()
   WHERE chequeo = 'El método de pago no está habilitado en esa empresa';

  -- Un pedido para recoger, por cobrar, de 2 unidades
  v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'recoger', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":2}]'::jsonb, p_cliente_nombre => 'Cliente 56',
           p_cliente_telefono => '3005556677', p_clave => %L)$s$, v_uni, v_prod, 'p56a' || clock_timestamp()), 'taseca_app');
  v_id := (v_r ->> 'pedido_id')::BIGINT;
  v_cuenta := (v_r ->> 'subtotal')::NUMERIC + (v_r ->> 'costo_domicilio')::NUMERIC;
  v_fecha := (v_r ->> 'fecha_operativa')::DATE;
  v_ef := round(v_cuenta / 3);
  PERFORM pg_temp.anotar(v_id IS NOT NULL, 'se crea el pedido de prueba', COALESCE(v_r ->> 'error', ''));

  v_antes := pg_temp.app(format('SELECT rest.informe_caja(%L::DATE, %s)', v_fecha, v_uni), 'taseca_app');

  -- Lo que NO debe entrar
  v_r := pg_temp.app(format($s$SELECT rest.confirmar_pago_dividido(%s, '[{"metodo":"efectivo","base":%s}]'::jsonb)$s$, v_id, v_cuenta), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%al menos dos métodos%', 'una sola parte: no se acepta', v_r::TEXT);

  v_r := pg_temp.app(format($s$SELECT rest.confirmar_pago_dividido(%s, '[{"metodo":"efectivo","base":%s},{"metodo":"nequi","base":%s}]'::jsonb)$s$,
           v_id, v_ef, v_cuenta - v_ef - 100), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%tienen que dar lo mismo%', 'partes que no suman la cuenta: no se acepta', v_r::TEXT);

  v_r := pg_temp.app(format($s$SELECT rest.confirmar_pago_dividido(%s, '[{"metodo":"nequi","base":%s},{"metodo":"nequi","base":%s}]'::jsonb)$s$,
           v_id, v_ef, v_cuenta - v_ef), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%dos veces%', 'el mismo método dos veces: no se acepta', v_r::TEXT);

  v_r := pg_temp.app(format($s$SELECT rest.confirmar_pago_dividido(%s, '[{"metodo":"efectivo","base":%s},{"metodo":"mixto","base":%s}]'::jsonb)$s$,
           v_id, v_ef, v_cuenta - v_ef), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ->> 'error' IS NOT NULL, '«Pago dividido» no se elige como parte', v_r::TEXT);

  PERFORM pg_temp.anotar(NOT EXISTS (SELECT 1 FROM core.pedido_pagos WHERE pedido_id = v_id),
                         'los intentos fallidos no dejan partes sueltas');

  -- El bueno: un tercio en efectivo, el resto por Nequi (+500)
  v_r := pg_temp.app(format($s$SELECT rest.confirmar_pago_dividido(%s, '[{"metodo":"efectivo","base":%s},{"metodo":"nequi","base":%s}]'::jsonb, 'REF-56')$s$,
           v_id, v_ef, v_cuenta - v_ef), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ->> 'estado_pago' = 'confirmado' AND v_r ->> 'metodo_pago' = 'mixto',
                         'cobro dividido: queda confirmado y como «Pago dividido»', COALESCE(v_r ->> 'error', v_r ->> 'metodo_pago'));
  PERFORM pg_temp.anotar((v_r ->> 'recargo_pago')::NUMERIC = 500 AND (v_r ->> 'total')::NUMERIC = v_cuenta + 500,
                         'el recargo de Nequi va sólo sobre su parte y sube el total', v_r ->> 'total');
  PERFORM pg_temp.anotar(jsonb_array_length(v_r -> 'pagos') = 2
                         AND (v_r -> 'pagos' -> 1 ->> 'valor')::NUMERIC = v_cuenta - v_ef + 500,
                         'el pedido trae sus dos partes', COALESCE((v_r -> 'pagos')::TEXT, ''));
  PERFORM pg_temp.anotar(EXISTS (SELECT 1 FROM core.pedido_historial WHERE pedido_id = v_id AND descripcion LIKE 'Pago dividido:%'),
                         'el historial dice cómo se dividió');

  v_r := pg_temp.app(format($s$SELECT rest.confirmar_pago_dividido(%s, '[{"metodo":"efectivo","base":%s},{"metodo":"nequi","base":%s}]'::jsonb)$s$,
           v_id, v_ef, v_cuenta - v_ef), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%ya fue confirmado%', 'no se cobra dos veces', v_r::TEXT);

  -- El cruce de caja: cada parte en su columna
  v_despues := pg_temp.app(format('SELECT rest.informe_caja(%L::DATE, %s)', v_fecha, v_uni), 'taseca_app');
  PERFORM pg_temp.anotar(pg_temp.cobrado(v_despues, 'efectivo') - pg_temp.cobrado(v_antes, 'efectivo') = v_ef,
                         'el cruce suma al efectivo sólo la parte en efectivo',
                         (pg_temp.cobrado(v_despues, 'efectivo') - pg_temp.cobrado(v_antes, 'efectivo'))::TEXT);
  PERFORM pg_temp.anotar(pg_temp.cobrado(v_despues, 'nequi') - pg_temp.cobrado(v_antes, 'nequi') = v_cuenta - v_ef + 500,
                         'y a Nequi su parte con el recargo',
                         (pg_temp.cobrado(v_despues, 'nequi') - pg_temp.cobrado(v_antes, 'nequi'))::TEXT);
  PERFORM pg_temp.anotar(NOT (v_despues -> 'ventas' ? 'mixto'), '«Pago dividido» no aparece como columna del cruce');

  -- Inmutable
  BEGIN
    UPDATE core.pedido_pagos SET base = base + 1 WHERE pedido_id = v_id;
    PERFORM pg_temp.anotar(FALSE, 'una parte confirmada no se edita');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.anotar(SQLERRM LIKE '%no se modifican%', 'una parte confirmada no se edita', SQLERRM);
  END;

  -- Venta de mostrador dividida
  v_clave := 'p56m' || clock_timestamp();
  v_r := pg_temp.app(format($s$SELECT rest.vender_con_pago_dividido(%s, '[{"producto_id":%s,"cantidad":1}]'::jsonb,
           '[{"metodo":"efectivo","base":1000},{"metodo":"nequi","base":%s}]'::jsonb, %L)$s$, v_uni, v_prod, v_precio - 1000, v_clave), 'taseca_app');
  v_id := (v_r ->> 'pedido_id')::BIGINT;
  PERFORM pg_temp.anotar(v_r ->> 'estado_pago' = 'confirmado' AND v_r ->> 'metodo_pago' = 'mixto'
                         AND jsonb_array_length(v_r -> 'pagos') = 2,
                         'venta de mostrador dividida: nace cobrada en dos partes', COALESCE(v_r ->> 'error', v_r::TEXT));

  v_r := pg_temp.app(format($s$SELECT rest.vender_con_pago_dividido(%s, '[{"producto_id":%s,"cantidad":1}]'::jsonb,
           '[{"metodo":"efectivo","base":1000},{"metodo":"nequi","base":%s}]'::jsonb, %L)$s$, v_uni, v_prod, v_precio - 1000, v_clave), 'taseca_app');
  PERFORM pg_temp.anotar((v_r ->> 'pedido_id')::BIGINT = v_id, 'el mismo toque dos veces: una sola venta', COALESCE(v_r ->> 'error', ''));

  v_clave := 'p56n' || clock_timestamp();
  v_r := pg_temp.app(format($s$SELECT rest.vender_con_pago_dividido(%s, '[{"producto_id":%s,"cantidad":1}]'::jsonb,
           '[{"metodo":"efectivo","base":1000},{"metodo":"nequi","base":1}]'::jsonb, %L)$s$, v_uni, v_prod, v_clave), 'taseca_app');
  SELECT count(*) INTO v_n FROM core.pedidos WHERE clave_envio = v_clave;
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%tienen que dar lo mismo%' AND v_n = 0,
                         'venta con partes que no cuadran: no queda registrada', COALESCE(v_r::TEXT, ''));

  -- La venta de mostrador de siempre no cambió
  v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'mostrador', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb, p_clave => %L)$s$, v_uni, v_prod, 'p56o' || clock_timestamp()), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ->> 'estado_pago' = 'confirmado' AND v_r ->> 'metodo_pago' = 'efectivo'
                         AND jsonb_array_length(v_r -> 'pagos') = 0,
                         'venta de mostrador con un solo método: igual que antes', COALESCE(v_r ->> 'error', ''));

  -- El chequeo de integridad no marca los pagos divididos como error
  SELECT COALESCE(sum(filas), 0) INTO v_mal_despues FROM api.fn_chequeo_integridad()
   WHERE chequeo = 'El método de pago no está habilitado en esa empresa';
  PERFORM pg_temp.anotar(v_mal_despues = v_mal_antes, 'el chequeo de integridad acepta «Pago dividido»',
                         v_mal_antes || ' → ' || v_mal_despues);
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE PAGO DIVIDIDO PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
