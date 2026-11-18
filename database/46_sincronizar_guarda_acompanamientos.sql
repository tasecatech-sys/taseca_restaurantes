/* ============================================================================
   46 · EL PANEL GUARDA EL INTERRUPTOR DE ACOMPAÑAMIENTOS

   La 45 abrió que el menú del chef pida acompañamientos (columna
   core.menus_dia.pide_acompanamientos). Faltaba que el PANEL pudiera
   prenderlo/apagarlo: el panel guarda el menú con rest.sincronizar_catalogo,
   que no tocaba ese campo.

   Esta migración es la MISMA rest.sincronizar_catalogo de producción, con un
   solo agregado: tras guardar cada menú, si el documento trae el campo
   `pideAcompanamientos`, se escribe en la columna. El `IF r ? …` es a
   propósito: un cliente viejo (que no manda el campo) NO apaga el flag.

   Los grupos (Entrada, Bebida…) ya se guardaban por esta misma función: son
   las mismas menu_categorias/menu_opciones del menú armado, y el panel reusa
   su editor. Aquí sólo se añade el interruptor.

   Idempotente. Requiere: la 45 (columna pide_acompanamientos).
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.sincronizar_catalogo(p_cambios jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'public'
AS $function$
DECLARE
    v_usuario      INTEGER := core.fn_exigir_sesion();
    v_empresa      INTEGER := core.fn_jwt_empresa();
    r              JSONB;
    a              JSONB;
    c              JSONB;
    o              JSONB;
    k              INTEGER;
    k2             INTEGER;
    v_txt          TEXT;
    v_int          INTEGER;
    v_big          BIGINT;
    v_flag         BOOLEAN;
    v_unidades     INTEGER[];
    v_unidad       INTEGER;
    v_fecha        DATE;
    v_menu         BIGINT;
    v_existente    BIGINT;
    v_cat_menu     BIGINT;
    v_mapa_cat     JSONB := '{}';
    v_desactivados JSONB := '[]';
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    p_cambios := COALESCE(p_cambios, '{}');

    /* ---- 1. Categorías de la carta ---- */
    FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_cambios -> 'categorias', '[]')) LOOP
        v_int := core.fn_id_de_app(r ->> 'id', 'c');
        v_unidades := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(COALESCE(r -> 'sucursales', '[]')) x);
        CALL api.sp_guardar_categoria(
            p_empresa_id => v_empresa, p_nombre => r ->> 'nombre', p_unidades => v_unidades,
            p_usuario_id => v_usuario, p_icono => r ->> 'icono',
            p_orden => round(NULLIF(r ->> 'orden', '')::NUMERIC)::INTEGER,
            p_activa => COALESCE((r ->> 'activa')::BOOLEAN, TRUE), p_categoria_id => v_int);
        v_mapa_cat := v_mapa_cat || jsonb_build_object(r ->> 'id', v_int);
    END LOOP;

    /* ---- 2. Productos ---- */
    FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_cambios -> 'productos', '[]')) LOOP
        v_int := core.fn_id_de_app(r ->> 'id', 'p');
        v_unidades := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(COALESCE(r -> 'sucursales', '[]')) x);
        CALL api.sp_guardar_producto(
            p_empresa_id   => v_empresa,
            p_categoria_id => COALESCE((v_mapa_cat ->> (r ->> 'cat'))::INTEGER, core.fn_id_de_app(r ->> 'cat', 'c')::INTEGER),
            p_codigo       => r ->> 'codigo',
            p_nombre       => r ->> 'nombre',
            p_precio       => NULLIF(r ->> 'precio', '')::NUMERIC,
            p_unidades     => v_unidades,
            p_usuario_id   => v_usuario,
            p_descripcion  => r ->> 'desc',
            p_etiqueta     => r ->> 'tag',
            p_activo       => COALESCE((r ->> 'activo')::BOOLEAN, TRUE),
            p_orden        => round(NULLIF(r ->> 'orden', '')::NUMERIC)::INTEGER,
            p_imagen_url   => r ->> 'imagen',
            -- Si no viene, se prepara: una carta que nadie ha tocado no cambia
            p_requiere_preparacion => COALESCE((r ->> 'requierePreparacion')::BOOLEAN, TRUE),
            p_producto_id  => v_int);

        -- En la aplicación "agotado" es del producto: se aplica en sus unidades
        UPDATE core.producto_unidades
           SET agotado = COALESCE((r ->> 'agotado')::BOOLEAN, FALSE)
         WHERE producto_id = v_int
           AND agotado IS DISTINCT FROM COALESCE((r ->> 'agotado')::BOOLEAN, FALSE)
           AND core.fn_usuario_en_unidad(v_usuario, unidad_id);
    END LOOP;

    /* ---- 3. Borrados de la carta (productos antes que categorías) ---- */
    FOR v_txt IN SELECT jsonb_array_elements_text(COALESCE(p_cambios -> 'productos_borrados', '[]')) LOOP
        v_int := core.fn_id_de_app(v_txt, 'p');
        CONTINUE WHEN v_int IS NULL;
        v_flag := NULL;
        CALL api.sp_borrar_producto(v_int, v_usuario, v_empresa, v_flag);
        IF v_flag THEN
            v_desactivados := v_desactivados || to_jsonb(v_txt);
        END IF;
    END LOOP;

    FOR v_txt IN SELECT jsonb_array_elements_text(COALESCE(p_cambios -> 'categorias_borradas', '[]')) LOOP
        v_int := core.fn_id_de_app(v_txt, 'c');
        CONTINUE WHEN v_int IS NULL;
        CALL api.sp_borrar_categoria(v_int, v_usuario, v_empresa);
    END LOOP;

    /* ---- 4. Menús (modalidad, datos del armado, textos, categorías y opciones) ---- */
    FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_cambios -> 'menus', '[]')) LOOP
        v_unidad := (r ->> 'sucursalId')::INTEGER;
        IF core.fn_empresa_de_unidad(v_unidad) IS DISTINCT FROM v_empresa THEN
            RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_unidad USING ERRCODE = 'insufficient_privilege';
        END IF;

        -- Título y mensaje de la unidad para todos los días
        IF r ->> 'fecha' = '*' THEN
            CALL api.sp_guardar_texto_menu_unidad(v_unidad, r -> 'publico' ->> 'titulo', r -> 'publico' ->> 'mensaje', v_usuario);
            CONTINUE;
        END IF;

        v_fecha := (r ->> 'fecha')::DATE;
        v_menu  := core.fn_id_de_app(r ->> 'id', 'm');
        SELECT id INTO v_existente FROM core.menus_dia WHERE unidad_id = v_unidad AND fecha = v_fecha;

        /* Un menú nuevo en el navegador para un día que ya tiene menú en la
           base (lo guardó otra persona, o está fuera de las fechas cargadas):
           si se siguiera, se borrarían sus categorías. */
        IF v_menu IS NULL AND v_existente IS NOT NULL THEN
            RAISE EXCEPTION 'El % ya tiene un menú guardado. Recarga la página para verlo.', to_char(v_fecha, 'DD/MM/YYYY');
        END IF;
        IF v_menu IS NOT NULL AND v_menu IS DISTINCT FROM v_existente THEN
            RAISE EXCEPTION 'Ese menú ya no existe. Recarga la página.';
        END IF;

        a := COALESCE(r -> 'armado', '{}');
        CALL api.sp_guardar_menu_dia(
            p_unidad_id   => v_unidad,
            p_fecha       => v_fecha,
            p_tipo        => CASE WHEN r ->> 'tipo' IN ('armado', 'chef') THEN r ->> 'tipo' ELSE 'chef' END,
            p_usuario_id  => v_usuario,
            p_nombre      => NULLIF(trim(a ->> 'nombre'), ''),
            p_descripcion => NULLIF(trim(a ->> 'descripcion'), ''),
            p_precio      => NULLIF(NULLIF(a ->> 'precio', '')::NUMERIC, 0),
            p_disponible  => COALESCE((a ->> 'disponible')::BOOLEAN, TRUE),
            p_titulo      => r -> 'publico' ->> 'titulo',
            p_mensaje     => r -> 'publico' ->> 'mensaje',
            p_menu_id     => v_menu);

        /* NUEVO (46): el interruptor de acompañamientos del menú del chef.
           Sólo si el documento lo trae -un cliente viejo no lo apaga-. */
        IF r ? 'pideAcompanamientos' THEN
            UPDATE core.menus_dia
               SET pide_acompanamientos = COALESCE((r ->> 'pideAcompanamientos')::BOOLEAN, FALSE)
             WHERE id = v_menu;
        END IF;

        -- Categorías que ya no están (los ids ajenos a este menú no cuentan)
        FOR v_big IN
            SELECT mc.id FROM core.menu_categorias mc
             WHERE mc.menu_dia_id = v_menu
               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(a -> 'categorias', '[]')) x
                                WHERE core.fn_id_de_app(x ->> 'id', 'mc') = mc.id)
        LOOP
            CALL api.sp_borrar_menu_categoria(v_big, v_usuario);
        END LOOP;

        FOR c, k IN SELECT x.value, x.ordinality::INTEGER
                      FROM jsonb_array_elements(COALESCE(a -> 'categorias', '[]')) WITH ORDINALITY x
        LOOP
            SELECT mc.id INTO v_cat_menu FROM core.menu_categorias mc
             WHERE mc.id = core.fn_id_de_app(c ->> 'id', 'mc') AND mc.menu_dia_id = v_menu;
            IF NOT FOUND THEN
                v_cat_menu := NULL; -- nueva (o copiada de otro día)
            END IF;

            CALL api.sp_guardar_menu_categoria(
                p_menu_dia_id   => v_menu,
                p_nombre        => c ->> 'nombre',
                p_usuario_id    => v_usuario,
                p_max_seleccion => COALESCE(NULLIF(c ->> 'maxSeleccion', '')::NUMERIC::INTEGER, 1),
                p_obligatoria   => COALESCE((c ->> 'obligatoria')::BOOLEAN, TRUE),
                p_icono         => c ->> 'icono',
                p_activa        => COALESCE((c ->> 'activa')::BOOLEAN, TRUE),
                p_orden         => k,
                p_categoria_id  => v_cat_menu);

            FOR v_big IN
                SELECT mo.id FROM core.menu_opciones mo
                 WHERE mo.menu_categoria_id = v_cat_menu
                   AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(c -> 'opciones', '[]')) x
                                    WHERE core.fn_id_de_app(x ->> 'id', 'mo') = mo.id)
            LOOP
                CALL api.sp_borrar_menu_opcion(v_big, v_usuario);
            END LOOP;

            FOR o, k2 IN SELECT x.value, x.ordinality::INTEGER
                           FROM jsonb_array_elements(COALESCE(c -> 'opciones', '[]')) WITH ORDINALITY x
            LOOP
                SELECT mo.id INTO v_big FROM core.menu_opciones mo
                 WHERE mo.id = core.fn_id_de_app(o ->> 'id', 'mo') AND mo.menu_categoria_id = v_cat_menu;
                IF NOT FOUND THEN
                    v_big := NULL;
                END IF;
                CALL api.sp_guardar_menu_opcion(
                    p_menu_categoria_id => v_cat_menu,
                    p_nombre            => o ->> 'nombre',
                    p_usuario_id        => v_usuario,
                    p_activa            => COALESCE((o ->> 'activa')::BOOLEAN, TRUE),
                    p_orden             => k2,
                    p_opcion_id         => v_big);
            END LOOP;
        END LOOP;
    END LOOP;

    /* ---- 5. Platos del chef ---- */
    FOR v_txt IN SELECT jsonb_array_elements_text(COALESCE(p_cambios -> 'platos_borrados', '[]')) LOOP
        v_big := core.fn_id_de_app(v_txt, 'd');
        CONTINUE WHEN v_big IS NULL;
        IF NOT EXISTS (SELECT 1 FROM core.platos_dia p JOIN core.menus_dia m ON m.id = p.menu_dia_id
                        WHERE p.id = v_big AND core.fn_empresa_de_unidad(m.unidad_id) = v_empresa) THEN
            RAISE EXCEPTION 'Ese plato ya no existe. Recarga la página.';
        END IF;
        CALL api.sp_borrar_plato_dia(v_big, v_usuario);
    END LOOP;

    FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_cambios -> 'platos', '[]')) LOOP
        v_unidad := (r ->> 'sucursalId')::INTEGER;
        v_fecha  := (r ->> 'fecha')::DATE;
        IF core.fn_empresa_de_unidad(v_unidad) IS DISTINCT FROM v_empresa THEN
            RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_unidad USING ERRCODE = 'insufficient_privilege';
        END IF;

        v_menu := NULL;
        SELECT id INTO v_menu FROM core.menus_dia WHERE unidad_id = v_unidad AND fecha = v_fecha;
        IF v_menu IS NULL THEN
            -- Primer plato del día: el menú se crea como menú del chef
            CALL api.sp_guardar_menu_dia(p_unidad_id => v_unidad, p_fecha => v_fecha, p_tipo => 'chef',
                                         p_usuario_id => v_usuario, p_menu_id => v_menu);
        END IF;

        SELECT p.id INTO v_big FROM core.platos_dia p
         WHERE p.id = core.fn_id_de_app(r ->> 'id', 'd') AND p.menu_dia_id = v_menu;
        IF NOT FOUND THEN
            IF core.fn_id_de_app(r ->> 'id', 'd') IS NOT NULL THEN
                RAISE EXCEPTION 'Ese plato ya no existe. Recarga la página.';
            END IF;
            v_big := NULL;
        END IF;

        CALL api.sp_guardar_plato_dia(
            p_menu_dia_id => v_menu,
            p_nombre      => r ->> 'nombre',
            p_precio      => NULLIF(r ->> 'precio', '')::NUMERIC,
            p_usuario_id  => v_usuario,
            p_descripcion => r ->> 'desc',
            p_emoji       => r ->> 'emoji',
            p_cupos       => NULLIF(NULLIF(r ->> 'cupos', '')::NUMERIC::INTEGER, 0),
            p_disponible  => COALESCE((r ->> 'disponible')::BOOLEAN, TRUE),
            p_orden       => round(NULLIF(r ->> 'orden', '')::NUMERIC)::INTEGER,
            p_sopa        => r ->> 'sopa',
            p_principio   => r ->> 'principio',
            p_proteina    => r ->> 'proteina',
            p_bebida      => r ->> 'bebida',
            p_plato_id    => v_big);
    END LOOP;

    RETURN jsonb_build_object('desactivados', v_desactivados);
END;
$function$;
