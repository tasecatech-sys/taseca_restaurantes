/* ============================================================================
   47 · EL PLATO DEL CHEF PUEDE TENER FOTO

   Los productos de la carta ya tienen foto (core.productos.imagen_url, subida
   a Supabase Storage por database/27_fotos_en_storage.sql). Los platos del
   chef no tenían dónde guardarla. Esta migración:

     1. core.platos_dia.imagen_url (sólo la dirección; el archivo va a Storage,
        al mismo bucket «carta», reusando S.subirFotoCarta del cliente).
     2. rest.sincronizar_catalogo guarda la imagen del plato: un UPDATE
        guardado (IF r ? 'imagen') tras guardar el plato, igual que el
        interruptor de acompañamientos. Así NO hay que cambiar la firma de
        sp_guardar_plato_dia, y un cliente viejo que no manda el campo no
        borra la foto.
     3. api.v_platos_dia y rest.menus_dia publican la imagen para que la
        tarjeta del cliente la muestre.

   Idempotente. Requiere: la 46.
   ============================================================================ */

ALTER TABLE core.platos_dia
    ADD COLUMN IF NOT EXISTS imagen_url VARCHAR(400);

COMMENT ON COLUMN core.platos_dia.imagen_url IS
    'Dirección de la foto del plato (en Storage, bucket carta). Ver database/47_plato_chef_con_imagen.sql.';


/* ----------------------------------------------------------------------------
   Las vistas publican la imagen
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW api.v_platos_dia AS
SELECT pd.id AS plato_dia_id, pd.menu_dia_id, m.unidad_id, m.fecha,
       pd.nombre, pd.descripcion, pd.emoji, pd.precio, pd.cupos, pd.disponible, pd.orden,
       v.vendidos,
       CASE WHEN pd.cupos IS NULL THEN NULL ELSE GREATEST(pd.cupos - v.vendidos, 0) END AS cupos_restantes,
       (pd.disponible AND m.disponible AND (pd.cupos IS NULL OR v.vendidos < pd.cupos)) AS se_puede_pedir,
       pd.incluye_sopa, pd.incluye_principio, pd.incluye_proteina, pd.incluye_bebida,
       pd.imagen_url
  FROM core.platos_dia pd
  JOIN core.menus_dia m ON m.id = pd.menu_dia_id
  CROSS JOIN LATERAL (SELECT core.fn_vendidos_plato(pd.id) AS vendidos) v;

CREATE OR REPLACE VIEW rest.menus_dia AS
SELECT m.id AS menu_dia_id, u.empresa_id, m.unidad_id, m.fecha, t.codigo AS tipo,
       m.nombre, m.descripcion, m.precio, m.disponible,
       m.titulo_publico AS titulo_fecha, m.mensaje_publico AS mensaje_fecha,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'categoria_id', c.id, 'nombre', c.nombre, 'icono', c.icono, 'orden', c.orden,
                          'obligatoria', c.obligatoria, 'max_seleccion', c.max_seleccion, 'activa', c.activa,
                          'opciones', COALESCE((SELECT jsonb_agg(jsonb_build_object('opcion_id', o.id, 'nombre', o.nombre,
                                                                                    'orden', o.orden, 'activa', o.activa)
                                                                 ORDER BY o.orden)
                                                  FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id), '[]'))
                      ORDER BY c.orden)
                   FROM core.menu_categorias c WHERE c.menu_dia_id = m.id), '[]') AS categorias,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'plato_dia_id', p.plato_dia_id, 'nombre', p.nombre, 'descripcion', p.descripcion,
                          'emoji', p.emoji, 'precio', p.precio, 'cupos', p.cupos, 'vendidos', p.vendidos,
                          'disponible', p.disponible, 'orden', p.orden,
                          'sopa', p.incluye_sopa, 'principio', p.incluye_principio,
                          'proteina', p.incluye_proteina, 'bebida', p.incluye_bebida,
                          'imagen', p.imagen_url)
                      ORDER BY p.orden)
                   FROM api.v_platos_dia p WHERE p.menu_dia_id = m.id), '[]') AS platos,
       m.pide_acompanamientos
  FROM core.menus_dia m
  JOIN core.unidades u   ON u.id = m.unidad_id
  JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
 WHERE m.fecha BETWEEN core.fn_fecha_operativa(u.empresa_id, now()) - 7
                   AND core.fn_fecha_operativa(u.empresa_id, now()) + 14;


/* ----------------------------------------------------------------------------
   La sincronización guarda la imagen del plato (UPDATE guardado)
   Es la MISMA rest.sincronizar_catalogo de la 46, con una sola línea añadida
   en la sección 5 (platos del chef): tras guardar el plato, si el documento
   trae `imagen`, se escribe. El IF evita que un cliente viejo la borre.
   ---------------------------------------------------------------------------- */
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
            p_requiere_preparacion => COALESCE((r ->> 'requierePreparacion')::BOOLEAN, TRUE),
            p_producto_id  => v_int);

        UPDATE core.producto_unidades
           SET agotado = COALESCE((r ->> 'agotado')::BOOLEAN, FALSE)
         WHERE producto_id = v_int
           AND agotado IS DISTINCT FROM COALESCE((r ->> 'agotado')::BOOLEAN, FALSE)
           AND core.fn_usuario_en_unidad(v_usuario, unidad_id);
    END LOOP;

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

    FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_cambios -> 'menus', '[]')) LOOP
        v_unidad := (r ->> 'sucursalId')::INTEGER;
        IF core.fn_empresa_de_unidad(v_unidad) IS DISTINCT FROM v_empresa THEN
            RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_unidad USING ERRCODE = 'insufficient_privilege';
        END IF;

        IF r ->> 'fecha' = '*' THEN
            CALL api.sp_guardar_texto_menu_unidad(v_unidad, r -> 'publico' ->> 'titulo', r -> 'publico' ->> 'mensaje', v_usuario);
            CONTINUE;
        END IF;

        v_fecha := (r ->> 'fecha')::DATE;
        v_menu  := core.fn_id_de_app(r ->> 'id', 'm');
        SELECT id INTO v_existente FROM core.menus_dia WHERE unidad_id = v_unidad AND fecha = v_fecha;

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

        IF r ? 'pideAcompanamientos' THEN
            UPDATE core.menus_dia
               SET pide_acompanamientos = COALESCE((r ->> 'pideAcompanamientos')::BOOLEAN, FALSE)
             WHERE id = v_menu;
        END IF;

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
                v_cat_menu := NULL;
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

        /* NUEVO (47): la foto del plato. Sólo si el documento la trae -un
           cliente viejo no la borra-. El vacío ('') se guarda como NULL. */
        IF r ? 'imagen' THEN
            UPDATE core.platos_dia SET imagen_url = NULLIF(r ->> 'imagen', '') WHERE id = v_big;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('desactivados', v_desactivados);
END;
$function$;
