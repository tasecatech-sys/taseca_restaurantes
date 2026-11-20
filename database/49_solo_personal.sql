/* ============================================================================
   49 · PRODUCTOS «SOLO PERSONAL»: EL MESERO SÍ, EL CLIENTE NO

   Lo que pidió el cliente: una bebida en botella de vidrio no se ofrece en la
   carta del cliente (no viaja a domicilio), pero el mesero y la caja sí tienen
   que poder venderla.

   Hasta ahora había un solo interruptor, `activo` («Visible en la carta»), y
   apagarlo quitaba el producto de TODAS partes. Ahora cada producto tiene tres
   estados:

     · En la carta     activo, sin solo_personal   → lo ven todos
     · Solo personal   activo, con solo_personal   → mesero y caja; el cliente no
     · Oculto          inactivo                    → nadie (p. ej. descontinuado)

   El cliente es quien pide sin sesión de empleado: el portal web y el QR de la
   mesa. Se hace cumplir en tres sitios:

     1. rest.carta (que también alimenta rest.arranque) no entrega lo «solo
        personal» a quien no sea personal de ESA empresa.
     2. core.tg_pedido_items_antes rechaza el ítem si el pedido no lo tomó un
        empleado (tomado_por_id nulo), aunque alguien lo pida a mano.
     3. rest.sincronizar_catalogo guarda el campo desde el panel (con `r ?`:
        un cliente viejo no lo borra).

   Nace en FALSE: nada cambia hasta que el dueño marque un producto.
   Idempotente. Va al final del instalador (redefine funciones de la 03 y la 47
   y la vista de la 25).
   ============================================================================ */

ALTER TABLE core.productos ADD COLUMN IF NOT EXISTS solo_personal BOOLEAN NOT NULL DEFAULT FALSE;
COMMENT ON COLUMN core.productos.solo_personal IS
    'Lo venden mesero y caja, pero no sale en la carta del cliente (portal y QR de mesa).';

/* ---- 1 · La carta: lo «solo personal» sólo para el personal de la empresa.
   La columna nueva va al FINAL (CREATE OR REPLACE VIEW sólo deja añadir). ---- */
CREATE OR REPLACE VIEW rest.carta AS
SELECT p.id AS producto_id, p.empresa_id, p.codigo, p.categoria_id, p.nombre, p.descripcion, p.precio,
       et.codigo AS etiqueta, p.imagen_url, p.orden, p.activo,
       COALESCE(jsonb_agg(jsonb_build_object('unidad_id', pu.unidad_id, 'agotado', pu.agotado)
                          ORDER BY pu.unidad_id) FILTER (WHERE pu.id IS NOT NULL), '[]') AS unidades,
       p.requiere_preparacion,
       p.solo_personal
  FROM core.productos p
  LEFT JOIN core.etiquetas_producto et ON et.id = p.etiqueta_id
  LEFT JOIN core.producto_unidades pu  ON pu.producto_id = p.id
 WHERE NOT p.solo_personal
    OR (    (core.fn_jwt_claims() ->> 'usuario_id') IS NOT NULL
        AND (core.fn_jwt_claims() ->> 'empresa_id')::INTEGER = p.empresa_id)
 GROUP BY p.id, et.codigo;

/* ---- 2 · El ítem del pedido: el cliente no puede pedir lo «solo personal» ---- */
CREATE OR REPLACE FUNCTION core.tg_pedido_items_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
DECLARE
    v_pedido  core.pedidos;
    v_estado  VARCHAR;
    v_nombre  VARCHAR;
    v_precio  NUMERIC;
    v_ok      BOOLEAN;
    v_solo    BOOLEAN;
    v_cupos   INTEGER;
    v_otros   INTEGER := 0;
