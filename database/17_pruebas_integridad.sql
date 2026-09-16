/* ============================================================================
   TASECA · 17 · PRUEBAS DE INTEGRIDAD MULTIEMPRESA
   ----------------------------------------------------------------------------
   Ejecutar después de 17_integridad_multiempresa.sql. Todo dentro de una
   transacción que termina en ROLLBACK: no deja ningún dato.

   La prueba 1 revisa TUS datos reales: si sale un ERROR, ahí está el cruce.

   En DBeaver: Alt+X y mira la pestaña «Salida». Cada prueba escribe ✔.
   ============================================================================ */

BEGIN;

CREATE FUNCTION pg_temp.esperar_error(p_sql TEXT, p_contiene TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM ILIKE '%' || p_contiene || '%' THEN
            RAISE NOTICE '      ✔ bloqueado como se esperaba: %', SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'Falló con otro error: «%» (se esperaba «%»)', SQLERRM, p_contiene;
    END;
    RAISE EXCEPTION 'Debió fallar y no falló: %', p_sql;
END;
$$;

DO $$
DECLARE
    v_ce     INTEGER;  v_com    INTEGER;  v_admin  INTEGER;  v_super INTEGER;
    v_emp2   INTEGER;  v_uni2   INTEGER;  v_cli2   BIGINT;   v_mesa2 INTEGER;
    v_ped    BIGINT;   v_cod    VARCHAR;  v_prod   INTEGER;  v_prod2 INTEGER;
    v_iu     INTEGER;  v_iu2    INTEGER;  v_cierre BIGINT;   v_hoy   DATE;   v_libre DATE;
    v_errores INTEGER; v_avisos INTEGER;  r RECORD;
BEGIN
    SELECT unidad_id INTO v_ce  FROM api.v_unidades WHERE nombre = 'COMIC''ENDO AREPA';
    SELECT unidad_id INTO v_com FROM api.v_unidades WHERE nombre = 'NASCAR-Comidas';
    SELECT id INTO v_admin FROM core.usuarios WHERE usuario = 'admin';
    SELECT u.id INTO v_super FROM core.usuarios u WHERE u.empresa_id IS NULL LIMIT 1;
    SELECT jornada_actual INTO v_hoy FROM api.v_empresas WHERE codigo = 'empresa_nascar';

    -- 1 · LA BASE DE VERDAD: NINGÚN DATO CRUZADO -------------------------------------
    SELECT count(*) FILTER (WHERE gravedad = 'ERROR' AND filas > 0),
           count(*) FILTER (WHERE gravedad = 'AVISO' AND filas > 0)
      INTO v_errores, v_avisos
      FROM api.fn_chequeo_integridad();

    FOR r IN SELECT * FROM api.fn_chequeo_integridad() WHERE filas > 0 ORDER BY gravedad, tabla LOOP
        RAISE NOTICE '      % · % · % → % fila(s): %', r.gravedad, r.tabla, r.chequeo, r.filas, r.ejemplo;
    END LOOP;

    ASSERT v_errores = 0, format('Hay %s relaciones cruzadas: mira el detalle de arriba', v_errores);
    RAISE NOTICE '✔ 1  Chequeo de la base real: 0 relaciones cruzadas (avisos informativos: %)', v_avisos;

    -- Fixtures: una segunda empresa completa, para intentar cruzarla con NASCAR
    INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_cruce', 'Empresa cruce') RETURNING id INTO v_emp2;
    INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
    SELECT v_emp2, id, 'Sede cruce', 'CRUCE' FROM core.tipos_negocio WHERE codigo = 'restaurante'
    RETURNING id INTO v_uni2;
    INSERT INTO core.mesas (unidad_id, numero) VALUES (v_uni2, '1') RETURNING id INTO v_mesa2;
    INSERT INTO core.clientes (empresa_id, nombre, telefono) VALUES (v_emp2, 'Cliente ajeno', '3009998877')
    RETURNING id INTO v_cli2;

    SELECT producto_id INTO v_prod FROM api.v_carta WHERE unidad_id = v_ce LIMIT 1;
    CALL api.sp_crear_pedido(
        p_unidad_id => v_ce, p_tipo => 'mesa', p_metodo_pago => 'efectivo', p_usuario_id => v_admin, p_mesa => '1',
        p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)),
        p_pedido_id => v_ped, p_codigo => v_cod);

    -- 2 · UNA FACTURA NO SE CUELGA DE OTRA EMPRESA -----------------------------------
    PERFORM pg_temp.esperar_error(format(
        $s$INSERT INTO core.pedidos (empresa_id, unidad_id, codigo, tipo_pedido_id, estado_pedido_id,
                                     estado_pago_id, metodo_pago_id, fecha_operativa)
           VALUES (%s, %s, 'X0001', core.fn_id_catalogo('tipos_pedido', 'mesa'),
                   core.fn_id_catalogo('estados_pedido', 'nuevo'), core.fn_id_catalogo('estados_pago', 'pendiente'),
                   core.fn_id_catalogo('metodos_pago', 'efectivo'), '%s')$s$, v_emp2, v_ce, v_hoy),
        'no pertenece a la empresa');   -- lo para el trigger de alta, antes incluso que el del 17
    PERFORM pg_temp.esperar_error(format(
        'UPDATE core.pedidos SET mesa_id = %s WHERE id = %s', v_mesa2, v_ped), 'mesa es de otra unidad');
    PERFORM pg_temp.esperar_error(format(
        'UPDATE core.pedidos SET cliente_id = %s WHERE id = %s', v_cli2, v_ped), 'cliente es de otra empresa');
    RAISE NOTICE '✔ 2  Pedidos: empresa, mesa y cliente tienen que ser de la misma unidad y empresa';

    -- 3 · LO QUE SE VENDE ES DE ESA CARTA --------------------------------------------
    INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_emp2, 'Cruce')
    RETURNING id INTO v_prod2;
    INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio)
    VALUES (v_emp2, v_prod2, 'CR1', 'Producto ajeno', 1000) RETURNING id INTO v_prod2;
    PERFORM pg_temp.esperar_error(format(
        $s$INSERT INTO core.pedido_items (pedido_id, producto_id, nombre, precio_unitario, cantidad)
           VALUES (%s, %s, 'Ajeno', 1000, 1)$s$, v_ped, v_prod2), 'unidad');
    PERFORM pg_temp.esperar_error(format(
        $s$INSERT INTO core.pedido_items (pedido_id, plato_dia_id, nombre, precio_unitario, cantidad)
           SELECT %s, pd.id, 'Plato ajeno', 1000, 1
             FROM core.platos_dia pd JOIN core.menus_dia md ON md.id = pd.menu_dia_id
            WHERE md.unidad_id = %s LIMIT 1$s$, v_ped, v_com), 'unidad');
    RAISE NOTICE '✔ 3  Ítems: el producto y el plato del día tienen que ser de la empresa y la unidad de la factura';

    -- 4 · INVENTARIO Y CAJA -----------------------------------------------------------
    SELECT iu.id INTO v_iu  FROM core.insumo_unidades iu WHERE iu.unidad_id = v_ce  LIMIT 1;
    SELECT iu.id INTO v_iu2 FROM core.insumo_unidades iu WHERE iu.unidad_id <> v_ce LIMIT 1;

    INSERT INTO core.cierres_inventario (unidad_id, area_id, estado_cierre_id, fecha_operativa, registrado_por_id)
    SELECT v_ce, core.fn_id_catalogo('areas_inventario', 'comidas'),
           core.fn_id_catalogo('estados_cierre', 'borrador'), v_hoy, v_admin
    RETURNING id INTO v_cierre;
    PERFORM pg_temp.esperar_error(format(
        $s$INSERT INTO core.cierre_detalles (cierre_id, insumo_unidad_id, saldo_fisico)
           VALUES (%s, %s, 1)$s$, v_cierre, v_iu2), 'no es de la unidad');

    PERFORM pg_temp.esperar_error(format(
        $s$INSERT INTO core.entradas_inventario (insumo_unidad_id, tipo_entrada_id, fecha_operativa, cantidad, pedido_id)
           VALUES (%s, core.fn_id_catalogo('tipos_entrada', 'compra'), '%s', 1, %s)$s$, v_iu2, v_hoy, v_ped),
        'factura es de otra unidad');

    PERFORM pg_temp.esperar_error(format(
        $s$INSERT INTO core.bases_caja (unidad_id, fecha_operativa, monto, usuario_id)
           SELECT %s, '%s', 1000, id FROM core.usuarios WHERE usuario = 'mesero'$s$, v_uni2, v_hoy),
        'no es de la empresa de la unidad');
    RAISE NOTICE '✔ 4  Inventario y caja: conteos, entradas y bases se quedan en su unidad y su empresa';

    -- 5 · LO QUE SÍ ESTÁ PERMITIDO ----------------------------------------------------
    /* El SuperAdmin no pertenece a ninguna empresa: administrando un negocio
       sí puede registrar movimientos suyos. */
    IF v_super IS NOT NULL THEN
        /* Sólo puede haber UNA base vigente por unidad y jornada, y la unidad
           puede tener la de hoy ya registrada: se busca una jornada libre. */
        SELECT d::DATE INTO v_libre
          FROM generate_series(v_hoy - 400, v_hoy, INTERVAL '1 day') d
         WHERE NOT EXISTS (SELECT 1 FROM core.bases_caja b
                            WHERE b.unidad_id = v_ce AND b.fecha_operativa = d::DATE AND b.vigente)
         LIMIT 1;
        ASSERT v_libre IS NOT NULL, 'Hace falta una jornada sin base para esta prueba';

        INSERT INTO core.bases_caja (unidad_id, fecha_operativa, monto, usuario_id)
        VALUES (v_ce, v_libre, 1000, v_super);
        ASSERT (SELECT count(*) FROM core.bases_caja
                 WHERE unidad_id = v_ce AND fecha_operativa = v_libre AND usuario_id = v_super) = 1,
               'La plataforma sí puede operar dentro de una empresa';
    END IF;
    INSERT INTO core.pedido_items (pedido_id, producto_id, nombre, precio_unitario, cantidad)
    VALUES (v_ped, v_prod, 'Otro más de la misma carta', 1000, 1);
    ASSERT (SELECT count(*) FROM core.pedido_items WHERE pedido_id = v_ped) = 2, 'Lo normal sigue funcionando';
    RAISE NOTICE '✔ 5  Lo legítimo sigue pasando: misma carta, y la plataforma operando dentro de una empresa';
END;
$$;

ROLLBACK;
