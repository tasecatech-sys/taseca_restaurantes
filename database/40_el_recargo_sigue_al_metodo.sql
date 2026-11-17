/* ============================================================================
   40 · EL RECARGO SIGUE AL MÉTODO

   QUÉ ESTÁ MAL
   ------------
   Caja puede cambiar el método al confirmar el cobro: el pedido entró como
   Nequi y el cliente terminó pagando en efectivo. api.sp_actualizar_pago
   cambiaba `metodo_pago_id` y ahí se quedaba.

   Pero el recargo del método es una COLUMNA congelada en el pedido
   (core.pedidos.recargo_pago, migración 30), y el total de api.v_pedidos es
   subtotal + costo_domicilio + recargo_pago. Así que el pedido quedaba
   diciendo «pagado en efectivo» con los $500 de Nequi dentro del total.

   Pasa en las dos direcciones, y las dos cuestan dinero:

     Nequi  → efectivo : al cliente se le cobran $500 que no debe.
     efectivo → Nequi  : el negocio paga los $500 de su bolsillo.

   El cambio de método SÍ queda anotado -lo hace el trigger
   core.tg_pedidos_historial, que escribe «Método de pago: Nequi →
   Efectivo»-, pero lo que ese trigger no puede decir es que con el método
   se movió el total. Esa línea falta.

   QUÉ SE HACE
   -----------
   Cuando -y sólo cuando- el método cambia de verdad, se recalcula
   recargo_pago con core.fn_recargo_pago sobre la misma base que usa quien
   crea el pedido (subtotal + domicilio), y se anota en el historial el
   recargo que se quitó o se puso. El cambio de método lo sigue anotando el
   trigger de siempre; aquí NO se repite.

   POR QUÉ NO HAY QUE TOCAR NADA MÁS
   ---------------------------------
   Ningún sitio guarda el total: api.v_pedidos lo calcula, y los informes,
   los cierres y la caja leen de ahí. Al mover recargo_pago se mueve el
   total en todas partes a la vez. Tampoco hay que cambiar la vista, ni la
   firma del procedimiento, ni rest.confirmar_pago, ni el cliente para
   leerlo.

   SOBRE LA CONFIGURACIÓN DE AYER
   ------------------------------
   El recargo nuevo se calcula con la configuración de HOY. Es lo correcto:
   lo que se congeló al crear el pedido era el precio del método ANTERIOR, y
   ese método ya no es el que se está cobrando. El recargo del método viejo
   se pierde a propósito; queda escrito en el historial.

   Idempotente: se puede ejecutar dos veces.
   ============================================================================ */

/* ----------------------------------------------------------------------------
   0. ANTES DE TOCAR NADA

   Si el procedimiento no está donde se espera, mejor parar aquí que dejar
   la base a medias.
   ---------------------------------------------------------------------------- */
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'api' AND p.proname = 'sp_actualizar_pago'
           /* prokind 'p' = procedimiento, y sus cinco parámetros. En un
              PROCEDURE, pg_get_function_identity_arguments trae además el
              modo («IN p_pedido_id bigint»), así que comparar esa cadena
              contra la firma escrita a mano falla siempre. */
           AND p.prokind = 'p' AND p.pronargs = 5
    ) THEN
        RAISE EXCEPTION 'Falta api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR, VARCHAR). Ejecuta antes database/16_pagos_en_caja.sql.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'core' AND p.proname = 'fn_recargo_pago'
    ) THEN
        RAISE EXCEPTION 'Falta core.fn_recargo_pago. Ejecuta antes database/30_recargo_por_metodo.sql y database/33_recargo_cero_no_es_nulo.sql.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'core' AND table_name = 'pedidos' AND column_name = 'recargo_pago'
    ) THEN
        RAISE EXCEPTION 'Falta core.pedidos.recargo_pago. Ejecuta antes database/30_recargo_por_metodo.sql.';
    END IF;
END $$;


