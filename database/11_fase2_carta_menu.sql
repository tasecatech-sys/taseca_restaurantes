/* ============================================================================
   TASECA · 11 · FASE 2 · BLOQUE 1: CARTA Y MENÚ DEL DÍA DESDE LA APLICACIÓN
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 10. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · Los procedimientos que faltaban para administrar la carta y el menú:
       categorías de la carta, borrar (producto, categoría, plato, categoría
       y opción del menú armado) y el ORDEN de categorías, opciones y platos.
     · rest.sincronizar_catalogo: la aplicación manda en UNA petición lo que
       cambió una acción del panel (guardar, mover, copiar, borrar…) y la
       base lo aplica en UNA transacción llamando a esos procedimientos. Si
       algo falla no queda nada a medias.

   REGLAS QUE PROTEGEN LA HISTORIA
     · Un producto que ya se vendió no se borra: se oculta de la carta.
     · Un plato del chef, o una opción del menú armado, que ya se vendió no
       se borra ni se renombra: se marca como no disponible / inactiva.
     · Una categoría de la carta con productos no se borra.

   SEGURIDAD
     El usuario y la empresa salen SIEMPRE del token. Cada procedimiento
     vuelve a exigir el permiso ('carta' o 'menu'), que el usuario trabaje en
     la unidad y que todo sea de su empresa: el navegador no puede tocar la
     carta de otra empresa aunque cambie los ids de la petición.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. APOYO
   ============================================================================ */

/* La aplicación escribe los ids con prefijo (p12, c3, mc5…). Devuelve el
   número si el texto tiene ESE prefijo; si no (un registro nuevo creado en
   el navegador, con id propio), NULL. */
CREATE OR REPLACE FUNCTION core.fn_id_de_app(p_id TEXT, p_prefijo TEXT)
RETURNS BIGINT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE WHEN p_id ~ ('^' || p_prefijo || '[0-9]{1,18}$')
                THEN substr(p_id, length(p_prefijo) + 1)::BIGINT END;
$$;

/* Cada unidad de la lista debe ser de la empresa y el usuario debe trabajar
   en ella. */
CREATE OR REPLACE FUNCTION core.fn_exigir_unidades(p_usuario_id INTEGER, p_empresa_id INTEGER, p_unidades INTEGER[])
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_u INTEGER;
BEGIN
    IF p_unidades IS NULL OR cardinality(p_unidades) = 0 THEN
        RAISE EXCEPTION 'Elige al menos una unidad.';
    END IF;
    FOREACH v_u IN ARRAY p_unidades LOOP
        IF core.fn_empresa_de_unidad(v_u) IS DISTINCT FROM p_empresa_id THEN
            RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_u USING ERRCODE = 'insufficient_privilege';
        END IF;
        IF NOT core.fn_usuario_en_unidad(p_usuario_id, v_u) THEN
            RAISE EXCEPTION 'No trabajas en la unidad "%".', (SELECT nombre FROM core.unidades WHERE id = v_u)
                  USING ERRCODE = 'insufficient_privilege';
        END IF;
    END LOOP;
END;
$$;


/* ============================================================================
   2. CARTA
   ============================================================================ */

/* Categoría de la carta. Una categoría NUEVA con el nombre de otra que ya
   existe en la empresa no se duplica: la existente pasa a ser también de
   estas unidades (así "Bebidas" puede estar en el bar y en la arepera). */
