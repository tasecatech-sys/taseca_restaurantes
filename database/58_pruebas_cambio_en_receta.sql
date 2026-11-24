/* ============================================================================
   58 · PRUEBAS · CAMBIO EN LA RECETA (la gaseosa del combo)

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/58_pruebas_cambio_en_receta.sql

   Se deshace sola. Tiene que salir «TODAS LAS PRUEBAS DEL CAMBIO EN LA RECETA PASARON».
   Monta su propia empresa: no depende de los datos que haya.
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);

CREATE FUNCTION pg_temp.anotar(p_ok BOOLEAN, p_que TEXT, p_detalle TEXT DEFAULT '') RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO resultados (ok, que, detalle) VALUES (COALESCE(p_ok, FALSE), p_que, p_detalle); $$;

/* Corre una consulta como la aplicación (taseca_app) con la sesión puesta */
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

CREATE FUNCTION pg_temp.detalle(p_item BIGINT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT detalle FROM api.v_pedido_items WHERE pedido_item_id = p_item; $$;

DO $$
DECLARE
  v_emp INT; v_uni INT; v_cat INT; v_admin INT; v_cat_ins INT;
  v_bar INT := (SELECT id FROM core.areas_inventario WHERE codigo = 'bar');
  v_com INT := (SELECT id FROM core.areas_inventario WHERE codigo = 'comidas');
  v_um  INT := (SELECT id FROM core.unidades_medida ORDER BY id LIMIT 1);
  v_combo INT; v_post_sola INT; v_alas INT;
  v_post INT; v_coca INT; v_ging INT; v_pan INT; v_ala INT;
  v_iu_post INT; v_iu_coca INT; v_iu_ging INT;
  v_ped BIGINT; v_cod VARCHAR; v_item BIGINT;
  v_hoy DATE; v_r JSONB; v_txt TEXT; v_n INT; v_err TEXT;
BEGIN
  /* ---------- Un negocio con un combo, una gaseosa suelta y alas ---------- */
  INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_t58', 'Pollos T58') RETURNING id INTO v_emp;
  INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo) SELECT v_emp, id, TRUE FROM core.modulos;
  INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos) VALUES (v_emp, 'pedido', 0, 5);
  INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo)
  SELECT v_emp, id, TRUE FROM core.metodos_pago WHERE codigo = 'efectivo';
  INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
  VALUES (v_emp, (SELECT id FROM core.tipos_negocio ORDER BY id LIMIT 1), 'T58 · Sede', 'T58') RETURNING id INTO v_uni;
  INSERT INTO core.mesas (unidad_id, numero) VALUES (v_uni, '1');

  INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_emp, 'Pollo') RETURNING id INTO v_cat;
  INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio)
  VALUES (v_emp, v_cat, 'T58-C1', 'Combo 1', 40000) RETURNING id INTO v_combo;
  INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio)
  VALUES (v_emp, v_cat, 'T58-P', 'Postobón 1.5', 7000) RETURNING id INTO v_post_sola;
  INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio)
  VALUES (v_emp, v_cat, 'T58-A', 'Ala', 3000) RETURNING id INTO v_alas;
  INSERT INTO core.producto_unidades (producto_id, unidad_id) VALUES (v_combo, v_uni), (v_post_sola, v_uni), (v_alas, v_uni);

  INSERT INTO core.categorias_insumo (empresa_id, nombre) VALUES (v_emp, 'Todo') RETURNING id INTO v_cat_ins;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, grupo_cambio)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T58POST', 'Postobón 1.5', 'Gaseosa 1.5') RETURNING id INTO v_post;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, grupo_cambio)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T58COCA', 'Coca-Cola 1.5', ' gaseosa 1.5 ') RETURNING id INTO v_coca;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, grupo_cambio)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T58GING', 'Ginger 1.5', 'Gaseosa 1.5') RETURNING id INTO v_ging;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
  VALUES (v_emp, v_cat_ins, v_com, v_um, 'T58ALA', 'Ala') RETURNING id INTO v_ala;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, grupo_cambio)
  VALUES (v_emp, v_cat_ins, v_com, v_um, 'T58PAN', 'Pan', 'Panes') RETURNING id INTO v_pan;
  INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (v_post, v_uni) RETURNING id INTO v_iu_post;
  INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (v_coca, v_uni) RETURNING id INTO v_iu_coca;
  INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (v_ging, v_uni) RETURNING id INTO v_iu_ging;
  INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (v_ala, v_uni), (v_pan, v_uni);

  -- El combo: 2 alas + 1 gaseosa 1.5 que SE ELIGE. La Postobón suelta: la suya, sin elegir.
  INSERT INTO core.producto_insumos (producto_id, insumo_id, cantidad, cambiable)
  VALUES (v_combo, v_ala, 2, FALSE), (v_combo, v_post, 1, TRUE), (v_post_sola, v_post, 1, FALSE), (v_alas, v_ala, 1, FALSE);

  INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
  VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'admin'), 'Admin T58', 't58.admin', core.fn_hash_pin('1111'))
  RETURNING id INTO v_admin;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_admin, 'empresa_id', v_emp)::TEXT, TRUE);
  v_hoy := core.fn_fecha_operativa(v_emp, now());

  /* 1 · La carta dice qué se elige: sólo en el combo, con la de la receta primero */
  SELECT cambios INTO v_r FROM rest.carta WHERE producto_id = v_combo;
  PERFORM pg_temp.anotar(jsonb_array_length(v_r) = 1 AND v_r -> 0 ->> 'grupo' = 'Gaseosa 1.5'
                         AND jsonb_array_length(v_r -> 0 -> 'opciones') = 3
                         AND (v_r -> 0 -> 'opciones' -> 0 ->> 'id')::INT = v_post,
                         'la carta del combo ofrece las 3 gaseosas 1.5, Postobón primero', v_r::TEXT);
  SELECT cambios INTO v_r FROM rest.carta WHERE producto_id = v_post_sola;
  PERFORM pg_temp.anotar(v_r = '[]'::JSONB, 'la Postobón suelta no ofrece elegir (ella es la marca)', v_r::TEXT);

  /* 2 · Combo con Coca-Cola: se guarda, el detalle lo dice y gasta Coca-Cola */
  CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_combo, 'cantidad', 2,
                                    'cambios', jsonb_build_array(jsonb_build_object('de', v_post, 'a', v_coca)))),
       p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
  SELECT id INTO v_item FROM core.pedido_items WHERE pedido_id = v_ped;
  PERFORM pg_temp.anotar(EXISTS (SELECT 1 FROM core.pedido_item_cambios WHERE pedido_item_id = v_item
                                    AND insumo_original_id = v_post AND insumo_elegido_id = v_coca),
                         'el pedido guarda que el combo va con Coca-Cola');
  v_txt := pg_temp.detalle(v_item);
  PERFORM pg_temp.anotar(v_txt = 'Gaseosa 1.5: Coca-Cola 1.5', 'el detalle (ticket y comanda) dice la marca', v_txt);
  PERFORM pg_temp.anotar((SELECT d.value ->> 'detalle' FROM jsonb_array_elements(core.fn_pedido_json(v_ped) -> 'items') d) = v_txt,
                         'el pedido que lee el panel trae el mismo detalle');
  PERFORM pg_temp.anotar(core.fn_z_insumo(v_iu_coca, v_hoy - 1, v_hoy) = 2 AND core.fn_z_insumo(v_iu_post, v_hoy - 1, v_hoy) = 0,
                         '2 combos con Coca-Cola gastan 2 Coca-Cola y 0 Postobón',
                         'coca ' || core.fn_z_insumo(v_iu_coca, v_hoy - 1, v_hoy) || ' · post ' || core.fn_z_insumo(v_iu_post, v_hoy - 1, v_hoy));

  /* 3 · Sin elegir (un panel viejo, o el portal sin cambiar): como antes, Postobón */
  CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_combo, 'cantidad', 1)),
       p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
  SELECT id INTO v_item FROM core.pedido_items WHERE pedido_id = v_ped;
  PERFORM pg_temp.anotar(core.fn_z_insumo(v_iu_post, v_hoy - 1, v_hoy) = 1 AND pg_temp.detalle(v_item) IS NULL,
                         'sin elegir gasta la de la receta y el detalle queda vacío', pg_temp.detalle(v_item));

  /* 4 · Elegir la misma de la receta: se guarda para que la comanda lo diga */
  v_ped := NULL;
  CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_combo, 'cantidad', 1,
                                    'cambios', jsonb_build_array(jsonb_build_object('de', v_post, 'a', v_post)))),
       p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
  SELECT id INTO v_item FROM core.pedido_items WHERE pedido_id = v_ped;
  PERFORM pg_temp.anotar(pg_temp.detalle(v_item) = 'Gaseosa 1.5: Postobón 1.5' AND core.fn_z_insumo(v_iu_post, v_hoy - 1, v_hoy) = 2,
                         'elegir la de la receta la deja dicha en el detalle y gasta Postobón', pg_temp.detalle(v_item));

  /* 5 · Lo que no vale se rechaza y el pedido entero no entra */
  SELECT count(*) INTO v_n FROM core.pedidos WHERE empresa_id = v_emp;
  BEGIN
    v_ped := NULL;
    CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_combo, 'cantidad', 1,
                                      'cambios', jsonb_build_array(jsonb_build_object('de', v_post, 'a', v_pan)))),
         p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
    v_err := NULL;
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  PERFORM pg_temp.anotar(v_err LIKE '%no es de «Gaseosa 1.5»%' AND (SELECT count(*) FROM core.pedidos WHERE empresa_id = v_emp) = v_n,
                         'cambiar la gaseosa por un pan se rechaza y no queda pedido', v_err);
  BEGIN
    v_ped := NULL;
    CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_post_sola, 'cantidad', 1,
                                      'cambios', jsonb_build_array(jsonb_build_object('de', v_post, 'a', v_coca)))),
         p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
    v_err := NULL;
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  PERFORM pg_temp.anotar(v_err LIKE '%no deja elegir%', 'una Postobón suelta no se puede volver Coca-Cola', v_err);
  BEGIN
    UPDATE core.pedido_item_cambios SET insumo_elegido_id = v_ging WHERE pedido_item_id = v_item;
    v_err := NULL;
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  PERFORM pg_temp.anotar(v_err LIKE '%no se modifica%', 'lo elegido en una venta no se edita después', v_err);

  /* 6 · Un insumo inactivo deja de ofrecerse (pero lo ya vendido sigue valiendo) */
  UPDATE core.insumos SET activo = FALSE WHERE id = v_ging;
  SELECT cambios INTO v_r FROM rest.carta WHERE producto_id = v_combo;
  PERFORM pg_temp.anotar(jsonb_array_length(v_r -> 0 -> 'opciones') = 2, 'Ginger inactivo ya no sale como opción', v_r::TEXT);
  UPDATE core.insumos SET activo = TRUE WHERE id = v_ging;

  /* 7 · El cruce del cierre usa lo elegido */
  INSERT INTO core.cierres_inventario (unidad_id, area_id, estado_cierre_id, fecha_operativa, registrado_por_id)
  VALUES (v_uni, v_bar, (SELECT id FROM core.estados_cierre ORDER BY id LIMIT 1), v_hoy, v_admin);
  INSERT INTO core.cierre_detalles (cierre_id, insumo_unidad_id, saldo_fisico)
  SELECT currval(pg_get_serial_sequence('core.cierres_inventario', 'id')), x, 10 FROM unnest(ARRAY[v_iu_post, v_iu_coca, v_iu_ging]) x;
  SELECT string_agg(codigo || '=' || ventas::INT, ' ' ORDER BY codigo) INTO v_txt FROM api.v_cruce_inventario WHERE empresa_id = v_emp;
  PERFORM pg_temp.anotar(v_txt = 'T58COCA=2 T58GING=0 T58POST=2', 'el cruce del bar cuenta 2 Coca-Cola y 2 Postobón', v_txt);

  /* 8 · Anular después del cierre: vuelve la Coca-Cola, no la Postobón */
  SELECT p.id INTO v_ped FROM core.pedidos p JOIN core.pedido_items i ON i.pedido_id = p.id
    JOIN core.pedido_item_cambios c ON c.pedido_item_id = i.id AND c.insumo_elegido_id = v_coca WHERE p.empresa_id = v_emp;
  PERFORM core.fn_fijar_usuario(v_admin);
  UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'entregado') WHERE id = v_ped;
  CALL api.sp_anular_pedido(v_ped, 'Prueba de anulación', v_admin);
  SELECT string_agg(i.codigo || '=' || e.cantidad::INT, ' ' ORDER BY i.codigo) INTO v_txt
    FROM core.entradas_inventario e JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id JOIN core.insumos i ON i.id = iu.insumo_id
   WHERE e.pedido_id = v_ped AND i.area_id = v_bar;
  PERFORM pg_temp.anotar(v_txt = 'T58COCA=2', 'al anular, el retorno del bar es la Coca-Cola elegida', v_txt);

  /* 9 · Guardar desde el panel: el grupo y la marca de «se elige» */
  v_r := pg_temp.app(format($s$SELECT rest.guardar_insumo('{"insumo_id":%s,"codigo":"T58GING","nombre":"Ginger 1.5","categoria":"Todo","area":"bar",
            "unidad":"unidad","unidades":[%s],"grupo_cambio":"Gaseosa 1.5","productos":[{"producto_id":%s,"cantidad":1,"cambiable":true}]}')$s$,
            v_ging, v_uni, v_alas));
  PERFORM pg_temp.anotar((SELECT cambiable FROM core.producto_insumos WHERE producto_id = v_alas AND insumo_id = v_ging),
                         'guardar marca «se elige» en la receta', COALESCE(v_r ->> 'error', ''));
  v_r := pg_temp.app(format($s$SELECT rest.guardar_insumo('{"insumo_id":%s,"codigo":"T58GING","nombre":"Ginger 1.5","categoria":"Todo","area":"bar",
            "unidad":"unidad","unidades":[%s],"productos":[{"producto_id":%s,"cantidad":1}]}')$s$, v_ging, v_uni, v_alas));
  PERFORM pg_temp.anotar((SELECT cambiable FROM core.producto_insumos WHERE producto_id = v_alas AND insumo_id = v_ging)
                         AND (SELECT grupo_cambio FROM core.insumos WHERE id = v_ging) = 'Gaseosa 1.5',
                         'un panel viejo (sin los campos nuevos) no borra el grupo ni la marca', COALESCE(v_r ->> 'error', ''));
  v_r := pg_temp.app(format($s$SELECT rest.guardar_insumo('{"insumo_id":%s,"codigo":"T58GING","nombre":"Ginger 1.5","categoria":"Todo","area":"bar",
            "unidad":"unidad","unidades":[%s],"grupo_cambio":"  ","productos":[{"producto_id":%s,"cantidad":1,"cambiable":false}]}')$s$,
            v_ging, v_uni, v_alas));
  PERFORM pg_temp.anotar((SELECT grupo_cambio FROM core.insumos WHERE id = v_ging) IS NULL
                         AND NOT (SELECT cambiable FROM core.producto_insumos WHERE producto_id = v_alas AND insumo_id = v_ging),
                         'grupo vacío lo quita y la marca se apaga', COALESCE(v_r ->> 'error', ''));

  /* 10 · El stock que lee el panel trae los dos datos */
  v_r := pg_temp.app($s$SELECT jsonb_agg(jsonb_build_object('c', codigo, 'g', grupo_cambio, 'p', productos)) FROM rest.stock WHERE codigo = 'T58POST'$s$);
  PERFORM pg_temp.anotar(v_r -> 0 ->> 'g' = 'Gaseosa 1.5'
                         AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_r -> 0 -> 'p') x WHERE (x ->> 'cambiable')::BOOLEAN),
                         'rest.stock trae el grupo y qué receta deja elegir', v_r::TEXT);
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DEL CAMBIO EN LA RECETA PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
