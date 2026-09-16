/* ============================================================================
   TASECA · 08 · PRUEBAS
   ----------------------------------------------------------------------------
   Recorre los flujos reales y comprueba que las reglas se cumplan.
   TODO ocurre dentro de una transacción que termina en ROLLBACK: se puede
   ejecutar las veces que quieras, no deja ningún dato.

   En DBeaver: ejecútalo con Alt+X y mira la pestaña «Salida» (Output):
   cada prueba escribe una línea ✔. Si alguna falla, el script se detiene
   con el mensaje de lo que no se cumplió.

   Parte 1 corre como taseca_app (lo que hará la aplicación).
   Parte 2 corre como dueño e intenta romper las reglas directo en las tablas.
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

GRANT EXECUTE ON FUNCTION pg_temp.esperar_error(TEXT, TEXT) TO taseca_app;

/* Los platos de ejemplo se sembraron con la fecha de la instalación. Si hoy
   los restaurantes no tienen menú, su último menú pasa a hoy SÓLO dentro de
   esta transacción (el ROLLBACK del final lo devuelve). Así las pruebas no
   dependen del día en que se ejecuten. */
UPDATE core.menus_dia m
   SET fecha = core.fn_fecha_operativa(u.empresa_id, now())
  FROM core.unidades u
 WHERE u.id = m.unidad_id
   AND u.nombre IN ('NASCAR-Comidas', 'Chicharrón Mental')
   AND m.id = (SELECT m2.id FROM core.menus_dia m2 WHERE m2.unidad_id = m.unidad_id ORDER BY m2.fecha DESC LIMIT 1)
   AND NOT EXISTS (SELECT 1 FROM core.menus_dia m3
                    WHERE m3.unidad_id = m.unidad_id AND m3.fecha = core.fn_fecha_operativa(u.empresa_id, now()));


/* ============================================================================
   PARTE 1 · COMO LA APLICACIÓN (rol taseca_app)
   ============================================================================ */
SET LOCAL ROLE taseca_app;

DO $$
DECLARE
    v_ce INTEGER; v_bar INTEGER; v_com INTEGER; v_chi INTEGER;
    v_admin INTEGER; v_mesero INTEGER; v_cocina INTEGER; v_caja INTEGER;
    p_chorizo INTEGER; p_gas15 INTEGER; p_cerveza INTEGER;
    v_ped1 BIGINT; v_cod1 VARCHAR; v_ped2 BIGINT; v_cod2 VARCHAR; v_ped3 BIGINT; v_cod3 VARCHAR;
    v_ped4 BIGINT; v_cod4 VARCHAR; v_ped5 BIGINT; v_cod5 VARCHAR;
    v_plato BIGINT; v_plato_cupo BIGINT; v_menu_chef BIGINT;
    v_menu BIGINT; c1 BIGINT; c2 BIGINT; c3 BIGINT;
    o1 BIGINT; o2 BIGINT; o3 BIGINT; o4 BIGINT; o5 BIGINT; o6 BIGINT;
    v_hoy DATE; v_insumo INTEGER; v_entrada BIGINT; v_cierre BIGINT;
    v_base BIGINT; v_gasto BIGINT; v_cat_gasto INTEGER; v_borradas INTEGER;
    v_esperado NUMERIC; r RECORD;