CREATE OR REPLACE PROCEDURE api.sp_guardar_categoria(
    p_empresa_id  INTEGER,
    p_nombre      VARCHAR,
    p_unidades    INTEGER[],
    p_usuario_id  INTEGER,
    p_icono       VARCHAR DEFAULT NULL,
    p_orden       INTEGER DEFAULT NULL,
    p_activa      BOOLEAN DEFAULT TRUE,
    INOUT p_categoria_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');
    PERFORM core.fn_exigir_unidades(p_usuario_id, p_empresa_id, p_unidades);

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'Escribe el nombre de la categoría.';
    END IF;

    IF p_categoria_id IS NULL THEN
        SELECT id INTO p_categoria_id
          FROM core.categorias
         WHERE empresa_id = p_empresa_id AND lower(nombre) = lower(v_nombre);

        IF p_categoria_id IS NULL THEN
            INSERT INTO core.categorias (empresa_id, nombre, icono, orden, activa)
            VALUES (p_empresa_id, v_nombre, NULLIF(trim(p_icono), ''),
                    COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 10 FROM core.categorias WHERE empresa_id = p_empresa_id)),
                    COALESCE(p_activa, TRUE))
            RETURNING id INTO p_categoria_id;
        END IF;

        INSERT INTO core.categoria_unidades (categoria_id, unidad_id)
        SELECT p_categoria_id, x FROM unnest(p_unidades) x
        ON CONFLICT (categoria_id, unidad_id) DO NOTHING;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM core.categorias
                WHERE empresa_id = p_empresa_id AND lower(nombre) = lower(v_nombre) AND id <> p_categoria_id) THEN
        RAISE EXCEPTION 'Ya hay otra categoría llamada "%".', v_nombre;
    END IF;

    UPDATE core.categorias
       SET nombre = v_nombre, icono = NULLIF(trim(p_icono), ''), orden = COALESCE(p_orden, orden),
           activa = COALESCE(p_activa, activa)
     WHERE id = p_categoria_id AND empresa_id = p_empresa_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa categoría ya no existe. Recarga la página.';
    END IF;

    -- Sólo se retiran las unidades en las que trabaja el usuario
    DELETE FROM core.categoria_unidades
     WHERE categoria_id = p_categoria_id
       AND unidad_id <> ALL (p_unidades)
       AND core.fn_usuario_en_unidad(p_usuario_id, unidad_id);
    INSERT INTO core.categoria_unidades (categoria_id, unidad_id)
    SELECT p_categoria_id, x FROM unnest(p_unidades) x
    ON CONFLICT (categoria_id, unidad_id) DO NOTHING;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_borrar_categoria(p_categoria_id INTEGER, p_usuario_id INTEGER, p_empresa_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_productos INTEGER;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');

    IF NOT EXISTS (SELECT 1 FROM core.categorias WHERE id = p_categoria_id AND empresa_id = p_empresa_id) THEN
        RAISE EXCEPTION 'Esa categoría ya no existe. Recarga la página.';
    END IF;

    SELECT count(*) INTO v_productos FROM core.productos WHERE categoria_id = p_categoria_id;
    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: hay % productos en esta categoría. Muévelos a otra o desactiva la categoría.', v_productos;
    END IF;

    DELETE FROM core.categorias WHERE id = p_categoria_id;
END;
$$;

/* Se reemplaza la versión de 04: agrega la imagen, genera el código si
   viene vacío, da mensajes claros y no retira unidades ajenas al usuario. */
DROP PROCEDURE IF EXISTS api.sp_guardar_producto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER[], INTEGER,
                                                 VARCHAR, VARCHAR, BOOLEAN, INTEGER, INTEGER);

