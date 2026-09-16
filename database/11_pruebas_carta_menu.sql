/* ============================================================================
   TASECA · 11 · PRUEBAS DE CARTA Y MENÚ DEL DÍA (fase 2, bloque 1)
   ----------------------------------------------------------------------------
   Ejecutar después de 11_fase2_carta_menu.sql. Todo corre como la aplicación
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

/* Simula el token de PostgREST para lo que sigue en la transacción. */
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

/* La petición corre como taseca_app, igual que desde PostgREST; las
   comprobaciones de después leen las tablas como dueño. */
CREATE FUNCTION pg_temp.sync(p_json TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v JSONB;
BEGIN
    SET LOCAL ROLE taseca_app;
    v := rest.sincronizar_catalogo(p_json::JSONB);
    RESET ROLE;
    RETURN v;
END;
$$;

GRANT EXECUTE ON FUNCTION pg_temp.esperar_error(TEXT, TEXT) TO taseca_anon;

SELECT pg_temp.token('admin');

DO $$
DECLARE
    v_ce INTEGER; v_bar INTEGER; v_com INTEGER; v_hoy DATE;
    v_cat INTEGER; v_prod INTEGER; v_prod2 INTEGER; v_menu BIGINT; v_menu2 BIGINT;
    v_sopa BIGINT; v_prin BIGINT; v_op1 BIGINT; v_op2 BIGINT; v_plato BIGINT; v_plato2 BIGINT;
    v_ped BIGINT; v_cod VARCHAR; v_r JSONB; v_txt TEXT;
BEGIN
    SELECT unidad_id INTO v_ce  FROM rest.unidades WHERE nombre = 'COMIC''ENDO AREPA';
    SELECT unidad_id INTO v_bar FROM rest.unidades WHERE nombre = 'NASCAR Bar VIP';
    SELECT unidad_id INTO v_com FROM rest.unidades WHERE nombre = 'NASCAR-Comidas';
    SELECT jornada_actual INTO v_hoy FROM rest.empresas WHERE codigo = 'empresa_nascar';

    -- 1 · CATEGORÍA NUEVA Y PRODUCTO NUEVO EN LA MISMA PETICIÓN -------------
    PERFORM pg_temp.sync(format($j${
        "categorias": [{"id": "cat-local1", "nombre": "Postres de prueba", "icono": "🍰", "orden": 900,
                        "activa": true, "sucursales": [%s]}],
        "productos":  [{"id": "xlocal1", "codigo": "", "cat": "cat-local1", "nombre": "Brownie de prueba",
                        "desc": "Con helado", "precio": 9000, "tag": "nuevo", "orden": 5, "activo": true,
                        "agotado": true, "sucursales": [%s], "imagen": ""}]
    }$j$, v_ce, v_ce));

    SELECT categoria_id INTO v_cat FROM rest.categorias WHERE nombre = 'Postres de prueba';
    SELECT producto_id INTO v_prod FROM rest.carta WHERE nombre = 'Brownie de prueba';
    ASSERT v_cat IS NOT NULL AND v_prod IS NOT NULL, 'Se crean la categoría y el producto';
    ASSERT (SELECT categoria_id FROM rest.carta WHERE producto_id = v_prod) = v_cat,
           'El producto queda en la categoría creada en la misma petición';
    ASSERT (SELECT codigo FROM rest.carta WHERE producto_id = v_prod) = 'P' || lpad(v_prod::TEXT, 4, '0'),
           'Sin código se genera uno';
    ASSERT (SELECT etiqueta FROM rest.carta WHERE producto_id = v_prod) = 'nuevo', 'Guarda la etiqueta';
    ASSERT (SELECT (unidades -> 0 ->> 'agotado')::BOOLEAN FROM rest.carta WHERE producto_id = v_prod),
           'Agotado queda en su unidad';
    RAISE NOTICE '✔ 1  Categoría y producto nuevos, código automático, etiqueta y agotado';

    -- 2 · EDITAR PRECIO, AGOTADO, CATEGORÍA COMPARTIDA ----------------------
    PERFORM pg_temp.sync(format($j${"productos": [{"id": "p%s", "codigo": "BRW-1", "cat": "c%s",
        "nombre": "Brownie de prueba", "precio": 9500, "tag": "", "orden": 5, "activo": true, "agotado": false,
        "sucursales": [%s]}]}$j$, v_prod, v_cat, v_ce));
    ASSERT (SELECT precio FROM rest.carta WHERE producto_id = v_prod) = 9500, 'Cambia el precio';
    ASSERT (SELECT codigo FROM rest.carta WHERE producto_id = v_prod) = 'BRW-1', 'Cambia el código';
    ASSERT NOT (SELECT (unidades -> 0 ->> 'agotado')::BOOLEAN FROM rest.carta WHERE producto_id = v_prod),
           'Vuelve a estar disponible';

    -- "Postres de prueba" nueva en el bar: se comparte, no se duplica
    PERFORM pg_temp.sync(format($j${"categorias": [{"id": "cat-local2", "nombre": "postres de prueba",
        "sucursales": [%s]}]}$j$, v_bar));
    ASSERT (SELECT count(*) FROM rest.categorias WHERE lower(nombre) = 'postres de prueba') = 1, 'No duplica la categoría';
    ASSERT (SELECT unidades FROM rest.categorias WHERE categoria_id = v_cat) @> ARRAY[v_ce, v_bar],
           'La categoría queda en las dos unidades';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.sync('{"productos": [{"id": "x2", "codigo": "brw-1",
        "cat": "c%s", "nombre": "Otro", "precio": 1, "sucursales": [%s]}]}')$s$, v_cat, v_ce), 'código BRW-1');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.sync('{"productos": [{"id": "x3", "cat": "c%s",
        "nombre": "Sin precio", "precio": -5, "sucursales": [%s]}]}')$s$, v_cat, v_ce), 'precio');
    RAISE NOTICE '✔ 2  Edición, categoría compartida por nombre, código repetido y precio inválido';

    -- 3 · TODO O NADA -------------------------------------------------------
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.sync('{
        "categorias": [{"id": "cat-x", "nombre": "No debe quedar", "sucursales": [%s]}],
        "productos":  [{"id": "x4", "cat": "cat-x", "nombre": "Malo", "precio": 1, "tag": "no-existe", "sucursales": [%s]}]}')$s$,
        v_ce, v_ce), 'no existe');
    ASSERT NOT EXISTS (SELECT 1 FROM rest.categorias WHERE nombre = 'No debe quedar'),
           'Si una parte falla, no se guarda nada';
    RAISE NOTICE '✔ 3  Una petición con un error no deja nada a medias';

    -- 4 · BORRAR: SIN VENTAS SE ELIMINA, CON VENTAS SE OCULTA -----------------
    PERFORM pg_temp.sync(format($j${"productos": [{"id": "xlocal5", "cat": "c%s", "nombre": "Para vender",
        "precio": 3000, "sucursales": [%s]}]}$j$, v_cat, v_ce));
    SELECT producto_id INTO v_prod2 FROM rest.carta WHERE nombre = 'Para vender';

    SELECT (r ->> 'pedido_id')::BIGINT INTO v_ped
      FROM rest.crear_pedido(v_ce, 'mesa', 'efectivo', format('[{"producto_id": %s, "cantidad": 1}]', v_prod2)::JSONB,
                             p_mesa => '1') r;
    ASSERT v_ped IS NOT NULL, 'Se vende el producto';

    v_r := pg_temp.sync(format('{"productos_borrados": ["p%s", "p%s"]}', v_prod, v_prod2));
    ASSERT NOT EXISTS (SELECT 1 FROM rest.carta WHERE producto_id = v_prod), 'Sin ventas se elimina';
    ASSERT (SELECT NOT activo FROM rest.carta WHERE producto_id = v_prod2), 'Con ventas se oculta';
    ASSERT v_r -> 'desactivados' = format('["p%s"]', v_prod2)::JSONB, 'Avisa cuáles se ocultaron';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.sync('{"categorias_borradas": ["c%s"]}')$s$, v_cat),
                                  'hay 1 productos');
    RAISE NOTICE '✔ 4  Borrar producto: eliminado si no se vendió, oculto si se vendió; categoría con productos no se borra';

    -- 5 · MENÚ ARMADO NUEVO ---------------------------------------------------
    PERFORM pg_temp.sync(format($j${"menus": [{"id": "local-m1", "sucursalId": %s, "fecha": "%s", "tipo": "armado",
        "publico": {"titulo": "Hoy", "mensaje": ""},
        "armado": {"nombre": "Ejecutivo", "descripcion": "", "precio": 18000, "disponible": true, "categorias": [
            {"id": "k1", "nombre": "Sopa", "icono": "🥣", "obligatoria": true, "maxSeleccion": 1, "activa": true,
             "opciones": [{"id": "o1", "nombre": "Sancocho", "activa": true}, {"id": "o2", "nombre": "Ajiaco", "activa": true}]},
            {"id": "k2", "nombre": "Principio", "icono": "", "obligatoria": true, "maxSeleccion": 2, "activa": true,
             "opciones": [{"id": "o3", "nombre": "Frijoles", "activa": true}]}]}}]}$j$, v_com, v_hoy + 3));

    SELECT menu_dia_id INTO v_menu FROM rest.menus_dia WHERE unidad_id = v_com AND fecha = v_hoy + 3;
    ASSERT (SELECT tipo FROM rest.menus_dia WHERE menu_dia_id = v_menu) = 'armado', 'Se crea el menú armado';
    ASSERT (SELECT precio FROM rest.menus_dia WHERE menu_dia_id = v_menu) = 18000, 'Con su precio';
    ASSERT (SELECT jsonb_array_length(categorias) FROM rest.menus_dia WHERE menu_dia_id = v_menu) = 2, 'Dos categorías';
    SELECT id INTO v_sopa FROM core.menu_categorias WHERE menu_dia_id = v_menu AND nombre = 'Sopa';
    SELECT id INTO v_prin FROM core.menu_categorias WHERE menu_dia_id = v_menu AND nombre = 'Principio';
    SELECT id INTO v_op1 FROM core.menu_opciones WHERE menu_categoria_id = v_sopa AND nombre = 'Sancocho';
    SELECT id INTO v_op2 FROM core.menu_opciones WHERE menu_categoria_id = v_sopa AND nombre = 'Ajiaco';
    ASSERT (SELECT max_seleccion FROM core.menu_categorias WHERE id = v_prin) = 2, 'Guarda cuántas se eligen';
    RAISE NOTICE '✔ 5  Menú armado nuevo con categorías y opciones';

    -- 6 · EDITAR: ORDEN, RENOMBRAR, AGREGAR Y QUITAR --------------------------
    PERFORM pg_temp.sync(format($j${"menus": [{"id": "m%s", "sucursalId": %s, "fecha": "%s", "tipo": "armado",
        "publico": {"titulo": "", "mensaje": ""},
        "armado": {"nombre": "Ejecutivo", "precio": 19000, "disponible": true, "categorias": [
            {"id": "mc%s", "nombre": "Principio", "maxSeleccion": 2, "activa": true,
             "opciones": [{"id": "nueva", "nombre": "Lentejas", "activa": true}]},
            {"id": "mc%s", "nombre": "Sopa", "maxSeleccion": 1, "activa": false,
             "opciones": [{"id": "mo%s", "nombre": "Ajiaco santafereño", "activa": true}]}]}}]}$j$,
        v_menu, v_com, v_hoy + 3, v_prin, v_sopa, v_op2));

    ASSERT (SELECT orden FROM core.menu_categorias WHERE id = v_prin) = 1
       AND (SELECT orden FROM core.menu_categorias WHERE id = v_sopa) = 2, 'Cambia el orden de las categorías';
    ASSERT (SELECT NOT activa FROM core.menu_categorias WHERE id = v_sopa), 'Desactiva la categoría';
    ASSERT NOT EXISTS (SELECT 1 FROM core.menu_opciones WHERE id = v_op1), 'Quita la opción que ya no está';
    ASSERT (SELECT nombre FROM core.menu_opciones WHERE id = v_op2) = 'Ajiaco santafereño', 'Renombra';
    ASSERT (SELECT string_agg(nombre, ',' ORDER BY orden) FROM core.menu_opciones WHERE menu_categoria_id = v_prin) = 'Lentejas',
           'Frijoles se quitó y Lentejas se agregó';
    ASSERT (SELECT precio FROM core.menus_dia WHERE id = v_menu) = 19000, 'Cambia el precio';
    RAISE NOTICE '✔ 6  Editar el menú: orden, activar, renombrar, agregar y quitar';

    -- 7 · PROTECCIONES DEL MENÚ ----------------------------------------------
    -- Otro navegador intenta crear un menú para un día que ya lo tiene
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.sync('{"menus": [{"id": "otro", "sucursalId": %s,
        "fecha": "%s", "tipo": "chef", "armado": {"categorias": []}}]}')$s$, v_com, v_hoy + 3), 'ya tiene un menú');
    ASSERT (SELECT count(*) FROM core.menu_categorias WHERE menu_dia_id = v_menu) = 2, 'Y no se borró nada';

    -- Copiar a otro día: los ids del día de origen crean categorías NUEVAS
    PERFORM pg_temp.sync(format($j${"menus": [{"id": "copia", "sucursalId": %s, "fecha": "%s", "tipo": "armado",
        "armado": {"nombre": "Ejecutivo", "precio": 19000, "categorias": [
            {"id": "mc%s", "nombre": "Principio", "opciones": [{"id": "mo%s", "nombre": "Lentejas"}]}]}}]}$j$,
        v_com, v_hoy + 4, v_prin, v_op2));
    SELECT menu_dia_id INTO v_menu2 FROM rest.menus_dia WHERE unidad_id = v_com AND fecha = v_hoy + 4;
    ASSERT (SELECT count(*) FROM core.menu_categorias WHERE menu_dia_id = v_menu2) = 1, 'La copia tiene su categoría';
    ASSERT (SELECT count(*) FROM core.menu_categorias WHERE menu_dia_id = v_menu) = 2, 'El original sigue intacto';
    RAISE NOTICE '✔ 7  Un menú ajeno no se pisa y copiar no mueve las categorías del original';

    -- 8 · PLATOS DEL CHEF ------------------------------------------------------
    PERFORM pg_temp.sync(format($j${"platos": [
        {"id": "loc1", "sucursalId": %1$s, "fecha": "%2$s", "nombre": "Bandeja paisa", "desc": "Completa",
         "emoji": "🍛", "precio": 22000, "cupos": 10, "disponible": true, "orden": 1,
         "sopa": "Sancocho", "bebida": "Limonada"},
        {"id": "loc2", "sucursalId": %1$s, "fecha": "%2$s", "nombre": "Mojarra", "precio": 25000, "cupos": null,
         "disponible": true, "orden": 2}]}$j$, v_com, v_hoy + 6));
    ASSERT (SELECT tipo FROM rest.menus_dia WHERE unidad_id = v_com AND fecha = v_hoy + 6) = 'chef',
           'El primer plato crea el menú del chef';
    SELECT plato_dia_id INTO v_plato  FROM api.v_platos_dia WHERE unidad_id = v_com AND fecha = v_hoy + 6 AND nombre = 'Bandeja paisa';
    SELECT plato_dia_id INTO v_plato2 FROM api.v_platos_dia WHERE unidad_id = v_com AND fecha = v_hoy + 6 AND nombre = 'Mojarra';
    ASSERT (SELECT p ->> 'sopa' FROM rest.menus_dia m, jsonb_array_elements(m.platos) p
             WHERE m.unidad_id = v_com AND m.fecha = v_hoy + 6 AND p ->> 'nombre' = 'Bandeja paisa') = 'Sancocho',
           'Guarda y publica qué incluye el plato';

    PERFORM pg_temp.sync(format($j${"platos": [
        {"id": "d%s", "sucursalId": %s, "fecha": "%s", "nombre": "Bandeja paisa", "precio": 23000, "cupos": 10, "disponible": false, "orden": 2},
        {"id": "d%s", "sucursalId": %s, "fecha": "%s", "nombre": "Mojarra", "precio": 25000, "disponible": true, "orden": 1}]}$j$,
        v_plato, v_com, v_hoy + 6, v_plato2, v_com, v_hoy + 6));
    ASSERT (SELECT orden FROM core.platos_dia WHERE id = v_plato2) = 1, 'Cambia el orden';
    ASSERT (SELECT precio FROM core.platos_dia WHERE id = v_plato) = 23000
       AND (SELECT NOT disponible FROM core.platos_dia WHERE id = v_plato), 'Cambia precio y disponibilidad';

    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.sync('{"platos": [{"id": "loc3", "sucursalId": %s,
        "fecha": "%s", "nombre": "Gratis", "precio": 0}]}')$s$, v_com, v_hoy + 6), 'mayor a cero');

    PERFORM pg_temp.sync(format('{"platos_borrados": ["d%s"]}', v_plato2));
    ASSERT NOT EXISTS (SELECT 1 FROM core.platos_dia WHERE id = v_plato2), 'Plato sin ventas se elimina';

    -- Un plato de hoy que se vende ya no se puede borrar
    SELECT plato_dia_id INTO v_plato FROM api.v_platos_dia WHERE unidad_id = v_com AND fecha = v_hoy LIMIT 1;
    IF v_plato IS NOT NULL THEN
        PERFORM rest.crear_pedido(v_com, 'mesa', 'efectivo', format('[{"plato_dia_id": %s, "cantidad": 1}]', v_plato)::JSONB,
                                  p_mesa => '1');
        PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.sync('{"platos_borrados": ["d%s"]}')$s$, v_plato), 'ya se vendió');
    END IF;
    RAISE NOTICE '✔ 8  Platos del chef: crear, ordenar, editar, precio en cero bloqueado, borrar; vendido no se borra';

    -- 9 · TEXTO DE LA UNIDAD ----------------------------------------------------
    PERFORM pg_temp.sync(format($j${"menus": [{"id": "mt%s", "sucursalId": %s, "fecha": "*", "tipo": "texto",
        "publico": {"titulo": "Almuerzos NASCAR", "mensaje": "De 12 a 3"}}]}$j$, v_com, v_com));
    ASSERT (SELECT titulo FROM rest.textos_menu WHERE unidad_id = v_com) = 'Almuerzos NASCAR', 'Guarda el texto de la unidad';
    RAISE NOTICE '✔ 9  Título y mensaje de la unidad';
