/* ============================================================================
   TASECA · 35 · AVANZAR UN PEDIDO DESDE DONDE SE ESTÁ VIENDO
   ----------------------------------------------------------------------------
   EL SÍNTOMA

     Doble clic en «A preparación» y el pedido se va a «Listo», saltándose
     un estado. La cocina nunca lo ve. Medido en producción:

       nuevo → preparacion → listo   (con dos clics seguidos)

   POR QUÉ NO BASTABA EL ARREGLO DEL NAVEGADOR

     El panel ya deshabilita el botón mientras trabaja, y no sirve: el
     tablero se repinta entre un clic y el siguiente, así que el segundo
     cae sobre un botón NUEVO, que no está deshabilitado.

     Se le puso un candado a js/store.js y tampoco alcanzó: js/remoto.js
     REEMPLAZA los métodos del store cuando se trabaja contra la base
     (S[k] = operaciones[k]), así que en la nube ese candado no existía.

     Y aunque existiera, no cubriría lo de verdad peligroso: el mesero y la
     cocina tocando el mismo pedido desde dos pantallas. Eso sólo se
     resuelve donde hay una única verdad, que es aquí.

   EL ARREGLO, EN DOS CAPAS

     1. El paso se vuelve ATÓMICO. El UPDATE comprueba en su propio WHERE
        que el pedido siga en el estado desde el que se calculó el
        siguiente. Dos llamadas a la vez: una gana, la otra no encuentra
        fila y avisa. Protege aunque nadie mande nada nuevo.

     2. Se puede decir DESDE DÓNDE se avanza (`p_desde`). Es lo que para el
        doble clic: el segundo sigue diciendo «vengo de nuevo», pero el
        pedido ya está en preparación, y se rechaza con un mensaje claro.

   OJO CON LAS SOBRECARGAS

     Al procedimiento se le añade un parámetro, así que hay que BORRAR el
     de dos argumentos antes de crear el de tres. Si se dejaran los dos,
     PostgreSQL preferiría el de aridad exacta al llamarlo con dos, y
     rest.avanzar_estado seguiría usando la versión SIN arreglar.

     A rest.avanzar_estado, en cambio, no se le toca nada: se añade otra
     función de dos argumentos SIN valor por defecto, y así no hay
     ambigüedad al llamar con uno solo.

   LA PRUEBA DE VERDAD VA APARTE

     En 35_pruebas_avanzar.sql. Tiene que deshacerse con ROLLBACK, y si
     estuviera en este archivo -que el editor de Supabase corre entero en
     una transacción- se desharían también las funciones de arriba.

   Se puede ejecutar más de una vez.
   Requiere: 00 … 34 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. EL PROCEDIMIENTO: ATÓMICO, Y CON «DESDE DÓNDE» OPCIONAL
   ============================================================================ */
DROP PROCEDURE IF EXISTS api.sp_avanzar_estado_pedido(BIGINT, INTEGER);

CREATE OR REPLACE PROCEDURE api.sp_avanzar_estado_pedido(
    IN p_pedido_id BIGINT,
    IN p_usuario_id INTEGER,
    IN p_desde VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $pr$
DECLARE
    v_actual    INTEGER;
    v_cod_act   VARCHAR;
    v_siguiente INTEGER;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, NULL,
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    PERFORM core.fn_exigir_alguno(p_usuario_id,
            ARRAY['pedidos_gestionar', 'pedidos_cocina', 'pedidos_listos', 'pedidos_domicilio']);

    SELECT p.estado_pedido_id, e.codigo
      INTO v_actual, v_cod_act
      FROM core.pedidos p
      JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
     WHERE p.id = p_pedido_id;

    IF v_actual IS NULL THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;

    /* ¿Sigue donde quien pulsó lo estaba viendo? Si no, alguien se
       adelantó: otra pantalla, o su propio segundo clic. */
    IF p_desde IS NOT NULL AND v_cod_act <> p_desde THEN
        RAISE EXCEPTION 'Ese pedido ya está en «%». Alguien se te adelantó.',
            (SELECT e.nombre FROM core.estados_pedido e WHERE e.id = v_actual);
    END IF;

    v_siguiente := core.fn_siguiente_estado(p_pedido_id);
    IF v_siguiente IS NULL THEN
        RAISE EXCEPTION 'El pedido % ya no tiene un estado siguiente.', p_pedido_id;
    END IF;

    /* El estado actual va en el WHERE: eso es lo que hace atómico el paso.
       Si entre el SELECT de arriba y este UPDATE alguien movió el pedido,
       aquí no hay fila que actualizar y se avisa en vez de pisarlo. */
    UPDATE core.pedidos
       SET estado_pedido_id = v_siguiente
     WHERE id = p_pedido_id
       AND estado_pedido_id = v_actual;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese pedido lo movió alguien más mientras lo actualizabas. Vuelve a intentarlo.';
    END IF;
END;
$pr$;


/* ============================================================================
   2. LA PUERTA DE LA APLICACIÓN
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.avanzar_estado(p_pedido_id BIGINT, p_desde TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $fn$
BEGIN
    CALL api.sp_avanzar_estado_pedido(p_pedido_id, core.fn_exigir_sesion(),
                                      NULLIF(trim(p_desde), ''));
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$fn$;

GRANT EXECUTE ON FUNCTION rest.avanzar_estado(BIGINT, TEXT) TO taseca_app;

COMMENT ON FUNCTION rest.avanzar_estado(BIGINT, TEXT) IS
    'Avanza un pedido al siguiente estado, pero sólo si sigue en p_desde. Contra el doble clic y contra dos pantallas a la vez.';


/* ============================================================================
   3. REVISIÓN

   Sólo de forma: que las firmas quedaran como se espera y que no haya
   sobrecargas sueltas. El comportamiento se prueba en
   35_pruebas_avanzar.sql, que se deshace con ROLLBACK.
   ============================================================================ */
DO $blk$
DECLARE
    v_proc  INTEGER;
    v_viejo INTEGER;
    v_rest  INTEGER;
BEGIN
    SELECT count(*) INTO v_proc
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'sp_avanzar_estado_pedido' AND p.pronargs = 3;

    SELECT count(*) INTO v_viejo
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'sp_avanzar_estado_pedido' AND p.pronargs = 2;

    SELECT count(*) INTO v_rest
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rest' AND p.proname = 'avanzar_estado';

    IF v_proc <> 1 THEN
        RAISE EXCEPTION 'api.sp_avanzar_estado_pedido de 3 argumentos: hay %.', v_proc;
    END IF;

    IF v_viejo <> 0 THEN
        RAISE EXCEPTION 'Sigue existiendo el de 2 argumentos: las llamadas antiguas usarían la versión sin arreglar.';
    END IF;

    IF v_rest <> 2 THEN
        RAISE EXCEPTION 'rest.avanzar_estado debería tener 2 variantes (1 y 2 argumentos); hay %.', v_rest;
    END IF;

    IF position('AND estado_pedido_id = v_actual' IN
                (SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'api' AND p.proname = 'sp_avanzar_estado_pedido')) = 0 THEN
        RAISE EXCEPTION 'El UPDATE no quedó atómico.';
    END IF;

    RAISE NOTICE 'OK · procedimiento atómico y con p_desde; rest.avanzar_estado con sus dos variantes.';
    RAISE NOTICE '  Ahora corre 35_pruebas_avanzar.sql para probar el comportamiento.';
END;
$blk$;