CREATE OR REPLACE PROCEDURE api.sp_guardar_producto(
    p_empresa_id    INTEGER,
    p_categoria_id  INTEGER,
    p_codigo        VARCHAR,
    p_nombre        VARCHAR,
    p_precio        NUMERIC,
    p_unidades      INTEGER[],
    p_usuario_id    INTEGER,
    p_descripcion   VARCHAR DEFAULT NULL,
    p_etiqueta      VARCHAR DEFAULT NULL,
    p_activo        BOOLEAN DEFAULT TRUE,
    p_orden         INTEGER DEFAULT NULL,
    p_imagen_url    VARCHAR DEFAULT NULL,
    INOUT p_producto_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_etiqueta INTEGER := CASE WHEN NULLIF(trim(p_etiqueta), '') IS NULL THEN NULL
                               ELSE core.fn_id_catalogo('etiquetas_producto', trim(p_etiqueta)) END;
    v_codigo   VARCHAR := NULLIF(upper(trim(COALESCE(p_codigo, ''))), '');
    v_nombre   VARCHAR := trim(COALESCE(p_nombre, ''));
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');
    PERFORM core.fn_exigir_unidades(p_usuario_id, p_empresa_id, p_unidades);

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El producto necesita un nombre.';
    END IF;
    IF p_precio IS NULL OR p_precio < 0 THEN
        RAISE EXCEPTION 'El precio de "%" no es válido.', v_nombre;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.categorias WHERE id = p_categoria_id AND empresa_id = p_empresa_id) THEN
        RAISE EXCEPTION 'El producto "%" necesita una categoría de esta empresa.', v_nombre;
    END IF;
    IF v_codigo IS NOT NULL AND EXISTS (SELECT 1 FROM core.productos
                                         WHERE empresa_id = p_empresa_id AND codigo = v_codigo
                                           AND id IS DISTINCT FROM p_producto_id) THEN
        RAISE EXCEPTION 'Ya hay otro producto con el código %.', v_codigo;
    END IF;

    IF p_producto_id IS NULL THEN
        INSERT INTO core.productos (empresa_id, categoria_id, etiqueta_id, codigo, nombre, descripcion,
                                    precio, imagen_url, activo, orden)
        VALUES (p_empresa_id, p_categoria_id, v_etiqueta,
                COALESCE(v_codigo, 'TMP-' || left(md5(random()::TEXT || clock_timestamp()::TEXT), 24)),
                v_nombre, NULLIF(trim(p_descripcion), ''), p_precio, NULLIF(trim(p_imagen_url), ''),
                COALESCE(p_activo, TRUE),
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 10 FROM core.productos WHERE empresa_id = p_empresa_id)))
        RETURNING id INTO p_producto_id;

        IF v_codigo IS NULL THEN
            UPDATE core.productos SET codigo = 'P' || lpad(p_producto_id::TEXT, 4, '0') WHERE id = p_producto_id;
        END IF;
    ELSE
        UPDATE core.productos
           SET categoria_id = p_categoria_id, etiqueta_id = v_etiqueta, codigo = COALESCE(v_codigo, codigo),
               nombre = v_nombre, descripcion = NULLIF(trim(p_descripcion), ''), precio = p_precio,
               imagen_url = NULLIF(trim(p_imagen_url), ''), activo = COALESCE(p_activo, activo),
               orden = COALESCE(p_orden, orden)
         WHERE id = p_producto_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese producto ya no existe. Recarga la página.';
        END IF;
    END IF;

    DELETE FROM core.producto_unidades
     WHERE producto_id = p_producto_id
       AND unidad_id <> ALL (p_unidades)
       AND core.fn_usuario_en_unidad(p_usuario_id, unidad_id);
    INSERT INTO core.producto_unidades (producto_id, unidad_id)
    SELECT p_producto_id, x FROM unnest(p_unidades) x
    ON CONFLICT (producto_id, unidad_id) DO NOTHING;
END;
$$;