BEGIN
    SELECT unidad_id INTO v_ce  FROM api.v_unidades WHERE nombre = 'COMIC''ENDO AREPA';
    SELECT unidad_id INTO v_bar FROM api.v_unidades WHERE nombre = 'NASCAR Bar VIP';
    SELECT unidad_id INTO v_com FROM api.v_unidades WHERE nombre = 'NASCAR-Comidas';
    SELECT unidad_id INTO v_chi FROM api.v_unidades WHERE nombre = 'Chicharrón Mental';
    SELECT jornada_actual INTO v_hoy FROM api.v_empresas WHERE codigo = 'empresa_nascar';

    -- 1 · ACCESO -----------------------------------------------------------
    SELECT usuario_id INTO v_admin  FROM api.fn_login('admin', '2580');
    SELECT usuario_id INTO v_mesero FROM api.fn_login('mesero', '1111');
    SELECT usuario_id INTO v_cocina FROM api.fn_login('cocina', '2222');
    SELECT usuario_id INTO v_caja   FROM api.fn_login('caja', '4444');
    ASSERT v_admin IS NOT NULL AND v_mesero IS NOT NULL, 'Los usuarios de prueba deben poder entrar';
    ASSERT (SELECT count(*) FROM api.fn_login('admin', '0000')) = 0, 'Un PIN incorrecto no debe entrar';
    ASSERT api.fn_tiene_permiso(v_admin, 'pedidos_anular') AND NOT api.fn_tiene_permiso(v_mesero, 'pedidos_anular'),
           'Admin anula, mesero no';
    ASSERT NOT api.fn_tiene_permiso(v_admin, 'plataforma'), 'El admin de una empresa no administra la plataforma';
    RAISE NOTICE '✔ 1  Login con PIN (bcrypt) y permisos por rol';

    -- 2 · ESTRUCTURA DE NASCAR ---------------------------------------------
    ASSERT (SELECT count(*) FROM api.v_carta WHERE unidad_id = v_ce)  = 58, 'COMIC''ENDO: 58 productos';
    ASSERT (SELECT count(*) FROM api.v_carta WHERE unidad_id = v_bar) = 29, 'Bar: 29 productos';
    ASSERT (SELECT count(*) FROM api.v_carta WHERE unidad_id IN (v_com, v_chi)) = 0, 'Restaurantes sin carta';
    ASSERT (SELECT count(*) FROM api.v_stock WHERE unidad_id = v_ce)  = 18, 'COMIC''ENDO: 18 insumos';
    ASSERT (SELECT count(*) FROM api.v_stock WHERE unidad_id = v_bar) = 29, 'Bar: 29 insumos';
    ASSERT (SELECT count(*) FROM api.v_platos_dia WHERE unidad_id IN (v_com, v_chi) AND fecha = v_hoy) = 5, '5 platos de ejemplo';
    ASSERT (SELECT count(*) FROM api.v_carta WHERE unidad_id = v_bar AND sin_precio) = 29, 'Bar con precio por definir';
    RAISE NOTICE '✔ 2  4 unidades: carta, inventario y menú del día donde corresponde';

    -- 3 · PEDIDO A DOMICILIO SIN ZONAS ---------------------------------------
    SELECT producto_id INTO p_chorizo FROM api.v_carta WHERE unidad_id = v_ce  AND codigo = 'CE01';
    SELECT producto_id INTO p_gas15   FROM api.v_carta WHERE unidad_id = v_ce  AND codigo = 'CE53';
    SELECT producto_id INTO p_cerveza FROM api.v_carta WHERE unidad_id = v_bar AND codigo = 'BR01';

    CALL api.sp_crear_pedido(
        p_unidad_id => v_ce, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
        p_items => jsonb_build_array(jsonb_build_object('producto_id', p_chorizo, 'cantidad', 2),
                                     jsonb_build_object('producto_id', p_gas15, 'cantidad', 1, 'notas', 'bien fría')),
        p_cliente_nombre => 'Cliente Prueba', p_cliente_telefono => '300 123 4567',
        p_direccion => 'Cra 102 # 65-21', p_pedido_id => v_ped1, p_codigo => v_cod1);

    ASSERT v_cod1 = '00001', format('La primera factura debe ser 00001 (salió %s)', v_cod1);
    SELECT * INTO r FROM api.v_pedidos WHERE pedido_id = v_ped1;
    ASSERT r.subtotal = 26000 AND r.costo_domicilio = 0 AND r.total = 26000, 'Total 2×9.000 + 8.000 sin domicilio';
    ASSERT r.estado = 'nuevo' AND r.estado_pago = 'pendiente' AND r.fecha_operativa = v_hoy, 'Estados iniciales y jornada';
    ASSERT (SELECT count(*) FROM api.v_pedido_historial WHERE pedido_id = v_ped1) = 1, 'Historial "Pedido recibido"';
    RAISE NOTICE '✔ 3  Pedido a domicilio sin zonas: código 00001, total 26.000, sin costo de domicilio';

    -- 4 · SEGUIMIENTO --------------------------------------------------------
    SELECT * INTO r FROM api.fn_seguimiento_pedido('empresa_nascar', '#1');
    ASSERT r.codigo = '00001' AND r.pasos_totales = 5 AND r.paso_actual = 1, 'Seguimiento con "#1"';
    ASSERT (SELECT count(*) FROM api.fn_seguimiento_pedido('otra_empresa', '1')) = 0, 'Otra empresa no ve el pedido';
    RAISE NOTICE '✔ 4  Seguimiento: "#1" encuentra 00001 (paso 1 de 5); otra empresa no lo ve';

    -- 5 · MESA CON PLATO DEL CHEF --------------------------------------------
    SELECT plato_dia_id INTO v_plato FROM api.v_platos_dia WHERE unidad_id = v_com AND fecha = v_hoy ORDER BY orden LIMIT 1;
    CALL api.sp_crear_pedido(
        p_unidad_id => v_com, p_tipo => 'mesa', p_metodo_pago => 'efectivo', p_usuario_id => v_mesero, p_mesa => '3',
        p_items => jsonb_build_array(jsonb_build_object('plato_dia_id', v_plato, 'cantidad', 2)),
        p_pedido_id => v_ped2, p_codigo => v_cod2);
    ASSERT v_cod2 = '00002', 'Consecutivo compartido por la empresa';
    ASSERT (SELECT vendidos FROM api.v_platos_dia WHERE plato_dia_id = v_plato) = 2, 'Vendidos calculados';
    RAISE NOTICE '✔ 5  Pedido de mesa con plato del chef: 00002, vendidos = 2';

    -- 6 · AISLAMIENTO POR UNIDAD ---------------------------------------------
    PERFORM pg_temp.esperar_error(format(
        'CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => ''mesa'', p_metodo_pago => ''efectivo'', p_mesa => ''1'', p_items => %L::jsonb)',
        v_com, jsonb_build_array(jsonb_build_object('producto_id', p_cerveza, 'cantidad', 1))), 'no se vende');
    PERFORM pg_temp.esperar_error(format(
        'CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => ''mesa'', p_metodo_pago => ''efectivo'', p_usuario_id => %s, p_mesa => ''1'', p_items => %L::jsonb)',
        v_bar, v_mesero, jsonb_build_array(jsonb_build_object('producto_id', p_cerveza, 'cantidad', 1))), 'no trabaja en la unidad');
    RAISE NOTICE '✔ 6  Una cerveza del bar no se vende en el restaurante; el mesero no opera otra unidad';

    -- 7 · FLUJO DE ESTADOS ---------------------------------------------------
    CALL api.sp_avanzar_estado_pedido(v_ped2, v_cocina);   -- preparación
    CALL api.sp_avanzar_estado_pedido(v_ped2, v_cocina);   -- listo
    CALL api.sp_avanzar_estado_pedido(v_ped2, v_admin);    -- entregado (una mesa no pasa por "en camino")
    SELECT * INTO r FROM api.v_pedidos WHERE pedido_id = v_ped2;
    /* Con el 16 instalado, entregar ya no cobra: el pago lo confirma caja. */
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'api' AND p.proname = 'sp_actualizar_pago' AND p.pronargs = 5) THEN
        ASSERT r.estado = 'entregado' AND r.estado_pago = 'pendiente', 'Mesa: listo → entregado; el pago sigue pendiente';
        CALL api.sp_actualizar_pago(v_ped2, 'confirmado', v_admin);
        SELECT * INTO r FROM api.v_pedidos WHERE pedido_id = v_ped2;
    END IF;
    ASSERT r.estado = 'entregado' AND r.estado_pago = 'confirmado', 'Mesa: listo → entregado y efectivo confirmado';
    PERFORM pg_temp.esperar_error(format('CALL api.sp_cambiar_estado_pedido(%s, ''preparacion'', %s)', v_ped2, v_admin), 'no puede volver');
    PERFORM pg_temp.esperar_error(format('CALL api.sp_cambiar_estado_pedido(%s, ''camino'', %s)', v_ped2, v_admin), 'aplica a domicilios');

    CALL api.sp_avanzar_estado_pedido(v_ped1, v_admin);
    CALL api.sp_avanzar_estado_pedido(v_ped1, v_admin);
    CALL api.sp_avanzar_estado_pedido(v_ped1, v_admin);
    ASSERT (SELECT estado FROM api.v_pedidos WHERE pedido_id = v_ped1) = 'camino', 'Domicilio sí pasa por "en camino"';
    CALL api.sp_avanzar_estado_pedido(v_ped1, v_admin);
    ASSERT (SELECT paso_actual FROM api.fn_seguimiento_pedido('empresa_nascar', '1')) = 5, 'Seguimiento en el último paso';
    RAISE NOTICE '✔ 7  Flujo: mesa en 4 pasos, domicilio en 5; no se retrocede; el pago en efectivo queda confirmado';

    -- 8 · MENÚ ARMADO CON MÁXIMO POR CATEGORÍA ------------------------------
    CALL api.sp_guardar_menu_dia(p_unidad_id => v_com, p_fecha => v_hoy + 1, p_tipo => 'armado', p_usuario_id => v_admin,
                                 p_nombre => 'Almuerzo armado', p_precio => 18000, p_menu_id => v_menu);
    CALL api.sp_guardar_menu_categoria(p_menu_dia_id => v_menu, p_nombre => 'Sopa', p_usuario_id => v_admin, p_categoria_id => c1);
    CALL api.sp_guardar_menu_categoria(p_menu_dia_id => v_menu, p_nombre => 'Principio', p_usuario_id => v_admin, p_max_seleccion => 2, p_categoria_id => c2);
    CALL api.sp_guardar_menu_categoria(p_menu_dia_id => v_menu, p_nombre => 'Proteína', p_usuario_id => v_admin, p_categoria_id => c3);
    CALL api.sp_guardar_menu_opcion(p_menu_categoria_id => c1, p_nombre => 'Sancocho', p_usuario_id => v_admin, p_opcion_id => o1);
    CALL api.sp_guardar_menu_opcion(p_menu_categoria_id => c1, p_nombre => 'Crema de tomate', p_usuario_id => v_admin, p_opcion_id => o2);
    CALL api.sp_guardar_menu_opcion(p_menu_categoria_id => c2, p_nombre => 'Arroz', p_usuario_id => v_admin, p_opcion_id => o3);
    CALL api.sp_guardar_menu_opcion(p_menu_categoria_id => c2, p_nombre => 'Ensalada', p_usuario_id => v_admin, p_opcion_id => o4);
    CALL api.sp_guardar_menu_opcion(p_menu_categoria_id => c2, p_nombre => 'Frijoles', p_usuario_id => v_admin, p_opcion_id => o5);
    CALL api.sp_guardar_menu_opcion(p_menu_categoria_id => c3, p_nombre => 'Pollo', p_usuario_id => v_admin, p_opcion_id => o6);

    ASSERT (SELECT publicado FROM api.v_menu_dia WHERE menu_dia_id = v_menu), 'Menú armado publicado';
    ASSERT (SELECT jsonb_array_length(menu -> 'categorias') FROM api.v_menu_publico WHERE unidad_id = v_com AND fecha = v_hoy + 1) = 3,
           'Menú público con 3 categorías';

    CALL api.sp_crear_pedido(
        p_unidad_id => v_com, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
        p_items => jsonb_build_array(jsonb_build_object('menu_dia_id', v_menu, 'cantidad', 1, 'opciones', jsonb_build_array(o1, o3, o4, o6)),
                                     jsonb_build_object('menu_dia_id', v_menu, 'cantidad', 1, 'opciones', jsonb_build_array(o2, o5, o6))),
        p_cliente_nombre => 'Otra Clienta', p_cliente_telefono => '3109876543', p_direccion => 'Av. Calle 80 # 100-10',
        p_pedido_id => v_ped4, p_codigo => v_cod4);
    ASSERT (SELECT count(*) FROM api.v_pedido_items WHERE pedido_id = v_ped4) = 2, 'Dos combinaciones = dos líneas';
    ASSERT EXISTS (SELECT 1 FROM api.v_pedido_items WHERE pedido_id = v_ped4
                    AND detalle = 'Sopa: Sancocho · Principio: Arroz, Ensalada · Proteína: Pollo'), 'Detalle de la combinación';
    PERFORM pg_temp.esperar_error(format(
        'CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => ''mesa'', p_metodo_pago => ''efectivo'', p_mesa => ''2'', p_items => %L::jsonb)',
        v_com, jsonb_build_array(jsonb_build_object('menu_dia_id', v_menu, 'opciones', jsonb_build_array(o1, o3, o4, o5, o6)))), 'máximo 2');
    PERFORM pg_temp.esperar_error(format(
        'CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => ''mesa'', p_metodo_pago => ''efectivo'', p_mesa => ''2'', p_items => %L::jsonb)',
        v_com, jsonb_build_array(jsonb_build_object('menu_dia_id', v_menu, 'opciones', jsonb_build_array(o1, o6)))), 'Te falta elegir: Principio');
    RAISE NOTICE '✔ 8  Menú armado: combinaciones independientes, "Principio: Arroz, Ensalada", máximo 2 y obligatorias';

    -- 9 · CUPOS ---------------------------------------------------------------
    SELECT menu_dia_id INTO v_menu_chef FROM api.v_platos_dia WHERE plato_dia_id = v_plato;
    CALL api.sp_guardar_plato_dia(p_menu_dia_id => v_menu_chef,
                                  p_nombre => 'Plato con un cupo', p_precio => 20000, p_usuario_id => v_admin, p_cupos => 1,
                                  p_plato_id => v_plato_cupo);
    PERFORM pg_temp.esperar_error(format(
        'CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => ''mesa'', p_metodo_pago => ''efectivo'', p_mesa => ''4'', p_items => %L::jsonb)',
        v_com, jsonb_build_array(jsonb_build_object('plato_dia_id', v_plato_cupo, 'cantidad', 2))), 'cupos');
    RAISE NOTICE '✔ 9  Cupos del plato del chef';

    -- 10 · PERMISOS -----------------------------------------------------------
    PERFORM pg_temp.esperar_error(format('CALL api.sp_anular_pedido(%s, ''prueba'', %s)', v_ped2, v_mesero), 'permiso');
    PERFORM pg_temp.esperar_error(format('CALL api.sp_cambiar_estado_unidad(%s, false, %s)', v_chi, v_caja), 'permiso');
    PERFORM pg_temp.esperar_error('SELECT count(*) FROM core.pedidos', 'permission denied');
    RAISE NOTICE '✔ 10 Permisos: el mesero no anula, caja no configura unidades, la app no lee core';

    -- 11 · BAR: ENTRADA, CIERRE, CRUCE IN·EN·Z·SD Y ANULACIÓN ----------------
    SELECT insumo_id INTO v_insumo FROM api.v_stock WHERE unidad_id = v_bar AND codigo = 'BAR-01';
    CALL api.sp_registrar_entrada(p_unidad_id => v_bar, p_insumo_id => v_insumo, p_tipo => 'compra', p_cantidad => 24,
                                  p_usuario_id => v_admin, p_observacion => 'Canasta', p_entrada_id => v_entrada);
    ASSERT (SELECT stock_actual FROM api.v_stock WHERE unidad_id = v_bar AND codigo = 'BAR-01') = 24, 'La entrada suma al stock';

    CALL api.sp_crear_pedido(
        p_unidad_id => v_bar, p_tipo => 'mesa', p_metodo_pago => 'transferencia', p_mesa => '7',
        p_items => jsonb_build_array(jsonb_build_object('producto_id', p_cerveza, 'cantidad', 3)),
        p_pedido_id => v_ped3, p_codigo => v_cod3);

    CALL api.sp_registrar_cierre(p_unidad_id => v_bar, p_area => 'bar', p_usuario_id => v_admin,
                                 p_detalle => jsonb_build_array(jsonb_build_object('insumo_id', v_insumo, 'saldo', 20)),
                                 p_cierre_id => v_cierre);
    SELECT * INTO r FROM api.v_cruce_inventario WHERE cierre_id = v_cierre AND codigo = 'BAR-01';
    ASSERT r.inicial = 0 AND r.entradas = 24 AND r.ventas = 3 AND r.saldo_fisico = 20 AND r.diferencia = 1,
           format('Cruce IN 0 + EN 24 − Z 3 − SD 20 = 1 (salió %s/%s/%s/%s/%s)', r.inicial, r.entradas, r.ventas, r.saldo_fisico, r.diferencia);

    CALL api.sp_anular_pedido(v_ped3, 'Cliente devolvió las cervezas', v_admin);
    ASSERT (SELECT estado FROM api.v_pedidos WHERE pedido_id = v_ped3) = 'anulado', 'Factura anulada';
    ASSERT (SELECT count(*) FROM api.v_entradas WHERE factura = v_cod3 AND tipo = 'retorno_anulacion' AND fecha_operativa = v_hoy + 1) = 1,
           'Con el área ya cerrada, la mercancía vuelve como entrada de la jornada siguiente';
    /* Desde 13_fase2_inventario.sql el cruce de un día YA cerrado no cambia:
       la venta sigue contando allí y la mercancía vuelve sólo por la entrada.
       Antes de 13 la factura salía de Z (y el cierre firmado cambiaba). */
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'core.entradas_inventario'::regclass AND attname = 'anulada_en' AND NOT attisdropped) THEN
        ASSERT (SELECT ventas FROM api.v_cruce_inventario WHERE cierre_id = v_cierre AND codigo = 'BAR-01') = 3,
               'Con el día ya cerrado, la venta anulada sigue en su Z: el cierre firmado no cambia';
    ELSE
        ASSERT (SELECT ventas FROM api.v_cruce_inventario WHERE cierre_id = v_cierre AND codigo = 'BAR-01') = 0,
               'La factura anulada deja de contar en Z';
    END IF;
    PERFORM pg_temp.esperar_error(format('CALL api.sp_anular_pedido(%s, ''otra vez'', %s)', v_ped3, v_admin), 'ya está anulada');

    CALL api.sp_revisar_cierre(v_cierre, v_admin);
    PERFORM pg_temp.esperar_error(format(
        'CALL api.sp_registrar_cierre(p_unidad_id => %s, p_area => ''bar'', p_usuario_id => %s, p_detalle => %L::jsonb)',
        v_bar, v_admin, jsonb_build_array(jsonb_build_object('insumo_id', v_insumo, 'saldo', 99))), 'revisado');
    RAISE NOTICE '✔ 11 Bar: entrada +24, cruce IN·EN·Z·SD, anulación con retorno diferido, cierre revisado intocable';

    -- 12 · ANULAR SIN CIERRE: no se crea entrada (no se devuelve dos veces) --
    CALL api.sp_anular_pedido(v_ped1, 'Pedido de prueba', v_admin);
    ASSERT (SELECT count(*) FROM api.v_entradas WHERE factura = v_cod1) = 0,
           'Sin cierre, la anulación no crea entrada: basta con salir de Z';
    ASSERT (SELECT retorno_diferido FROM api.v_anulaciones WHERE codigo = v_cod1) = FALSE, 'Retorno en su propia jornada';
    RAISE NOTICE '✔ 12 Anulación sin cierre: sin entrada duplicada';

    -- 13 · CAJA ---------------------------------------------------------------
    SELECT categoria_gasto_id INTO v_cat_gasto FROM api.v_categorias_gasto WHERE nombre = 'Servicios';
    CALL api.sp_registrar_base_caja(p_unidad_id => v_com, p_monto => 50000, p_usuario_id => v_caja, p_base_id => v_base);
    PERFORM pg_temp.esperar_error(format('CALL api.sp_registrar_base_caja(p_unidad_id => %s, p_monto => 60000, p_usuario_id => %s)', v_com, v_caja), 'motivo');
    CALL api.sp_registrar_base_caja(p_unidad_id => v_com, p_monto => 60000, p_usuario_id => v_caja,
                                    p_observacion => 'Se contó mal el sencillo', p_base_id => v_base);
    ASSERT (SELECT count(*) FROM api.v_bases_caja WHERE unidad_id = v_com AND fecha_operativa = v_hoy) = 2
       AND (SELECT count(*) FROM api.v_bases_caja WHERE unidad_id = v_com AND fecha_operativa = v_hoy AND vigente) = 1,
           'La corrección conserva la base anterior';
    CALL api.sp_registrar_gasto(p_unidad_id => v_com, p_categoria_gasto_id => v_cat_gasto, p_metodo_pago => 'efectivo',
                                p_descripcion => 'Gas', p_monto => 10000, p_usuario_id => v_caja, p_gasto_id => v_gasto);

    /* Desde 14_fase2_caja_gastos.sql el efectivo esperado usa lo COBRADO (pago
       confirmado); antes usaba todo lo vendido. */
    SELECT 60000 + COALESCE(SUM(total), 0) - 10000 INTO v_esperado
      FROM api.v_pedidos WHERE unidad_id = v_com AND fecha_operativa = v_hoy AND grupo_caja = 'efectivo' AND cuenta_como_venta
       AND (estado_pago = 'confirmado'
            OR NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'api.v_cruce_caja'::regclass
                                                        AND attname = 'cobrado_efectivo' AND NOT attisdropped));
    ASSERT (SELECT efectivo_esperado FROM api.v_cruce_caja WHERE unidad_id = v_com AND fecha_operativa = v_hoy) = v_esperado,
           'Efectivo esperado = base + ventas en efectivo (cobradas) − gastos en efectivo';
    CALL api.sp_anular_gasto(v_gasto, 'Lo pagó el dueño', v_admin);
    ASSERT (SELECT gastos_efectivo FROM api.v_cruce_caja WHERE unidad_id = v_com AND fecha_operativa = v_hoy) = 0,
           'Un gasto anulado sale del cruce';
    RAISE NOTICE '✔ 13 Caja: base con corrección auditada, gasto, cruce de efectivo y anulación de gasto';

    -- 14 · UNIDAD INACTIVA ---------------------------------------------------
    CALL api.sp_cambiar_estado_unidad(v_chi, FALSE, v_admin);
    PERFORM pg_temp.esperar_error(format(
        'CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => ''mesa'', p_metodo_pago => ''efectivo'', p_mesa => ''1'', p_items => %L::jsonb)',
        v_chi, jsonb_build_array(jsonb_build_object('plato_dia_id', 1, 'cantidad', 1))), 'inactiva');
    ASSERT (SELECT count(*) FROM api.v_platos_dia WHERE unidad_id = v_chi) = 2, 'Su historia se conserva';
    CALL api.sp_cambiar_estado_unidad(v_chi, TRUE, v_admin);
    RAISE NOTICE '✔ 14 Unidad inactiva: sin operación nueva, historia intacta';

    -- 15 · LIMPIEZA DE FACTURAS DE PRUEBA -----------------------------------
    PERFORM pg_temp.esperar_error(format('CALL api.sp_borrar_facturas_prueba(1, ''borrar no'', %s)', v_admin), 'BORRAR');
    CALL api.sp_borrar_facturas_prueba(p_empresa_id => 1, p_confirmacion => 'borrar', p_usuario_id => v_admin, p_borradas => v_borradas);
    ASSERT v_borradas = 4 AND (SELECT count(*) FROM api.v_pedidos) = 0, format('Facturas borradas (%s)', v_borradas);
    ASSERT (SELECT stock_actual FROM api.v_stock WHERE unidad_id = v_bar AND codigo = 'BAR-01') = 24,
           'Se descuenta del stock lo que habían devuelto las anulaciones';
    CALL api.sp_crear_pedido(p_unidad_id => v_ce, p_tipo => 'mesa', p_metodo_pago => 'efectivo', p_mesa => '1',
                             p_items => jsonb_build_array(jsonb_build_object('producto_id', p_chorizo)),
                             p_pedido_id => v_ped5, p_codigo => v_cod5);
    ASSERT v_cod5 = '00001', 'La numeración vuelve a 00001';
    RAISE NOTICE '✔ 15 Limpieza de pruebas: 4 facturas borradas, stock coherente, numeración en 00001';
