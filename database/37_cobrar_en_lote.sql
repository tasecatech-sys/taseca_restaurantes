/* ============================================================================
   TASECA · 37 · COBRAR VARIOS PEDIDOS DE UNA VEZ
   ----------------------------------------------------------------------------
   EL PROBLEMA, MEDIDO

     Confirmar un pago tarda unos 460 ms desde el navegador. De esos:

         trabajo de la base .......... ~16 ms
         ida y vuelta por la red ..... ~445 ms

     O sea que el servidor no tiene la culpa: es el viaje. Y como la
     llamada va en XHR SÍNCRONO, el navegador se queda congelado todo ese
     rato -ni gira el indicador de espera-. Con veinte pedidos por cobrar
     son veinte congelones de medio segundo, uno detrás de otro: unos
     nueve segundos de caja sintiéndose colgada.

   EL ARREGLO

     Un solo viaje para todos. Veinte cobros pasan de ~9 s a ~0,5 s,
     porque lo que cuesta es el viaje y no el trabajo.

   TRES DECISIONES QUE IMPORTAN

     1. CADA PEDIDO CONSERVA SU MÉTODO. No se fuerza uno común: en la cola
        hay efectivo, Nequi y Daviplata mezclados, y machacarlos con un
        solo método falsearía la caja. Por eso se pasa NULL como método:
        sp_actualizar_pago entiende «déjalo como está».

     2. UNO MALO NO TUMBA A LOS DEMÁS. Si entre los veinte hay uno
        cancelado, se cobran los diecinueve y se devuelve por qué falló
        ese. Cada pedido va en su propio subbloque. Lo contrario -todo o
        nada- obligaría a la cajera a adivinar cuál era.

     3. SE DEVUELVEN LOS PEDIDOS YA ACTUALIZADOS. Así el panel se refresca
        con lo que vino en la misma respuesta y no hace OTRO viaje para
        enterarse de lo que acaba de hacer.

   NO ES UN ATAJO A LA REGLA DE CAJA

     Cada pedido sigue pasando por api.sp_actualizar_pago, que es la única
     puerta: comprueba el permiso, valida el método y deja registrado
     quién cobró y cuándo. Lo que cambia es cuántos viajes hace el
     navegador, no qué se comprueba.

   Se puede ejecutar más de una vez.
   Requiere: 00 … 36 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. LA FUNCIÓN
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.confirmar_pagos(
    p_pedidos    BIGINT[],
    p_referencia TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $fn$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_id      BIGINT;
    v_cod     VARCHAR;
    v_ok      JSONB := '[]'::JSONB;
    v_mal     JSONB := '[]'::JSONB;
    v_hechos  BIGINT[] := '{}';
BEGIN
    IF p_pedidos IS NULL OR COALESCE(array_length(p_pedidos, 1), 0) = 0 THEN
        RAISE EXCEPTION 'No llegó ningún pedido que cobrar.';
    END IF;

    /* Un tope para que un error de la pantalla no mande mil de golpe y
       deje la petición colgada medio minuto. */
    IF array_length(p_pedidos, 1) > 100 THEN
        RAISE EXCEPTION 'Son demasiados de una vez (%). El tope es 100.', array_length(p_pedidos, 1);
    END IF;

    FOREACH v_id IN ARRAY p_pedidos LOOP
        SELECT codigo INTO v_cod FROM core.pedidos WHERE id = v_id;
        BEGIN
            /* El método va en NULL: cada pedido se cobra con el suyo. */
            CALL api.sp_actualizar_pago(v_id, 'confirmado', v_usuario, p_referencia, NULL);
            v_hechos := v_hechos || v_id;
            v_ok := v_ok || jsonb_build_object('id', v_id, 'codigo', v_cod);
        EXCEPTION WHEN OTHERS THEN
            /* Este pedido no se pudo: se anota el porqué y se sigue con
               el resto. Su subbloque se deshace; los demás no. */
            v_mal := v_mal || jsonb_build_object('id',     v_id,
                                                 'codigo', COALESCE(v_cod, v_id::TEXT),
                                                 'motivo', SQLERRM);
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'cobrados', jsonb_array_length(v_ok),
        'fallidos', jsonb_array_length(v_mal),
        'ok',       v_ok,
        'mal',      v_mal,
        /* Los pedidos ya actualizados, para que el panel no tenga que
           volver a preguntar por ellos. */
        'pedidos',  COALESCE((SELECT jsonb_agg(core.fn_pedido_json(x))
                                FROM unnest(v_hechos) AS x), '[]'::JSONB)
    );
END;
$fn$;

GRANT EXECUTE ON FUNCTION rest.confirmar_pagos(BIGINT[], TEXT) TO taseca_app;

COMMENT ON FUNCTION rest.confirmar_pagos(BIGINT[], TEXT) IS
    'Confirma el pago de varios pedidos en un solo viaje. Cada uno conserva su método; uno que falle no tumba a los demás.';


/* ============================================================================
   2. REVISIÓN

   Sólo de forma. El comportamiento se prueba en 37_pruebas_cobro_lote.sql,
   que mueve pedidos de verdad y se deshace con ROLLBACK -y por eso va en
   otro archivo: el editor de Supabase corre todo en una transacción y al
   deshacerse se llevaría esta función por delante-.
   ============================================================================ */
DO $blk$
DECLARE
    v_def TEXT;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rest' AND p.proname = 'confirmar_pagos';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'rest.confirmar_pagos no quedó creada.';
    END IF;

    /* Que el método vaya en NULL es la decisión 1: si alguien lo cambia
       por un método fijo, la caja empezaría a mentir. */
    IF position('v_usuario, p_referencia, NULL' IN v_def) = 0 THEN
        RAISE EXCEPTION 'confirmar_pagos no está respetando el método de cada pedido.';
    END IF;

    IF NOT has_function_privilege('taseca_app', 'rest.confirmar_pagos(bigint[], text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'taseca_app no puede ejecutar rest.confirmar_pagos.';
    END IF;

    RAISE NOTICE 'OK · rest.confirmar_pagos lista. Ahora corre 37_pruebas_cobro_lote.sql.';
END;
$blk$;