/* Si ya se vendió se oculta (p_desactivado = TRUE); si no, se elimina. */
CREATE OR REPLACE PROCEDURE api.sp_borrar_producto(
    p_producto_id  INTEGER,
    p_usuario_id   INTEGER,
    p_empresa_id   INTEGER,
    INOUT p_desactivado BOOLEAN DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');

    IF NOT EXISTS (SELECT 1 FROM core.productos WHERE id = p_producto_id AND empresa_id = p_empresa_id) THEN
        RAISE EXCEPTION 'Ese producto ya no existe. Recarga la página.';
    END IF;

    IF EXISTS (SELECT 1 FROM core.pedido_items WHERE producto_id = p_producto_id) THEN
        UPDATE core.productos SET activo = FALSE WHERE id = p_producto_id;
        p_desactivado := TRUE;
    ELSE
        DELETE FROM core.productos WHERE id = p_producto_id;
        p_desactivado := FALSE;
    END IF;
END;
$$;


/* ============================================================================
   3. MENÚ DEL DÍA
   Se reemplazan tres procedimientos de 04 para agregar el ORDEN y avisar
   cuando el registro que se edita no existe (antes no hacían nada).
   ============================================================================ */

/* "Qué incluye" el plato del chef (opcional). El portal lo muestra debajo
   del plato; en el MVP local ya existía. */
ALTER TABLE core.platos_dia ADD COLUMN IF NOT EXISTS incluye_sopa      VARCHAR(80);
ALTER TABLE core.platos_dia ADD COLUMN IF NOT EXISTS incluye_principio VARCHAR(80);
ALTER TABLE core.platos_dia ADD COLUMN IF NOT EXISTS incluye_proteina  VARCHAR(80);
ALTER TABLE core.platos_dia ADD COLUMN IF NOT EXISTS incluye_bebida    VARCHAR(80);

CREATE OR REPLACE VIEW api.v_platos_dia AS
SELECT pd.id AS plato_dia_id, pd.menu_dia_id, m.unidad_id, m.fecha,
       pd.nombre, pd.descripcion, pd.emoji, pd.precio, pd.cupos, pd.disponible, pd.orden,
       v.vendidos,
       CASE WHEN pd.cupos IS NULL THEN NULL ELSE GREATEST(pd.cupos - v.vendidos, 0) END AS cupos_restantes,
       (pd.disponible AND m.disponible AND (pd.cupos IS NULL OR v.vendidos < pd.cupos)) AS se_puede_pedir,
       pd.incluye_sopa, pd.incluye_principio, pd.incluye_proteina, pd.incluye_bebida
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
                          'proteina', p.incluye_proteina, 'bebida', p.incluye_bebida)
                      ORDER BY p.orden)
                   FROM api.v_platos_dia p WHERE p.menu_dia_id = m.id), '[]') AS platos
  FROM core.menus_dia m
  JOIN core.unidades u   ON u.id = m.unidad_id
  JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
 WHERE m.fecha BETWEEN core.fn_fecha_operativa(u.empresa_id, now()) - 7
                   AND core.fn_fecha_operativa(u.empresa_id, now()) + 14;

