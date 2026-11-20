/* ============================================================================
   52 · PRUEBAS · COMANDA IMPRESA

   Usa la primera empresa con dueño, caja y mesero, y una sede donde trabaje
   caja (la «de comanda») y otra sede cualquiera (que debe quedar igual).
   Se deshace sola (ROLLBACK).

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/52_pruebas_comanda.sql

   Tiene que salir «TODAS LAS PRUEBAS DE COMANDA PASARON».
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);

CREATE FUNCTION pg_temp.como(p_usuario INT) RETURNS VOID LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', p_usuario,
         'empresa_id', (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario))::TEXT, TRUE); $$;
CREATE FUNCTION pg_temp.como_cliente() RETURNS VOID LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', '{"role":"taseca_anon"}', TRUE); $$;

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

CREATE FUNCTION pg_temp.anotar(p_ok BOOLEAN, p_que TEXT, p_detalle TEXT DEFAULT '') RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO resultados (ok, que, detalle) VALUES (COALESCE(p_ok, FALSE), p_que, p_detalle); $$;

CREATE FUNCTION pg_temp.de_rol(p_emp INT, p_rol TEXT) RETURNS INT LANGUAGE sql AS $$
  SELECT us.id FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE us.empresa_id = p_emp AND r.codigo = p_rol AND us.activo ORDER BY us.id LIMIT 1; $$;

CREATE FUNCTION pg_temp.estado(p_id BIGINT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT estado FROM api.v_pedidos WHERE pedido_id = p_id; $$;

CREATE FUNCTION pg_temp.pedido(p_unidad INT, p_prod INT, p_tipo TEXT DEFAULT 'recoger', p_rol TEXT DEFAULT 'taseca_app') RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v JSONB;
BEGIN
  v := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => %L, p_metodo_pago => 'efectivo',
         p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb, p_cliente_nombre => 'Cliente 52', p_cliente_telefono => '3001112233',
         p_clave => %L)$s$, p_unidad, p_tipo, p_prod, 'p52-' || clock_timestamp() || random()), p_rol);
  IF v ? 'error' THEN RAISE NOTICE 'crear pedido: %', v ->> 'error'; END IF;
  RETURN (v ->> 'pedido_id')::BIGINT;
END $$;

DO $$
DECLARE
  v_emp INT; v_uni INT; v_otra INT; v_dueno INT; v_caja INT; v_mesero INT;
  v_cocina INT; v_bebida INT; v_r JSONB;
  p_antes BIGINT; p1 BIGINT; p2 BIGINT; p_beb BIGINT; p_otra BIGINT; p_apagado BIGINT; p_dir BIGINT;
BEGIN
  SELECT e.id INTO v_emp FROM core.empresas e
   WHERE e.estado = 'activa' AND pg_temp.de_rol(e.id, 'admin') IS NOT NULL AND pg_temp.de_rol(e.id, 'caja') IS NOT NULL
     AND pg_temp.de_rol(e.id, 'mesero') IS NOT NULL ORDER BY e.id LIMIT 1;
  v_dueno := pg_temp.de_rol(v_emp, 'admin'); v_caja := pg_temp.de_rol(v_emp, 'caja'); v_mesero := pg_temp.de_rol(v_emp, 'mesero');
  SELECT u.id INTO v_uni FROM core.unidades u WHERE u.empresa_id = v_emp AND u.estado = 'activa'
     AND core.fn_usuario_en_unidad(v_caja, u.id) ORDER BY u.id LIMIT 1;
  SELECT u.id INTO v_otra FROM core.unidades u WHERE u.empresa_id = v_emp AND u.estado = 'activa' AND u.id <> v_uni ORDER BY u.id LIMIT 1;

  /* Dos productos: uno de cocina y otro que se entrega en el acto (bebida) */
  SELECT p.id INTO v_cocina FROM core.productos p JOIN core.categorias c ON c.id = p.categoria_id
   WHERE p.empresa_id = v_emp AND p.precio > 0 AND p.activo AND NOT p.solo_personal AND c.activa ORDER BY p.id LIMIT 1;
  SELECT p.id INTO v_bebida FROM core.productos p JOIN core.categorias c ON c.id = p.categoria_id
   WHERE p.empresa_id = v_emp AND p.precio > 0 AND p.activo AND NOT p.solo_personal AND c.activa AND p.id <> v_cocina ORDER BY p.id LIMIT 1;
  UPDATE core.productos SET requiere_preparacion = TRUE WHERE id = v_cocina;
  UPDATE core.productos SET requiere_preparacion = FALSE WHERE id = v_bebida;
  INSERT INTO core.producto_unidades (producto_id, unidad_id)
  SELECT x, u FROM unnest(ARRAY[v_cocina, v_bebida]) x, unnest(ARRAY[v_uni, v_otra]) u
  ON CONFLICT (producto_id, unidad_id) DO UPDATE SET agotado = FALSE;
  UPDATE core.empresa_metodos_pago SET activo = TRUE
   WHERE empresa_id = v_emp AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'efectivo');
  RAISE NOTICE 'Empresa %, sede comanda %, otra sede %, dueño %, caja %, mesero %', v_emp, v_uni, v_otra, v_dueno, v_caja, v_mesero;

  /* ---- 0 · Apagado (como hoy): todo igual ---- */
  PERFORM pg_temp.como(v_dueno);
  p_antes := pg_temp.pedido(v_uni, v_cocina);
  PERFORM pg_temp.anotar(pg_temp.estado(p_antes) = 'nuevo', 'apagado: el pedido nace «Nuevo», como siempre', pg_temp.estado(p_antes));
  PERFORM pg_temp.como(v_caja);
  v_r := pg_temp.app(format('SELECT rest.tomar_comandas(%s)', v_uni));
  PERFORM pg_temp.anotar(v_r = '[]'::JSONB, 'apagado: la estación no imprime nada', v_r::TEXT);
  /* ese pedido de antes, como si fuera de hace una hora */
  ALTER TABLE core.pedidos DISABLE TRIGGER trg_pedidos_antes_actualizar;
  UPDATE core.pedidos SET creado_en = now() - interval '1 hour' WHERE id = p_antes;
  ALTER TABLE core.pedidos ENABLE TRIGGER trg_pedidos_antes_actualizar;

  /* ---- 1 · Encender: sólo quien configura sedes ---- */
  v_r := pg_temp.app(format('SELECT rest.configurar_comanda(%s, true)', v_uni));
  PERFORM pg_temp.anotar(v_r ? 'error', 'caja no puede encender la comanda', v_r::TEXT);
  PERFORM pg_temp.como(v_dueno);
  v_r := pg_temp.app(format('SELECT rest.configurar_comanda(%s, true)', v_uni));
  PERFORM pg_temp.anotar((v_r ->> 'comanda_impresa')::BOOLEAN, 'el dueño la enciende y la sede lo publica', COALESCE(v_r ->> 'error', ''));
  PERFORM pg_temp.como_cliente();
  v_r := pg_temp.app(format('SELECT to_jsonb(comanda_impresa) FROM rest.unidades WHERE unidad_id = %s', v_uni), 'taseca_anon');
  PERFORM pg_temp.anotar(v_r = 'true'::JSONB, 'el portal del cliente sabe que la sede trabaja con comanda', v_r::TEXT);

  /* ---- 2 · Encendido: nace en preparación (mesero, dueño y cliente) ---- */
  PERFORM pg_temp.como(v_dueno);
  p1 := pg_temp.pedido(v_uni, v_cocina);
  PERFORM pg_temp.anotar(pg_temp.estado(p1) = 'preparacion', 'encendido: el pedido nace «En preparación»', pg_temp.estado(p1));
  PERFORM pg_temp.como_cliente();
  p2 := pg_temp.pedido(v_uni, v_cocina, 'recoger', 'taseca_anon');
  PERFORM pg_temp.anotar(pg_temp.estado(p2) = 'preparacion', 'el pedido del cliente (portal) también', pg_temp.estado(p2));
  PERFORM pg_temp.como(v_dueno);
  p_beb := pg_temp.pedido(v_uni, v_bebida);
  PERFORM pg_temp.anotar(p_beb IS NOT NULL, 'un pedido de sólo bebida se crea normal', pg_temp.estado(p_beb));
  p_otra := pg_temp.pedido(v_otra, v_cocina);
  PERFORM pg_temp.anotar(pg_temp.estado(p_otra) = 'nuevo', 'la OTRA sede (apagada) sigue igual', pg_temp.estado(p_otra));
  PERFORM pg_temp.anotar(pg_temp.estado(p_antes) = 'nuevo', 'el pedido de antes de encender no se mueve', pg_temp.estado(p_antes));

  /* ---- 3 · La estación toma las comandas: una sola vez ---- */
  PERFORM pg_temp.como(v_caja);
  v_r := pg_temp.app(format('SELECT rest.tomar_comandas(%s)', v_uni));
  PERFORM pg_temp.anotar(jsonb_array_length(v_r) = 2
                     AND (SELECT array_agg((x -> 'pedido' ->> 'pedido_id')::BIGINT ORDER BY 1) FROM jsonb_array_elements(v_r) x) = ARRAY[p1, p2],
                         'la estación toma las 2 comandas nuevas (ni la de bebida, ni la de antes, ni la otra sede)',
                         COALESCE(v_r ->> 'error', (SELECT string_agg(x -> 'pedido' ->> 'codigo', ',') FROM jsonb_array_elements(v_r) x)));
  PERFORM pg_temp.anotar((SELECT bool_and(jsonb_array_length(x -> 'cocina') = 1) FROM jsonb_array_elements(v_r) x),
                         'cada comanda dice qué ítems van a cocina');
  v_r := pg_temp.app(format('SELECT rest.tomar_comandas(%s)', v_uni));
  PERFORM pg_temp.anotar(v_r = '[]'::JSONB, 'la segunda vez no repite nada', v_r::TEXT);
  PERFORM pg_temp.anotar(EXISTS (SELECT 1 FROM core.estaciones_comanda WHERE unidad_id = v_uni AND usuario_id = v_caja),
                         'queda el latido de la estación');

  /* ---- 4 · Reimprimir ---- */
  v_r := pg_temp.app(format('SELECT rest.reimprimir_comanda(%s)', p1));
  v_r := pg_temp.app(format('SELECT rest.tomar_comandas(%s)', v_uni));
  PERFORM pg_temp.anotar(jsonb_array_length(v_r) = 1 AND (v_r -> 0 -> 'pedido' ->> 'pedido_id')::BIGINT = p1
                     AND (SELECT comanda_impresiones FROM core.pedidos WHERE id = p1) = 2,
                         'reimprimir la vuelve a sacar por la impresora', v_r::TEXT);

  /* ---- 5 · Caja marca «Listo» ---- */
  v_r := pg_temp.app(format('SELECT rest.comanda_lista(%s)', p1));
  PERFORM pg_temp.anotar(pg_temp.estado(p1) = 'listo', 'caja marca «Listo» cuando la cocina avisa', COALESCE(v_r ->> 'error', ''));
  v_r := pg_temp.app(format('SELECT rest.comanda_lista(%s)', p1));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%ya está en%', 'marcarlo dos veces avisa', v_r::TEXT);
  PERFORM pg_temp.como(v_mesero);
  v_r := pg_temp.app(format('SELECT rest.comanda_lista(%s)', p2));
  PERFORM pg_temp.anotar(v_r ? 'error' AND pg_temp.estado(p2) = 'preparacion', 'el mesero no marca listo desde caja', v_r::TEXT);
  v_r := pg_temp.app(format('SELECT rest.tomar_comandas(%s)', v_uni));
  PERFORM pg_temp.anotar(v_r ? 'error', 'el mesero no es estación de comandas', v_r::TEXT);

  /* ---- 6 · Lo de después sigue igual: el mesero entrega el listo ---- */
  v_r := pg_temp.app(format($s$SELECT rest.avanzar_estado(%s, 'listo')$s$, p1));
  PERFORM pg_temp.anotar(pg_temp.estado(p1) = 'entregado', 'después de «Listo» el flujo sigue como siempre', COALESCE(v_r ->> 'error', pg_temp.estado(p1)));

  /* ---- 7 · Estado para caja ---- */
  PERFORM pg_temp.como(v_caja);
  v_r := pg_temp.app(format('SELECT rest.estado_comandas(%s)', v_uni));
  PERFORM pg_temp.anotar((v_r ->> 'activa')::BOOLEAN AND (v_r ->> 'sin_imprimir')::INT = 0 AND v_r ? 'segundos_sin_estacion',
                         'caja ve si la estación está viva y cuántas faltan', v_r::TEXT);

  /* ---- 8 · Apagar: vuelve a ser como antes ---- */
  PERFORM pg_temp.como(v_dueno);
  PERFORM pg_temp.app(format('SELECT rest.configurar_comanda(%s, false)', v_uni));
  p_apagado := pg_temp.pedido(v_uni, v_cocina);
  PERFORM pg_temp.anotar(pg_temp.estado(p_apagado) = 'nuevo', 'apagada otra vez: el pedido nace «Nuevo»', pg_temp.estado(p_apagado));
  PERFORM pg_temp.como(v_caja);
  v_r := pg_temp.app(format('SELECT rest.tomar_comandas(%s)', v_uni));
  PERFORM pg_temp.anotar(v_r = '[]'::JSONB, 'apagada: la estación ya no imprime', v_r::TEXT);

  /* ---- 9 · Venta directa de sólo bebida: nace entregada, la comanda no la toca ---- */
  PERFORM pg_temp.como(v_dueno);
  PERFORM pg_temp.app(format('SELECT rest.configurar_comanda(%s, true)', v_uni));
  v_r := pg_temp.app(format($s$SELECT rest.crear_pedido(p_unidad_id => %s, p_tipo => 'mostrador', p_metodo_pago => 'efectivo',
           p_items => '[{"producto_id":%s,"cantidad":1}]'::jsonb, p_clave => %L)$s$, v_uni, v_bebida, 'p52-dir' || clock_timestamp()));
  p_dir := (v_r ->> 'pedido_id')::BIGINT;
  PERFORM pg_temp.anotar(pg_temp.estado(p_dir) = 'entregado', 'venta directa de bebida: sigue naciendo entregada', COALESCE(v_r ->> 'error', pg_temp.estado(p_dir)));
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE COMANDA PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
