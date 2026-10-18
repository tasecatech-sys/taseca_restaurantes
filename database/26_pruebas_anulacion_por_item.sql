/* ============================================================================
   TASECA · 26 · PRUEBAS DE LA ANULACIÓN POR ÍTEM
   ----------------------------------------------------------------------------
   Ejecutar después de 26_anulacion_por_item.sql. Todo dentro de una
   transacción que termina en ROLLBACK: no deja ningún dato.

   El inventario es lo que se comprueba, y se comprueba con números:

     1. Sin lista, se devuelve todo: como siempre.
     2. Dando de baja un plato, su mercancía NO vuelve.
     3. En la misma factura, lo que vuelve vuelve y lo que no, no.
     4. Queda constancia: en core.anulacion_items y en el historial.
     5. No se puede dar de baja un plato de OTRA factura.
     6. Una factura ya anulada sigue sin poder anularse dos veces.

   En DBeaver: Alt+X y mira la pestaña «Salida». Cada prueba escribe ✔.
   ============================================================================ */

BEGIN;

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

DO $falta$
BEGIN
    IF to_regclass('core.anulacion_items') IS NULL THEN
        RAISE EXCEPTION E'Falta correr database/26_anulacion_por_item.sql antes de esta prueba.'
            USING ERRCODE = 'undefined_table';
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
    v_emp   INTEGER; v_uni INTEGER; v_cat INTEGER; v_admin INTEGER;
    v_burg  INTEGER; v_gas INTEGER;
    v_pan   INTEGER; v_bot INTEGER;
    v_iu_pan INTEGER; v_iu_bot INTEGER;
    v_ped   BIGINT;  v_cod VARCHAR;
    v_it_burg BIGINT; v_it_gas BIGINT;
    v_hoy   DATE;
    v_z_pan NUMERIC; v_z_bot NUMERIC;
    v_n     INTEGER; v_txt TEXT;
    v_area  INTEGER := (SELECT id FROM core.areas_inventario ORDER BY id LIMIT 1);
    v_um    INTEGER := (SELECT id FROM core.unidades_medida  ORDER BY id LIMIT 1);
