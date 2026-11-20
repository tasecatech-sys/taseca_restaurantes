/* ============================================================================
   53 · PRUEBAS · DOMICILIO EN EFECTIVO: CON CUÁNTO PAGA

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/53_pruebas_paga_con.sql

   Se deshace sola. Tiene que salir «TODAS LAS PRUEBAS DE PAGA CON PASARON».
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

DO $$
DECLARE
  v_emp INT; v_uni INT; v_dueno INT; v_prod INT; v_zona INT; v_r JSONB; v_extra TEXT;
BEGIN
  SELECT pu.unidad_id, pu.producto_id, u.empresa_id INTO v_uni, v_prod, v_emp
    FROM core.producto_unidades pu JOIN core.productos pr ON pr.id = pu.producto_id
    JOIN core.categorias c ON c.id = pr.categoria_id JOIN core.unidades u ON u.id = pu.unidad_id
   WHERE pr.precio > 0 AND pr.activo AND NOT pr.solo_personal AND c.activa AND NOT pu.agotado AND u.estado = 'activa'
   ORDER BY pu.unidad_id, pu.producto_id LIMIT 1;
  SELECT us.id INTO v_dueno FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = v_emp AND r.codigo = 'admin' AND us.activo ORDER BY us.id LIMIT 1;
  INSERT INTO core.zonas_domicilio (unidad_id, nombre, costo, pedido_minimo, activa) VALUES (v_uni, 'Zona 53', 0, 0, TRUE) RETURNING id INTO v_zona;
  UPDATE core.empresa_metodos_pago SET activo = TRUE WHERE empresa_id = v_emp
     AND metodo_pago_id IN (core.fn_id_catalogo('metodos_pago', 'efectivo'), core.fn_id_catalogo('metodos_pago', 'nequi'));
  v_extra := format($s$, p_cliente_nombre => 'Cliente 53', p_cliente_telefono => '3001112233', p_direccion => 'Cra 5 # 5-55', p_zona_id => %s$s$, v_zona);

  -- Cliente (sin sesión de empleado)
  PERFORM set_config('request.jwt.claims', '{"role":"taseca_anon"}', TRUE);
  v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb %s, p_clave => %L)$s$, v_uni, v_prod, v_extra, 'p53a' || clock_timestamp()), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%con cuánto vas a pagar%', 'cliente a domicilio en efectivo SIN «paga con»: no entra', v_r::TEXT);

  v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb %s, p_paga_con => 100000, p_clave => %L)$s$, v_uni, v_prod, v_extra, 'p53b' || clock_timestamp()), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r ? 'pedido_id' AND (v_r ->> 'paga_con')::NUMERIC = 100000, 'con «paga con»: entra y lo guarda', COALESCE(v_r ->> 'error', ''));

  v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'domicilio', p_metodo_pago => 'nequi',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb %s, p_clave => %L)$s$, v_uni, v_prod, v_extra, 'p53c' || clock_timestamp()), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r ? 'pedido_id', 'a domicilio por Nequi: no se pide', COALESCE(v_r ->> 'error', ''));

  v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'recoger', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb, p_cliente_nombre => 'Cliente 53', p_cliente_telefono => '3001112233', p_clave => %L)$s$,
           v_uni, v_prod, 'p53d' || clock_timestamp()), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r ? 'pedido_id', 'para recoger en efectivo: sigue siendo opcional', COALESCE(v_r ->> 'error', ''));

  -- Caja tomando un domicilio por teléfono: no se le exige
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', v_dueno, 'empresa_id', v_emp)::TEXT, TRUE);
  v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb %s, p_clave => %L)$s$, v_uni, v_prod, v_extra, 'p53e' || clock_timestamp()), 'taseca_app');
  PERFORM pg_temp.anotar(v_r ? 'pedido_id', 'domicilio que toma el personal: no se le exige', COALESCE(v_r ->> 'error', ''));
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE PAGA CON PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
