/* ============================================================================
   TASECA · 25 · PRUEBAS DE LA VENTA DIRECTA
   ----------------------------------------------------------------------------
   Ejecutar después de 25_venta_directa.sql. Todo dentro de una transacción que
   termina en ROLLBACK: no deja ningún dato.

   Lo que se comprueba:
     1. Una venta de sólo cosas que no se preparan nace ENTREGADA y COBRADA.
     2. Si algo hay que prepararlo, la venta entra al flujo: queda en «nuevo»
        para que la cocina la vea, pero ya pagada.
     3. El cobro queda con su método, quién lo hizo y en el historial.
     4. No tiene mesa, ni zona, ni costo de domicilio, aunque se los manden.
     5. Un plato del día siempre se prepara, aunque todo lo demás no.
     6. Sin sesión no hay venta directa: la registra quien está en caja.
     7. Quien no tiene el permiso de pagos tampoco puede.
     8. Sigue sin poder cobrarse con un método que la empresa no tiene.

   En DBeaver: Alt+X y mira la pestaña «Salida». Cada prueba escribe ✔.
   ============================================================================ */

BEGIN;

/* ---------------------------------------------------------------------------
   ANTES DE NADA: ¿con qué usuario estás conectado?
   --------------------------------------------------------------------------- */

DO $guardia$
BEGIN
    IF NOT has_table_privilege(current_user, 'core.usuarios', 'SELECT') THEN
        RAISE EXCEPTION E'Esta prueba hay que correrla con el usuario dueño de la base.\n'
            'Estás conectado como «%», que no puede leer core.usuarios.\n'
            'En Supabase usa el SQL Editor; en DBeaver, la conexión de postgres.',
            current_user
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$guardia$;

/* ¿Está instalada la venta directa? */
DO $falta$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.tipos_pedido WHERE codigo = 'mostrador') THEN
        RAISE EXCEPTION E'Falta correr database/25_venta_directa.sql antes de esta prueba.\n'
            'Todavía no existe el tipo de pedido «mostrador».'
            USING ERRCODE = 'undefined_object';
    END IF;
END;
$falta$;