DROP PROCEDURE IF EXISTS api.sp_guardar_menu_categoria(BIGINT, VARCHAR, INTEGER, INTEGER, BOOLEAN, VARCHAR, BOOLEAN, BIGINT);
DROP PROCEDURE IF EXISTS api.sp_guardar_menu_opcion(BIGINT, VARCHAR, INTEGER, BOOLEAN, BIGINT);
DROP PROCEDURE IF EXISTS api.sp_guardar_plato_dia(BIGINT, VARCHAR, NUMERIC, INTEGER, VARCHAR, VARCHAR, INTEGER, BOOLEAN, BIGINT);
DROP PROCEDURE IF EXISTS api.sp_guardar_plato_dia(BIGINT, VARCHAR, NUMERIC, INTEGER, VARCHAR, VARCHAR, INTEGER, BOOLEAN, INTEGER, BIGINT);

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_categoria(
    p_menu_dia_id    BIGINT,
    p_nombre         VARCHAR,
    p_usuario_id     INTEGER,
    p_max_seleccion  INTEGER  DEFAULT 1,
    p_obligatoria    BOOLEAN  DEFAULT TRUE,
    p_icono          VARCHAR  DEFAULT NULL,
    p_activa         BOOLEAN  DEFAULT TRUE,
    p_orden          INTEGER  DEFAULT NULL,
    INOUT p_categoria_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT unidad_id FROM core.menus_dia WHERE id = p_menu_dia_id));

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'Escribe el nombre de la categoría.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.menu_categorias
                WHERE menu_dia_id = p_menu_dia_id AND lower(nombre) = lower(v_nombre)
                  AND id IS DISTINCT FROM p_categoria_id) THEN
        RAISE EXCEPTION 'Ya hay una categoría llamada "%".', v_nombre;
    END IF;

    IF p_categoria_id IS NULL THEN
        INSERT INTO core.menu_categorias (menu_dia_id, nombre, icono, orden, obligatoria, max_seleccion, activa)
        VALUES (p_menu_dia_id, v_nombre, NULLIF(trim(p_icono), ''),
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 1 FROM core.menu_categorias WHERE menu_dia_id = p_menu_dia_id)),
                COALESCE(p_obligatoria, TRUE), LEAST(GREATEST(COALESCE(p_max_seleccion, 1), 1), 10), COALESCE(p_activa, TRUE))
        RETURNING id INTO p_categoria_id;
    ELSE
        UPDATE core.menu_categorias
           SET nombre = v_nombre, icono = NULLIF(trim(p_icono), ''), obligatoria = COALESCE(p_obligatoria, obligatoria),
               max_seleccion = LEAST(GREATEST(COALESCE(p_max_seleccion, max_seleccion), 1), 10),
               activa = COALESCE(p_activa, activa), orden = COALESCE(p_orden, orden)
         WHERE id = p_categoria_id AND menu_dia_id = p_menu_dia_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Esa categoría ya no existe. Recarga la página.';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_opcion(
    p_menu_categoria_id BIGINT,
    p_nombre            VARCHAR,
    p_usuario_id        INTEGER,
    p_activa            BOOLEAN DEFAULT TRUE,
    p_orden             INTEGER DEFAULT NULL,
    INOUT p_opcion_id   BIGINT  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.menu_categorias c JOIN core.menus_dia m ON m.id = c.menu_dia_id
              WHERE c.id = p_menu_categoria_id));

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'Escribe el nombre de la opción.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.menu_opciones
                WHERE menu_categoria_id = p_menu_categoria_id AND lower(nombre) = lower(v_nombre)
                  AND id IS DISTINCT FROM p_opcion_id) THEN
        RAISE EXCEPTION '"%" ya está en esta categoría.', v_nombre;
    END IF;

    IF p_opcion_id IS NULL THEN
        INSERT INTO core.menu_opciones (menu_categoria_id, nombre, orden, activa)
        VALUES (p_menu_categoria_id, v_nombre,
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 1 FROM core.menu_opciones WHERE menu_categoria_id = p_menu_categoria_id)),
                COALESCE(p_activa, TRUE))
        RETURNING id INTO p_opcion_id;
    ELSE
        UPDATE core.menu_opciones
           SET nombre = v_nombre, activa = COALESCE(p_activa, activa), orden = COALESCE(p_orden, orden)
         WHERE id = p_opcion_id AND menu_categoria_id = p_menu_categoria_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Esa opción ya no existe. Recarga la página.';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_plato_dia(
    p_menu_dia_id  BIGINT,
    p_nombre       VARCHAR,
    p_precio       NUMERIC,
    p_usuario_id   INTEGER,
    p_descripcion  VARCHAR DEFAULT NULL,
    p_emoji        VARCHAR DEFAULT NULL,
    p_cupos        INTEGER DEFAULT NULL,
    p_disponible   BOOLEAN DEFAULT TRUE,
    p_orden        INTEGER DEFAULT NULL,
    p_sopa         VARCHAR DEFAULT NULL,
    p_principio    VARCHAR DEFAULT NULL,
    p_proteina     VARCHAR DEFAULT NULL,
    p_bebida       VARCHAR DEFAULT NULL,
    INOUT p_plato_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := trim(COALESCE(p_nombre, ''));
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT unidad_id FROM core.menus_dia WHERE id = p_menu_dia_id));

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El plato necesita un nombre.';
    END IF;
    IF p_precio IS NULL OR p_precio <= 0 THEN
        RAISE EXCEPTION 'El plato "%" necesita un precio mayor a cero.', v_nombre;
    END IF;
    IF p_cupos IS NOT NULL AND p_cupos <= 0 THEN
        RAISE EXCEPTION 'Los cupos de "%" deben ser mayores a cero, o dejarse vacíos para no tener límite.', v_nombre;
    END IF;

    IF p_plato_id IS NULL THEN
        INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, disponible, orden,
                                     incluye_sopa, incluye_principio, incluye_proteina, incluye_bebida)
        VALUES (p_menu_dia_id, v_nombre, NULLIF(trim(p_descripcion), ''), NULLIF(trim(p_emoji), ''), p_precio,
                p_cupos, COALESCE(p_disponible, TRUE),
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 1 FROM core.platos_dia WHERE menu_dia_id = p_menu_dia_id)),
                NULLIF(trim(p_sopa), ''), NULLIF(trim(p_principio), ''), NULLIF(trim(p_proteina), ''), NULLIF(trim(p_bebida), ''))
        RETURNING id INTO p_plato_id;
    ELSE
        UPDATE core.platos_dia
           SET nombre = v_nombre, descripcion = NULLIF(trim(p_descripcion), ''), emoji = NULLIF(trim(p_emoji), ''),
               precio = p_precio, cupos = p_cupos, disponible = COALESCE(p_disponible, disponible),
               orden = COALESCE(p_orden, orden),
               incluye_sopa = NULLIF(trim(p_sopa), ''), incluye_principio = NULLIF(trim(p_principio), ''),
               incluye_proteina = NULLIF(trim(p_proteina), ''), incluye_bebida = NULLIF(trim(p_bebida), '')
         WHERE id = p_plato_id AND menu_dia_id = p_menu_dia_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese plato ya no existe. Recarga la página.';
        END IF;
    END IF;
