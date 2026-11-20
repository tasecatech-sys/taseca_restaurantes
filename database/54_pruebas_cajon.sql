/* ============================================================================
   54 · PRUEBAS · CAJÓN MONEDERO

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/54_pruebas_cajon.sql

   Se deshace sola. Tiene que salir «TODAS LAS PRUEBAS DEL CAJÓN PASARON».
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);

CREATE FUNCTION pg_temp.app(p_sql TEXT, p_rol TEXT DEFAULT 'taseca_app') RETURNS JSONB LANGUAGE plpgsql AS $$
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

CREATE FUNCTION pg_temp.como(p_usuario INT) RETURNS VOID LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', p_usuario,
         'empresa_id', (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario))::TEXT, TRUE); $$;

CREATE FUNCTION pg_temp.anotar(p_ok BOOLEAN, p_que TEXT, p_detalle TEXT DEFAULT '') RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO resultados (ok, que, detalle) VALUES (COALESCE(p_ok, FALSE), p_que, p_detalle); $$;

DO $$
DECLARE v_emp INT; v_uni INT; v_otra INT; v_dueno INT; v_caja INT; v_r JSONB;
BEGIN
  SELECT e.id INTO v_emp FROM core.empresas e WHERE e.estado = 'activa'
     AND EXISTS (SELECT 1 FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id WHERE us.empresa_id = e.id AND r.codigo = 'admin')
     AND EXISTS (SELECT 1 FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id WHERE us.empresa_id = e.id AND r.codigo = 'caja')
   ORDER BY e.id LIMIT 1;
  SELECT us.id INTO v_dueno FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id WHERE us.empresa_id = v_emp AND r.codigo = 'admin' ORDER BY us.id LIMIT 1;
  SELECT us.id INTO v_caja FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id WHERE us.empresa_id = v_emp AND r.codigo = 'caja' ORDER BY us.id LIMIT 1;
  SELECT id INTO v_uni FROM core.unidades WHERE empresa_id = v_emp ORDER BY id LIMIT 1;
  SELECT id INTO v_otra FROM core.unidades WHERE empresa_id = v_emp AND id <> v_uni ORDER BY id LIMIT 1;

  PERFORM pg_temp.anotar((SELECT NOT cajon_monedero FROM core.unidades WHERE id = v_uni), 'nace apagado');

  PERFORM pg_temp.como(v_caja);
  v_r := pg_temp.app(format('SELECT rest.configurar_cajon(%s, true)', v_uni));
  PERFORM pg_temp.anotar(v_r ? 'error', 'caja no lo puede encender', v_r::TEXT);

  PERFORM pg_temp.como(v_dueno);
  v_r := pg_temp.app(format('SELECT rest.configurar_cajon(%s, true)', v_uni));
  PERFORM pg_temp.anotar((v_r ->> 'cajon_monedero')::BOOLEAN, 'el dueño lo enciende', COALESCE(v_r ->> 'error', ''));
  PERFORM pg_temp.anotar((SELECT NOT cajon_monedero FROM core.unidades WHERE id = v_otra), 'la otra sede sigue apagada');

  PERFORM pg_temp.como(v_caja);
  v_r := pg_temp.app(format('SELECT to_jsonb(cajon_monedero) FROM rest.unidades WHERE unidad_id = %s', v_uni));
  PERFORM pg_temp.anotar(v_r = 'true'::JSONB, 'la caja lo ve en su sede', v_r::TEXT);

  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_dueno, 'empresa_id', -1)::TEXT, TRUE);
  v_r := pg_temp.app(format('SELECT rest.configurar_cajon(%s, false)', v_uni));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no es de esta empresa%', 'otra empresa no lo toca', v_r::TEXT);

  PERFORM pg_temp.como(v_dueno);
  v_r := pg_temp.app(format('SELECT rest.configurar_cajon(%s, false)', v_uni));
  PERFORM pg_temp.anotar(NOT (v_r ->> 'cajon_monedero')::BOOLEAN, 'se apaga igual de fácil', COALESCE(v_r ->> 'error', ''));
  PERFORM pg_temp.anotar((v_r ->> 'comanda_impresa') IS NOT NULL, 'la vista conserva la comanda impresa', v_r::TEXT);
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DEL CAJÓN PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
