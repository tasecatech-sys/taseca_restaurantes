/* ============================================================================
   57 · PRUEBAS · DOMICILIOS POR SEDE

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/57_pruebas_domicilio_por_sede.sql

   Se deshace sola. Tiene que salir «TODAS LAS PRUEBAS DE DOMICILIO POR SEDE PASARON».
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

CREATE FUNCTION pg_temp.de_rol(p_emp INT, p_rol TEXT) RETURNS INT LANGUAGE sql AS $$
  SELECT us.id FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = p_emp AND r.codigo = p_rol AND us.activo ORDER BY us.id LIMIT 1; $$;

CREATE FUNCTION pg_temp.como(p_usuario INT, p_emp INT) RETURNS VOID LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
         jsonb_build_object('role', 'taseca_app', 'usuario_id', p_usuario, 'empresa_id', p_emp)::TEXT, TRUE); $$;

CREATE FUNCTION pg_temp.anonimo() RETURNS VOID LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', '{"role":"taseca_anon"}', TRUE); $$;

DO $$
DECLARE
  v_emp INT; v_uni INT; v_dueno INT; v_caja INT; v_prod INT; v_zona INT; v_r JSONB; v_dom TEXT; v_rec TEXT;
  c_msg CONSTANT TEXT := '%no está recibiendo domicilios%';
BEGIN
  SELECT pu.unidad_id, pu.producto_id, u.empresa_id INTO v_uni, v_prod, v_emp
    FROM core.producto_unidades pu JOIN core.productos pr ON pr.id = pu.producto_id
    JOIN core.categorias c ON c.id = pr.categoria_id JOIN core.unidades u ON u.id = pu.unidad_id
   WHERE pr.precio > 0 AND pr.activo AND NOT pr.solo_personal AND c.activa AND NOT pu.agotado AND u.estado = 'activa'
     AND pg_temp.de_rol(u.empresa_id, 'admin') IS NOT NULL
   ORDER BY pu.unidad_id, pu.producto_id LIMIT 1;
  v_dueno := pg_temp.de_rol(v_emp, 'admin');
  v_caja  := pg_temp.de_rol(v_emp, 'caja');
  INSERT INTO core.zonas_domicilio (unidad_id, nombre, costo, pedido_minimo, activa)
       VALUES (v_uni, 'Zona 57', 0, 0, TRUE) RETURNING id INTO v_zona;

  -- Un domicilio en efectivo con «paga con» (53) y otro para recoger
  v_dom := format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb, p_cliente_nombre => 'Cliente 57', p_cliente_telefono => '3001112233',
           p_direccion => 'Cra 5 # 5-57', p_zona_id => %s, p_paga_con => 100000, p_clave => %%L)$s$, v_uni, v_prod, v_zona);
  v_rec := format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'recoger', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb, p_cliente_nombre => 'Cliente 57', p_cliente_telefono => '3001112233',
           p_clave => %%L)$s$, v_uni, v_prod);

  PERFORM pg_temp.anotar((SELECT domicilio_activo FROM core.unidades WHERE id = v_uni), 'las sedes nacen recibiendo domicilios');

  PERFORM pg_temp.anonimo();
  v_r := pg_temp.app(format(v_dom, 'p57a' || clock_timestamp()), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r ? 'pedido_id', 'encendida: el cliente pide a domicilio', COALESCE(v_r ->> 'error', ''));

  -- Quién puede apagarlo
  IF v_caja IS NOT NULL THEN
    PERFORM pg_temp.como(v_caja, v_emp);
    v_r := pg_temp.app(format('SELECT rest.configurar_domicilio(%s, false)', v_uni), 'taseca_app');
    PERFORM pg_temp.anotar(v_r ? 'error', 'caja no lo puede apagar', v_r::TEXT);
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_dueno, 'empresa_id', -1)::TEXT, TRUE);
  v_r := pg_temp.app(format('SELECT rest.configurar_domicilio(%s, false)', v_uni), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no es de esta empresa%', 'otra empresa no lo toca', v_r::TEXT);

  PERFORM pg_temp.como(v_dueno, v_emp);
  v_r := pg_temp.app(format('SELECT rest.configurar_domicilio(%s, false)', v_uni), 'taseca_app');
  PERFORM pg_temp.anotar(NOT (v_r ->> 'domicilio_activo')::BOOLEAN, 'el dueño lo apaga', COALESCE(v_r ->> 'error', ''));
  PERFORM pg_temp.anotar((v_r ->> 'cajon_monedero') IS NOT NULL AND (v_r ->> 'comanda_impresa') IS NOT NULL,
                         'la vista conserva comanda y cajón', v_r::TEXT);

  -- El portal lo ve
  v_r := pg_temp.app(format('SELECT to_jsonb(domicilio_activo) FROM rest.unidades WHERE unidad_id = %s', v_uni), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r = 'false'::JSONB, 'el cliente ve que la sede no recibe domicilios', v_r::TEXT);

  -- Apagado: el cliente no puede pedir a domicilio, sí para recoger
  PERFORM pg_temp.anonimo();
  v_r := pg_temp.app(format(v_dom, 'p57b' || clock_timestamp()), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE c_msg, 'apagada: el domicilio del cliente se rechaza', v_r::TEXT);
  v_r := pg_temp.app(format(v_rec, 'p57c' || clock_timestamp()), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r ? 'pedido_id', 'apagada: para recoger sigue entrando', COALESCE(v_r ->> 'error', ''));

  -- El personal toma un domicilio por teléfono
  PERFORM pg_temp.como(v_dueno, v_emp);
  v_r := pg_temp.app(format(v_dom, 'p57d' || clock_timestamp()), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ? 'pedido_id', 'apagada: el personal sí puede tomar un domicilio', COALESCE(v_r ->> 'error', ''));

  -- Se vuelve a encender
  v_r := pg_temp.app(format('SELECT rest.configurar_domicilio(%s, true)', v_uni), 'taseca_app');
  PERFORM pg_temp.anotar((v_r ->> 'domicilio_activo')::BOOLEAN, 'se enciende igual de fácil', COALESCE(v_r ->> 'error', ''));
  PERFORM pg_temp.anonimo();
  v_r := pg_temp.app(format(v_dom, 'p57e' || clock_timestamp()), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r ? 'pedido_id', 'encendida otra vez: el cliente vuelve a pedir', COALESCE(v_r ->> 'error', ''));
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE DOMICILIO POR SEDE PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