END;
$$;

/* Igual que en 04, pero también copia "qué incluye" de cada plato. */
CREATE OR REPLACE PROCEDURE api.sp_copiar_menu_dia(
    p_unidad_id      INTEGER,
    p_fecha_origen   DATE,
    p_fecha_destino  DATE,
    p_usuario_id     INTEGER,
    INOUT p_menu_id  BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_origen core.menus_dia;
    v_cat    RECORD;
    v_nueva  BIGINT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu', p_unidad_id);

    SELECT * INTO v_origen FROM core.menus_dia WHERE unidad_id = p_unidad_id AND fecha = p_fecha_origen;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No hay menú el % en esta unidad.', p_fecha_origen;
    END IF;
    IF EXISTS (SELECT 1 FROM core.menus_dia WHERE unidad_id = p_unidad_id AND fecha = p_fecha_destino) THEN
        RAISE EXCEPTION 'El % ya tiene menú: copiar nunca lo reemplaza.', p_fecha_destino;
    END IF;

    INSERT INTO core.menus_dia (unidad_id, fecha, tipo_menu_id, nombre, descripcion, precio, disponible,
                                titulo_publico, mensaje_publico, creado_por_id)
    VALUES (p_unidad_id, p_fecha_destino, v_origen.tipo_menu_id, v_origen.nombre, v_origen.descripcion,
            v_origen.precio, v_origen.disponible, v_origen.titulo_publico, v_origen.mensaje_publico, p_usuario_id)
    RETURNING id INTO p_menu_id;

    FOR v_cat IN SELECT * FROM core.menu_categorias WHERE menu_dia_id = v_origen.id ORDER BY orden LOOP
        INSERT INTO core.menu_categorias (menu_dia_id, nombre, icono, orden, obligatoria, max_seleccion, activa)
        VALUES (p_menu_id, v_cat.nombre, v_cat.icono, v_cat.orden, v_cat.obligatoria, v_cat.max_seleccion, v_cat.activa)
        RETURNING id INTO v_nueva;

        INSERT INTO core.menu_opciones (menu_categoria_id, nombre, orden, activa)
        SELECT v_nueva, nombre, orden, activa FROM core.menu_opciones WHERE menu_categoria_id = v_cat.id;
    END LOOP;

    INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, disponible, orden,
                                 incluye_sopa, incluye_principio, incluye_proteina, incluye_bebida)
    SELECT p_menu_id, nombre, descripcion, emoji, precio, cupos, disponible, orden,
           incluye_sopa, incluye_principio, incluye_proteina, incluye_bebida
      FROM core.platos_dia WHERE menu_dia_id = v_origen.id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_borrar_plato_dia(p_plato_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.platos_dia p JOIN core.menus_dia m ON m.id = p.menu_dia_id
              WHERE p.id = p_plato_id));

    SELECT nombre INTO v_nombre FROM core.platos_dia WHERE id = p_plato_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese plato ya no existe. Recarga la página.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.pedido_items WHERE plato_dia_id = p_plato_id) THEN
        RAISE EXCEPTION '"%" ya se vendió: no se puede eliminar. Márcalo como no disponible.', v_nombre;
    END IF;

    DELETE FROM core.platos_dia WHERE id = p_plato_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_borrar_menu_opcion(p_opcion_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.menu_opciones o
               JOIN core.menu_categorias c ON c.id = o.menu_categoria_id
               JOIN core.menus_dia m       ON m.id = c.menu_dia_id
              WHERE o.id = p_opcion_id));

    SELECT nombre INTO v_nombre FROM core.menu_opciones WHERE id = p_opcion_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa opción ya no existe. Recarga la página.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.pedido_item_opciones WHERE menu_opcion_id = p_opcion_id) THEN
        RAISE EXCEPTION '"%" ya se vendió: no se puede eliminar. Desactívala.', v_nombre;
    END IF;

    DELETE FROM core.menu_opciones WHERE id = p_opcion_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_borrar_menu_categoria(p_categoria_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.menu_categorias c JOIN core.menus_dia m ON m.id = c.menu_dia_id
              WHERE c.id = p_categoria_id));

    SELECT nombre INTO v_nombre FROM core.menu_categorias WHERE id = p_categoria_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa categoría ya no existe. Recarga la página.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.menu_opciones o
                 JOIN core.pedido_item_opciones x ON x.menu_opcion_id = o.id
                WHERE o.menu_categoria_id = p_categoria_id) THEN
        RAISE EXCEPTION 'La categoría "%" ya tiene opciones vendidas: no se puede eliminar. Desactívala.', v_nombre;
    END IF;

    DELETE FROM core.menu_categorias WHERE id = p_categoria_id;
