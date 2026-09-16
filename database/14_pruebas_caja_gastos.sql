/* ============================================================================
   TASECA · 14 · PRUEBAS DE BASE DE CAJA, GASTOS Y CRUCE (fase 2, bloque 4)
   ----------------------------------------------------------------------------
   Ejecutar después de 14_fase2_caja_gastos.sql. Todo corre como la aplicación
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

CREATE FUNCTION pg_temp.token(p_usuario TEXT, p_empresa INTEGER DEFAULT NULL)
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
                       jsonb_build_object('role', 'taseca_app', 'usuario_id', v_id,
                                          'empresa_id', COALESCE(p_empresa, v_empresa))::TEXT, TRUE);
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
    v_com INTEGER; v_ce INTEGER; v_hoy DATE; v_cat INTEGER; v_plato BIGINT;
    v_r JSONB; v_g1 BIGINT; v_g2 BIGINT; v_ped BIGINT; v_ped2 BIGINT; v_ped3 BIGINT; v_inf JSONB;
    v_cobrado NUMERIC; v_esperado NUMERIC; v_i INTEGER;
BEGIN
    SELECT id INTO v_com FROM core.unidades WHERE nombre = 'NASCAR-Comidas';
    SELECT id INTO v_ce  FROM core.unidades WHERE nombre = 'COMIC''ENDO AREPA';
    SELECT jornada_actual INTO v_hoy FROM api.v_empresas WHERE codigo = 'empresa_nascar';
    SELECT categoria_gasto_id INTO v_cat FROM api.v_categorias_gasto WHERE nombre = 'Servicios';

    -- 1 · LECTURA POR PERMISO --------------------------------------------------------
    PERFORM pg_temp.token('caja');
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.categorias_gasto')::TEXT::INTEGER = 6, 'Seis categorías de gasto';
    PERFORM pg_temp.token('cocina');
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.bases_caja')::TEXT::INTEGER = 0, 'Cocina no ve la caja';
    RAISE NOTICE '✔ 1  Lectura: categorías de la empresa; sin permiso no se ve la caja';

    -- 2 · GASTOS: REGISTRAR CON CONSECUTIVO Y EDITAR --------------------------------------
    PERFORM pg_temp.token('caja');
    v_r := pg_temp.app(format($s$SELECT rest.guardar_gasto('{"unidad_id": %s, "fecha": "%s", "hora": "08:15",
        "categoria_gasto_id": %s, "metodo_pago": "efectivo", "descripcion": "Pipeta de gas", "tercero": "Gases del Norte",
        "observaciones": "Factura 123", "monto": 10000}')$s$, v_com, v_hoy, v_cat));
    v_g1 := (v_r ->> 'gasto_id')::BIGINT;
    ASSERT v_r ->> 'consecutivo' = 'G' || v_com || '-' || to_char(v_hoy, 'YYMMDD') || '-001', format('Consecutivo 001 (salió %s)', v_r ->> 'consecutivo');
    ASSERT v_r ->> 'estado' = 'registrado' AND v_r ->> 'tercero' = 'Gases del Norte' AND v_r ->> 'hora' = '08:15:00', 'Guarda todo';

    v_r := pg_temp.app(format($s$SELECT rest.guardar_gasto('{"unidad_id": %s, "fecha": "%s", "categoria_gasto_id": %s,
        "metodo_pago": "transferencia", "descripcion": "Internet", "monto": 90000}')$s$, v_com, v_hoy, v_cat));
    v_g2 := (v_r ->> 'gasto_id')::BIGINT;
    ASSERT v_r ->> 'consecutivo' LIKE '%-002', 'El segundo del día es 002';

    v_r := pg_temp.app(format($s$SELECT rest.guardar_gasto('{"gasto_id": %s, "fecha": "%s", "hora": "08:15",
        "categoria_gasto_id": %s, "metodo_pago": "efectivo", "descripcion": "Pipeta de gas 40 lb", "tercero": "Gases del Norte",
        "monto": 12000}')$s$, v_g1, v_hoy, v_cat));
    ASSERT (v_r ->> 'monto')::NUMERIC = 12000 AND v_r ->> 'descripcion' = 'Pipeta de gas 40 lb' AND v_r ->> 'consecutivo' LIKE '%-001',
           'Editar cambia valor y concepto; conserva el consecutivo';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_gasto(''{"unidad_id": %s, "fecha": "%s",
        "categoria_gasto_id": %s, "metodo_pago": "efectivo", "descripcion": "Algo", "monto": 0}'')')$s$, v_com, v_hoy, v_cat), 'mayor que cero');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_gasto(''{"unidad_id": %s, "fecha": "%s",
        "categoria_gasto_id": %s, "metodo_pago": "efectivo", "descripcion": "ab", "monto": 5}'')')$s$, v_com, v_hoy, v_cat), 'mínimo 3');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_gasto(''{"unidad_id": %s, "fecha": "%s",
        "categoria_gasto_id": %s, "metodo_pago": "bitcoin", "descripcion": "Algo", "monto": 5}'')')$s$, v_com, v_hoy, v_cat), 'método de pago');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_gasto(''{"unidad_id": %s, "fecha": "%s",
        "categoria_gasto_id": 999999, "metodo_pago": "efectivo", "descripcion": "Algo", "monto": 5}'')')$s$, v_com, v_hoy), 'categoría');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_gasto(''{"unidad_id": %s, "fecha": "%s",
        "categoria_gasto_id": %s, "metodo_pago": "efectivo", "descripcion": "Algo", "monto": 5}'')')$s$, v_com, v_hoy + 1, v_cat), 'futura');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_gasto(''{"unidad_id": %s, "fecha": "%s",
        "categoria_gasto_id": %s, "metodo_pago": "efectivo", "descripcion": "Algo", "monto": 5}'')')$s$, v_ce, v_hoy, v_cat), 'no trabaja en la unidad');
    RAISE NOTICE '✔ 2  Gastos: consecutivo por unidad y día, edición; valor, concepto, método, categoría, fecha y unidad inválidos';

    -- 3 · CONFIRMAR Y ANULAR ------------------------------------------------------------
    v_r := pg_temp.app(format('SELECT rest.confirmar_gasto(%s)', v_g1));
    ASSERT v_r ->> 'estado' = 'confirmado' AND v_r ->> 'confirmado_por' = 'Caja Comidas' AND v_r ->> 'confirmado_en' IS NOT NULL,
           'Confirmado con quién y cuándo';
    PERFORM pg_temp.app(format('SELECT rest.confirmar_gasto(%s)', v_g1));  -- dos veces: no pasa nada
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_gasto(''{"gasto_id": %s, "fecha": "%s",
        "categoria_gasto_id": %s, "metodo_pago": "efectivo", "descripcion": "Otra cosa", "monto": 1}'')')$s$, v_g1, v_hoy, v_cat),
        'confirmado ya no se puede editar');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.anular_gasto(%s, ''Error de digitación'')')$s$, v_g1),
        'permiso "gastos_anular"');

    PERFORM pg_temp.token('admin');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.anular_gasto(%s, ''no'')')$s$, v_g1), 'por qué se anula');
    v_r := pg_temp.app(format($s$SELECT rest.anular_gasto(%s, 'Lo pagó el dueño')$s$, v_g1));
    ASSERT v_r ->> 'estado' = 'anulado' AND v_r ->> 'anulado_por' = 'Dueño' AND v_r ->> 'motivo_anulacion' = 'Lo pagó el dueño', 'Anulado con motivo';
    PERFORM pg_temp.app(format($s$SELECT rest.anular_gasto(%s, 'Otra vez')$s$, v_g1));  -- ya estaba: no pasa nada
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.confirmar_gasto(%s)')$s$, v_g1), 'anulado no se puede confirmar');
    RAISE NOTICE '✔ 3  Confirmar y anular: quién y cuándo, repetir no hace nada, confirmado no se edita, anulado no se confirma';

    -- 4 · BASE DE CAJA -------------------------------------------------------------------
    PERFORM pg_temp.token('caja');
    v_r := pg_temp.app(format($s$SELECT rest.registrar_base('{"unidad_id": %s, "fecha": "%s", "monto": 50000,
        "hora": "07:30", "observaciones": "Billetes y monedas"}')$s$, v_com, v_hoy));
    ASSERT (v_r ->> 'monto')::NUMERIC = 50000 AND v_r ->> 'hora' = '07:30:00' AND (v_r ->> 'vigente')::BOOLEAN, 'Base de 50.000';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_base(''{"unidad_id": %s, "fecha": "%s",
        "monto": 70000}'')')$s$, v_com, v_hoy), 'hay que corregirla');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_base(''{"unidad_id": %s, "fecha": "%s",
        "monto": 70000, "corregir": true}'')')$s$, v_com, v_hoy), 'escribir el motivo');
    v_r := pg_temp.app(format($s$SELECT rest.registrar_base('{"unidad_id": %s, "fecha": "%s", "monto": 60000,
        "corregir": true, "motivo": "Se contó mal el sencillo"}')$s$, v_com, v_hoy));
    ASSERT (v_r ->> 'monto')::NUMERIC = 60000 AND v_r ->> 'motivo_correccion' = 'Se contó mal el sencillo'
       AND v_r ->> 'reemplaza_a_id' IS NOT NULL, 'La corrección apunta a la anterior';
    ASSERT (SELECT count(*) FROM core.bases_caja WHERE unidad_id = v_com AND fecha_operativa = v_hoy) = 2
       AND (SELECT monto FROM core.bases_caja WHERE unidad_id = v_com AND fecha_operativa = v_hoy AND NOT vigente) = 50000,
           'La anterior se conserva con su valor';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_base(''{"unidad_id": %s, "fecha": "%s",
        "monto": -1}'')')$s$, v_com, v_hoy - 1), 'mayor o igual');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_base(''{"unidad_id": %s, "fecha": "%s",
        "monto": 1}'')')$s$, v_com, v_hoy + 1), 'todavía no llega');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_base(''{"unidad_id": %s, "fecha": "%s",
        "monto": 1, "corregir": true, "motivo": "Por probar"}'')')$s$, v_com, v_hoy - 1), 'No hay una base que corregir');
    RAISE NOTICE '✔ 4  Base: no se pisa sin corregir, la corrección exige motivo y conserva la anterior; valor y fecha inválidos';

    -- 5 · CRUCE DE CAJA: SÓLO LO COBRADO CUADRA EL CAJÓN ----------------------------------
    PERFORM pg_temp.token('admin');
    /* Un plato propio de la prueba en el menú del chef de HOY: no depende de
       que la base tenga menú publicado para esta fecha (todo se deshace). */
    INSERT INTO core.menus_dia (unidad_id, fecha, tipo_menu_id, disponible)
    VALUES (v_com, v_hoy, core.fn_id_catalogo('tipos_menu', 'chef'), TRUE)
    ON CONFLICT (unidad_id, fecha) DO UPDATE
       SET tipo_menu_id = core.fn_id_catalogo('tipos_menu', 'chef'), disponible = TRUE;
    INSERT INTO core.platos_dia (menu_dia_id, nombre, precio, disponible, orden)
    SELECT id, 'Plato de prueba de caja', 18000, TRUE, 99
      FROM core.menus_dia WHERE unidad_id = v_com AND fecha = v_hoy
    RETURNING id INTO v_plato;
    ASSERT v_plato IS NOT NULL, 'Hay plato del día para vender';

    -- Pedido 1: efectivo, entregado (cobrado)
    SELECT (r ->> 'pedido_id')::BIGINT INTO v_ped FROM rest.crear_pedido(v_com, 'mesa', 'efectivo',
        format('[{"plato_dia_id": %s, "cantidad": 2}]', v_plato)::JSONB, p_mesa => '1') r;
    FOR v_i IN 1..3 LOOP
        PERFORM pg_temp.app(format('SELECT rest.avanzar_estado(%s)', v_ped));
    END LOOP;
    -- Con el 16 instalado entregar no cobra: caja confirma el pago
    IF (SELECT estado_pago FROM api.v_pedidos WHERE pedido_id = v_ped) <> 'confirmado' THEN
        PERFORM pg_temp.app(format('SELECT rest.confirmar_pago(%s)', v_ped));
    END IF;
    -- Pedido 2: efectivo, todavía en cocina (por cobrar)
    SELECT (r ->> 'pedido_id')::BIGINT INTO v_ped2 FROM rest.crear_pedido(v_com, 'mesa', 'efectivo',
        format('[{"plato_dia_id": %s, "cantidad": 1}]', v_plato)::JSONB, p_mesa => '2') r;
    -- Pedido 3: transferencia, anulado
    SELECT (r ->> 'pedido_id')::BIGINT INTO v_ped3 FROM rest.crear_pedido(v_com, 'mesa', 'transferencia',
        format('[{"plato_dia_id": %s, "cantidad": 1}]', v_plato)::JSONB, p_mesa => '3') r;
    PERFORM pg_temp.app(format($s$SELECT rest.anular_pedido(%s, 'Prueba de caja')$s$, v_ped3));

    ASSERT (SELECT estado_pago FROM api.v_pedidos WHERE pedido_id = v_ped) = 'confirmado', 'Efectivo entregado = cobrado';

    SELECT COALESCE(SUM(total) FILTER (WHERE estado_pago = 'confirmado'), 0) INTO v_cobrado
      FROM api.v_pedidos WHERE unidad_id = v_com AND fecha_operativa = v_hoy AND cuenta_como_venta AND grupo_caja = 'efectivo';
    v_esperado := 60000 + v_cobrado - 0;  -- el único gasto en efectivo quedó anulado

    v_inf := pg_temp.app(format($s$SELECT rest.informe_caja('%s', %s)$s$, v_hoy, v_com));
    ASSERT (v_inf -> 'base' ->> 'valor')::NUMERIC = 60000 AND (v_inf -> 'base' -> 'registro' ->> 'monto')::NUMERIC = 60000, 'Base vigente';
    ASSERT (v_inf -> 'ventas' -> 'efectivo' ->> 'cobrado')::NUMERIC = v_cobrado
       AND (v_inf -> 'ventas' -> 'efectivo' ->> 'pendiente')::NUMERIC > 0, 'Efectivo: cobrado y por cobrar por separado';
    ASSERT (v_inf -> 'anuladas' -> 'transferencia' ->> 'n')::INTEGER >= 1, 'La factura anulada se informa aparte';
    ASSERT NOT (v_inf -> 'gastos') ? 'efectivo' AND (v_inf -> 'gastos' -> 'transferencia' ->> 'total')::NUMERIC = 90000
       AND (v_inf -> 'gastos' -> 'transferencia' ->> 'pendientes')::INTEGER = 1, 'Gastos: el anulado no cuenta; el registrado sí, como pendiente';
    ASSERT (SELECT efectivo_esperado FROM api.v_cruce_caja WHERE unidad_id = v_com AND fecha_operativa = v_hoy) = v_esperado,
           format('Vista: efectivo esperado = 60.000 + cobrado %s (salió %s)', v_cobrado,
                  (SELECT efectivo_esperado FROM api.v_cruce_caja WHERE unidad_id = v_com AND fecha_operativa = v_hoy));
    ASSERT (SELECT por_cobrar > 0 AND anuladas >= 1 FROM api.v_cruce_caja WHERE unidad_id = v_com AND fecha_operativa = v_hoy),
           'La vista también separa lo pendiente y lo anulado';
    RAISE NOTICE '✔ 5  Cruce de caja: efectivo esperado con lo COBRADO; por cobrar, anuladas y gastos anulados aparte';

    -- 6 · SEGURIDAD -----------------------------------------------------------------------
    PERFORM pg_temp.token('mesero');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_gasto(''{"unidad_id": %s, "fecha": "%s",
        "categoria_gasto_id": %s, "metodo_pago": "efectivo", "descripcion": "Intruso", "monto": 5}'')')$s$, v_com, v_hoy, v_cat), 'permiso "gastos"');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.informe_caja(''%s'', %s)')$s$, v_hoy, v_com), 'no puede ver el cruce');

    PERFORM pg_temp.token('caja');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.informe_caja(''%s'', %s)')$s$, v_hoy, v_ce), 'No trabajas');

    PERFORM pg_temp.token('admin', 999999);
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.gastos')::TEXT::INTEGER = 0, 'Token de otra empresa: nada';
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.confirmar_gasto(%s)')$s$, v_g2), 'No se encontró el gasto');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_base(''{"unidad_id": %s, "monto": 1}'')')$s$, v_com),
        'no es de esta empresa');
    RAISE NOTICE '✔ 6  Seguridad: permisos del rol, unidad del usuario y empresa del token';
END;
$$;

SET LOCAL ROLE taseca_anon;
SELECT pg_temp.esperar_error($s$SELECT count(*) FROM rest.gastos$s$, 'permission denied');
SELECT pg_temp.esperar_error($s$SELECT rest.informe_caja(current_date)$s$, 'permission denied');
RESET ROLE;

ROLLBACK;
