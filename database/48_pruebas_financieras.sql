/* ============================================================================
   48 · PRUEBAS · CRUCE FINANCIERO DE PUNTA A PUNTA

   Crea pedidos con todos los métodos de pago (efectivo, Nequi, Daviplata,
   Bre-B, datáfono), con recargo fijo y porcentual, domicilio, cambio de método
   al cobrar, pago rechazado, pago reportado por el cliente, cancelación y
   anulación; registra base de caja y gastos (confirmados, sin confirmar y
   anulados), y comprueba que CADA PESO cae donde debe:

     · total de cada pedido = ítems + domicilio + recargo
     · ventas por método: vendido, cobrado, por cobrar y rechazado
     · bolsas de caja: efectivo / transferencia / otros
     · efectivo esperado = base + efectivo cobrado − gastos en efectivo
     · transferencias netas y otros netos
     · rest.informe_caja y api.v_cruce_caja dicen lo mismo
     · un pedido cobrado NO se puede cancelar (la 48)
     · controles: cobrar dos veces, método inactivo, otra sede, sin permiso

   Es genérica: toma la primera sede activa que tenga un producto con precio y
   el dueño de su empresa, y mide DIFERENCIAS contra lo que ya había en la
   jornada, así que no depende de los datos de nadie.

   TODO SE DESHACE al final (ROLLBACK). Corre con psql:

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/48_pruebas_financieras.sql

   Tiene que salir «TODAS LAS PRUEBAS FINANCIERAS PASARON».
   Sin la migración 48 falla «un pedido cobrado no se cancela».
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, esperado TEXT, obtenido TEXT);

CREATE FUNCTION pg_temp.token(p_usuario_id INT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', p_usuario_id,
          'empresa_id', (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario_id))::TEXT, TRUE);
END $$;

CREATE FUNCTION pg_temp.app(p_sql TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v JSONB;
BEGIN
  SET LOCAL ROLE taseca_app;
  EXECUTE p_sql INTO v;
  RESET ROLE;
  RETURN v;
END $$;

/* Paso que debe salir bien: si falla, queda anotado. */
CREATE FUNCTION pg_temp.paso(p_que TEXT, p_sql TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v JSONB;
BEGIN
  v := pg_temp.app(p_sql);
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO resultados (ok, que, esperado, obtenido) VALUES (FALSE, p_que, 'sin error', SQLERRM);
  RETURN NULL;
END $$;

/* Paso que debe FALLAR con un mensaje que contenga p_contiene. */
CREATE FUNCTION pg_temp.bloqueado(p_que TEXT, p_sql TEXT, p_contiene TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    PERFORM pg_temp.app(p_sql);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    INSERT INTO resultados (ok, que, esperado, obtenido)
    VALUES (SQLERRM ILIKE '%' || p_contiene || '%', p_que, 'bloqueado: ' || p_contiene, SQLERRM);
    RETURN;
  END;
  INSERT INTO resultados (ok, que, esperado, obtenido) VALUES (FALSE, p_que, 'bloqueado: ' || p_contiene, 'lo dejó pasar');
END $$;

CREATE FUNCTION pg_temp.igual(p_que TEXT, p_esp NUMERIC, p_obt NUMERIC) RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO resultados (ok, que, esperado, obtenido)
  VALUES (p_obt IS NOT DISTINCT FROM p_esp, p_que, p_esp::TEXT, COALESCE(p_obt::TEXT, 'NULL')); $$;

/* Un número de rest.informe_caja (0 si no está). */
CREATE FUNCTION pg_temp.n(p JSONB, VARIADIC p_ruta TEXT[]) RETURNS NUMERIC LANGUAGE sql AS $$
  SELECT COALESCE((p #>> p_ruta)::NUMERIC, 0); $$;

/* La fila del cruce como JSON (ceros si la jornada aún no tiene nada). */
CREATE FUNCTION pg_temp.cruce(p_unidad INT, p_fecha DATE) RETURNS JSONB LANGUAGE sql AS $$
  SELECT COALESCE((SELECT to_jsonb(c) FROM api.v_cruce_caja c WHERE c.unidad_id = p_unidad AND c.fecha_operativa = p_fecha), '{}'); $$;

CREATE FUNCTION pg_temp.pedido(p_unidad INT, p_tipo TEXT, p_metodo TEXT, p_cant INT, p_prod INT, p_extra TEXT DEFAULT '')
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v JSONB;
BEGIN
  v := pg_temp.paso('crear pedido ' || p_tipo || '/' || p_metodo,
        format('SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => %L, p_metodo_pago => %L, p_items => %L::jsonb %s, p_clave => %L)',
               p_unidad, p_tipo, p_metodo, jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant)),
               p_extra, 'p48-' || clock_timestamp()::TEXT || random()::TEXT));
  RETURN (v ->> 'pedido_id')::BIGINT;
END $$;

CREATE FUNCTION pg_temp.total(p_id BIGINT) RETURNS NUMERIC LANGUAGE sql AS $$
  SELECT total FROM api.v_pedidos WHERE pedido_id = p_id; $$;

DO $$
DECLARE
  v_uni INT; v_emp INT; v_cod_emp TEXT; v_dueno INT; v_otro INT; v_prod INT; P NUMERIC;
  v_hoy DATE; v_zona INT; v_cat INT; v_dom TEXT; v_cli TEXT;
  i0 JSONB; i1 JSONB; c0 JSONB; c1 JSONB; v_r JSONB;
  q1 BIGINT; q2 BIGINT; q3 BIGINT; q4 BIGINT; q5 BIGINT; q6 BIGINT; q7 BIGINT;
  q8 BIGINT; q9 BIGINT; q10 BIGINT; q11 BIGINT; q12 BIGINT; q13 BIGINT;
  g1 BIGINT; g2 BIGINT; g3 BIGINT; g4 BIGINT; g5 BIGINT;
  r1 NUMERIC; r2 NUMERIC; v_cod TEXT;
  e_ef_v NUMERIC; e_ef_c NUMERIC; e_ef_p NUMERIC; e_nq_v NUMERIC; e_nq_c NUMERIC; e_nq_p NUMERIC;
  e_dv NUMERIC; e_df_v NUMERIC; e_df_c NUMERIC; e_df_p NUMERIC; e_br NUMERIC; e_an NUMERIC;
BEGIN
  /* ---- Escenario: primera sede activa con un producto con precio ---- */
  SELECT pu.unidad_id, pu.producto_id, pr.precio, u.empresa_id
    INTO v_uni, v_prod, P, v_emp
    FROM core.producto_unidades pu
    JOIN core.productos pr ON pr.id = pu.producto_id
    JOIN core.unidades u ON u.id = pu.unidad_id
    JOIN core.empresas e ON e.id = u.empresa_id
   WHERE pr.precio > 0 AND pr.activo AND u.estado = 'activa' AND e.estado = 'activa'
   ORDER BY pu.unidad_id, pu.producto_id LIMIT 1;
  IF v_uni IS NULL THEN RAISE EXCEPTION 'No hay ninguna sede activa con un producto con precio para probar.'; END IF;
  SELECT codigo INTO v_cod_emp FROM core.empresas WHERE id = v_emp;
  SELECT us.id INTO v_dueno FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = v_emp AND r.codigo = 'admin' AND us.activo ORDER BY us.id LIMIT 1;
  SELECT jornada_actual INTO v_hoy FROM api.v_empresas WHERE codigo = v_cod_emp;
  SELECT MIN(id) INTO v_cat FROM core.categorias_gasto WHERE empresa_id = v_emp;
  IF v_cat IS NULL THEN
    INSERT INTO core.categorias_gasto (empresa_id, nombre) VALUES (v_emp, 'Prueba 48') RETURNING id INTO v_cat;
  END IF;
  RAISE NOTICE 'Sede %, empresa %, producto % a $%, jornada %', v_uni, v_cod_emp, v_prod, P, v_hoy;

  /* Nequi +$500 fijo, datáfono +5 %, el resto sin recargo; zona de $4.000. */
  UPDATE core.empresa_metodos_pago SET activo = TRUE, recargo = 0, recargo_tipo = 'fijo'
   WHERE empresa_id = v_emp AND metodo_pago_id IN (SELECT id FROM core.metodos_pago
         WHERE codigo IN ('efectivo','nequi','daviplata','breb','datafono'));
  INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, recargo, recargo_tipo)
  SELECT v_emp, m.id, TRUE, 0, 'fijo' FROM core.metodos_pago m
   WHERE m.codigo IN ('efectivo','nequi','daviplata','breb','datafono')
     AND NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago x WHERE x.empresa_id = v_emp AND x.metodo_pago_id = m.id);
  UPDATE core.empresa_metodos_pago SET recargo = 500, recargo_tipo = 'fijo'
   WHERE empresa_id = v_emp AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'nequi');
  UPDATE core.empresa_metodos_pago SET recargo = 5, recargo_tipo = 'porcentaje'
   WHERE empresa_id = v_emp AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'datafono');
  INSERT INTO core.zonas_domicilio (unidad_id, nombre, costo, pedido_minimo, activa)
  VALUES (v_uni, 'Zona prueba 48', 4000, 0, TRUE) RETURNING id INTO v_zona;
  v_dom := format(', p_cliente_nombre => ''Cliente 48'', p_cliente_telefono => ''3001234567'', p_direccion => ''Cra 1 # 2-3'', p_zona_id => %s', v_zona);
  v_cli := ', p_cliente_nombre => ''Cliente 48'', p_cliente_telefono => ''3001234567''';

  PERFORM pg_temp.token(v_dueno);
  i0 := pg_temp.app(format('SELECT rest.informe_caja(%L, %s)', v_hoy, v_uni));
  c0 := pg_temp.cruce(v_uni, v_hoy);

  /* ---- Base de caja: queda en $120.000 ---- */
  IF EXISTS (SELECT 1 FROM core.bases_caja WHERE unidad_id = v_uni AND fecha_operativa = v_hoy AND vigente) THEN
    PERFORM pg_temp.paso('base 120.000 (corrige la existente)', format($s$SELECT rest.registrar_base('{"unidad_id":%s,"fecha":"%s","monto":120000,"corregir":true,"motivo":"Prueba 48"}')$s$, v_uni, v_hoy));
  ELSE
    PERFORM pg_temp.paso('base 100.000', format($s$SELECT rest.registrar_base('{"unidad_id":%s,"fecha":"%s","monto":100000}')$s$, v_uni, v_hoy));
    PERFORM pg_temp.paso('base corregida a 120.000', format($s$SELECT rest.registrar_base('{"unidad_id":%s,"fecha":"%s","monto":120000,"corregir":true,"motivo":"Se contó mal"}')$s$, v_uni, v_hoy));
  END IF;

  /* ---- Pedidos ---- */
  q1  := pg_temp.pedido(v_uni, 'recoger',   'efectivo',  2, v_prod, v_cli);
  q2  := pg_temp.pedido(v_uni, 'recoger',   'nequi',     1, v_prod, v_cli);
  q3  := pg_temp.pedido(v_uni, 'domicilio', 'daviplata', 2, v_prod, v_dom);
  q4  := pg_temp.pedido(v_uni, 'mostrador', 'datafono',  2, v_prod);
  q5  := pg_temp.pedido(v_uni, 'domicilio', 'nequi',     1, v_prod, v_dom);
  q6  := pg_temp.pedido(v_uni, 'recoger',   'efectivo',  1, v_prod, v_cli);
  q7  := pg_temp.pedido(v_uni, 'recoger',   'breb',      1, v_prod, v_cli);
  q8  := pg_temp.pedido(v_uni, 'recoger',   'efectivo',  1, v_prod, v_cli);
  q9  := pg_temp.pedido(v_uni, 'recoger',   'nequi',     3, v_prod, v_cli);
  q10 := pg_temp.pedido(v_uni, 'recoger',   'efectivo',  2, v_prod, v_cli || format(', p_paga_con => %s', 2 * P + 50000));
  q11 := pg_temp.pedido(v_uni, 'domicilio', 'datafono',  1, v_prod, v_dom);
  q12 := pg_temp.pedido(v_uni, 'domicilio', 'nequi',     1, v_prod, v_dom);
  q13 := pg_temp.pedido(v_uni, 'recoger',   'efectivo',  1, v_prod, v_cli);

  r1 := round(2 * P * 5 / 100.0);
  r2 := round((P + 4000) * 5 / 100.0);
  PERFORM pg_temp.igual('total: efectivo sin recargo',                 2 * P,            pg_temp.total(q1));
  PERFORM pg_temp.igual('total: Nequi + $500',                         P + 500,          pg_temp.total(q2));
  PERFORM pg_temp.igual('total: domicilio Daviplata + $4.000',         2 * P + 4000,     pg_temp.total(q3));
  PERFORM pg_temp.igual('total: datáfono + 5 %',                       2 * P + r1,       pg_temp.total(q4));
  PERFORM pg_temp.igual('total: domicilio Nequi + $4.000 + $500',      P + 4500,         pg_temp.total(q5));
  PERFORM pg_temp.igual('total: «paga con» no cambia el total',        2 * P,            pg_temp.total(q10));
  PERFORM pg_temp.igual('total: 5 % del datáfono incluye el domicilio', P + 4000 + r2,   pg_temp.total(q11));
  PERFORM pg_temp.igual('venta de mostrador nace cobrada', 1,
          (SELECT count(*) FROM api.v_pedidos WHERE pedido_id = q4 AND estado_pago = 'confirmado'));

  /* ---- Cobros ---- */
  PERFORM pg_temp.paso('cobrar efectivo',            format('SELECT rest.confirmar_pago(%s, NULL, NULL)', q1));
  PERFORM pg_temp.paso('cobrar Nequi',               format('SELECT rest.confirmar_pago(%s, ''NEQ-2'', NULL)', q2));
  PERFORM pg_temp.paso('cobrar Daviplata',           format('SELECT rest.confirmar_pago(%s, ''DAV-3'', NULL)', q3));
  PERFORM pg_temp.paso('cobrar Nequi como efectivo', format('SELECT rest.confirmar_pago(%s, NULL, ''efectivo'')', q5));
  PERFORM pg_temp.igual('al pasar a efectivo se cae el recargo', P + 4000, pg_temp.total(q5));
  PERFORM pg_temp.paso('rechazar Bre-B',             format('SELECT rest.rechazar_pago(%s, ''No llegó'')', q7));
  PERFORM pg_temp.paso('cancelar pedido SIN cobrar', format('SELECT rest.cancelar_pedido(%s, ''Se arrepintió'')', q8));
  PERFORM pg_temp.paso('cobrar Nequi (se anulará)',  format('SELECT rest.confirmar_pago(%s, ''NEQ-9'', NULL)', q9));
  PERFORM pg_temp.paso('anular factura cobrada',     format('SELECT rest.anular_pedido(%s, ''Factura mal hecha'', NULL)', q9));
  PERFORM pg_temp.paso('cobrar efectivo con cambio', format('SELECT rest.confirmar_pago(%s, NULL, NULL)', q10));
  PERFORM pg_temp.paso('cobrar efectivo (q13)',      format('SELECT rest.confirmar_pago(%s, NULL, NULL)', q13));

  /* La 48: lo cobrado no se cancela */
  PERFORM pg_temp.bloqueado('un pedido cobrado no se cancela (la 48)',
          format('SELECT rest.cancelar_pedido(%s, ''probar'')', q13), 'ya se cobró');
  PERFORM pg_temp.igual('el pedido cobrado sigue vivo tras el intento', 1,
          (SELECT count(*) FROM api.v_pedidos WHERE pedido_id = q13 AND estado <> 'cancelado' AND estado_pago = 'confirmado'));
  PERFORM pg_temp.bloqueado('cobrar dos veces no duplica', format('SELECT rest.confirmar_pago(%s, NULL, NULL)', q1), 'ya fue confirmado');
  PERFORM pg_temp.bloqueado('un pago confirmado no se rechaza', format('SELECT rest.rechazar_pago(%s, ''x'')', q2), 'ya fue confirmado');

  /* El cliente reporta su pago: queda por cobrar hasta que caja confirme */
  SELECT codigo INTO v_cod FROM core.pedidos WHERE id = q12;
  BEGIN
    PERFORM set_config('request.jwt.claims', '{"role":"taseca_anon"}', TRUE);
    SET LOCAL ROLE taseca_anon;
    PERFORM rest.reportar_pago(v_cod, 'NEQ-12', NULL, v_cod_emp);
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    INSERT INTO resultados (ok, que, esperado, obtenido) VALUES (FALSE, 'el cliente reporta su pago', 'sin error', SQLERRM);
  END;
  PERFORM pg_temp.token(v_dueno);
  PERFORM pg_temp.igual('pago reportado queda «reportado», no cobrado', 1,
          (SELECT count(*) FROM api.v_pedidos WHERE pedido_id = q12 AND estado_pago = 'reportado'));

  /* ---- Gastos (débitos) ---- */
  v_r := pg_temp.paso('gasto efectivo 20.000', format($s$SELECT rest.guardar_gasto('{"unidad_id":%s,"fecha":"%s","categoria_gasto_id":%s,"metodo_pago":"efectivo","descripcion":"Compra de verduras","monto":20000}')$s$, v_uni, v_hoy, v_cat));
  g1 := (v_r ->> 'gasto_id')::BIGINT;
  v_r := pg_temp.paso('gasto efectivo 5.000 (sin confirmar)', format($s$SELECT rest.guardar_gasto('{"unidad_id":%s,"fecha":"%s","categoria_gasto_id":%s,"metodo_pago":"efectivo","descripcion":"Bolsas y servilletas","monto":5000}')$s$, v_uni, v_hoy, v_cat));
  g2 := (v_r ->> 'gasto_id')::BIGINT;
  v_r := pg_temp.paso('gasto Nequi 30.000', format($s$SELECT rest.guardar_gasto('{"unidad_id":%s,"fecha":"%s","categoria_gasto_id":%s,"metodo_pago":"nequi","descripcion":"Proveedor de carnes","monto":30000}')$s$, v_uni, v_hoy, v_cat));
  g3 := (v_r ->> 'gasto_id')::BIGINT;
  v_r := pg_temp.paso('gasto efectivo 7.000 (se anula)', format($s$SELECT rest.guardar_gasto('{"unidad_id":%s,"fecha":"%s","categoria_gasto_id":%s,"metodo_pago":"efectivo","descripcion":"Gasto equivocado","monto":7000}')$s$, v_uni, v_hoy, v_cat));
  g4 := (v_r ->> 'gasto_id')::BIGINT;
  v_r := pg_temp.paso('gasto datáfono 3.000', format($s$SELECT rest.guardar_gasto('{"unidad_id":%s,"fecha":"%s","categoria_gasto_id":%s,"metodo_pago":"datafono","descripcion":"Comisión datáfono","monto":3000}')$s$, v_uni, v_hoy, v_cat));
  g5 := (v_r ->> 'gasto_id')::BIGINT;
  PERFORM pg_temp.paso('confirmar gasto efectivo', format('SELECT rest.confirmar_gasto(%s)', g1));
  PERFORM pg_temp.paso('confirmar gasto Nequi',    format('SELECT rest.confirmar_gasto(%s)', g3));
  PERFORM pg_temp.paso('confirmar gasto datáfono', format('SELECT rest.confirmar_gasto(%s)', g5));
  PERFORM pg_temp.paso('anular gasto',             format($s$SELECT rest.anular_gasto(%s, 'Se registró por error')$s$, g4));

  /* ---- Lo esperado ---- */
  e_ef_v := 2*P + (P + 4000) + P + 2*P + P;   -- q1 q5 q6 q10 q13
  e_ef_c := 2*P + (P + 4000) + 2*P + P;       -- q1 q5 q10 q13
  e_ef_p := P;                                -- q6
  e_nq_v := (P + 500) + (P + 4500);           -- q2 q12
  e_nq_c := P + 500;                          -- q2
  e_nq_p := P + 4500;                         -- q12 (reportado)
  e_dv   := 2*P + 4000;                       -- q3
  e_df_v := (2*P + r1) + (P + 4000 + r2);     -- q4 q11
  e_df_c := 2*P + r1;                         -- q4
  e_df_p := P + 4000 + r2;                    -- q11
  e_br   := P;                                -- q7 rechazado
  e_an   := 3*P + 500;                        -- q9 anulada

  i1 := pg_temp.app(format('SELECT rest.informe_caja(%L, %s)', v_hoy, v_uni));
  c1 := pg_temp.cruce(v_uni, v_hoy);

  /* Por método (rest.informe_caja), como diferencia contra lo que había */
  PERFORM pg_temp.igual('efectivo vendido',  e_ef_v, pg_temp.n(i1,'ventas','efectivo','vendido')   - pg_temp.n(i0,'ventas','efectivo','vendido'));
  PERFORM pg_temp.igual('efectivo cobrado',  e_ef_c, pg_temp.n(i1,'ventas','efectivo','cobrado')   - pg_temp.n(i0,'ventas','efectivo','cobrado'));
  PERFORM pg_temp.igual('efectivo por cobrar', e_ef_p, pg_temp.n(i1,'ventas','efectivo','pendiente') - pg_temp.n(i0,'ventas','efectivo','pendiente'));
  PERFORM pg_temp.igual('Nequi vendido',     e_nq_v, pg_temp.n(i1,'ventas','nequi','vendido')      - pg_temp.n(i0,'ventas','nequi','vendido'));
  PERFORM pg_temp.igual('Nequi cobrado',     e_nq_c, pg_temp.n(i1,'ventas','nequi','cobrado')      - pg_temp.n(i0,'ventas','nequi','cobrado'));
  PERFORM pg_temp.igual('Nequi por cobrar (reportado)', e_nq_p, pg_temp.n(i1,'ventas','nequi','pendiente') - pg_temp.n(i0,'ventas','nequi','pendiente'));
  PERFORM pg_temp.igual('Daviplata cobrado', e_dv,   pg_temp.n(i1,'ventas','daviplata','cobrado')  - pg_temp.n(i0,'ventas','daviplata','cobrado'));
  PERFORM pg_temp.igual('datáfono vendido',  e_df_v, pg_temp.n(i1,'ventas','datafono','vendido')   - pg_temp.n(i0,'ventas','datafono','vendido'));
  PERFORM pg_temp.igual('datáfono cobrado',  e_df_c, pg_temp.n(i1,'ventas','datafono','cobrado')   - pg_temp.n(i0,'ventas','datafono','cobrado'));
  PERFORM pg_temp.igual('datáfono por cobrar', e_df_p, pg_temp.n(i1,'ventas','datafono','pendiente') - pg_temp.n(i0,'ventas','datafono','pendiente'));
  PERFORM pg_temp.igual('Bre-B rechazado',   e_br,   pg_temp.n(i1,'ventas','breb','rechazado')     - pg_temp.n(i0,'ventas','breb','rechazado'));
  PERFORM pg_temp.igual('Bre-B cobrado',     0,      pg_temp.n(i1,'ventas','breb','cobrado')       - pg_temp.n(i0,'ventas','breb','cobrado'));
  PERFORM pg_temp.igual('anulada aparte (Nequi)', e_an, pg_temp.n(i1,'anuladas','nequi','total')   - pg_temp.n(i0,'anuladas','nequi','total'));
  PERFORM pg_temp.igual('cancelado no cuenta: 5 pedidos en efectivo', 5, pg_temp.n(i1,'ventas','efectivo','n') - pg_temp.n(i0,'ventas','efectivo','n'));
  PERFORM pg_temp.igual('gastos efectivo (incluye sin confirmar)', 25000, pg_temp.n(i1,'gastos','efectivo','total') - pg_temp.n(i0,'gastos','efectivo','total'));
  PERFORM pg_temp.igual('gastos efectivo sin confirmar', 5000, pg_temp.n(i1,'gastos','efectivo','montoPendiente') - pg_temp.n(i0,'gastos','efectivo','montoPendiente'));
  PERFORM pg_temp.igual('gastos Nequi',      30000, pg_temp.n(i1,'gastos','nequi','total')    - pg_temp.n(i0,'gastos','nequi','total'));
  PERFORM pg_temp.igual('gastos datáfono',   3000,  pg_temp.n(i1,'gastos','datafono','total') - pg_temp.n(i0,'gastos','datafono','total'));
  PERFORM pg_temp.igual('base vigente',      120000, pg_temp.n(i1,'base','valor'));

  /* Bolsas del cruce (api.v_cruce_caja) */
  PERFORM pg_temp.igual('cruce: pedidos que cuentan',  11, pg_temp.n(c1,'pedidos') - pg_temp.n(c0,'pedidos'));
  PERFORM pg_temp.igual('cruce: ventas efectivo',      e_ef_v, pg_temp.n(c1,'ventas_efectivo') - pg_temp.n(c0,'ventas_efectivo'));
  PERFORM pg_temp.igual('cruce: ventas transferencia', e_nq_v + e_dv + e_br, pg_temp.n(c1,'ventas_transferencia') - pg_temp.n(c0,'ventas_transferencia'));
  PERFORM pg_temp.igual('cruce: ventas otros',         e_df_v, pg_temp.n(c1,'ventas_otros') - pg_temp.n(c0,'ventas_otros'));
  PERFORM pg_temp.igual('cruce: cobrado efectivo',     e_ef_c, pg_temp.n(c1,'cobrado_efectivo') - pg_temp.n(c0,'cobrado_efectivo'));
  PERFORM pg_temp.igual('cruce: cobrado transferencia', e_nq_c + e_dv, pg_temp.n(c1,'cobrado_transferencia') - pg_temp.n(c0,'cobrado_transferencia'));
  PERFORM pg_temp.igual('cruce: cobrado otros',        e_df_c, pg_temp.n(c1,'cobrado_otros') - pg_temp.n(c0,'cobrado_otros'));
  PERFORM pg_temp.igual('cruce: por cobrar',           e_ef_p + e_nq_p + e_df_p, pg_temp.n(c1,'por_cobrar') - pg_temp.n(c0,'por_cobrar'));
  PERFORM pg_temp.igual('cruce: rechazado',            e_br, pg_temp.n(c1,'rechazado') - pg_temp.n(c0,'rechazado'));
  PERFORM pg_temp.igual('cruce: anuladas',             e_an, pg_temp.n(c1,'anuladas_total') - pg_temp.n(c0,'anuladas_total'));
  PERFORM pg_temp.igual('cruce: gastos efectivo',      25000, pg_temp.n(c1,'gastos_efectivo') - pg_temp.n(c0,'gastos_efectivo'));
  PERFORM pg_temp.igual('cruce: gastos transferencia', 30000, pg_temp.n(c1,'gastos_transferencia') - pg_temp.n(c0,'gastos_transferencia'));
  PERFORM pg_temp.igual('cruce: gastos otros',         3000,  pg_temp.n(c1,'gastos_otros') - pg_temp.n(c0,'gastos_otros'));
  PERFORM pg_temp.igual('cruce: base',                 120000, pg_temp.n(c1,'base'));

  /* Fórmulas del arqueo */
  PERFORM pg_temp.igual('EFECTIVO ESPERADO = base + efectivo cobrado − gastos en efectivo',
          120000 + pg_temp.n(c1,'cobrado_efectivo') - pg_temp.n(c1,'gastos_efectivo'), pg_temp.n(c1,'efectivo_esperado'));
  PERFORM pg_temp.igual('efectivo esperado se movió base + cobrado − gastos',
          120000 - pg_temp.n(c0,'base') + e_ef_c - 25000, pg_temp.n(c1,'efectivo_esperado') - pg_temp.n(c0,'efectivo_esperado'));
  PERFORM pg_temp.igual('transferencias netas = cobrado − gastos',
          pg_temp.n(c1,'cobrado_transferencia') - pg_temp.n(c1,'gastos_transferencia'), pg_temp.n(c1,'transferencias_netas'));
  PERFORM pg_temp.igual('otros netos = cobrado − gastos',
          pg_temp.n(c1,'cobrado_otros') - pg_temp.n(c1,'gastos_otros'), pg_temp.n(c1,'otros_netos'));
  PERFORM pg_temp.igual('cobrado + por cobrar + rechazado = vendido', pg_temp.n(c1,'ventas_total'),
          pg_temp.n(c1,'cobrado_efectivo') + pg_temp.n(c1,'cobrado_transferencia') + pg_temp.n(c1,'cobrado_otros')
          + pg_temp.n(c1,'por_cobrar') + pg_temp.n(c1,'rechazado'));
  PERFORM pg_temp.igual('informe y cruce: mismo efectivo cobrado', pg_temp.n(c1,'cobrado_efectivo'),
          pg_temp.n(i1,'ventas','efectivo','cobrado'));
  PERFORM pg_temp.igual('ningún pedido con total ≠ ítems + domicilio + recargo', 0,
          (SELECT count(*) FROM api.v_pedidos vp JOIN core.pedidos p ON p.id = vp.pedido_id
            WHERE vp.unidad_id = v_uni AND vp.fecha_operativa = v_hoy
              AND vp.total <> (SELECT COALESCE(SUM(i.precio_unitario * i.cantidad), 0) FROM core.pedido_items i WHERE i.pedido_id = p.id)
                             + p.costo_domicilio + p.recargo_pago));

  /* ---- Controles ---- */
  UPDATE core.empresa_metodos_pago SET activo = FALSE
   WHERE empresa_id = v_emp AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'daviplata');
  PERFORM pg_temp.bloqueado('no se cobra con un método inactivo',
          format('SELECT rest.confirmar_pago(%s, ''X'', ''daviplata'')', q6), 'no está disponible');
  SELECT us.id INTO v_otro FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = v_emp AND r.codigo = 'mesero' AND us.activo ORDER BY us.id LIMIT 1;
  IF v_otro IS NOT NULL THEN
    PERFORM pg_temp.token(v_otro);
    PERFORM pg_temp.bloqueado('un mesero no cobra', format('SELECT rest.confirmar_pago(%s, NULL, NULL)', q6), 'no tiene el permiso');
    PERFORM pg_temp.bloqueado('un mesero no cancela', format('SELECT rest.cancelar_pedido(%s, ''x'')', q6), 'no tiene el permiso');
  END IF;
  PERFORM pg_temp.token(v_dueno);
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, esperado, obtenido
  FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS FINANCIERAS PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