BEGIN
    /* ---------- Un negocio con dos platos y dos insumos ---------- */
    INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_baja', 'Baja') RETURNING id INTO v_emp;
    INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo) SELECT v_emp, id, TRUE FROM core.modulos;
    INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos) VALUES (v_emp, 'pedido', 0, 5);
    INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo)
    SELECT v_emp, id, TRUE FROM core.metodos_pago WHERE codigo = 'efectivo';

    INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
    VALUES (v_emp, (SELECT id FROM core.tipos_negocio ORDER BY id LIMIT 1), 'Baja · Sede', 'Baja')
    RETURNING id INTO v_uni;
    INSERT INTO core.mesas (unidad_id, numero) VALUES (v_uni, '1');

    INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_emp, 'Carta') RETURNING id INTO v_cat;
    INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio)
    VALUES (v_emp, v_cat, 'BAJ-1', 'Hamburguesa', 20000) RETURNING id INTO v_burg;
    INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio)
    VALUES (v_emp, v_cat, 'BAJ-2', 'Gaseosa', 4000) RETURNING id INTO v_gas;
    INSERT INTO core.producto_unidades (producto_id, unidad_id) VALUES (v_burg, v_uni), (v_gas, v_uni);

    INSERT INTO core.categorias_insumo (empresa_id, nombre) VALUES (v_emp, 'Insumos');
    INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
    VALUES (v_emp, (SELECT id FROM core.categorias_insumo WHERE empresa_id = v_emp), v_area, v_um, 'I-PAN', 'Pan')
    RETURNING id INTO v_pan;
    INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
    VALUES (v_emp, (SELECT id FROM core.categorias_insumo WHERE empresa_id = v_emp), v_area, v_um, 'I-BOT', 'Botella')
    RETURNING id INTO v_bot;
    INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (v_pan, v_uni) RETURNING id INTO v_iu_pan;
    INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (v_bot, v_uni) RETURNING id INTO v_iu_bot;
    -- Cada hamburguesa gasta 1 pan; cada gaseosa, 1 botella
    INSERT INTO core.producto_insumos (producto_id, insumo_id, cantidad) VALUES (v_burg, v_pan, 1), (v_gas, v_bot, 1);

    INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
    VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'admin'), 'Admin', 'baja.admin', core.fn_hash_pin('1111'))
    RETURNING id INTO v_admin;

    v_hoy := core.fn_fecha_operativa(v_emp, now());

    /* Una factura con las dos cosas, entregada */
    CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_burg, 'cantidad', 1),
                                      jsonb_build_object('producto_id', v_gas,  'cantidad', 1)),
         p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
    SELECT id INTO v_it_burg FROM core.pedido_items WHERE pedido_id = v_ped AND producto_id = v_burg;
    SELECT id INTO v_it_gas  FROM core.pedido_items WHERE pedido_id = v_ped AND producto_id = v_gas;

    PERFORM core.fn_fijar_usuario(v_admin);
    UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'entregado') WHERE id = v_ped;

    -- Vendido: 1 pan y 1 botella
    ASSERT core.fn_z_insumo(v_iu_pan, v_hoy - 1, v_hoy) = 1
       AND core.fn_z_insumo(v_iu_bot, v_hoy - 1, v_hoy) = 1, 'La venta tiene que consumir 1 de cada uno';

    -- 1 · DANDO DE BAJA SÓLO LA HAMBURGUESA --------------------------------------------
    CALL api.sp_anular_pedido(v_ped, 'Al cliente se le cayó la hamburguesa', v_admin,
                              ARRAY[v_it_burg]::BIGINT[]);

    v_z_pan := core.fn_z_insumo(v_iu_pan, v_hoy - 1, v_hoy);
    v_z_bot := core.fn_z_insumo(v_iu_bot, v_hoy - 1, v_hoy);

    ASSERT v_z_pan = 1, format('El pan se perdió: sigue contando como consumido (salió %s)', v_z_pan);
    RAISE NOTICE '✔ 1  Lo dado de baja NO vuelve al inventario: el pan sigue contando como gastado';

    ASSERT v_z_bot = 0, format('La botella sí vuelve: deja de contar (salió %s)', v_z_bot);
    RAISE NOTICE '✔ 2  Lo que no se dio de baja SÍ vuelve: la botella deja de contar';

    RAISE NOTICE '✔ 3  En la misma factura conviven las dos cosas, y cada una hace lo suyo';

    -- 4 · QUEDA CONSTANCIA -------------------------------------------------------------
    SELECT count(*) INTO v_n
      FROM core.anulacion_items ai
      JOIN core.anulaciones a ON a.id = ai.anulacion_id
     WHERE a.pedido_id = v_ped;
    ASSERT v_n = 1, format('Tiene que quedar 1 producto dado de baja (hay %s)', v_n);

    SELECT h.descripcion INTO v_txt FROM core.pedido_historial h
     WHERE h.pedido_id = v_ped AND h.descripcion ILIKE '%ANULADA%' ORDER BY h.id DESC LIMIT 1;
    ASSERT v_txt ILIKE '%dado de baja%' AND v_txt ILIKE '%Hamburguesa%',
           format('El historial tiene que decir qué se perdió (dice: %s)', v_txt);
    RAISE NOTICE '✔ 4  Queda constancia: en anulacion_items y en el historial, con nombre y cantidad';

    -- 5 · NO SE PUEDE DAR DE BAJA LO DE OTRA FACTURA -----------------------------------
    PERFORM pg_temp.esperar_error(
        format('CALL api.sp_anular_pedido(%s, ''Prueba'', %s, ARRAY[%s]::BIGINT[])',
               v_ped, v_admin, v_it_burg),
        'ya está anulada');
    RAISE NOTICE '✔ 5  Una factura anulada sigue sin poder anularse dos veces';

    -- 6 · SIN LISTA, SE DEVUELVE TODO (como siempre) -----------------------------------
    CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_gas, 'cantidad', 3)),
         p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
    UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'entregado') WHERE id = v_ped;
    ASSERT core.fn_z_insumo(v_iu_bot, v_hoy - 1, v_hoy) = 3, 'Tres gaseosas, tres botellas';

    CALL api.sp_anular_pedido(v_ped, 'Se equivocaron de mesa', v_admin);
    ASSERT core.fn_z_insumo(v_iu_bot, v_hoy - 1, v_hoy) = 0,
           'Sin lista se devuelve todo: ninguna botella queda consumida';
    RAISE NOTICE '✔ 6  Anular sin elegir nada devuelve todo, igual que antes';

    -- 7 · UN PLATO DE OTRA FACTURA NO SE PUEDE DAR DE BAJA -----------------------------
    CALL api.sp_crear_pedido(p_unidad_id => v_uni, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_gas, 'cantidad', 1)),
         p_usuario_id => v_admin, p_mesa => '1', p_pedido_id => v_ped, p_codigo => v_cod);
    UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'entregado') WHERE id = v_ped;
    PERFORM pg_temp.esperar_error(
        format('CALL api.sp_anular_pedido(%s, ''Prueba de cruce'', %s, ARRAY[%s]::BIGINT[])',
               v_ped, v_admin, v_it_burg),
        'de esta misma factura');
    RAISE NOTICE '✔ 7  No se puede dar de baja un producto de otra factura';
END;
$$;

ROLLBACK;
