/* ============================================================================
   TASECA · 24 · ABRIR EL PANEL EN UN SOLO VIAJE
   ----------------------------------------------------------------------------
   Abrir el panel costaba ONCE peticiones, una detrás de otra y bloqueando la
   pantalla entre medias:

       /empresas  /unidades  /categorias  /carta  /menus_dia  /textos_menu
       /logos_unidad  /empresa_imagenes  /pedidos  /pedidos(marca)  /usuarios

   Contra Supabase, con la base en otro país, cada viaje son unos 250 ms. Once
   viajes en fila son dos o tres segundos de pantalla muerta antes de poder
   tocar nada. Y es lo mismo que hace que quien atiende toque el botón dos
   veces (ver database/23_pedidos_sin_duplicados.sql).

   rest.arranque() devuelve todo eso de una vez. La aplicación no ve nada
   nuevo: son los MISMOS datos de las mismas vistas, juntos en una respuesta.

   QUIÉN VE QUÉ
     Sin sesión -el portal del cliente- devuelve sólo el catálogo público:
     empresa, unidades, categorías, carta y menús. Con sesión añade los
     usuarios y los pedidos, cada uno con el alcance de siempre: las vistas
     `rest.*` que se leen aquí dentro siguen filtrando por el token, así que
     nadie ve más de lo que veía.

   De paso baja la factura de Supabase: once peticiones por apertura de panel,
   multiplicadas por cada empleado y cada turno, son muchas.

   No cambia datos. Se puede ejecutar más de una vez.
   Requiere: 00 … 17 instalados.
   ============================================================================ */

SET search_path = core, public;


CREATE OR REPLACE FUNCTION rest.arranque(p_empresa TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_codigo  TEXT := NULLIF(trim(p_empresa), '');
    v_id      INTEGER;
    v_emp     JSONB;
    v_usuario INTEGER := core.fn_jwt_usuario();
    v_jornada DATE;
    v_salida  JSONB;
BEGIN
    /* De qué empresa es esta visita: la que pide la dirección o, si no dice,
       la del token. El portal del cliente no tiene token, por eso el
       parámetro. */
    IF v_codigo IS NULL THEN
        SELECT e.codigo INTO v_codigo FROM core.empresas e WHERE e.id = core.fn_jwt_empresa();
    END IF;
    IF v_codigo IS NULL THEN
        RAISE EXCEPTION 'Falta decir de qué negocio es esta página.';
    END IF;

    SELECT to_jsonb(e) INTO v_emp FROM rest.empresas e WHERE e.codigo = v_codigo;
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'La empresa "%" no existe en la base de datos o está desactivada.', v_codigo;
    END IF;

    v_id      := (v_emp ->> 'empresa_id')::INTEGER;
    v_jornada := core.fn_fecha_operativa(v_id, now());

    -- El catálogo: lo mismo que pedía una por una, de las mismas vistas
    v_salida := jsonb_build_object(
        'empresa', v_emp,
        'unidades', COALESCE((SELECT jsonb_agg(to_jsonb(u) ORDER BY u.nombre)
                                FROM rest.unidades u WHERE u.empresa_id = v_id), '[]'::JSONB),
        'categorias', COALESCE((SELECT jsonb_agg(to_jsonb(c))
                                  FROM rest.categorias c WHERE c.empresa_id = v_id), '[]'::JSONB),
        'carta', COALESCE((SELECT jsonb_agg(to_jsonb(p))
                             FROM rest.carta p WHERE p.empresa_id = v_id), '[]'::JSONB),
        'menus_dia', COALESCE((SELECT jsonb_agg(to_jsonb(m))
                                 FROM rest.menus_dia m WHERE m.empresa_id = v_id), '[]'::JSONB),
        'textos_menu', COALESCE((SELECT jsonb_agg(to_jsonb(t))
                                   FROM rest.textos_menu t WHERE t.empresa_id = v_id), '[]'::JSONB),
        'con_sesion', v_usuario IS NOT NULL
    );

    IF v_usuario IS NULL THEN
        RETURN v_salida;   -- el portal del cliente no necesita más
    END IF;

    /* Con sesión, lo que el panel pedía aparte. `rest.pedidos` y
       `rest.usuarios` siguen filtrando por el token: el alcance no cambia. */
    RETURN v_salida || jsonb_build_object(
        'usuarios', COALESCE((SELECT jsonb_agg(to_jsonb(u) ORDER BY u.nombre)
                                FROM rest.usuarios u), '[]'::JSONB),
        'pedidos', COALESCE((SELECT jsonb_agg(jsonb_build_object('pedido', p.pedido) ORDER BY p.pedido_id DESC)
                               FROM rest.pedidos p
                              WHERE p.fecha_operativa >= v_jornada - 1), '[]'::JSONB),
        /* El último cambio de los 31 días: sirve para saber desde dónde
           refrescar sin tener que bajar esos pedidos. Se mira sobre la vista
           sin el JSON de cada factura, que es lo caro. */
        'marca_pedidos', (SELECT max(vp.actualizado_en)
                            FROM api.v_pedidos vp
                           WHERE vp.empresa_id = v_id
                             AND core.fn_usuario_en_unidad(v_usuario, vp.unidad_id)
                             AND vp.fecha_operativa >= v_jornada - 31)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION rest.arranque(TEXT) TO taseca_anon, taseca_app;


/* ============================================================================
   REVISIÓN
   ============================================================================ */

DO $$
DECLARE
    v_r JSONB;
    v_n INTEGER;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rest' AND p.proname = 'arranque';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'rest.arranque no quedó creada.';
    END IF;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'rest.arranque() creada y con permisos.';
    RAISE NOTICE 'Lo que devuelve para cada empresa activa:';
    FOR v_r IN SELECT rest.arranque(e.codigo) FROM core.empresas e WHERE e.estado = 'activa' ORDER BY e.id LOOP
        RAISE NOTICE '  % · % unidades, % categorías, % productos, % menús',
            v_r -> 'empresa' ->> 'codigo',
            jsonb_array_length(v_r -> 'unidades'),
            jsonb_array_length(v_r -> 'categorias'),
            jsonb_array_length(v_r -> 'carta'),
            jsonb_array_length(v_r -> 'menus_dia');
    END LOOP;
    RAISE NOTICE '--------------------------------------------------';
END;
$$;
