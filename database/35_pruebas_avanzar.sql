/* ============================================================================
   TASECA · 35 · PRUEBAS DEL CANDADO AL AVANZAR  (se deshacen con ROLLBACK)
   ----------------------------------------------------------------------------
   Va aparte de 35_avanzar_desde_donde_se_ve.sql a propósito: estas pruebas
   mueven pedidos de verdad y terminan deshaciéndose. Si estuvieran en la
   misma transacción que las funciones, al deshacerse se llevarían también
   las funciones por delante.

   CÓMO CORRERLO

     Editor SQL de Supabase: pega y RUN. Al final sale un error a propósito
     -«PRUEBAS SUPERADAS»- y no queda nada escrito. Cualquier OTRO error
     significa que algo falló de verdad.

   Requiere: la 35 aplicada.
   ============================================================================ */

BEGIN;

DO $blk$
DECLARE
    v_pedido  BIGINT;
    v_usuario INTEGER;
    v_estado  VARCHAR;
    v_fallo   TEXT;
BEGIN
    /* --- Un pedido recién nacido con el que jugar --------------------- */
    SELECT p.id INTO v_pedido
      FROM core.pedidos p
      JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
     WHERE e.codigo = 'nuevo'
     ORDER BY p.id DESC
     LIMIT 1;

    IF v_pedido IS NULL THEN
        RAISE EXCEPTION 'No hay ningún pedido en «nuevo» con el que probar. Crea uno y vuelve.';
    END IF;

    SELECT us.id INTO v_usuario
      FROM core.usuarios us
      JOIN core.pedidos p ON p.empresa_id = us.empresa_id
     WHERE p.id = v_pedido AND us.activo
     ORDER BY us.id
     LIMIT 1;

    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'La empresa de ese pedido no tiene usuarios activos.';
    END IF;

    /* --- 1 · El primer clic pasa -------------------------------------- */
    CALL api.sp_avanzar_estado_pedido(v_pedido, v_usuario, 'nuevo');

    SELECT e.codigo INTO v_estado
      FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
     WHERE p.id = v_pedido;

    IF v_estado <> 'preparacion' THEN
        RAISE EXCEPTION '1 · El primer clic dejó el pedido en «%» y debía dejarlo en preparación.', v_estado;
    END IF;
    RAISE NOTICE '1 · OK  el primer clic lleva el pedido a preparación';

    /* --- 2 · El segundo clic, con la pantalla vieja, se rechaza -------- */
    v_fallo := NULL;
    BEGIN
        CALL api.sp_avanzar_estado_pedido(v_pedido, v_usuario, 'nuevo');
    EXCEPTION WHEN OTHERS THEN
        v_fallo := SQLERRM;
    END;

    IF v_fallo IS NULL THEN
        RAISE EXCEPTION '2 · El segundo clic pasó: el candado NO funciona. Esto es el fallo del doble clic.';
    END IF;
    RAISE NOTICE '2 · OK  el segundo clic se rechaza: %', v_fallo;

    SELECT e.codigo INTO v_estado
      FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
     WHERE p.id = v_pedido;

    IF v_estado <> 'preparacion' THEN
        RAISE EXCEPTION '2 · El pedido se movió igual, hasta «%».', v_estado;
    END IF;
    RAISE NOTICE '2 · OK  y el pedido sigue en preparación, no saltó a listo';

    /* --- 3 · Sin decir desde dónde, sigue avanzando como siempre ------- */
    CALL api.sp_avanzar_estado_pedido(v_pedido, v_usuario);

    SELECT e.codigo INTO v_estado
      FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
     WHERE p.id = v_pedido;

    IF v_estado <> 'listo' THEN
        RAISE EXCEPTION '3 · Sin p_desde debería haber avanzado a listo, y quedó en «%».', v_estado;
    END IF;
    RAISE NOTICE '3 · OK  sin p_desde se comporta como siempre (compatibilidad)';

    /* --- 4 · Decir un estado que no es, se rechaza --------------------- */
    v_fallo := NULL;
    BEGIN
        CALL api.sp_avanzar_estado_pedido(v_pedido, v_usuario, 'nuevo');
    EXCEPTION WHEN OTHERS THEN
        v_fallo := SQLERRM;
    END;

    IF v_fallo IS NULL THEN
        RAISE EXCEPTION '4 · Avanzar diciendo un estado equivocado pasó igual.';
    END IF;
    RAISE NOTICE '4 · OK  avanzar desde un estado equivocado se rechaza';

    RAISE NOTICE '-------------------------------------------------';
    RAISE NOTICE 'Las cuatro pruebas pasaron. Ahora se deshace todo.';
    RAISE EXCEPTION 'PRUEBAS SUPERADAS · el error es a propósito, para no dejar nada escrito.';
END;
$blk$;

ROLLBACK;