/* ----------------------------------------------------------------------------
   1. EL PROCEDIMIENTO

   Misma firma que el de 16_pagos_en_caja.sql -no se añade ningún parámetro,
   así que no hay sobrecarga que limpiar- y mismas validaciones, en el mismo
   orden. Lo único nuevo es el bloque del recargo y las dos líneas de
   historial.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE api.sp_actualizar_pago(
    p_pedido_id    BIGINT,
    p_estado_pago  VARCHAR,
    p_usuario_id   INTEGER,
    p_nota         VARCHAR DEFAULT NULL,
    p_metodo_pago  VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa        INTEGER;
    v_estado         VARCHAR;
    v_pago           VARCHAR;
    v_codigo         VARCHAR;
    v_metodo         INTEGER;
    v_metodo_antes   INTEGER;
    v_recargo_antes  NUMERIC;
    v_recargo        NUMERIC;
    v_base           NUMERIC;
BEGIN
    SELECT p.empresa_id, e.codigo, ep.codigo, p.codigo, p.metodo_pago_id, p.recargo_pago
      INTO v_empresa, v_estado, v_pago, v_codigo, v_metodo, v_recargo_antes
      FROM core.pedidos p
      JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
      JOIN core.estados_pago ep  ON ep.id = p.estado_pago_id
     WHERE p.id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;

    /* Con qué método entró. Hay que guardarlo antes de que v_metodo se
       pise con el nuevo, unas líneas más abajo. */
    v_metodo_antes  := v_metodo;
    v_recargo       := v_recargo_antes;

    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pagos',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));

    IF p_estado_pago NOT IN ('confirmado', 'rechazado') THEN
        RAISE EXCEPTION 'Caja sólo confirma o rechaza pagos.';
    END IF;
    IF v_estado IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'La factura % está %: no hay pago que registrar.', v_codigo, v_estado;
    END IF;
    IF v_pago = 'confirmado' THEN
        RAISE EXCEPTION 'El pago de la factura % ya fue confirmado.', v_codigo;
    END IF;

    IF NULLIF(trim(p_metodo_pago), '') IS NOT NULL THEN
        IF p_estado_pago <> 'confirmado' THEN
            RAISE EXCEPTION 'El método de pago se registra al confirmar el cobro.';
        END IF;
        v_metodo := core.fn_id_catalogo('metodos_pago', trim(p_metodo_pago));
        IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago
                        WHERE empresa_id = v_empresa AND metodo_pago_id = v_metodo AND activo) THEN
            RAISE EXCEPTION 'El método de pago "%" no está disponible.', p_metodo_pago;
        END IF;
    END IF;

    /* ------------------------------------------------------------------
       EL RECARGO SIGUE AL MÉTODO

       Sólo si el método cambió de verdad. Pedir el mismo que ya tenía no
       toca el recargo: reconfirmar no puede mover una factura.

       La base es la misma que usa quien crea el pedido (migración 30):
       subtotal de los ítems + domicilio. El recargo NO se recarga a sí
       mismo.
       ------------------------------------------------------------------ */
    IF v_metodo IS DISTINCT FROM v_metodo_antes THEN
        SELECT COALESCE((SELECT SUM(i.precio_unitario * i.cantidad)
                           FROM core.pedido_items i WHERE i.pedido_id = p.id), 0)
               + p.costo_domicilio
          INTO v_base
          FROM core.pedidos p
         WHERE p.id = p_pedido_id;

        v_recargo := core.fn_recargo_pago(v_empresa, v_metodo, v_base);

    END IF;

    UPDATE core.pedidos
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago),
           metodo_pago_id = v_metodo,
           recargo_pago   = v_recargo
     WHERE id = p_pedido_id;

    UPDATE core.comprobantes_pago
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago),
           revisado_por_id = p_usuario_id, revisado_en = now()
     WHERE pedido_id = p_pedido_id AND revisado_en IS NULL;

    /* ------------------------------------------------------------------
       CONSTANCIA

       Que el método cambió ya lo escribe el trigger core.tg_pedidos_historial
       («Método de pago: Nequi → Efectivo»), así que aquí NO se repite. Lo
       que ese trigger no sabe decir es que con el método se movió el TOTAL
       de la factura, y eso no puede pasar en silencio.

       Sólo si el recargo cambió de valor: pasar de un método sin recargo a
       otro sin recargo no mueve nada y no merece una línea.
       ------------------------------------------------------------------ */
    IF v_recargo IS DISTINCT FROM v_recargo_antes THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        VALUES (p_pedido_id,
                format('Recargo del pago: %s → %s · lo cobrado cambia en %s',
                       round(COALESCE(v_recargo_antes, 0)),
                       round(COALESCE(v_recargo, 0)),
                       round(COALESCE(v_recargo, 0) - COALESCE(v_recargo_antes, 0))),
                p_usuario_id);
    END IF;

    IF NULLIF(trim(p_nota), '') IS NOT NULL THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        VALUES (p_pedido_id,
                CASE WHEN p_estado_pago = 'confirmado' THEN 'Referencia del pago: ' ELSE 'Motivo: ' END || trim(p_nota),
                p_usuario_id);
    END IF;
END;
$$;

COMMENT ON PROCEDURE api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR, VARCHAR) IS
    'Caja confirma o rechaza el pago. Si cambia el método, el recargo del pedido se recalcula con el del método nuevo y queda constancia en el historial.';


/* ----------------------------------------------------------------------------
   2. PERMISOS

   CREATE OR REPLACE los conserva, pero se repiten por si esta migración se
   ejecuta sobre una base donde el procedimiento se recreó a mano.
   ---------------------------------------------------------------------------- */
REVOKE ALL ON PROCEDURE api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR, VARCHAR) TO taseca_app;


/* ----------------------------------------------------------------------------
   3. QUE QUEDÓ COMO SE QUERÍA

   No prueba el comportamiento -eso va en 40_pruebas_recargo.sql, aparte,
   porque el editor de Supabase ejecuta todo el archivo en UNA transacción y
   una prueba que se deshaga a sí misma se llevaría por delante lo de
   arriba-. Aquí sólo se comprueba que el texto instalado es el nuevo.
   ---------------------------------------------------------------------------- */
DO $$
DECLARE
    v_def TEXT;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'sp_actualizar_pago';

    IF v_def NOT LIKE '%fn_recargo_pago%' THEN
        RAISE EXCEPTION 'sp_actualizar_pago no quedó con el recalculo del recargo.';
    END IF;
    IF v_def NOT LIKE '%recargo_pago   = v_recargo%' THEN
        RAISE EXCEPTION 'sp_actualizar_pago no escribe recargo_pago.';
    END IF;
    IF v_def NOT LIKE '%Recargo del pago: %' THEN
        RAISE EXCEPTION 'sp_actualizar_pago no deja constancia de que el total se movió.';
    END IF;

    /* Que no se haya colado una sobrecarga: con dos, Postgres elegiría la
       de firma exacta y esta migración no serviría de nada. */
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'api' AND p.proname = 'sp_actualizar_pago') <> 1 THEN
        RAISE EXCEPTION 'Hay más de un api.sp_actualizar_pago: sobra una sobrecarga.';
    END IF;

    RAISE NOTICE 'OK · el recargo ahora sigue al método de pago.';
END $$;

NOTIFY pgrst, 'reload schema';
