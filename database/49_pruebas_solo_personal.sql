/* ============================================================================
   49 · PRUEBAS · PRODUCTOS «SOLO PERSONAL»

   Genérica (toma la primera sede activa con un producto con precio) y se
   deshace sola (ROLLBACK).

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/49_pruebas_solo_personal.sql

   Tiene que salir «TODAS LAS PRUEBAS DE SOLO PERSONAL PASARON».
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);

CREATE FUNCTION pg_temp.como_cliente() RETURNS VOID LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', '{"role":"taseca_anon"}', TRUE); $$;
CREATE FUNCTION pg_temp.como_empleado(p_usuario INT) RETURNS VOID LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', p_usuario,
         'empresa_id', (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario))::TEXT, TRUE); $$;

/* Ejecuta p_sql con el rol p_rol; devuelve el JSON o el error como texto. */
CREATE FUNCTION pg_temp.correr(p_rol TEXT, p_sql TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
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

/* El documento del producto tal como lo manda el panel (se arma como dueño de
   la base, ANTES de pasar al rol de la aplicación). */
CREATE FUNCTION pg_temp.doc(p_prod INT, p_solo BOOLEAN) RETURNS TEXT LANGUAGE sql AS $$
  SELECT jsonb_build_object('productos', jsonb_build_array(
           jsonb_build_object('id', 'p' || p.id, 'cat', 'c' || p.categoria_id, 'codigo', p.codigo, 'nombre', p.nombre,
                              'precio', p.precio, 'activo', TRUE,
                              'sucursales', (SELECT jsonb_agg(unidad_id) FROM core.producto_unidades WHERE producto_id = p.id))
           || CASE WHEN p_solo IS NULL THEN '{}'::JSONB ELSE jsonb_build_object('soloPersonal', p_solo) END))::TEXT
    FROM core.productos p WHERE p.id = p_prod; $$;

DO $$
DECLARE
  v_uni INT; v_emp INT; v_cod_emp TEXT; v_dueno INT; v_mesero INT; v_prod INT; v_otro INT; v_cat INT;
  v_r JSONB; v_items TEXT; v_items_otro TEXT;
BEGIN
  SELECT pu.unidad_id, pu.producto_id, u.empresa_id, pr.categoria_id INTO v_uni, v_prod, v_emp, v_cat
    FROM core.producto_unidades pu
    JOIN core.productos pr ON pr.id = pu.producto_id
    JOIN core.categorias c ON c.id = pr.categoria_id
    JOIN core.unidades u ON u.id = pu.unidad_id
    JOIN core.empresas e ON e.id = u.empresa_id
   WHERE pr.precio > 0 AND pr.activo AND c.activa AND NOT pu.agotado AND u.estado = 'activa' AND e.estado = 'activa'
   ORDER BY pu.unidad_id, pu.producto_id LIMIT 1;
  SELECT pu.producto_id INTO v_otro
    FROM core.producto_unidades pu JOIN core.productos pr ON pr.id = pu.producto_id
    JOIN core.categorias c ON c.id = pr.categoria_id
   WHERE pu.unidad_id = v_uni AND pu.producto_id <> v_prod AND pr.precio > 0 AND pr.activo AND c.activa AND NOT pu.agotado
   ORDER BY pu.producto_id LIMIT 1;
  SELECT codigo INTO v_cod_emp FROM core.empresas WHERE id = v_emp;
  SELECT us.id INTO v_dueno FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = v_emp AND r.codigo = 'admin' AND us.activo ORDER BY us.id LIMIT 1;
  /* Un empleado que toma pedidos en ESTA sede (o el dueño si no hay) */
  SELECT us.id INTO v_mesero FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = v_emp AND r.codigo = 'mesero' AND us.activo AND core.fn_usuario_en_unidad(us.id, v_uni)
   ORDER BY us.id LIMIT 1;
  v_mesero := COALESCE(v_mesero, v_dueno);
  UPDATE core.empresa_metodos_pago SET activo = TRUE
   WHERE empresa_id = v_emp AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'efectivo');
  RAISE NOTICE 'Sede %, producto %, otro %, mesero %', v_uni, v_prod, v_otro, v_mesero;

  v_items := jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1))::TEXT;
  v_items_otro := jsonb_build_array(jsonb_build_object('producto_id', v_otro, 'cantidad', 1))::TEXT;

  /* ---- 0 · Nace apagado: nada cambia ---- */
  PERFORM pg_temp.anotar((SELECT NOT solo_personal FROM core.productos WHERE id = v_prod), 'nace en FALSE');

  /* ---- 1 · El panel lo marca (sincronizar_catalogo) ---- */
  PERFORM pg_temp.como_empleado(v_dueno);
  v_r := pg_temp.correr('taseca_app', format('SELECT rest.sincronizar_catalogo(%L::jsonb)', pg_temp.doc(v_prod, TRUE)));
  PERFORM pg_temp.anotar((SELECT solo_personal FROM core.productos WHERE id = v_prod), 'el panel lo marca «solo personal»', COALESCE(v_r ->> 'error', ''));

  /* Un cliente viejo (sin el campo) no lo apaga */
  v_r := pg_temp.correr('taseca_app', format('SELECT rest.sincronizar_catalogo(%L::jsonb)', pg_temp.doc(v_prod, NULL)));
  PERFORM pg_temp.anotar((SELECT solo_personal FROM core.productos WHERE id = v_prod), 'guardar sin el campo no lo apaga', COALESCE(v_r ->> 'error', ''));

  /* ---- 2 · Quién lo ve ---- */
  PERFORM pg_temp.como_cliente();
  v_r := pg_temp.correr('taseca_anon', format('SELECT to_jsonb(count(*)) FROM rest.carta WHERE producto_id = %s', v_prod));
  PERFORM pg_temp.anotar(v_r = '0'::JSONB, 'el cliente NO lo ve en la carta', v_r::TEXT);
  v_r := pg_temp.correr('taseca_anon', format('SELECT to_jsonb(count(*)) FROM rest.carta WHERE producto_id = %s', v_otro));
  PERFORM pg_temp.anotar(v_r = '1'::JSONB, 'el cliente sigue viendo lo normal', v_r::TEXT);
  v_r := pg_temp.correr('taseca_anon', format('SELECT rest.arranque(%L)', v_cod_emp));
  PERFORM pg_temp.anotar(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r -> 'carta') x WHERE (x ->> 'producto_id')::INT = v_prod)
                         AND jsonb_array_length(v_r -> 'carta') > 0,
                         'el arranque del cliente tampoco lo trae', COALESCE(v_r ->> 'error', ''));

  PERFORM pg_temp.como_empleado(v_mesero);
  v_r := pg_temp.correr('taseca_app', format('SELECT to_jsonb(count(*)) FROM rest.carta WHERE producto_id = %s', v_prod));
  PERFORM pg_temp.anotar(v_r = '1'::JSONB, 'el mesero SÍ lo ve', v_r::TEXT);
  v_r := pg_temp.correr('taseca_app', format('SELECT (SELECT x ->> ''solo_personal'' FROM jsonb_array_elements(rest.arranque(%L) -> ''carta'') x WHERE (x ->> ''producto_id'')::INT = %s)::jsonb', v_cod_emp, v_prod));
  PERFORM pg_temp.anotar(v_r = 'true'::JSONB, 'el arranque del personal lo trae marcado', COALESCE(v_r::TEXT, 'no vino'));

  /* Personal de OTRA empresa no lo ve */
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_dueno, 'empresa_id', -1)::TEXT, TRUE);
  v_r := pg_temp.correr('taseca_app', format('SELECT to_jsonb(count(*)) FROM rest.carta WHERE producto_id = %s', v_prod));
  PERFORM pg_temp.anotar(v_r = '0'::JSONB, 'personal de otra empresa no lo ve', v_r::TEXT);

  /* ---- 3 · Quién lo puede pedir ---- */
  PERFORM pg_temp.como_cliente();
  v_r := pg_temp.correr('taseca_anon', format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'recoger', p_metodo_pago => 'efectivo',
            p_items => %L::jsonb, p_cliente_nombre => 'Cliente 49', p_cliente_telefono => '3001234567', p_clave => %L)$s$,
            v_uni, v_items, 'p49a-' || clock_timestamp()));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%sólo se pide con el mesero%', 'el cliente no lo puede pedir aunque lo intente', v_r::TEXT);

  v_r := pg_temp.correr('taseca_anon', format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'recoger', p_metodo_pago => 'efectivo',
            p_items => %L::jsonb, p_cliente_nombre => 'Cliente 49', p_cliente_telefono => '3001234567', p_clave => %L)$s$,
            v_uni, v_items_otro, 'p49b-' || clock_timestamp()));
  PERFORM pg_temp.anotar(v_r ? 'pedido_id', 'el cliente sigue pidiendo lo normal', v_r::TEXT);

  PERFORM pg_temp.como_empleado(v_mesero);
  v_r := pg_temp.correr('taseca_app', format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
            p_items => %L::jsonb, p_mesa => (SELECT numero FROM core.mesas WHERE unidad_id = %s ORDER BY id LIMIT 1), p_clave => %L)$s$,
            v_uni, v_items, v_uni, 'p49c-' || clock_timestamp()));
  IF v_r ? 'error' AND v_r ->> 'error' ILIKE '%mesa%' THEN   -- sede sin mesas: para llevar
    v_r := pg_temp.correr('taseca_app', format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'recoger', p_metodo_pago => 'efectivo',
              p_items => %L::jsonb, p_cliente_nombre => 'Cliente 49', p_cliente_telefono => '3001234567', p_clave => %L)$s$,
              v_uni, v_items, 'p49d-' || clock_timestamp()));
  END IF;
  PERFORM pg_temp.anotar(v_r ? 'pedido_id', 'el mesero SÍ lo puede vender', v_r::TEXT);

  /* ---- 4 · Oculto de verdad (inactivo) no lo vende nadie ---- */
  UPDATE core.productos SET activo = FALSE WHERE id = v_prod;
  v_r := pg_temp.correr('taseca_app', format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'recoger', p_metodo_pago => 'efectivo',
            p_items => %L::jsonb, p_cliente_nombre => 'Cliente 49', p_cliente_telefono => '3001234567', p_clave => %L)$s$,
            v_uni, v_items, 'p49e-' || clock_timestamp()));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no está disponible%', 'oculto (inactivo): ni el mesero lo vende', v_r::TEXT);

  /* ---- 5 · Apagarlo desde el panel lo devuelve a la carta ---- */
  UPDATE core.productos SET activo = TRUE WHERE id = v_prod;
  PERFORM pg_temp.como_empleado(v_dueno);
  v_r := pg_temp.correr('taseca_app', format('SELECT rest.sincronizar_catalogo(%L::jsonb)', pg_temp.doc(v_prod, FALSE)));
  PERFORM pg_temp.como_cliente();
  v_r := pg_temp.correr('taseca_anon', format('SELECT to_jsonb(count(*)) FROM rest.carta WHERE producto_id = %s', v_prod));
  PERFORM pg_temp.anotar(v_r = '1'::JSONB, 'desmarcado vuelve a la carta del cliente', v_r::TEXT);
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE SOLO PERSONAL PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