END;
$$;

-- 10 · SEGURIDAD ---------------------------------------------------------------
DO $$
DECLARE
    v_com INTEGER := (SELECT unidad_id FROM rest.unidades WHERE nombre = 'NASCAR-Comidas');
    v_hoy DATE := (SELECT jornada_actual FROM rest.empresas WHERE codigo = 'empresa_nascar');
BEGIN
    -- El cocinero no publica menú
    PERFORM pg_temp.token('cocina');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.sync('{"platos": [{"id": "z", "sucursalId": %s,
        "fecha": "%s", "nombre": "Intruso", "precio": 1000}]}')$s$, v_com, v_hoy + 8), 'permiso');

    -- Un token con otra empresa no toca las unidades de NASCAR
    PERFORM pg_temp.token('admin', 999999);
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.sync('{"platos": [{"id": "z", "sucursalId": %s,
        "fecha": "%s", "nombre": "Intruso", "precio": 1000}]}')$s$, v_com, v_hoy + 8), 'no es de esta empresa');

    -- Sin sesión
    PERFORM set_config('request.jwt.claims', '', TRUE);
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.sync('{}')$s$, 'iniciar sesión');
    RAISE NOTICE '✔ 10 Seguridad: permiso del rol, empresa del token y sesión obligatoria';
END;
$$;

RESET ROLE;
SET LOCAL ROLE taseca_anon;
SELECT pg_temp.esperar_error($s$SELECT rest.sincronizar_catalogo('{}')$s$, 'permission denied');
RESET ROLE;

ROLLBACK;