CREATE FUNCTION pg_temp.esperar_error(p_sql TEXT, p_contiene TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM ILIKE '%' || p_contiene || '%' THEN
            RAISE NOTICE '      ✔ bloqueado: %', SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'Falló con otro error: «%» (se esperaba «%»)', SQLERRM, p_contiene;
    END;
    RAISE EXCEPTION 'DEBIÓ FALLAR Y NO FALLÓ: %', p_sql;
END;
$$;

DO $$
DECLARE
    v_emp    INTEGER;  v_uni   INTEGER;  v_cat  INTEGER;
    v_caja   INTEGER;  v_coc   INTEGER;  v_mesero INTEGER;
    v_bebida INTEGER;  v_plato INTEGER;  v_menu BIGINT;  v_pd BIGINT;
    v_mesa   INTEGER;
    v_ped    BIGINT;   v_cod   VARCHAR;
    v_r      RECORD;   v_n     INTEGER;  v_hoy DATE;
BEGIN
    /* ---------- Un negocio de prueba, con su barra y su cocina ---------- */
    INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_mostrador', 'Mostrador') RETURNING id INTO v_emp;
    INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo) SELECT v_emp, id, TRUE FROM core.modulos;
    INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos) VALUES (v_emp, 'pedido', 0, 5);
    INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo)
    SELECT v_emp, id, codigo IN ('efectivo', 'datafono') FROM core.metodos_pago;

    INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
    VALUES (v_emp, (SELECT id FROM core.tipos_negocio ORDER BY id LIMIT 1), 'Mostrador · Sede', 'Mostrador')
    RETURNING id INTO v_uni;
    INSERT INTO core.mesas (unidad_id, numero) VALUES (v_uni, '1') RETURNING id INTO v_mesa;

    INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_emp, 'Barra') RETURNING id INTO v_cat;
    -- Una gaseosa: se entrega en el acto
    INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio, requiere_preparacion)
    VALUES (v_emp, v_cat, 'MOS-1', 'Gaseosa', 4000, FALSE) RETURNING id INTO v_bebida;
    -- Una hamburguesa: pasa por cocina
    INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio, requiere_preparacion)
    VALUES (v_emp, v_cat, 'MOS-2', 'Hamburguesa', 18000, TRUE) RETURNING id INTO v_plato;
    INSERT INTO core.producto_unidades (producto_id, unidad_id) VALUES (v_bebida, v_uni), (v_plato, v_uni);

    -- Caja puede cobrar; cocina no
    INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
    VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'caja'), 'Caja', 'mos.caja', core.fn_hash_pin('1111'))
    RETURNING id INTO v_caja;
    INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
    VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'cocinero'), 'Cocina', 'mos.cocina', core.fn_hash_pin('2222'))
    RETURNING id INTO v_coc;
    INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
    VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'mesero'), 'Mesero', 'mos.mesero', core.fn_hash_pin('3333'))
    RETURNING id INTO v_mesero;
    INSERT INTO core.usuario_unidades (usuario_id, unidad_id)
    VALUES (v_caja, v_uni), (v_coc, v_uni), (v_mesero, v_uni);

    v_hoy := core.fn_fecha_operativa(v_emp, now());

    -- 1 · SÓLO BARRA: NACE ENTREGADA Y COBRADA -----------------------------------------
    CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mostrador', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_bebida, 'cantidad', 2)),
         p_usuario_id => v_caja, p_pedido_id => v_ped, p_codigo => v_cod);

    SELECT estado, estado_pago, metodo_pago, total, mesa, zona, costo_domicilio
      INTO v_r FROM api.v_pedidos WHERE pedido_id = v_ped;
    ASSERT v_r.estado = 'entregado', format('Debía nacer entregada (salió %s)', v_r.estado);
    ASSERT v_r.estado_pago = 'confirmado', format('Y cobrada (salió %s)', v_r.estado_pago);
    ASSERT v_r.total = 8000, format('2 gaseosas = 8000 (salió %s)', v_r.total);
    RAISE NOTICE '✔ 1  Venta de barra %: nace entregada y cobrada, sin pasar por cocina', v_cod;

    -- 2 · NO TIENE MESA, NI ZONA, NI DOMICILIO -----------------------------------------
    ASSERT v_r.mesa IS NULL AND v_r.zona IS NULL AND v_r.costo_domicilio = 0,
           'Una venta directa no tiene mesa, ni zona, ni domicilio';
    RAISE NOTICE '✔ 2  No arrastra mesa, zona ni costo de domicilio';

    -- 3 · EL COBRO QUEDA CON SU MÉTODO, SU FIRMA Y EN EL HISTORIAL ----------------------
    ASSERT v_r.metodo_pago = 'efectivo', format('Método (salió %s)', v_r.metodo_pago);
    SELECT count(*) INTO v_n FROM core.pedido_historial h
     WHERE h.pedido_id = v_ped AND h.usuario_id = v_caja AND h.descripcion ILIKE '%pago%';
    ASSERT v_n >= 1, 'El cobro tiene que quedar en el historial, firmado por quien cobró';
    RAISE NOTICE '✔ 3  El cobro queda con su método, quién lo hizo y en el historial';

    -- 4 · CON ALGO QUE PREPARAR, ENTRA AL FLUJO ----------------------------------------
    CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mostrador', p_metodo_pago => 'datafono',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_bebida, 'cantidad', 1),
                                      jsonb_build_object('producto_id', v_plato, 'cantidad', 1)),
         p_usuario_id => v_caja, p_pedido_id => v_ped, p_codigo => v_cod);

    SELECT estado, estado_pago, metodo_pago INTO v_r FROM api.v_pedidos WHERE pedido_id = v_ped;
    ASSERT v_r.estado = 'nuevo', format('Con cocina de por medio queda en nuevo (salió %s)', v_r.estado);
    ASSERT v_r.estado_pago = 'confirmado' AND v_r.metodo_pago = 'datafono',
           'Pero ya pagada, y con el método que eligió la caja';
    RAISE NOTICE '✔ 4  Venta % con algo que preparar: va a cocina, pero ya cobrada por datáfono', v_cod;

    -- 5 · UN PLATO DEL DÍA SIEMPRE SE PREPARA ------------------------------------------
    INSERT INTO core.menus_dia (unidad_id, tipo_menu_id, fecha, creado_por_id)
    VALUES (v_uni, (SELECT id FROM core.tipos_menu WHERE codigo = 'chef'), v_hoy, v_caja)
    RETURNING id INTO v_menu;
    INSERT INTO core.platos_dia (menu_dia_id, nombre, precio)
    VALUES (v_menu, 'Bandeja del día', 20000) RETURNING id INTO v_pd;

    CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mostrador', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('plato_dia_id', v_pd, 'cantidad', 1)),
         p_usuario_id => v_caja, p_pedido_id => v_ped, p_codigo => v_cod);
    SELECT estado INTO v_r FROM api.v_pedidos WHERE pedido_id = v_ped;
    ASSERT v_r.estado = 'nuevo', format('El plato del día se prepara siempre (salió %s)', v_r.estado);
    RAISE NOTICE '✔ 5  Un plato del día siempre pasa por cocina, aunque nada más lo necesite';

    -- 6 · SIN SESIÓN NO HAY VENTA DIRECTA ----------------------------------------------
    PERFORM pg_temp.esperar_error(
        format($q$CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => 'mostrador', p_metodo_pago => 'efectivo',
               p_items => '[{"producto_id": %s, "cantidad": 1}]'::JSONB)$q$, v_uni, v_bebida),
        'quien está en caja');
    RAISE NOTICE '✔ 6  Sin sesión no se registra una venta directa: la hace quien está en caja';

    -- 7 · SIN EL PERMISO DE PAGOS TAMPOCO ----------------------------------------------
    PERFORM pg_temp.esperar_error(
        format($q$CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => 'mostrador', p_metodo_pago => 'efectivo',
               p_items => '[{"producto_id": %s, "cantidad": 1}]'::JSONB, p_usuario_id => %s)$q$,
               v_uni, v_bebida, v_coc),
        'permiso');
    RAISE NOTICE '✔ 7  Quien no cobra no vende: cocina no puede registrar una venta directa';

    -- 8 · EL MÉTODO TIENE QUE ESTAR HABILITADO -----------------------------------------
    PERFORM pg_temp.esperar_error(
        format($q$CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => 'mostrador', p_metodo_pago => 'transferencia',
               p_items => '[{"producto_id": %s, "cantidad": 1}]'::JSONB, p_usuario_id => %s)$q$,
               v_uni, v_bebida, v_caja),
        'no está disponible');
    RAISE NOTICE '✔ 8  Sigue sin poder cobrarse con un método que la empresa no tiene habilitado';

    -- 9 · LO DE SIEMPRE NO CAMBIA ------------------------------------------------------
    CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_bebida, 'cantidad', 1)),
         p_usuario_id => v_mesero, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
    SELECT estado, estado_pago INTO v_r FROM api.v_pedidos WHERE pedido_id = v_ped;
    ASSERT v_r.estado = 'nuevo' AND v_r.estado_pago = 'pendiente',
           format('Un pedido de mesa sigue naciendo nuevo y sin pagar (salió %s / %s)', v_r.estado, v_r.estado_pago);
    RAISE NOTICE '✔ 9  Un pedido de mesa sigue naciendo nuevo y sin pagar: nada de lo viejo cambió';
END;
$$;

ROLLBACK;