BEGIN
    SELECT * INTO v_pedido FROM core.pedidos WHERE id = COALESCE(NEW.pedido_id, OLD.pedido_id);
    SELECT codigo INTO v_estado FROM core.estados_pedido WHERE id = v_pedido.estado_pedido_id;

    IF v_estado <> 'nuevo' AND current_setting('taseca.borrado_pruebas', TRUE) IS DISTINCT FROM 'si' THEN
        RAISE EXCEPTION 'La factura % ya está en "%": sus productos no se pueden cambiar.', v_pedido.codigo, v_estado;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    IF NEW.producto_id IS NOT NULL THEN
        SELECT p.nombre, p.precio, (p.activo AND c.activa AND NOT pu.agotado), p.solo_personal
          INTO v_nombre, v_precio, v_ok, v_solo
          FROM core.productos p
          JOIN core.categorias c         ON c.id = p.categoria_id
          JOIN core.producto_unidades pu ON pu.producto_id = p.id AND pu.unidad_id = v_pedido.unidad_id
         WHERE p.id = NEW.producto_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El producto % no se vende en la unidad del pedido.', NEW.producto_id;
        ELSIF NOT v_ok THEN
            RAISE EXCEPTION '"%" no está disponible en este momento.', v_nombre;
        END IF;
        /* (49) Lo «solo personal» lo pide el mesero o la caja, no el cliente. */
        IF v_solo AND v_pedido.tomado_por_id IS NULL THEN
            RAISE EXCEPTION '"%" sólo se pide con el mesero o en caja.', v_nombre;
        END IF;

    ELSIF NEW.plato_dia_id IS NOT NULL THEN
        SELECT pd.nombre, pd.precio, (pd.disponible AND m.disponible), pd.cupos
          INTO v_nombre, v_precio, v_ok, v_cupos
          FROM core.platos_dia pd
          JOIN core.menus_dia m ON m.id = pd.menu_dia_id
          JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
         WHERE pd.id = NEW.plato_dia_id
           AND m.unidad_id = v_pedido.unidad_id
           AND t.codigo = 'chef';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El plato del día % no es del menú del chef de esta unidad.', NEW.plato_dia_id;
        ELSIF NOT v_ok THEN
            RAISE EXCEPTION '"%" ya no está disponible.', v_nombre;
        END IF;
        IF v_cupos IS NOT NULL THEN
            IF TG_OP = 'UPDATE' AND OLD.plato_dia_id = NEW.plato_dia_id THEN
                v_otros := OLD.cantidad;
            END IF;
            IF core.fn_vendidos_plato(NEW.plato_dia_id) - v_otros + NEW.cantidad > v_cupos THEN
                RAISE EXCEPTION 'No quedan cupos suficientes de "%".', v_nombre;
            END IF;
        END IF;

    ELSE
        SELECT COALESCE(m.nombre, 'Menú del día'), m.precio, m.disponible
          INTO v_nombre, v_precio, v_ok
          FROM core.menus_dia m
          JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
         WHERE m.id = NEW.menu_dia_id
           AND m.unidad_id = v_pedido.unidad_id
           AND t.codigo = 'armado';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El menú % no es un menú armado de esta unidad.', NEW.menu_dia_id;
        ELSIF NOT v_ok OR v_precio IS NULL THEN
            RAISE EXCEPTION 'El menú armado no está disponible o no tiene precio.';
        END IF;
    END IF;

    NEW.nombre          := COALESCE(NEW.nombre, v_nombre);
    NEW.precio_unitario := COALESCE(NEW.precio_unitario, v_precio);
    RETURN NEW;
END;
$$;


/* ---- 3 · El panel guarda el estado ---- */
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

        /* NUEVO (49): «solo personal». Sólo si el documento lo trae: un
           cliente viejo no lo apaga. */
        IF r ? 'soloPersonal' THEN
            UPDATE core.productos
               SET solo_personal = COALESCE((r ->> 'soloPersonal')::BOOLEAN, FALSE)
             WHERE id = v_int AND empresa_id = v_empresa;
        END IF;

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

        /* (47) la foto del plato. Sólo si el documento la trae -un
           cliente viejo no la borra-. El vacío ('') se guarda como NULL. */
        IF r ? 'imagen' THEN
            UPDATE core.platos_dia SET imagen_url = NULLIF(r ->> 'imagen', '') WHERE id = v_big;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('desactivados', v_desactivados);
END;
$function$;
