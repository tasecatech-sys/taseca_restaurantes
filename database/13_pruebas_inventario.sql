/* ============================================================================
   TASECA · 13 · PRUEBAS DE STOCK, ENTRADAS Y CIERRES (fase 2, bloque 3)
   ----------------------------------------------------------------------------
   Ejecutar después de 13_fase2_inventario.sql. Todo corre como la aplicación
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

/* Ejecuta como taseca_app, igual que PostgREST, y devuelve el resultado. */
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

CREATE FUNCTION pg_temp.fila(p_cruce JSONB, p_codigo TEXT)
RETURNS JSONB
LANGUAGE sql
AS $$ SELECT f FROM jsonb_array_elements(p_cruce -> 'filas') f WHERE f ->> 'codigo' = p_codigo; $$;

DO $$
DECLARE
    v_bar INTEGER; v_com INTEGER; v_hoy DATE; p_cerveza INTEGER;
    v_insumo INTEGER; v_r JSONB; v_e1 BIGINT; v_e2 BIGINT; v_cierre_ayer BIGINT; v_cierre_hoy BIGINT;
    v_ped BIGINT; v_cruce JSONB; v_f JSONB; v_stock NUMERIC;
    v_admin INTEGER := (SELECT id FROM core.usuarios WHERE usuario = 'admin');