END;
$$;


/* ============================================================================
   4. API REST · SINCRONIZAR LO QUE CAMBIÓ EN EL PANEL
   ----------------------------------------------------------------------------
   POST /rpc/sincronizar_catalogo  { "p_cambios": { … } }

   p_cambios trae sólo lo que cambió, con la forma que usa la aplicación:
     categorias           [{ id, nombre, icono, orden, activa, sucursales }]
     productos            [{ id, codigo, cat, nombre, desc, precio, tag, orden,
                             activo, agotado, sucursales, imagen }]
     productos_borrados   ["p12", …]
     categorias_borradas  ["c3", …]
     menus                [{ id, sucursalId, fecha, tipo, publico,
                             armado: { nombre, descripcion, precio, disponible,
                                       categorias: [{ id, nombre, icono, obligatoria,
                                                      maxSeleccion, activa,
                                                      opciones: [{ id, nombre, activa }] }] } }]
                          (fecha "*" = título y mensaje de la unidad)
     platos_borrados      ["d8", …]
     platos               [{ id, sucursalId, fecha, nombre, desc, emoji, precio,
                             cupos, disponible, orden }]

   Un id sin el prefijo de la base (p, c, m, mc, mo, d) es un registro nuevo.
   Devuelve { "desactivados": ["p12"] }: productos que se ocultaron en vez
   de borrarse porque ya tenían ventas.
   ============================================================================ */

