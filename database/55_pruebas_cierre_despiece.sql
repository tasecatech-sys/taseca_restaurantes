/* ============================================================================
   55 · PRUEBAS · CIERRE CONTANDO POR DESPIECE

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/55_pruebas_cierre_despiece.sql

   Se deshace sola. Tiene que salir «TODAS LAS PRUEBAS DEL CIERRE POR DESPIECE PASARON».
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);

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

CREATE FUNCTION pg_temp.saldo(p_cierre JSONB, p_codigo TEXT) RETURNS NUMERIC LANGUAGE sql AS $$
  SELECT (x ->> 'saldo')::NUMERIC FROM jsonb_array_elements(p_cierre -> 'productos') x WHERE x ->> 'codigo' = p_codigo; $$;

DO $$
DECLARE
  v_uni INT; v_emp INT; v_dueno INT; v_hoy DATE; v_r JSONB; v_desp INT; v_foto TEXT; c TEXT;
BEGIN
  SELECT u.id, u.empresa_id INTO v_uni, v_emp FROM core.unidades u JOIN core.empresas e ON e.id = u.empresa_id
   WHERE u.estado = 'activa' AND e.estado = 'activa' ORDER BY u.id LIMIT 1;
  SELECT us.id INTO v_dueno FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = v_emp AND r.codigo = 'admin' AND us.activo ORDER BY us.id LIMIT 1;
  v_hoy := core.fn_fecha_operativa(v_emp, now());
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_dueno, 'empresa_id', v_emp)::TEXT, TRUE);

  -- Un área sin cierre de hoy en esta sede (para no chocar con datos existentes)
  DELETE FROM core.cierre_detalles WHERE cierre_id IN (SELECT id FROM core.cierres_inventario WHERE unidad_id = v_uni AND fecha_operativa = v_hoy);
  DELETE FROM core.cierres_inventario WHERE unidad_id = v_uni AND fecha_operativa = v_hoy;

  FOREACH c IN ARRAY ARRAY['T55PECH', 'T55ALA', 'T55PIER', 'T55MUSL'] LOOP
    v_r := pg_temp.app(format($s$SELECT rest.guardar_insumo('{"codigo":"%s","nombre":"Prueba %s","categoria":"Presas 55",
             "area":"comidas","unidad":"unidad","unidades":[%s],"stock_actual":0,"stock_minimo":0}')$s$, c, c, v_uni));
  END LOOP;
  v_r := pg_temp.app($s$SELECT rest.guardar_despiece('{"nombre":"Pollo entero 55","componentes":[
           {"codigo":"T55PECH","cantidad":2},{"codigo":"T55ALA","cantidad":2},{"codigo":"T55PIER","cantidad":2},{"codigo":"T55MUSL","cantidad":2}]}')$s$);
  v_desp := (v_r ->> 'despiece_id')::INT;

  /* 1 · 10 pollos enteros + sueltas 3/5/2/4: el panel manda los totales y el desglose */
  v_r := pg_temp.app(format($s$SELECT rest.registrar_cierre(jsonb_build_object(
           'unidad_id', %s, 'area', 'comidas', 'fecha', %L, 'estado', 'completado', 'nuevo', true,
           'productos', '[{"codigo":"T55PECH","saldo":23},{"codigo":"T55ALA","saldo":25},{"codigo":"T55PIER","saldo":22},{"codigo":"T55MUSL","saldo":24}]'::jsonb,
           'despieces', jsonb_build_array(jsonb_build_object('despiece_id', %s, 'nombre', 'Pollo entero 55', 'cantidad', 10,
               'componentes', '[{"codigo":"T55PECH","cantidad":2},{"codigo":"T55ALA","cantidad":2},{"codigo":"T55PIER","cantidad":2},{"codigo":"T55MUSL","cantidad":2}]'::jsonb))))$s$,
           v_uni, v_hoy, v_desp));
  PERFORM pg_temp.anotar(pg_temp.saldo(v_r, 'T55PECH') = 23 AND pg_temp.saldo(v_r, 'T55MUSL') = 24, 'los saldos por presa quedan con los totales', COALESCE(v_r ->> 'error', ''));
  PERFORM pg_temp.anotar((v_r -> 'conteo_despieces' -> 0 ->> 'cantidad')::NUMERIC = 10 AND v_r -> 'conteo_despieces' -> 0 ->> 'nombre' = 'Pollo entero 55',
                         'queda el desglose: 10 pollos enteros', (v_r -> 'conteo_despieces')::TEXT);

  /* 2 · Corregir desde un panel viejo (sin «despieces»): el desglose se conserva */
  v_r := pg_temp.app(format($s$SELECT rest.registrar_cierre(jsonb_build_object(
           'unidad_id', %s, 'area', 'comidas', 'fecha', %L, 'estado', 'completado', 'nuevo', false,
           'productos', '[{"codigo":"T55PECH","saldo":24},{"codigo":"T55ALA","saldo":25},{"codigo":"T55PIER","saldo":22},{"codigo":"T55MUSL","saldo":24}]'::jsonb))$s$,
           v_uni, v_hoy));
  PERFORM pg_temp.anotar(pg_temp.saldo(v_r, 'T55PECH') = 24 AND jsonb_array_length(v_r -> 'conteo_despieces') = 1,
                         'corregir sin el campo conserva el desglose', COALESCE(v_r ->> 'error', ''));

  /* 3 · Un desglose que no cabe en el saldo se rechaza */
  v_r := pg_temp.app(format($s$SELECT rest.registrar_cierre(jsonb_build_object(
           'unidad_id', %s, 'area', 'comidas', 'fecha', %L, 'estado', 'completado', 'nuevo', false,
           'productos', '[{"codigo":"T55PECH","saldo":5},{"codigo":"T55ALA","saldo":25},{"codigo":"T55PIER","saldo":22},{"codigo":"T55MUSL","saldo":24}]'::jsonb,
           'despieces', jsonb_build_array(jsonb_build_object('despiece_id', %s, 'nombre', 'Pollo entero 55', 'cantidad', 10,
               'componentes', '[{"codigo":"T55PECH","cantidad":2},{"codigo":"T55ALA","cantidad":2}]'::jsonb))))$s$,
           v_uni, v_hoy, v_desp));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no cuadra%', 'un desglose que no cabe se rechaza (y no se guarda nada)', v_r::TEXT);
  SELECT conteo_despieces::TEXT INTO v_foto FROM core.cierres_inventario WHERE unidad_id = v_uni AND fecha_operativa = v_hoy;
  PERFORM pg_temp.anotar(v_foto LIKE '%"cantidad": 10%' AND (SELECT d.saldo_fisico FROM core.cierre_detalles d JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
                          JOIN core.insumos i ON i.id = iu.insumo_id JOIN core.cierres_inventario ci ON ci.id = d.cierre_id
                         WHERE ci.unidad_id = v_uni AND ci.fecha_operativa = v_hoy AND i.codigo = 'T55PECH') = 24,
                         'tras el rechazo todo sigue como estaba', v_foto);

  /* 4 · Corregir quitando los enteros (lista vacía): el desglose se limpia */
  v_r := pg_temp.app(format($s$SELECT rest.registrar_cierre(jsonb_build_object(
           'unidad_id', %s, 'area', 'comidas', 'fecha', %L, 'estado', 'completado', 'nuevo', false,
           'productos', '[{"codigo":"T55PECH","saldo":24},{"codigo":"T55ALA","saldo":25},{"codigo":"T55PIER","saldo":22},{"codigo":"T55MUSL","saldo":24}]'::jsonb,
           'despieces', '[]'::jsonb))$s$, v_uni, v_hoy));
  PERFORM pg_temp.anotar(v_r -> 'conteo_despieces' = '[]'::JSONB, 'sin enteros, el desglose queda vacío', COALESCE(v_r ->> 'error', (v_r -> 'conteo_despieces')::TEXT));

  /* 5 · El cruce sigue siendo por presa: el pollo entero no es un insumo */
  PERFORM pg_temp.anotar(NOT EXISTS (SELECT 1 FROM core.insumos WHERE empresa_id = v_emp AND nombre ILIKE 'Pollo entero 55'),
                         'el pollo entero no existe como insumo con stock');
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DEL CIERRE POR DESPIECE PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