BEGIN
    SELECT id INTO v_bar FROM core.unidades WHERE nombre = 'NASCAR Bar VIP';
    SELECT id INTO v_com FROM core.unidades WHERE nombre = 'NASCAR-Comidas';
    SELECT jornada_actual INTO v_hoy FROM api.v_empresas WHERE codigo = 'empresa_nascar';
    SELECT producto_id INTO p_cerveza FROM api.v_carta WHERE unidad_id = v_bar AND codigo = 'BR01';

    PERFORM pg_temp.token('admin');

    -- 1 · STOCK: CREAR Y EDITAR --------------------------------------------------
    v_r := pg_temp.app(format($s$SELECT rest.guardar_insumo('{"codigo": " prb-01 ", "nombre": "Cerveza de prueba",
        "categoria": "Pruebas 13", "area": "bar", "unidad": "Lata", "activo": true, "stock_actual": 10,
        "stock_minimo": 5, "unidades": [%s], "productos": [%s]}')$s$, v_bar, p_cerveza));
    v_insumo := (v_r ->> 'insumo_id')::INTEGER;
    ASSERT (SELECT codigo FROM core.insumos WHERE id = v_insumo) = 'PRB-01', 'Código en mayúsculas y sin espacios';
    ASSERT (SELECT nombre FROM core.categorias_insumo WHERE id = (SELECT categoria_insumo_id FROM core.insumos WHERE id = v_insumo)) = 'Pruebas 13',
           'Crea la categoría';
    ASSERT (SELECT um.codigo FROM core.unidades_medida um JOIN core.insumos i ON i.unidad_medida_id = um.id WHERE i.id = v_insumo) = 'lata',
           'Crea la unidad de conteo';
    ASSERT (SELECT stock_actual FROM core.insumo_unidades WHERE insumo_id = v_insumo AND unidad_id = v_bar) = 10, 'Stock 10';
    ASSERT EXISTS (SELECT 1 FROM core.producto_insumos WHERE insumo_id = v_insumo AND producto_id = p_cerveza), 'Se vende como BR01';

    PERFORM pg_temp.app(format($s$SELECT rest.guardar_insumo('{"insumo_id": %s, "codigo": "PRB-1", "nombre": "Cerveza de prueba",
        "categoria": "Pruebas 13", "area": "bar", "unidad": "lata", "stock_minimo": 6, "unidades": [%s]}')$s$, v_insumo, v_bar));
    ASSERT (SELECT codigo FROM core.insumos WHERE id = v_insumo) = 'PRB-1', 'Cambia el código';
    ASSERT (SELECT stock_actual FROM core.insumo_unidades WHERE insumo_id = v_insumo) = 10, 'Sin stock_actual no lo toca';
    ASSERT EXISTS (SELECT 1 FROM core.producto_insumos WHERE insumo_id = v_insumo), 'Sin productos no toca el enlace con la carta';

    PERFORM pg_temp.app(format($s$SELECT rest.ajustar_stock(%s, 'prb-1', 12)$s$, v_bar));
    ASSERT (SELECT stock_actual FROM core.insumo_unidades WHERE insumo_id = v_insumo) = 12, 'Ajuste manual a 12';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_insumo(''{"codigo": "BAR-01", "nombre": "Otro",
        "area": "bar", "unidades": [%s]}'')')$s$, v_bar), 'Ya existe otro producto con el código BAR-01');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.ajustar_stock(%s, ''PRB-1'', -1)')$s$, v_bar), 'entero');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.ajustar_stock(%s, ''PRB-1'', 2.5)')$s$, v_bar), 'entero');
    RAISE NOTICE '✔ 1  Stock: crear con categoría y unidad nuevas, enlazar con la carta, editar, ajustar; código repetido y cantidades inválidas';

    -- 2 · ENTRADAS: REGISTRAR, CORREGIR, ELIMINAR ------------------------------------
    v_r := pg_temp.app(format($s$SELECT rest.registrar_entrada('{"unidad_id": %s, "codigo": "PRB-1", "tipo": "compra",
        "cantidad": 24, "observacion": "Canasta", "fecha": "%s"}')$s$, v_bar, v_hoy));
    v_e1 := (v_r ->> 'entrada_id')::BIGINT;
    ASSERT (SELECT stock_actual FROM core.insumo_unidades WHERE insumo_id = v_insumo) = 36, 'La entrada suma: 12 + 24';

    v_r := pg_temp.app(format($s$SELECT rest.corregir_entrada(%s, '{"cantidad": 20}')$s$, v_e1));
    v_e2 := (v_r ->> 'entrada_id')::BIGINT;
    ASSERT v_e2 <> v_e1 AND (v_r ->> 'cantidad')::NUMERIC = 20 AND v_r ->> 'observacion' = 'Canasta', 'La corrección conserva lo demás';
    ASSERT (SELECT anulada_en IS NOT NULL AND motivo_anulacion LIKE 'Corregida%' FROM core.entradas_inventario WHERE id = v_e1),
           'La original queda anulada, no borrada';
    ASSERT (SELECT stock_actual FROM core.insumo_unidades WHERE insumo_id = v_insumo) = 32, 'Stock 12 + 20';
    ASSERT NOT EXISTS (SELECT 1 FROM rest.entradas WHERE entrada_id = v_e1), 'La anulada ya no se lista';

    PERFORM pg_temp.app(format('SELECT rest.anular_entrada(%s)', v_e2));
    ASSERT (SELECT stock_actual FROM core.insumo_unidades WHERE insumo_id = v_insumo) = 12, 'Eliminar la devuelve a 12';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.anular_entrada(%s)')$s$, v_e2), 'ya estaba eliminada');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_entrada(''{"unidad_id": %s,
        "codigo": "PRB-1", "cantidad": 2.5, "fecha": "%s"}'')')$s$, v_bar, v_hoy), 'entero mayor que cero');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_entrada(''{"unidad_id": %s,
        "codigo": "PRB-1", "cantidad": 1, "fecha": "%s"}'')')$s$, v_bar, v_hoy + 1), 'futura');
    PERFORM pg_temp.esperar_error(format('UPDATE core.entradas_inventario SET cantidad = 1 WHERE id = %s', v_e2), 'no se modifican');
    PERFORM pg_temp.esperar_error(format('DELETE FROM core.entradas_inventario WHERE id = %s', v_e2), 'no se modifican');
    RAISE NOTICE '✔ 2  Entradas: suman al stock; corregir = anular + nueva; eliminar = anular; nunca se editan ni borran de verdad';

    -- 3 · CIERRE DE AYER: BORRADOR, YA_EXISTE Y COMPLETAR ---------------------------
    v_r := pg_temp.app(format($s$SELECT rest.registrar_cierre('{"unidad_id": %s, "area": "bar", "fecha": "%s",
        "estado": "borrador", "productos": [{"codigo": "PRB-1", "saldo": 10}, {"codigo": "BAR-01", "saldo": 0}], "nuevo": true}')$s$,
        v_bar, v_hoy - 1));
    v_cierre_ayer := (v_r ->> 'cierre_id')::BIGINT;
    ASSERT v_r ->> 'estado' = 'borrador' AND jsonb_array_length(v_r -> 'productos') = 2, 'Borrador con dos productos';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.revisar_cierre(%s)')$s$, v_cierre_ayer), 'borrador');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_cierre(''{"unidad_id": %s, "area": "bar",
        "fecha": "%s", "productos": [{"codigo": "PRB-1", "saldo": 1}], "nuevo": true}'')')$s$, v_bar, v_hoy - 1), 'YA_EXISTE');

    -- Corregir: el conteo nuevo reemplaza (BAR-01 sale del cierre)
    v_r := pg_temp.app(format($s$SELECT rest.registrar_cierre('{"unidad_id": %s, "area": "bar", "fecha": "%s",
        "estado": "completado", "observacion": "Conteo completo", "productos": [{"codigo": "PRB-1", "saldo": 10}]}')$s$, v_bar, v_hoy - 1));
    ASSERT v_r ->> 'estado' = 'completado' AND jsonb_array_length(v_r -> 'productos') = 1, 'Completo, con el conteo nuevo';
    v_r := pg_temp.app(format($s$SELECT rest.registrar_cierre('{"unidad_id": %s, "area": "bar", "fecha": "%s",
        "estado": "borrador", "productos": [{"codigo": "PRB-1", "saldo": 10}]}')$s$, v_bar, v_hoy - 1));
    ASSERT v_r ->> 'estado' = 'completado', 'Lo completado no vuelve a borrador';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_cierre(''{"unidad_id": %s, "area": "bar",
        "fecha": "%s", "productos": [{"codigo": "PRB-1", "saldo": 1}]}'')')$s$, v_bar, v_hoy + 1), 'todavía no llega');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_cierre(''{"unidad_id": %s, "area": "comidas",
        "fecha": "%s", "productos": [{"codigo": "PRB-1", "saldo": 1}]}'')')$s$, v_bar, v_hoy), 'ni de esta área');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_cierre(''{"unidad_id": %s, "area": "bar",
        "fecha": "%s", "productos": [{"codigo": "PRB-1", "saldo": 1.5}]}'')')$s$, v_bar, v_hoy), 'entero');
    RAISE NOTICE '✔ 3  Cierres: borrador, YA_EXISTE, corrección que reemplaza, completado no retrocede; fecha futura, área y saldo inválidos';

    -- 4 · CRUCE DE HOY ----------------------------------------------------------------
    PERFORM pg_temp.app(format($s$SELECT rest.registrar_entrada('{"unidad_id": %s, "codigo": "PRB-1", "cantidad": 24, "fecha": "%s"}')$s$,
        v_bar, v_hoy));
    SELECT (r ->> 'pedido_id')::BIGINT INTO v_ped
      FROM rest.crear_pedido(v_bar, 'mesa', 'efectivo', format('[{"producto_id": %s, "cantidad": 3}]', p_cerveza)::JSONB, p_mesa => '2') r;

    v_cruce := pg_temp.app(format($s$SELECT rest.cruce_inventario(%s, '%s', 'bar')$s$, v_bar, v_hoy));
    v_f := pg_temp.fila(v_cruce, 'PRB-1');
    ASSERT (v_f ->> 'IN')::NUMERIC = 10 AND v_f ->> 'origenIN' = 'cierre' AND (v_f ->> 'EN')::NUMERIC = 24
       AND (v_f ->> 'Z')::NUMERIC = 3 AND NOT (v_f ->> 'registrado')::BOOLEAN AND v_f -> 'SD' = 'null',
           format('Antes de contar: IN 10 · EN 24 · Z 3 · sin SD (salió %s)', v_f);
    ASSERT v_cruce -> 'cierre' = 'null' AND v_cruce -> 'cierre_anterior' ->> 'fecha' = (v_hoy - 1)::TEXT, 'Sin cierre hoy; anterior ayer';
    ASSERT jsonb_array_length(v_cruce -> 'filas') > 1, 'Trae todo el catálogo del área, no sólo lo contado';

    v_r := pg_temp.app(format($s$SELECT rest.registrar_cierre('{"unidad_id": %s, "area": "bar", "fecha": "%s",
        "productos": [{"codigo": "PRB-1", "saldo": 30}], "nuevo": true}')$s$, v_bar, v_hoy));
    v_cierre_hoy := (v_r ->> 'cierre_id')::BIGINT;
    v_f := pg_temp.fila(pg_temp.app(format($s$SELECT rest.cruce_inventario(%s, '%s', 'bar')$s$, v_bar, v_hoy)), 'PRB-1');
    ASSERT (v_f ->> 'SD')::NUMERIC = 30 AND (v_f ->> 'registrado')::BOOLEAN, 'SD 30 contado';
    ASSERT (SELECT diferencia FROM api.v_cruce_inventario WHERE cierre_id = v_cierre_hoy AND codigo = 'PRB-1') = 1,
           'La vista coincide: 10 + 24 − 3 − 30 = 1 faltante';

    -- Un producto nunca contado toma su IN del stock registrado antes de hoy
    v_f := pg_temp.fila(pg_temp.app(format($s$SELECT rest.cruce_inventario(%s, '%s', 'bar')$s$, v_bar, v_hoy)), 'BAR-02');
    ASSERT v_f ->> 'origenIN' IN ('stock', 'sin-dato') AND v_f -> 'fuenteIN' = 'null', 'Sin conteo previo: IN del stock o sin dato';
    RAISE NOTICE '✔ 4  Cruce de todo el catálogo: IN del cierre anterior, EN, Z por la carta, SD; coincide con la vista';

    -- 5 · REVISAR: TODO QUEDA CONGELADO -------------------------------------------------
    PERFORM pg_temp.app(format('SELECT rest.revisar_cierre(%s)', v_cierre_hoy));
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_cierre(''{"unidad_id": %s, "area": "bar",
        "fecha": "%s", "productos": [{"codigo": "PRB-1", "saldo": 31}]}'')')$s$, v_bar, v_hoy), 'ya fue revisado');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.anular_entrada(%s)')$s$,
        (SELECT id FROM core.entradas_inventario WHERE insumo_unidad_id = (SELECT id FROM core.insumo_unidades WHERE insumo_id = v_insumo)
            AND anulada_en IS NULL AND fecha_operativa = v_hoy LIMIT 1)), 'congeladas');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.revisar_cierre(%s)')$s$, v_cierre_hoy), 'ya estaba revisado');
    RAISE NOTICE '✔ 5  Cierre revisado: no se corrige, sus entradas se congelan';

    -- 6 · ANULAR UNA VENTA DE UN DÍA YA CERRADO -------------------------------------------
    CALL api.sp_anular_pedido(v_ped, 'Devolvieron las cervezas', v_admin);
    v_f := pg_temp.fila(pg_temp.app(format($s$SELECT rest.cruce_inventario(%s, '%s', 'bar')$s$, v_bar, v_hoy)), 'PRB-1');
    ASSERT (v_f ->> 'Z')::NUMERIC = 3, 'El cruce del día cerrado NO cambia: Z sigue en 3';
    ASSERT (SELECT ventas FROM api.v_cruce_inventario WHERE cierre_id = v_cierre_hoy AND codigo = 'PRB-1') = 3, 'Tampoco en la vista';
    v_f := pg_temp.fila(pg_temp.app(format($s$SELECT rest.cruce_inventario(%s, '%s', 'bar')$s$, v_bar, v_hoy + 1)), 'PRB-1');
    ASSERT (v_f ->> 'IN')::NUMERIC = 30 AND (v_f ->> 'EN')::NUMERIC = 3 AND (v_f ->> 'Z')::NUMERIC = 0,
           format('Mañana: IN 30 (conteo de hoy) + EN 3 (retorno) (salió %s)', v_f);
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.anular_entrada(%s)')$s$,
        (SELECT id FROM core.entradas_inventario WHERE pedido_id = v_ped LIMIT 1)), 'genera el sistema');
    RAISE NOTICE '✔ 6  Anular venta de un día cerrado: ese cruce no cambia y la mercancía vuelve mañana, una sola vez';

    -- 7 · APLICAR SALDOS AL STOCK Y CAMBIO DE ÁREA -------------------------------------------
    ASSERT pg_temp.app(format('SELECT to_jsonb(rest.aplicar_cierre_a_stock(%s))', v_cierre_hoy))::TEXT::INTEGER = 1, 'Un producto aplicado';
    v_stock := (SELECT stock_actual FROM core.insumo_unidades WHERE insumo_id = v_insumo);
    ASSERT v_stock = 30, format('El stock pasa a lo contado (salió %s)', v_stock);
    PERFORM pg_temp.app(format('SELECT to_jsonb(rest.aplicar_cierre_a_stock(%s))', v_cierre_hoy));  -- otra vez: no falla
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.guardar_insumo(''{"insumo_id": %s, "codigo": "PRB-1",
        "nombre": "Cerveza de prueba", "area": "comidas", "unidades": [%s]}'')')$s$, v_insumo, v_bar), 'no puede cambiar de área');
    RAISE NOTICE '✔ 7  Aplicar saldos al stock (repetible) y producto contado sin cambio de área';

    -- 8 · SEGURIDAD --------------------------------------------------------------------------
    PERFORM pg_temp.token('mesero');   -- trabaja en NASCAR-Comidas
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.cierres WHERE area = ''bar''')::TEXT::INTEGER = 0,
           'El mesero de Comidas no ve los cierres del bar';
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.registrar_cierre(''{"unidad_id": %s, "area": "bar",
        "fecha": "%s", "productos": [{"codigo": "PRB-1", "saldo": 1}]}'')')$s$, v_bar, v_hoy - 2), 'no trabaja en la unidad');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_insumo(''{"codigo": "X1", "nombre": "Intruso",
        "area": "comidas", "unidades": []}'')')$s$, 'permiso "stock"');

    PERFORM pg_temp.token('caja');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.cruce_inventario(%s, ''%s'', ''bar'')')$s$, v_bar, v_hoy),
        'No trabajas en esa unidad');

    PERFORM pg_temp.token('cocina');
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.stock')::TEXT::INTEGER = 0, 'Cocina no ve el inventario';
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.cruce_inventario(%s, ''%s'', ''comidas'')')$s$, v_com, v_hoy),
        'no puede ver el cruce');

    PERFORM pg_temp.token('admin', 999999);
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.stock')::TEXT::INTEGER = 0, 'Token de otra empresa: nada';
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.app('SELECT rest.anular_entrada(%s)')$s$, v_e2), 'No se encontró la entrada');
    RAISE NOTICE '✔ 8  Seguridad: unidad del usuario, permisos del rol y empresa del token';
END;
$$;

SET LOCAL ROLE taseca_anon;
SELECT pg_temp.esperar_error($s$SELECT count(*) FROM rest.stock$s$, 'permission denied');
SELECT pg_temp.esperar_error($s$SELECT rest.registrar_cierre('{}')$s$, 'permission denied');
RESET ROLE;

ROLLBACK;