CREATE OR REPLACE FUNCTION rest.sincronizar_catalogo(p_cambios JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
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
$$;


/* ============================================================================
   5. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_id_de_app(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION core.fn_exigir_unidades(INTEGER, INTEGER, INTEGER[]) FROM PUBLIC;

REVOKE ALL ON PROCEDURE api.sp_guardar_categoria(INTEGER, VARCHAR, INTEGER[], INTEGER, VARCHAR, INTEGER, BOOLEAN, INTEGER),
                        api.sp_borrar_categoria(INTEGER, INTEGER, INTEGER),
                        api.sp_guardar_producto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER[], INTEGER, VARCHAR,
                                                VARCHAR, BOOLEAN, INTEGER, VARCHAR, INTEGER),
                        api.sp_borrar_producto(INTEGER, INTEGER, INTEGER, BOOLEAN),
                        api.sp_guardar_menu_categoria(BIGINT, VARCHAR, INTEGER, INTEGER, BOOLEAN, VARCHAR, BOOLEAN, INTEGER, BIGINT),
                        api.sp_guardar_menu_opcion(BIGINT, VARCHAR, INTEGER, BOOLEAN, INTEGER, BIGINT),
                        api.sp_guardar_plato_dia(BIGINT, VARCHAR, NUMERIC, INTEGER, VARCHAR, VARCHAR, INTEGER, BOOLEAN, INTEGER,
                                                 VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT),
                        api.sp_borrar_plato_dia(BIGINT, INTEGER),
                        api.sp_borrar_menu_opcion(BIGINT, INTEGER),
                        api.sp_borrar_menu_categoria(BIGINT, INTEGER)
       FROM PUBLIC;

GRANT EXECUTE ON PROCEDURE api.sp_guardar_categoria(INTEGER, VARCHAR, INTEGER[], INTEGER, VARCHAR, INTEGER, BOOLEAN, INTEGER),
                           api.sp_borrar_categoria(INTEGER, INTEGER, INTEGER),
                           api.sp_guardar_producto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER[], INTEGER, VARCHAR,
                                                   VARCHAR, BOOLEAN, INTEGER, VARCHAR, INTEGER),
                           api.sp_borrar_producto(INTEGER, INTEGER, INTEGER, BOOLEAN),
                           api.sp_guardar_menu_categoria(BIGINT, VARCHAR, INTEGER, INTEGER, BOOLEAN, VARCHAR, BOOLEAN, INTEGER, BIGINT),
                           api.sp_guardar_menu_opcion(BIGINT, VARCHAR, INTEGER, BOOLEAN, INTEGER, BIGINT),
                           api.sp_guardar_plato_dia(BIGINT, VARCHAR, NUMERIC, INTEGER, VARCHAR, VARCHAR, INTEGER, BOOLEAN, INTEGER,
                                                 VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT),
                           api.sp_borrar_plato_dia(BIGINT, INTEGER),
                           api.sp_borrar_menu_opcion(BIGINT, INTEGER),
                           api.sp_borrar_menu_categoria(BIGINT, INTEGER)
      TO taseca_app;

-- Las funciones nuevas de rest nacen ejecutables por PUBLIC: se cierra
REVOKE ALL ON FUNCTION rest.sincronizar_catalogo(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.sincronizar_catalogo(JSONB) TO taseca_app;

-- PostgREST vuelve a leer el esquema sin reiniciarlo
NOTIFY pgrst, 'reload schema';
