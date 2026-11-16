/* ============================================================================
   TASECA · 37 · PRUEBAS DEL COBRO EN LOTE  (se deshacen con ROLLBACK)
   ----------------------------------------------------------------------------
   Va aparte de 37_cobrar_en_lote.sql a propósito: estas pruebas cobran
   pedidos de verdad y terminan deshaciéndose. Si estuvieran en la misma
   transacción que la función, al deshacerse se la llevarían por delante.

   CÓMO CORRERLO

     Editor SQL de Supabase: pega y RUN. Al final sale un error a propósito
     -«PRUEBAS SUPERADAS»- y no queda nada escrito. Cualquier OTRO error
     significa que algo falló de verdad.

   Requiere: la 37 aplicada.
   ============================================================================ */

BEGIN;

DO $blk$
DECLARE
    v_uni    INT;
    v_prod   INT;
    v_emp    INT;
    v_ids    BIGINT[] := '{}';
    v_id     BIGINT;
    v_cod    VARCHAR;
    v_r      JSONB;
    v_cancel BIGINT;
    v_usuario INT;
    i        INT;
BEGIN
    /* --- Terreno: una unidad con un producto que se le venda ---------- */
    SELECT pu.unidad_id, pu.producto_id, u.empresa_id
      INTO v_uni, v_prod, v_emp
      FROM core.producto_unidades pu
      JOIN core.productos pr ON pr.id = pu.producto_id
      JOIN core.unidades u   ON u.id  = pu.unidad_id
     WHERE pr.precio > 0 AND pr.activo
     ORDER BY pu.unidad_id, pu.producto_id
     LIMIT 1;

    IF v_uni IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna unidad con productos: no se puede probar.';
    END IF;

    /* --- Una sesión, porque confirmar_pagos la exige -----------------
       En la aplicación el token lo pone PostgREST; aquí se pone a mano
       el mismo ajuste que él escribe, con un usuario real de la empresa
       de esa unidad. Si esto no estuviera, la prueba fallaría con
       «Tienes que iniciar sesión», que es justo lo que la función tiene
       que exigir. */
    SELECT us.id INTO v_usuario
      FROM core.usuarios us
     WHERE us.empresa_id = v_emp AND us.activo
     ORDER BY us.id
     LIMIT 1;

    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'La empresa % no tiene usuarios activos.', v_emp;
    END IF;

    PERFORM set_config('request.jwt.claims',
                       jsonb_build_object('usuario_id', v_usuario,
                                          'empresa_id', v_emp)::TEXT,
                       TRUE);

    /* --- Cinco pedidos nuevos, con métodos DISTINTOS ------------------ */
    FOR i IN 1 .. 5 LOOP
        CALL api.sp_crear_pedido(
            p_unidad_id      => v_uni,
            p_tipo           => 'domicilio',
            p_metodo_pago    => CASE WHEN i % 2 = 0 THEN 'nequi' ELSE 'efectivo' END,
            p_items          => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)),
            p_cliente_nombre => 'Lote ' || i,
            p_cliente_telefono => '30011122' || lpad(i::TEXT, 2, '0'),
            p_direccion      => 'Cra 1 # 1-' || i,
            p_clave          => 'lote-prueba-' || i,
            p_pedido_id      => v_id,
            p_codigo         => v_cod);
        v_ids := v_ids || v_id;
    END LOOP;

    /* --- 1 · Cobrar los cinco de un viaje ----------------------------- */
    v_r := rest.confirmar_pagos(v_ids, 'LOTE-PRUEBA');

    IF (v_r ->> 'cobrados')::INT <> 5 THEN
        RAISE EXCEPTION '1 · Se cobraron % de 5. Fallidos: %', v_r ->> 'cobrados', v_r -> 'mal';
    END IF;
    RAISE NOTICE '1 · OK  los cinco cobrados en una sola llamada';

    /* --- 2 · Cada uno conservó SU método ------------------------------ */
    IF EXISTS (
        SELECT 1 FROM core.pedidos p
          JOIN core.metodos_pago m ON m.id = p.metodo_pago_id
         WHERE p.id = ANY(v_ids)
           AND m.codigo <> CASE WHEN array_position(v_ids, p.id) % 2 = 0 THEN 'nequi' ELSE 'efectivo' END
    ) THEN
        RAISE EXCEPTION '2 · Algún pedido cambió de método de pago al cobrarse en lote.';
    END IF;
    RAISE NOTICE '2 · OK  cada pedido conservó su método (efectivo y nequi mezclados)';

    /* --- 3 · Quedaron confirmados de verdad --------------------------- */
    IF EXISTS (
        SELECT 1 FROM core.pedidos p
          JOIN core.estados_pago ep ON ep.id = p.estado_pago_id
         WHERE p.id = ANY(v_ids) AND ep.codigo <> 'confirmado'
    ) THEN
        RAISE EXCEPTION '3 · Alguno no quedó confirmado.';
    END IF;
    RAISE NOTICE '3 · OK  los cinco quedaron con el pago confirmado';

    /* --- 4 · Devuelve los pedidos ya actualizados --------------------- */
    IF jsonb_array_length(v_r -> 'pedidos') <> 5 THEN
        RAISE EXCEPTION '4 · Devolvió % pedidos y debían ser 5.', jsonb_array_length(v_r -> 'pedidos');
    END IF;
    RAISE NOTICE '4 · OK  devuelve los 5 pedidos, sin otro viaje para refrescar';

    /* --- 5 · Uno malo NO tumba a los demás ---------------------------- */
    CALL api.sp_crear_pedido(
        p_unidad_id => v_uni, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
        p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)),
        p_cliente_nombre => 'Para cancelar', p_cliente_telefono => '3001112299',
        p_direccion => 'Cra 9 # 9-99', p_clave => 'lote-cancelado',
        p_pedido_id => v_cancel, p_codigo => v_cod);

    CALL api.sp_crear_pedido(
        p_unidad_id => v_uni, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
        p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)),
        p_cliente_nombre => 'Este si se cobra', p_cliente_telefono => '3001112288',
        p_direccion => 'Cra 8 # 8-88', p_clave => 'lote-bueno',
        p_pedido_id => v_id, p_codigo => v_cod);

    /* Por la puerta de siempre, no con un UPDATE crudo: la base exige el
       motivo con un trigger, y saltárselo aquí haría que la prueba
       montara un estado que la aplicación no puede producir. */
    CALL api.sp_cancelar_pedido(v_cancel, 'Prueba del cobro en lote', v_usuario);

    v_r := rest.confirmar_pagos(ARRAY[v_cancel, v_id], 'LOTE-MIXTO');

    IF (v_r ->> 'cobrados')::INT <> 1 OR (v_r ->> 'fallidos')::INT <> 1 THEN
        RAISE EXCEPTION '5 · Esperaba 1 cobrado y 1 fallido; salieron % y %.',
            v_r ->> 'cobrados', v_r ->> 'fallidos';
    END IF;
    RAISE NOTICE '5 · OK  el cancelado falla solo y el bueno se cobra';
    RAISE NOTICE '      motivo del fallido: %', v_r -> 'mal' -> 0 ->> 'motivo';

    /* --- 6 · Una lista vacía se rechaza ------------------------------- */
    BEGIN
        v_r := rest.confirmar_pagos(ARRAY[]::BIGINT[], NULL);
        RAISE EXCEPTION '6 · Una lista vacía debería rechazarse y pasó.';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%6 ·%' THEN RAISE; END IF;
    END;
    RAISE NOTICE '6 · OK  una lista vacía se rechaza';

    RAISE NOTICE '-------------------------------------------------';
    RAISE EXCEPTION 'PRUEBAS SUPERADAS · el error es a propósito, no queda nada escrito.';
END;
$blk$;

ROLLBACK;