END;
$$;


/* ============================================================================
   PARTE 2 · DIRECTO EN LAS TABLAS (dueño): las reglas no dependen de la app
   ============================================================================ */
RESET ROLE;

DO $$
DECLARE
    v_emp2 INTEGER; v_cat2 INTEGER; v_ped BIGINT; v_item BIGINT; v_unidad INTEGER;
BEGIN
    -- 16 · MULTIEMPRESA ------------------------------------------------------
    INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_prueba', 'Empresa de prueba') RETURNING id INTO v_emp2;
    INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_emp2, 'Postres') RETURNING id INTO v_cat2;
    PERFORM pg_temp.esperar_error(format(
        'INSERT INTO core.categoria_unidades (categoria_id, unidad_id) SELECT %s, id FROM core.unidades WHERE nombre = ''NASCAR-Comidas''', v_cat2),
        'empresas distintas');
    PERFORM pg_temp.esperar_error(format(
        'INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio) VALUES (1, %s, ''X1'', ''Cruzado'', 1000)', v_cat2),
        'empresas distintas');
    PERFORM pg_temp.esperar_error(
        'INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash) SELECT 1, id, ''x'', ''x'', ''x'' FROM core.roles WHERE codigo = ''superadmin''',
        'plataforma no pertenece');
    RAISE NOTICE '✔ 16 Multiempresa: nada se cruza entre empresas; SuperAdmin sin empresa';

    -- 17 · FACTURAS INMUTABLES ----------------------------------------------
    SELECT id INTO v_ped FROM core.pedidos WHERE codigo = '00001' AND empresa_id = 1;
    PERFORM pg_temp.esperar_error(format('DELETE FROM core.pedidos WHERE id = %s', v_ped), 'no se borran');
    PERFORM pg_temp.esperar_error(format('UPDATE core.pedidos SET codigo = ''99999'' WHERE id = %s', v_ped), 'no puede cambiar');
    PERFORM pg_temp.esperar_error(format('UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo(''estados_pedido'', ''anulado'') WHERE id = %s', v_ped),
                                  'sp_anular_pedido');
    UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'preparacion') WHERE id = v_ped;
    SELECT id INTO v_item FROM core.pedido_items WHERE pedido_id = v_ped LIMIT 1;
    PERFORM pg_temp.esperar_error(format('UPDATE core.pedido_items SET cantidad = 9 WHERE id = %s', v_item), 'no se pueden cambiar');
    PERFORM pg_temp.esperar_error(format('UPDATE core.pedido_items SET precio_unitario = 1 WHERE id = %s', v_item), 'no se pueden cambiar');
    RAISE NOTICE '✔ 17 Facturas: no se borran, no cambian de código, se anulan sólo por procedimiento, ítems congelados';

    -- 18 · REGLAS DE UNIDADES Y MOVIMIENTOS ---------------------------------
    PERFORM pg_temp.esperar_error('UPDATE core.unidades SET estado = ''inactiva'' WHERE empresa_id = 1', 'al menos una unidad activa');
    PERFORM pg_temp.esperar_error('UPDATE core.entradas_inventario SET cantidad = 1', 'no se modifican');
    PERFORM pg_temp.esperar_error('UPDATE core.cierres_inventario SET observacion = ''cambio''', 'revisado');
    PERFORM pg_temp.esperar_error('INSERT INTO core.menu_categorias (menu_dia_id, nombre, max_seleccion) SELECT id, ''Postre'', 11 FROM core.menus_dia LIMIT 1', 'check');
    RAISE NOTICE '✔ 18 Siempre una unidad activa; entradas inmutables; cierre revisado intocable; máximo por categoría ≤ 10';

    -- 19 · AUDITORÍA ---------------------------------------------------------
    -- Sirve con la auditoría completa (01…09) y con la liviana (10)
    ASSERT (SELECT count(*) FROM core.auditoria WHERE tabla IN ('unidades', 'gastos', 'bases_caja')) > 0,
           'Los cambios de unidades, gastos y bases quedan auditados';
    ASSERT (SELECT count(*) FROM core.auditoria a WHERE to_jsonb(a)::TEXT LIKE '%pin_hash%') = 0,
           'La auditoría nunca guarda el hash del PIN';
    RAISE NOTICE '✔ 19 Auditoría registrada, sin datos sensibles';

    -- 20 · REPORTE MATERIALIZADO --------------------------------------------
    CALL api.sp_refrescar_reportes();
    ASSERT (SELECT count(*) FROM api.mv_ventas_mensuales) >= 1, 'Reporte mensual refrescado';
    RAISE NOTICE '✔ 20 Vista materializada de ventas mensuales refrescada';

    RAISE NOTICE '';
    RAISE NOTICE '══════════ TODAS LAS PRUEBAS PASARON · se deshace todo con ROLLBACK ══════════';
END;
$$;

ROLLBACK;
