/* ============================================================================
   50 · PRUEBAS · DESPIECES (una entrada que llena varios insumos)

   Genérica: crea sus propios insumos de prueba en la primera sede activa y
   usa el dueño de esa empresa. Se deshace sola (ROLLBACK).

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/50_pruebas_despiece.sql

   Tiene que salir «TODAS LAS PRUEBAS DE DESPIECE PASARON».
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

CREATE FUNCTION pg_temp.stock(p_codigo TEXT, p_unidad INT) RETURNS NUMERIC LANGUAGE sql AS $$
  SELECT iu.stock_actual FROM core.insumo_unidades iu JOIN core.insumos i ON i.id = iu.insumo_id
   WHERE i.codigo = p_codigo AND iu.unidad_id = p_unidad; $$;

DO $$
DECLARE
  v_uni INT; v_otra INT; v_emp INT; v_dueno INT; v_hoy DATE; v_cod_otra TEXT;
  v_r JSONB; v_pollo INT; v_pernil INT; v_lote BIGINT; v_e1 BIGINT; v_suelta BIGINT; v_n INT;
  c TEXT;
BEGIN
  SELECT u.id, u.empresa_id INTO v_uni, v_emp FROM core.unidades u JOIN core.empresas e ON e.id = u.empresa_id
   WHERE u.estado = 'activa' AND e.estado = 'activa' ORDER BY u.id LIMIT 1;
  SELECT id INTO v_otra FROM core.unidades WHERE empresa_id = v_emp AND id <> v_uni AND estado = 'activa' ORDER BY id LIMIT 1;
  SELECT us.id INTO v_dueno FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = v_emp AND r.codigo = 'admin' AND us.activo ORDER BY us.id LIMIT 1;
  v_hoy := core.fn_fecha_operativa(v_emp, now());
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_dueno, 'empresa_id', v_emp)::TEXT, TRUE);
  RAISE NOTICE 'Sede %, otra sede %, empresa %, dueño %, jornada %', v_uni, v_otra, v_emp, v_dueno, v_hoy;

  /* ---- Insumos de prueba: cuatro presas en 0, sólo en esta sede ---- */
  FOREACH c IN ARRAY ARRAY['T50PECH', 'T50ALA', 'T50PIER', 'T50MUSL'] LOOP
    v_r := pg_temp.app(format($s$SELECT rest.guardar_insumo('{"codigo":"%s","nombre":"Prueba %s","categoria":"Presas prueba 50",
             "area":"comidas","unidad":"unidad","unidades":[%s],"stock_actual":0,"stock_minimo":0}')$s$, c, c, v_uni));
    IF v_r ? 'error' THEN PERFORM pg_temp.anotar(FALSE, 'crear insumo ' || c, v_r ->> 'error'); END IF;
  END LOOP;

  /* ---- 1 · Configurar los despieces ---- */
  v_r := pg_temp.app($s$SELECT rest.guardar_despiece('{"nombre":"Pollo entero prueba","componentes":[
           {"codigo":"t50pech","cantidad":2},{"codigo":"T50ALA","cantidad":2},{"codigo":"T50PIER","cantidad":2},{"codigo":"T50MUSL","cantidad":2}]}')$s$);
  v_pollo := (v_r ->> 'despiece_id')::INT;
  PERFORM pg_temp.anotar(jsonb_array_length(v_r -> 'componentes') = 4, 'pollo entero con 4 presas', COALESCE(v_r ->> 'error', ''));
  v_r := pg_temp.app($s$SELECT rest.guardar_despiece('{"nombre":"Pierna pernil prueba","componentes":[
           {"codigo":"T50PIER","cantidad":1},{"codigo":"T50MUSL","cantidad":1}]}')$s$);
  v_pernil := (v_r ->> 'despiece_id')::INT;
  PERFORM pg_temp.anotar(jsonb_array_length(v_r -> 'componentes') = 2, 'pierna pernil con pierna y muslo', COALESCE(v_r ->> 'error', ''));

  v_r := pg_temp.app($s$SELECT rest.guardar_despiece('{"nombre":"pollo ENTERO prueba","componentes":[{"codigo":"T50ALA","cantidad":1}]}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%Ya hay un despiece%', 'no se repite el nombre', v_r::TEXT);
  v_r := pg_temp.app($s$SELECT rest.guardar_despiece('{"nombre":"Malo","componentes":[{"codigo":"NOEXISTE","cantidad":1}]}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no existe%', 'componente inexistente se rechaza', v_r::TEXT);
  v_r := pg_temp.app($s$SELECT rest.guardar_despiece('{"nombre":"Malo","componentes":[{"codigo":"T50ALA","cantidad":1.5}]}')$s$);
  PERFORM pg_temp.anotar(v_r ? 'error', 'cantidad no entera se rechaza', v_r::TEXT);
  v_r := pg_temp.app($s$SELECT rest.guardar_despiece('{"nombre":"Malo","componentes":[]}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%se reparte%', 'sin componentes se rechaza', v_r::TEXT);
  v_r := pg_temp.app($s$SELECT rest.guardar_despiece('{"nombre":"Malo","componentes":[{"codigo":"T50ALA","cantidad":1},{"codigo":"T50ALA","cantidad":2}]}')$s$);
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%dos veces%', 'componente repetido se rechaza', v_r::TEXT);

  /* ---- 2 · Entrada de 10 pollos: +20 de cada presa ---- */
  v_r := pg_temp.app(format($s$SELECT rest.registrar_entrada_despiece('{"unidad_id":%s,"despiece_id":%s,"cantidad":10,"fecha":"%s","observacion":"Factura 77"}')$s$,
           v_uni, v_pollo, v_hoy));
  v_lote := (v_r ->> 'lote_despiece')::BIGINT;
  PERFORM pg_temp.anotar(jsonb_array_length(v_r -> 'entradas') = 4, '10 pollos crean 4 entradas', COALESCE(v_r ->> 'error', v_r::TEXT));
  PERFORM pg_temp.anotar(pg_temp.stock('T50PECH', v_uni) = 20 AND pg_temp.stock('T50ALA', v_uni) = 20
                     AND pg_temp.stock('T50PIER', v_uni) = 20 AND pg_temp.stock('T50MUSL', v_uni) = 20,
                         'stock: +20 pechuga, ala, pierna y muslo',
                         format('%s/%s/%s/%s', pg_temp.stock('T50PECH', v_uni), pg_temp.stock('T50ALA', v_uni),
                                pg_temp.stock('T50PIER', v_uni), pg_temp.stock('T50MUSL', v_uni)));
  PERFORM pg_temp.anotar((SELECT bool_and(x ->> 'despiece' = 'Pollo entero prueba' AND (x ->> 'observacion') LIKE 'Despiece: 10 × Pollo entero prueba · Factura 77')
                            FROM jsonb_array_elements(v_r -> 'entradas') x),
                         'cada entrada dice de qué despiece salió', (v_r -> 'entradas' -> 0 ->> 'observacion'));

  /* ---- 3 · 5 piernas pernil: +5 pierna y +5 muslo ---- */
  v_r := pg_temp.app(format($s$SELECT rest.registrar_entrada_despiece('{"unidad_id":%s,"despiece_id":%s,"cantidad":5,"fecha":"%s"}')$s$,
           v_uni, v_pernil, v_hoy));
  PERFORM pg_temp.anotar(pg_temp.stock('T50PIER', v_uni) = 25 AND pg_temp.stock('T50MUSL', v_uni) = 25 AND pg_temp.stock('T50ALA', v_uni) = 20,
                         'pernil llena sólo pierna y muslo', format('pierna %s muslo %s ala %s', pg_temp.stock('T50PIER', v_uni),
                         pg_temp.stock('T50MUSL', v_uni), pg_temp.stock('T50ALA', v_uni)));

  /* ---- 4 · El cruce (EN) ve las entradas como cualquier otra ---- */
  SELECT count(*) INTO v_n FROM rest.entradas WHERE lote_despiece IS NOT NULL AND fecha_operativa = v_hoy AND codigo LIKE 'T50%';
  PERFORM pg_temp.anotar(v_n = 6, 'rest.entradas lista las 6 entradas de despiece', v_n::TEXT);

  /* ---- 5 · Corregir una presa suelta: no ---- */
  SELECT x.entrada_id INTO v_e1 FROM rest.entradas x WHERE x.lote_despiece = v_lote LIMIT 1;
  v_r := pg_temp.app(format($s$SELECT rest.corregir_entrada(%s, '{"cantidad":99}')$s$, v_e1));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%salió del despiece%', 'una presa del lote no se corrige suelta', v_r::TEXT);
  PERFORM pg_temp.anotar(pg_temp.stock('T50PECH', v_uni) = 20, 'el intento no tocó el stock', pg_temp.stock('T50PECH', v_uni)::TEXT);

  /* ---- 6 · Eliminar una entrada del lote elimina el lote entero ---- */
  v_r := pg_temp.app(format($s$SELECT rest.anular_entrada(%s, 'Factura equivocada')$s$, v_e1));
  PERFORM pg_temp.anotar((v_r ->> 'entradas_anuladas')::INT = 4, 'eliminar una del pollo elimina las 4', v_r::TEXT);
  PERFORM pg_temp.anotar(pg_temp.stock('T50PECH', v_uni) = 0 AND pg_temp.stock('T50ALA', v_uni) = 0
                     AND pg_temp.stock('T50PIER', v_uni) = 5 AND pg_temp.stock('T50MUSL', v_uni) = 5,
                         'el stock vuelve: queda sólo lo del pernil',
                         format('%s/%s/%s/%s', pg_temp.stock('T50PECH', v_uni), pg_temp.stock('T50ALA', v_uni),
                                pg_temp.stock('T50PIER', v_uni), pg_temp.stock('T50MUSL', v_uni)));

  /* ---- 7 · Lo de siempre no cambió: entrada suelta y su corrección ---- */
  v_r := pg_temp.app(format($s$SELECT rest.registrar_entrada('{"unidad_id":%s,"codigo":"T50ALA","cantidad":3,"fecha":"%s"}')$s$, v_uni, v_hoy));
  v_suelta := (v_r ->> 'entrada_id')::BIGINT;
  v_r := pg_temp.app(format($s$SELECT rest.corregir_entrada(%s, '{"cantidad":4}')$s$, v_suelta));
  PERFORM pg_temp.anotar(pg_temp.stock('T50ALA', v_uni) = 4, 'entrada suelta: registrar y corregir siguen igual', COALESCE(v_r ->> 'error', pg_temp.stock('T50ALA', v_uni)::TEXT));
  v_r := pg_temp.app(format($s$SELECT rest.anular_entrada(%s, 'Prueba')$s$, (v_r ->> 'entrada_id')::BIGINT));
  PERFORM pg_temp.anotar((v_r ->> 'entradas_anuladas')::INT = 1 AND pg_temp.stock('T50ALA', v_uni) = 0, 'eliminar una suelta elimina sólo esa', v_r::TEXT);

  /* ---- 8 · Validaciones de la entrada ---- */
  v_r := pg_temp.app(format($s$SELECT rest.registrar_entrada_despiece('{"unidad_id":%s,"despiece_id":%s,"cantidad":0,"fecha":"%s"}')$s$, v_uni, v_pollo, v_hoy));
  PERFORM pg_temp.anotar(v_r ? 'error', 'cantidad 0 se rechaza', v_r::TEXT);
  v_r := pg_temp.app(format($s$SELECT rest.registrar_entrada_despiece('{"unidad_id":%s,"despiece_id":%s,"cantidad":1,"fecha":"%s"}')$s$, v_uni, v_pollo, v_hoy + 1));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%futura%', 'jornada futura se rechaza', v_r::TEXT);
  IF v_otra IS NOT NULL THEN
    v_r := pg_temp.app(format($s$SELECT rest.registrar_entrada_despiece('{"unidad_id":%s,"despiece_id":%s,"cantidad":1,"fecha":"%s"}')$s$, v_otra, v_pollo, v_hoy));
    PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no está activo en esta sede%', 'sede sin esas presas: se rechaza entero', v_r::TEXT);
    PERFORM pg_temp.anotar(NOT EXISTS (SELECT 1 FROM core.entradas_inventario e JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
                                        WHERE iu.unidad_id = v_otra AND e.despiece_id = v_pollo), 'y no deja nada a medias');
  END IF;

  /* ---- 9 · Borrar: con entradas se apaga; sin entradas se borra ---- */
  v_r := pg_temp.app(format('SELECT rest.borrar_despiece(%s)', v_pollo));
  PERFORM pg_temp.anotar((v_r ->> 'desactivado')::BOOLEAN, 'despiece usado: se desactiva, no se borra', v_r::TEXT);
  v_r := pg_temp.app(format($s$SELECT rest.registrar_entrada_despiece('{"unidad_id":%s,"despiece_id":%s,"cantidad":1,"fecha":"%s"}')$s$, v_uni, v_pollo, v_hoy));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%desactivado%', 'despiece desactivado no recibe entradas', v_r::TEXT);
  v_r := pg_temp.app($s$SELECT rest.guardar_despiece('{"nombre":"Sin uso prueba","componentes":[{"codigo":"T50ALA","cantidad":1}]}')$s$);
  v_r := pg_temp.app(format('SELECT rest.borrar_despiece(%s)', (v_r ->> 'despiece_id')::INT));
  PERFORM pg_temp.anotar((v_r ->> 'borrado')::BOOLEAN, 'despiece sin uso: se borra', v_r::TEXT);

  /* ---- 10 · Aislamiento: otra empresa no ve ni usa estos despieces ---- */
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_dueno, 'empresa_id', -1)::TEXT, TRUE);
  v_r := pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.despieces');
  PERFORM pg_temp.anotar(v_r = '0'::JSONB, 'otra empresa no ve los despieces', v_r::TEXT);
  v_r := pg_temp.app(format($s$SELECT rest.registrar_entrada_despiece('{"unidad_id":%s,"despiece_id":%s,"cantidad":1,"fecha":"%s"}')$s$, v_uni, v_pernil, v_hoy));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no existe%', 'otra empresa no usa el despiece ajeno', v_r::TEXT);

  /* ---- 11 · La tabla sigue inmutable: no se cambia el lote a mano ---- */
  BEGIN
    UPDATE core.entradas_inventario SET lote_despiece = lote_despiece + 1 WHERE lote_despiece IS NOT NULL AND anulada_en IS NULL;
    PERFORM pg_temp.anotar(NOT FOUND, 'cambiar un lote ya sellado: bloqueado');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.anotar(SQLERRM LIKE '%no se modifican%', 'cambiar un lote ya sellado: bloqueado', SQLERRM);
  END;
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE DESPIECE PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
