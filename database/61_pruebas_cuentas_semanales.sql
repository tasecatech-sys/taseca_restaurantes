/* ============================================================================
   61 · PRUEBAS · CUENTAS SEMANALES

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/61_pruebas_cuentas_semanales.sql

   Se deshace sola. Tiene que salir «TODAS LAS PRUEBAS DE CUENTAS SEMANALES PASARON».
   Monta su propia empresa con dos sedes: no depende de los datos que haya.
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);

CREATE FUNCTION pg_temp.anotar(p_ok BOOLEAN, p_que TEXT, p_detalle TEXT DEFAULT '') RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO resultados (ok, que, detalle) VALUES (COALESCE(p_ok, FALSE), p_que, p_detalle); $$;

CREATE FUNCTION pg_temp.app(p_usuario INT, p_empresa INT, p_sql TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v JSONB;
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', p_usuario, 'empresa_id', p_empresa)::TEXT, TRUE);
  SET LOCAL ROLE taseca_app;
  EXECUTE p_sql INTO v;
  RESET ROLE;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RETURN jsonb_build_object('error', SQLERRM);
END $$;

/* Una cifra de una cuenta en la respuesta de rest.cuentas_semana */
CREATE FUNCTION pg_temp.de(p_r JSONB, p_metodo TEXT, p_campo TEXT) RETURNS NUMERIC LANGUAGE sql AS $$
  SELECT (c ->> p_campo)::NUMERIC FROM jsonb_array_elements(p_r -> 'cuentas') c WHERE c ->> 'metodo' = p_metodo; $$;

DO $$
DECLARE
  v_emp INT; v_u1 INT; v_u2 INT; v_cat INT; v_admin INT; v_mesero INT; v_prod INT; v_catg INT;
  v_hoy DATE; v_dia INT; v_r JSONB; v_ped BIGINT; v_cod VARCHAR; v_ret BIGINT; v_txt TEXT;
