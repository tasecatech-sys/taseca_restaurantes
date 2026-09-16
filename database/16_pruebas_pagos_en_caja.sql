/* ============================================================================
   TASECA · 16 · PRUEBAS: TODOS LOS PAGOS SE CONFIRMAN EN CAJA
   ----------------------------------------------------------------------------
   Ejecutar después de 16_pagos_en_caja.sql. Todo corre como la aplicación
   (rol taseca_app con un token simulado) dentro de una transacción que
   termina en ROLLBACK: no deja ningún dato.

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

CREATE FUNCTION pg_temp.token(p_usuario TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_id INTEGER;
    v_empresa INTEGER;
BEGIN
    SELECT id, empresa_id INTO v_id, v_empresa FROM core.usuarios WHERE usuario = p_usuario;
    PERFORM set_config('request.jwt.claims',
                       jsonb_build_object('role', 'taseca_app', 'usuario_id', v_id, 'empresa_id', v_empresa)::TEXT, TRUE);
END;
$$;

CREATE FUNCTION pg_temp.app(p_sql TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v JSONB;
BEGIN
    SET LOCAL ROLE taseca_app;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
END;
$$;

DO $$
DECLARE
    v_ce INTEGER; v_hoy DATE; v_prod INTEGER;
    v_mesa BIGINT; v_domi BIGINT; v_canc BIGINT; v_rech BIGINT; v_i INTEGER;
    v_r JSONB; v_items JSONB;
BEGIN
    SELECT unidad_id INTO v_ce FROM api.v_unidades WHERE nombre = 'COMIC''ENDO AREPA';
    SELECT jornada_actual INTO v_hoy FROM api.v_empresas WHERE codigo = 'empresa_nascar';
    SELECT producto_id INTO v_prod FROM api.v_carta WHERE unidad_id = v_ce AND codigo = 'CE01';
    v_items := jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1));

    -- 1 · ENTREGAR NO COBRA ------------------------------------------------------------
    PERFORM pg_temp.token('admin');
    SELECT (r ->> 'pedido_id')::BIGINT INTO v_mesa FROM rest.crear_pedido(v_ce, 'mesa', 'efectivo', v_items, p_mesa => '4') r;
    FOR v_i IN 1..3 LOOP
        PERFORM pg_temp.app(format('SELECT rest.avanzar_estado(%s)', v_mesa));
    END LOOP;
    SELECT (r ->> 'pedido_id')::BIGINT INTO v_domi FROM rest.crear_pedido(v_ce, 'domicilio', 'efectivo', v_items,
        p_cliente_nombre => 'Cliente Caja', p_cliente_telefono => '3001234567', p_direccion => 'Calle 1 # 2-3') r;
    FOR v_i IN 1..4 LOOP
        PERFORM pg_temp.app(format('SELECT rest.avanzar_estado(%s)', v_domi));
    END LOOP;

    ASSERT (SELECT estado = 'entregado' AND estado_pago = 'pendiente' FROM api.v_pedidos WHERE pedido_id = v_mesa),
           'Mesa en efectivo entregada: el pago sigue pendiente';
    ASSERT (SELECT estado = 'entregado' AND estado_pago = 'pendiente' FROM api.v_pedidos WHERE pedido_id = v_domi),
           'Domicilio en efectivo entregado: el pago sigue pendiente';
    ASSERT (pg_temp.app(format($s$SELECT rest.informe_caja('%s', %s)$s$, v_hoy, v_ce)) -> 'ventas' -> 'efectivo' ->> 'pendiente')::NUMERIC > 0,
           'El cruce de caja lo muestra por cobrar, no cobrado';
    RAISE NOTICE '✔ 1  Entregar (mesa o domiciliario) no confirma el pago: queda pendiente para caja';

    -- 2 · CAJA CONFIRMA CON EL MÉTODO REAL --------------------------------------------
    v_r := pg_temp.app(format($s$SELECT rest.confirmar_pago(%s, 'Voucher 889', 'datafono')$s$, v_mesa));
    ASSERT v_r ->> 'estado_pago' = 'confirmado' AND v_r ->> 'metodo_pago' = 'datafono',
           format('Confirmado con datáfono (salió %s / %s)', v_r ->> 'estado_pago', v_r ->> 'metodo_pago');
    ASSERT EXISTS (SELECT 1 FROM core.pedido_historial WHERE pedido_id = v_mesa AND descripcion LIKE 'Método de pago:%'),
           'El cambio de método queda en el historial';
    ASSERT EXISTS (SELECT 1 FROM core.pedido_historial WHERE pedido_id = v_mesa AND descripcion LIKE '%Voucher 889%'),
           'La referencia queda en el historial';

    v_r := pg_temp.app(format($s$SELECT rest.confirmar_pago(%s)$s$, v_domi));
    ASSERT v_r ->> 'estado_pago' = 'confirmado' AND v_r ->> 'metodo_pago' = 'efectivo', 'Sin método: se conserva el del pedido';
    RAISE NOTICE '✔ 2  Caja confirma: registra el método real (datáfono) o conserva el del pedido; queda en el historial';

    -- 3 · UN PAGO CONFIRMADO NO CAMBIA -------------------------------------------------
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.confirmar_pago(%s, NULL, ''efectivo'')')$s$, v_mesa),
        'ya fue confirmado');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.rechazar_pago(%s, ''Error'')')$s$, v_mesa),
        'ya fue confirmado');
    PERFORM pg_temp.esperar_error(format(
        $s$UPDATE core.pedidos SET metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'efectivo') WHERE id = %s$s$, v_mesa),
        'no se puede cambiar');
    RAISE NOTICE '✔ 3  Un pago confirmado no se vuelve a confirmar, no se rechaza y no cambia de método';

    -- 4 · LO QUE NO SE COBRA ------------------------------------------------------------
    SELECT (r ->> 'pedido_id')::BIGINT INTO v_canc FROM rest.crear_pedido(v_ce, 'mesa', 'efectivo', v_items, p_mesa => '5') r;
    PERFORM pg_temp.app(format($s$SELECT rest.cancelar_pedido(%s, 'Cliente se fue')$s$, v_canc));
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.confirmar_pago(%s)')$s$, v_canc), 'no hay pago');

    SELECT (r ->> 'pedido_id')::BIGINT INTO v_rech FROM rest.crear_pedido(v_ce, 'mesa', 'efectivo', v_items, p_mesa => '6') r;
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.confirmar_pago(%s, NULL, ''bitcoin'')')$s$, v_rech),
        'bitcoin');
    v_r := pg_temp.app(format($s$SELECT rest.rechazar_pago(%s, 'No llegó la transferencia')$s$, v_rech));
    ASSERT v_r ->> 'estado_pago' = 'rechazado', 'Rechazado';
    v_r := pg_temp.app(format($s$SELECT rest.confirmar_pago(%s, 'Pagó después', 'transferencia')$s$, v_rech));
    ASSERT v_r ->> 'estado_pago' = 'confirmado' AND v_r ->> 'metodo_pago' = 'transferencia', 'Un rechazado se puede cobrar después';
    RAISE NOTICE '✔ 4  Cancelado no se cobra; método inexistente no; un pago rechazado sí se puede cobrar después';

    -- 5 · SEGURIDAD --------------------------------------------------------------------
    SELECT (r ->> 'pedido_id')::BIGINT INTO v_mesa FROM rest.crear_pedido(v_ce, 'mesa', 'efectivo', v_items, p_mesa => '7') r;
    FOR v_i IN 1..3 LOOP
        PERFORM pg_temp.app(format('SELECT rest.avanzar_estado(%s)', v_mesa));
    END LOOP;
    PERFORM pg_temp.token('mesero');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.confirmar_pago(%s)')$s$, v_mesa), 'permiso "pagos"');
    PERFORM pg_temp.esperar_error(format(
        $s$UPDATE core.pedidos SET metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'datafono') WHERE id = %s$s$, v_mesa),
        'sólo caja');
    ASSERT (SELECT estado_pago FROM api.v_pedidos WHERE pedido_id = v_mesa) = 'pendiente', 'Sigue pendiente';
    RAISE NOTICE '✔ 5  Seguridad: el mesero no confirma pagos; el método de un pedido entregado sólo lo fija caja al cobrar';
END;
$$;

SET LOCAL ROLE taseca_anon;
SELECT pg_temp.esperar_error($s$SELECT rest.confirmar_pago(1)$s$, 'permission denied');
RESET ROLE;

ROLLBACK;
