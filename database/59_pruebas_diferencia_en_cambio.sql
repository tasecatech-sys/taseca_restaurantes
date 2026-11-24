/* ============================================================================
   59 · PRUEBAS · LA DIFERENCIA DE PRECIO AL ELEGIR

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/59_pruebas_diferencia_en_cambio.sql

   Se deshace sola. Tiene que salir «TODAS LAS PRUEBAS DE LA DIFERENCIA PASARON».
   Monta su propia empresa: no depende de los datos que haya.
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);
GRANT ALL ON resultados TO PUBLIC;

CREATE FUNCTION pg_temp.anotar(p_ok BOOLEAN, p_que TEXT, p_detalle TEXT DEFAULT '') RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO resultados (ok, que, detalle) VALUES (COALESCE(p_ok, FALSE), p_que, p_detalle); $$;

CREATE FUNCTION pg_temp.como(p_rol TEXT, p_sql TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
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

CREATE FUNCTION pg_temp.extra(p_cambios JSONB, p_nombre TEXT) RETURNS NUMERIC LANGUAGE sql AS $$
  SELECT (o ->> 'extra')::NUMERIC FROM jsonb_array_elements(p_cambios -> 0 -> 'opciones') o WHERE o ->> 'nombre' = p_nombre; $$;

DO $$
DECLARE
  v_emp INT; v_uni INT; v_cat INT; v_admin INT; v_cat_ins INT;
  v_bar INT := (SELECT id FROM core.areas_inventario WHERE codigo = 'bar');
  v_um  INT := (SELECT id FROM core.unidades_medida ORDER BY id LIMIT 1);
  v_combo INT; v_super INT; v_p_post INT; v_p_coca INT; v_p_ging INT;
  v_post INT; v_coca INT; v_ging INT; v_kola INT;
  v_ped BIGINT; v_cod VARCHAR; v_item BIGINT; v_r JSONB; v_n NUMERIC; v_txt TEXT;
BEGIN
  INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_t59', 'Pollos T59') RETURNING id INTO v_emp;
  INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo) SELECT v_emp, id, TRUE FROM core.modulos;
  INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos) VALUES (v_emp, 'pedido', 0, 5);
  INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo)
  SELECT v_emp, id, TRUE FROM core.metodos_pago WHERE codigo = 'efectivo';
  INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
  VALUES (v_emp, (SELECT id FROM core.tipos_negocio ORDER BY id LIMIT 1), 'T59 · Sede', 'T59') RETURNING id INTO v_uni;
  INSERT INTO core.mesas (unidad_id, numero) VALUES (v_uni, '1');
  INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_emp, 'Pollo') RETURNING id INTO v_cat;

  -- Combo $40.000 con 1 gaseosa; Super con 2. Las gaseosas sueltas: 6.000 / 7.000 / 5.000
  INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio) VALUES (v_emp, v_cat, 'T59-C', 'Combo', 40000) RETURNING id INTO v_combo;
  INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio) VALUES (v_emp, v_cat, 'T59-S', 'Super', 60000) RETURNING id INTO v_super;
  INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio) VALUES (v_emp, v_cat, 'T59-P', 'Postobón 1.5', 6000) RETURNING id INTO v_p_post;
  INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio) VALUES (v_emp, v_cat, 'T59-K', 'Coca-Cola 1.5', 7000) RETURNING id INTO v_p_coca;
  INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio) VALUES (v_emp, v_cat, 'T59-G', 'Ginger 1.5', 5000) RETURNING id INTO v_p_ging;
  INSERT INTO core.producto_unidades (producto_id, unidad_id) SELECT x, v_uni FROM unnest(ARRAY[v_combo, v_super, v_p_post, v_p_coca, v_p_ging]) x;

  INSERT INTO core.categorias_insumo (empresa_id, nombre) VALUES (v_emp, 'Bebidas') RETURNING id INTO v_cat_ins;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, grupo_cambio)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T59POST', 'Postobón 1.5', 'Gaseosa 1.5') RETURNING id INTO v_post;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, grupo_cambio)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T59COCA', 'Coca-Cola 1.5', 'Gaseosa 1.5') RETURNING id INTO v_coca;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, grupo_cambio)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T59GING', 'Ginger 1.5', 'Gaseosa 1.5') RETURNING id INTO v_ging;
  -- Una que no se vende sola: no hay con qué comparar
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, grupo_cambio)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T59KOLA', 'Kola 1.5', 'Gaseosa 1.5') RETURNING id INTO v_kola;
  INSERT INTO core.insumo_unidades (insumo_id, unidad_id) SELECT x, v_uni FROM unnest(ARRAY[v_post, v_coca, v_ging, v_kola]) x;

  INSERT INTO core.producto_insumos (producto_id, insumo_id, cantidad, cambiable)
  VALUES (v_combo, v_post, 1, TRUE), (v_super, v_post, 2, TRUE),
         (v_p_post, v_post, 1, FALSE), (v_p_coca, v_coca, 1, FALSE), (v_p_ging, v_ging, 1, FALSE);

  INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
  VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'admin'), 'Admin T59', 't59.admin', core.fn_hash_pin('1111'))
  RETURNING id INTO v_admin;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_admin, 'empresa_id', v_emp)::TEXT, TRUE);

  /* 1 · La carta dice cuánto cuesta de más cada opción */
  SELECT cambios INTO v_r FROM rest.carta WHERE producto_id = v_combo;
  PERFORM pg_temp.anotar(pg_temp.extra(v_r, 'Postobón 1.5') = 0 AND pg_temp.extra(v_r, 'Coca-Cola 1.5') = 1000
                         AND pg_temp.extra(v_r, 'Ginger 1.5') = 0 AND pg_temp.extra(v_r, 'Kola 1.5') = 0,
                         'carta: Coca-Cola +1.000; Ginger (más barata) y Kola (no se vende sola) +0', v_r::TEXT);
  SELECT cambios INTO v_r FROM rest.carta WHERE producto_id = v_super;
  PERFORM pg_temp.anotar(pg_temp.extra(v_r, 'Coca-Cola 1.5') = 2000, 'el Super lleva 2 gaseosas: Coca-Cola +2.000', v_r::TEXT);

  /* 2 · El portal sin sesión también lo lee */
  v_r := pg_temp.como('taseca_anon', format('SELECT cambios FROM rest.carta WHERE producto_id = %s', v_combo));
  PERFORM pg_temp.anotar(v_r ->> 'error' IS NULL AND pg_temp.extra(v_r, 'Coca-Cola 1.5') = 1000,
                         'el portal (taseca_anon) lee la carta con la diferencia', v_r::TEXT);
  v_r := pg_temp.como('taseca_app', format('SELECT cambios FROM rest.carta WHERE producto_id = %s', v_combo));
  PERFORM pg_temp.anotar(v_r ->> 'error' IS NULL AND pg_temp.extra(v_r, 'Coca-Cola 1.5') = 1000,
                         'el panel (taseca_app) también', v_r::TEXT);

  /* 3 · Combo con Coca-Cola: 41.000, y la diferencia queda guardada */
  CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_combo, 'cantidad', 2,
                                    'cambios', jsonb_build_array(jsonb_build_object('de', v_post, 'a', v_coca, 'recargo', 99999)))),
       p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
  SELECT id INTO v_item FROM core.pedido_items WHERE pedido_id = v_ped;
  PERFORM pg_temp.anotar((SELECT precio_unitario FROM core.pedido_items WHERE id = v_item) = 41000
                         AND (SELECT total FROM api.v_pedidos WHERE pedido_id = v_ped) = 82000,
                         '2 combos con Coca-Cola: 41.000 c/u, total 82.000',
                         (SELECT precio_unitario || ' · total ' || total FROM api.v_pedido_items i JOIN api.v_pedidos p USING (pedido_id) WHERE pedido_item_id = v_item));
  PERFORM pg_temp.anotar((SELECT recargo FROM core.pedido_item_cambios WHERE pedido_item_id = v_item) = 1000,
                         'la diferencia la pone la base (un «recargo» que mande la pantalla no cuenta)');

  /* 4 · Más barata o la misma: el combo no baja ni sube */
  v_ped := NULL;
  CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
       p_items => jsonb_build_array(
           jsonb_build_object('producto_id', v_combo, 'cantidad', 1, 'cambios', jsonb_build_array(jsonb_build_object('de', v_post, 'a', v_ging))),
           jsonb_build_object('producto_id', v_combo, 'cantidad', 1, 'cambios', jsonb_build_array(jsonb_build_object('de', v_post, 'a', v_post))),
           jsonb_build_object('producto_id', v_combo, 'cantidad', 1)),
       p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
  SELECT string_agg(precio_unitario::INT::TEXT, ',' ORDER BY id) INTO v_txt FROM core.pedido_items WHERE pedido_id = v_ped;
  PERFORM pg_temp.anotar(v_txt = '40000,40000,40000', 'con Ginger (más barata), con Postobón o sin elegir: 40.000', v_txt);

  /* 5 · El Super con 2 gaseosas Coca-Cola: +2.000 */
  v_ped := NULL;
  CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_super, 'cantidad', 1,
                                    'cambios', jsonb_build_array(jsonb_build_object('de', v_post, 'a', v_coca)))),
       p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
  PERFORM pg_temp.anotar((SELECT precio_unitario FROM core.pedido_items WHERE pedido_id = v_ped) = 62000,
                         'Super con 2 Coca-Cola: 62.000', (SELECT precio_unitario::TEXT FROM core.pedido_items WHERE pedido_id = v_ped));

  /* 6 · Venta de mostrador: se cobra con la diferencia */
  v_ped := NULL;
  CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mostrador', p_metodo_pago => 'efectivo',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_combo, 'cantidad', 1,
                                    'cambios', jsonb_build_array(jsonb_build_object('de', v_post, 'a', v_coca)))),
       p_usuario_id => v_admin, p_pedido_id => v_ped, p_codigo => v_cod);
  SELECT total INTO v_n FROM api.v_pedidos WHERE pedido_id = v_ped AND estado_pago = 'confirmado';
  PERFORM pg_temp.anotar(v_n = 41000, 'la venta de mostrador queda cobrada por 41.000', COALESCE(v_n::TEXT, 'sin cobrar'));

  /* 7 · Si mañana sube la Coca-Cola, lo vendido hoy no cambia */
  UPDATE core.productos SET precio = 9000 WHERE id = v_p_coca;
  PERFORM pg_temp.anotar((SELECT precio_unitario FROM core.pedido_items WHERE id = v_item) = 41000
                         AND pg_temp.extra((SELECT cambios FROM rest.carta WHERE producto_id = v_combo), 'Coca-Cola 1.5') = 3000,
                         'subir la Coca-Cola a 9.000 no toca lo vendido; la carta ya cobra +3.000');
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE LA DIFERENCIA PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