BEGIN
  INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_t61', 'T61') RETURNING id INTO v_emp;
  INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo) SELECT v_emp, id, TRUE FROM core.modulos;
  INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos) VALUES (v_emp, 'pedido', 0, 5);
  INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo)
  SELECT v_emp, id, TRUE FROM core.metodos_pago WHERE codigo IN ('efectivo', 'nequi', 'daviplata');
  INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
  VALUES (v_emp, (SELECT id FROM core.tipos_negocio ORDER BY id LIMIT 1), 'T61 · Sede 1', 'S1') RETURNING id INTO v_u1;
  INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
  VALUES (v_emp, (SELECT id FROM core.tipos_negocio ORDER BY id LIMIT 1), 'T61 · Sede 2', 'S2') RETURNING id INTO v_u2;
  INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_emp, 'Pollo') RETURNING id INTO v_cat;
  INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio, requiere_preparacion)
  VALUES (v_emp, v_cat, 'T61-A', 'Ala', 10000, FALSE) RETURNING id INTO v_prod;
  INSERT INTO core.producto_unidades (producto_id, unidad_id) VALUES (v_prod, v_u1), (v_prod, v_u2);
  INSERT INTO core.categorias_gasto (empresa_id, nombre) VALUES (v_emp, 'Varios') RETURNING id INTO v_catg;

  INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
  VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'admin'), 'Admin T61', 't61.admin', core.fn_hash_pin('1111'))
  RETURNING id INTO v_admin;
  INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
  VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'mesero'), 'Mesero T61', 't61.mesero', core.fn_hash_pin('2222'))
  RETURNING id INTO v_mesero;

  v_hoy := core.fn_fecha_operativa(v_emp, now());
  v_dia := EXTRACT(ISODOW FROM v_hoy)::INT;

  /* 1 · Sin día escogido: lo dice y no deja registrar */
  v_r := pg_temp.app(v_admin, v_emp, 'SELECT rest.cuentas_semana()');
  PERFORM pg_temp.anotar((v_r ->> 'configurado')::BOOLEAN = FALSE, 'sin día escogido, la pantalla lo pide', v_r::TEXT);
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.registrar_base_cuenta('{"metodo":"nequi","monto":1000}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%escoge el día%', 'sin día no se registra la base', v_r::TEXT);

  /* 2 · El día lo escoge el negocio; la semana arranca ese día */
  v_r := pg_temp.app(v_admin, v_emp, format('SELECT rest.configurar_semana_cuentas(%s)', v_dia % 7 + 1));
  v_r := pg_temp.app(v_admin, v_emp, 'SELECT rest.cuentas_semana()');
  PERFORM pg_temp.anotar((v_r ->> 'semana_inicio')::DATE = v_hoy - 6 AND (v_r ->> 'semana_fin')::DATE = v_hoy,
                         'si la semana empieza mañana, hoy es su último día', v_r ->> 'semana_inicio');
  v_r := pg_temp.app(v_admin, v_emp, format('SELECT rest.configurar_semana_cuentas(%s)', v_dia));
  v_r := pg_temp.app(v_admin, v_emp, 'SELECT rest.cuentas_semana()');
  PERFORM pg_temp.anotar((v_r ->> 'semana_inicio')::DATE = v_hoy AND jsonb_array_length(v_r -> 'cuentas') = 2,
                         'con el día de hoy, la semana empieza hoy; cuentas: Nequi y Daviplata (no efectivo)',
                         (v_r ->> 'semana_inicio') || ' · ' || (v_r -> 'cuentas')::TEXT);

  /* 3 · La base, y su corrección con motivo */
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.registrar_base_cuenta('{"metodo":"nequi","monto":50000}')$s$);
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.registrar_base_cuenta('{"metodo":"nequi","monto":40000}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%motivo de la corrección%', 'corregir la base pide el motivo', v_r::TEXT);
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.registrar_base_cuenta('{"metodo":"nequi","monto":50000,"motivo":"x"}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' IS NULL, 'repetir la misma base no pide motivo', v_r::TEXT);

  /* 4 · Lo cobrado suma las dos sedes; el efectivo y la semana pasada no cuentan */
  CALL api.sp_crear_pedido(p_unidad_id => v_u1, p_tipo => 'mostrador', p_metodo_pago => 'nequi',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2)), p_usuario_id => v_admin,
       p_pedido_id => v_ped, p_codigo => v_cod);
  v_ped := NULL;
  CALL api.sp_crear_pedido(p_unidad_id => v_u2, p_tipo => 'mostrador', p_metodo_pago => 'nequi',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)), p_usuario_id => v_admin,
       p_pedido_id => v_ped, p_codigo => v_cod);
  v_ped := NULL;
  CALL api.sp_crear_pedido(p_unidad_id => v_u1, p_tipo => 'mostrador', p_metodo_pago => 'efectivo',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 5)), p_usuario_id => v_admin,
       p_pedido_id => v_ped, p_codigo => v_cod);
  v_ped := NULL;
  CALL api.sp_crear_pedido(p_unidad_id => v_u1, p_tipo => 'mostrador', p_metodo_pago => 'nequi',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 7)), p_usuario_id => v_admin,
       p_pedido_id => v_ped, p_codigo => v_cod);
  -- De la semana pasada: la base no deja cambiar la jornada de una factura,
  -- así que sólo para esta línea de prueba se saltan los triggers.
  SET LOCAL session_replication_role = replica;
  UPDATE core.pedidos SET fecha_operativa = v_hoy - 1 WHERE id = v_ped;
  SET LOCAL session_replication_role = origin;

  /* 5 · Gastos por Nequi (uno anulado no cuenta) */
  PERFORM core.fn_fijar_usuario(v_admin);
  INSERT INTO core.gastos (unidad_id, categoria_gasto_id, metodo_pago_id, estado_gasto_id, fecha_operativa, descripcion, monto, registrado_por_id)
  VALUES (v_u2, v_catg, (SELECT id FROM core.metodos_pago WHERE codigo = 'nequi'), (SELECT id FROM core.estados_gasto WHERE codigo = 'confirmado'), v_hoy, 'Gas', 5000, v_admin),
         (v_u1, v_catg, (SELECT id FROM core.metodos_pago WHERE codigo = 'nequi'), (SELECT id FROM core.estados_gasto WHERE codigo = 'anulado'), v_hoy, 'Duplicado', 3000, v_admin);

  /* 6 · Un retiro, anularlo, y otra vez */
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.registrar_retiro_cuenta('{"metodo":"nequi","monto":20000,"motivo":"Pago al proveedor"}')$s$);
  v_ret := (v_r ->> 'id')::BIGINT;
  v_r := pg_temp.app(v_admin, v_emp, 'SELECT rest.cuentas_semana()');
  PERFORM pg_temp.anotar(pg_temp.de(v_r, 'nequi', 'cobrado') = 30000 AND pg_temp.de(v_r, 'nequi', 'gastos') = 5000
                         AND pg_temp.de(v_r, 'nequi', 'retiros') = 20000 AND pg_temp.de(v_r, 'nequi', 'esperado') = 55000,
                         'Nequi: 50.000 + 30.000 (dos sedes) − 5.000 − 20.000 = 55.000', (v_r -> 'cuentas' -> 0)::TEXT);
  PERFORM pg_temp.anotar(pg_temp.de(v_r, 'daviplata', 'esperado') = 0, 'Daviplata sin nada: 0');
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.anular_retiro_cuenta(%s, 'Se registró mal')$s$, v_ret));
  v_r := pg_temp.app(v_admin, v_emp, 'SELECT rest.cuentas_semana()');
  PERFORM pg_temp.anotar(pg_temp.de(v_r, 'nequi', 'esperado') = 75000, 'al anular el retiro vuelve a 75.000', pg_temp.de(v_r, 'nequi', 'esperado')::TEXT);
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.registrar_retiro_cuenta('{"metodo":"nequi","monto":20000,"motivo":"Pago al proveedor"}')$s$);
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.registrar_retiro_cuenta('{"metodo":"nequi","monto":0,"motivo":"nada"}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%mayor que 0%', 'un retiro de 0 no entra', v_r::TEXT);

  /* 7 · Cerrar: hay que dar el saldo de cada cuenta */
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.cerrar_semana_cuentas('{"saldos":[{"metodo":"nequi","saldo_real":54000}]}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%Falta el saldo real de%', 'sin el saldo de Daviplata no se cierra', v_r::TEXT);
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.cerrar_semana_cuentas('{"saldos":[{"metodo":"nequi","saldo_real":54000},{"metodo":"daviplata","saldo_real":0}],"observacion":"Prueba"}')$s$);
  v_r := pg_temp.app(v_admin, v_emp, 'SELECT rest.cuentas_semana()');
  PERFORM pg_temp.anotar((v_r ->> 'cerrada')::BOOLEAN AND pg_temp.de(v_r, 'nequi', 'diferencia') = -1000
                         AND pg_temp.de(v_r, 'daviplata', 'diferencia') = 0,
                         'cerrada: a Nequi le faltan 1.000, Daviplata cuadra', (v_r -> 'cuentas')::TEXT);

  /* 8 · Cerrada no se mueve: ni ventas nuevas, ni base, ni retiros */
  v_ped := NULL;
  CALL api.sp_crear_pedido(p_unidad_id => v_u1, p_tipo => 'mostrador', p_metodo_pago => 'nequi',
       p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)), p_usuario_id => v_admin,
       p_pedido_id => v_ped, p_codigo => v_cod);
  v_r := pg_temp.app(v_admin, v_emp, 'SELECT rest.cuentas_semana()');
  PERFORM pg_temp.anotar(pg_temp.de(v_r, 'nequi', 'cobrado') = 30000, 'una venta después del cierre no cambia la foto');
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.registrar_base_cuenta('{"metodo":"nequi","monto":1,"motivo":"cambio"}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%ya está cerrada%', 'la base de una semana cerrada no se cambia', v_r::TEXT);
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.registrar_retiro_cuenta('{"metodo":"nequi","monto":1000,"motivo":"tarde"}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%ya está cerrada%', 'no entran retiros en una semana cerrada', v_r::TEXT);
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.cerrar_semana_cuentas('{"saldos":[{"metodo":"nequi","saldo_real":1},{"metodo":"daviplata","saldo_real":0}]}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%ya está cerrada%', 'no se cierra dos veces', v_r::TEXT);

  /* 9 · La semana pasada se consulta con su fecha, y sale en el historial */
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.cuentas_semana(%L)$s$, v_hoy - 1));
  PERFORM pg_temp.anotar((v_r ->> 'semana_inicio')::DATE = v_hoy - 7 AND pg_temp.de(v_r, 'nequi', 'cobrado') = 70000
                         AND NOT (v_r ->> 'es_actual')::BOOLEAN AND jsonb_array_length(v_r -> 'semanas') = 1,
                         'la semana pasada: su propio cobrado (70.000) y la actual en el historial', (v_r -> 'semanas')::TEXT);

  /* 10 · Permisos: un mesero no ve las cuentas */
  v_r := pg_temp.app(v_mesero, v_emp, 'SELECT rest.cuentas_semana()');
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no puede ver%', 'un mesero no ve ni registra las cuentas', v_r::TEXT);
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE CUENTAS SEMANALES PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
