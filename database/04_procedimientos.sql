/* ============================================================================
   TASECA · 04 · PROCEDIMIENTOS Y FUNCIONES DE LA API (esquema api)
   ----------------------------------------------------------------------------
   Toda escritura de la aplicación pasa por aquí. Cada procedimiento:
     1. fija el usuario de la operación (auditoría e historial),
     2. comprueba el permiso del rol y el módulo de la empresa,
     3. comprueba que el usuario trabaje en esa unidad,
     4. escribe; los triggers de 03 garantizan el resto de reglas.

   SECURITY DEFINER: se ejecutan con los privilegios del dueño. Así el rol
   de la aplicación sólo necesita EXECUTE sobre api, nunca acceso a core.
   `SET search_path` fijo evita que alguien los engañe con otro esquema.

   Llamada desde DBeaver o la aplicación (parámetros por nombre):
     CALL api.sp_crear_pedido(p_unidad_id => 4, p_tipo => 'domicilio', ...);
   Los parámetros INOUT devuelven el resultado (id, código).

   p_usuario_id NULL = operación sin sesión: el cliente del portal público
   (crear pedido) o la carga de datos del DBA.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   0. APOYO
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_preparar_operacion(p_usuario_id INTEGER, p_permiso TEXT, p_unidad_id INTEGER DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_usuario_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.usuarios WHERE id = p_usuario_id AND activo) THEN
        RAISE EXCEPTION 'El usuario % no existe o está inactivo.', p_usuario_id
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    PERFORM core.fn_fijar_usuario(p_usuario_id);

    IF p_permiso IS NOT NULL THEN
        PERFORM core.fn_exigir_permiso(p_usuario_id, p_permiso);
    END IF;

    IF p_unidad_id IS NOT NULL AND NOT core.fn_usuario_en_unidad(p_usuario_id, p_unidad_id) THEN
        RAISE EXCEPTION 'El usuario % no trabaja en la unidad %.', p_usuario_id, p_unidad_id
              USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;

/* Para las acciones que admiten varios permisos (el cocinero avanza su
   pedido, el domiciliario el suyo…). */
CREATE OR REPLACE FUNCTION core.fn_exigir_alguno(p_usuario_id INTEGER, p_permisos TEXT[])
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    IF p_usuario_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM unnest(p_permisos) p WHERE core.fn_tiene_permiso(p_usuario_id, p)) THEN
        RAISE EXCEPTION 'El usuario % no tiene ninguno de los permisos: %.', p_usuario_id, array_to_string(p_permisos, ', ')
              USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;


/* ============================================================================
   1. ACCESO
   ============================================================================ */

/* Devuelve el usuario si el PIN es correcto; ninguna fila si no. No dice
   cuál de los dos datos falló, a propósito. */
CREATE OR REPLACE FUNCTION api.fn_login(p_usuario VARCHAR, p_pin VARCHAR)
RETURNS TABLE (usuario_id INTEGER, nombre VARCHAR, usuario VARCHAR, rol VARCHAR,
               alcance VARCHAR, empresa_id INTEGER, empresa VARCHAR)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER;
BEGIN
    SELECT u.id INTO v_id
      FROM core.usuarios u
      LEFT JOIN core.empresas e ON e.id = u.empresa_id
     WHERE lower(u.usuario) = lower(trim(p_usuario))
       AND u.activo
       AND (e.id IS NULL OR e.estado = 'activa')
       AND core.fn_pin_valido(p_pin, u.pin_hash);

    IF v_id IS NULL THEN
        RETURN;
    END IF;

    UPDATE core.usuarios SET ultimo_acceso = now() WHERE id = v_id;

    RETURN QUERY
    SELECT u.id, u.nombre, u.usuario, r.codigo, r.alcance, u.empresa_id, e.nombre_comercial
      FROM core.usuarios u
      JOIN core.roles r ON r.id = u.rol_id
      LEFT JOIN core.empresas e ON e.id = u.empresa_id
     WHERE u.id = v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.fn_tiene_permiso(p_usuario_id INTEGER, p_permiso VARCHAR)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT core.fn_tiene_permiso(p_usuario_id, p_permiso);
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_usuario(
    p_empresa_id      INTEGER,
    p_rol             VARCHAR,
    p_nombre          VARCHAR,
    p_usuario         VARCHAR,
    p_admin_id        INTEGER,
    p_pin             VARCHAR   DEFAULT NULL,
    p_unidades        INTEGER[] DEFAULT NULL,
    p_activo          BOOLEAN   DEFAULT TRUE,
    INOUT p_usuario_id INTEGER  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_rol     core.roles;
BEGIN
    SELECT * INTO v_rol FROM core.roles WHERE codigo = p_rol;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El rol "%" no existe.', p_rol;
    END IF;

    PERFORM core.fn_preparar_operacion(p_admin_id, CASE WHEN v_rol.alcance = 'plataforma' THEN 'plataforma' ELSE 'usuarios' END);

    -- El admin de una empresa sólo crea usuarios de SU empresa
    IF p_admin_id IS NOT NULL AND NOT core.fn_tiene_permiso(p_admin_id, 'plataforma')
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_admin_id) THEN
        RAISE EXCEPTION 'No puedes administrar usuarios de otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_usuario_id IS NULL THEN
        IF p_pin IS NULL THEN
            RAISE EXCEPTION 'Un usuario nuevo necesita PIN.';
        END IF;
        INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash, activo)
        VALUES (CASE WHEN v_rol.alcance = 'plataforma' THEN NULL ELSE p_empresa_id END,
                v_rol.id, trim(p_nombre), p_usuario, core.fn_hash_pin(p_pin), p_activo)
        RETURNING id INTO p_usuario_id;
    ELSE
        UPDATE core.usuarios
           SET rol_id   = v_rol.id,
               nombre   = trim(p_nombre),
               usuario  = p_usuario,
               activo   = p_activo,
               pin_hash = CASE WHEN p_pin IS NULL THEN pin_hash ELSE core.fn_hash_pin(p_pin) END
         WHERE id = p_usuario_id
           AND (empresa_id = p_empresa_id OR (empresa_id IS NULL AND v_rol.alcance = 'plataforma'));
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El usuario % no existe en esa empresa.', p_usuario_id;
        END IF;
    END IF;

    IF p_unidades IS NOT NULL THEN
        DELETE FROM core.usuario_unidades WHERE usuario_id = p_usuario_id AND unidad_id <> ALL (p_unidades);
        INSERT INTO core.usuario_unidades (usuario_id, unidad_id)
        SELECT p_usuario_id, x FROM unnest(p_unidades) x
        ON CONFLICT (usuario_id, unidad_id) DO NOTHING;
    END IF;
END;
$$;


/* ============================================================================
   2. UNIDADES / LOCALES
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_guardar_unidad(
    p_empresa_id     INTEGER,
    p_nombre         VARCHAR,
    p_tipo_negocio   VARCHAR,
    p_usuario_id     INTEGER,
    p_nombre_corto   VARCHAR DEFAULT NULL,
    p_direccion      VARCHAR DEFAULT NULL,
    p_ciudad         VARCHAR DEFAULT NULL,
    p_telefono       VARCHAR DEFAULT NULL,
    p_whatsapp       VARCHAR DEFAULT NULL,
    p_horario        VARCHAR DEFAULT NULL,
    p_mapa_url       VARCHAR DEFAULT NULL,
    p_mesas          INTEGER DEFAULT NULL,
    INOUT p_unidad_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_corto VARCHAR := COALESCE(NULLIF(trim(p_nombre_corto), ''), left(trim(p_nombre), 40));
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');

    IF length(trim(COALESCE(p_nombre, ''))) < 2 THEN
        RAISE EXCEPTION 'La unidad necesita un nombre.';
    END IF;

    IF p_unidad_id IS NULL THEN
        INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto, direccion, ciudad,
                                   telefono, whatsapp, horario, mapa_url)
        VALUES (p_empresa_id, core.fn_id_catalogo('tipos_negocio', p_tipo_negocio), trim(p_nombre), v_corto,
                p_direccion, p_ciudad, p_telefono, p_whatsapp, p_horario, p_mapa_url)
        RETURNING id INTO p_unidad_id;
    ELSE
        UPDATE core.unidades
           SET tipo_negocio_id = core.fn_id_catalogo('tipos_negocio', p_tipo_negocio),
               nombre = trim(p_nombre), nombre_corto = v_corto, direccion = p_direccion,
               ciudad = p_ciudad, telefono = p_telefono, whatsapp = p_whatsapp,
               horario = p_horario, mapa_url = p_mapa_url
         WHERE id = p_unidad_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La unidad % no existe en la empresa %.', p_unidad_id, p_empresa_id;
        END IF;
    END IF;

    -- Mesas numeradas 1..N (nunca se borran las que ya tienen pedidos: se desactivan)
    IF p_mesas IS NOT NULL THEN
        INSERT INTO core.mesas (unidad_id, numero)
        SELECT p_unidad_id, g::TEXT FROM generate_series(1, p_mesas) g
        ON CONFLICT (unidad_id, numero) DO UPDATE SET activa = TRUE;
        UPDATE core.mesas SET activa = FALSE
         WHERE unidad_id = p_unidad_id AND numero ~ '^[0-9]+$' AND numero::INTEGER > p_mesas;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_cambiar_estado_unidad(p_unidad_id INTEGER, p_activa BOOLEAN, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    UPDATE core.unidades SET estado = CASE WHEN p_activa THEN 'activa' ELSE 'inactiva' END
     WHERE id = p_unidad_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;
END;
$$;


/* ============================================================================
   3. CARTA
   ============================================================================ */

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
    INOUT p_producto_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_etiqueta INTEGER := CASE WHEN p_etiqueta IS NULL THEN NULL
                               ELSE core.fn_id_catalogo('etiquetas_producto', p_etiqueta) END;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');

    IF p_unidades IS NULL OR cardinality(p_unidades) = 0 THEN
        RAISE EXCEPTION 'El producto debe venderse al menos en una unidad.';
    END IF;

    IF p_producto_id IS NULL THEN
        INSERT INTO core.productos (empresa_id, categoria_id, etiqueta_id, codigo, nombre, descripcion,
                                    precio, activo, orden)
        VALUES (p_empresa_id, p_categoria_id, v_etiqueta, upper(trim(p_codigo)), trim(p_nombre), p_descripcion,
                p_precio, p_activo,
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 10 FROM core.productos WHERE empresa_id = p_empresa_id)))
        RETURNING id INTO p_producto_id;
    ELSE
        UPDATE core.productos
           SET categoria_id = p_categoria_id, etiqueta_id = v_etiqueta, codigo = upper(trim(p_codigo)),
               nombre = trim(p_nombre), descripcion = p_descripcion, precio = p_precio,
               activo = p_activo, orden = COALESCE(p_orden, orden)
         WHERE id = p_producto_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El producto % no existe en la empresa %.', p_producto_id, p_empresa_id;
        END IF;
    END IF;

    DELETE FROM core.producto_unidades WHERE producto_id = p_producto_id AND unidad_id <> ALL (p_unidades);
    INSERT INTO core.producto_unidades (producto_id, unidad_id)
    SELECT p_producto_id, x FROM unnest(p_unidades) x
    ON CONFLICT (producto_id, unidad_id) DO NOTHING;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_marcar_agotado(p_producto_id INTEGER, p_unidad_id INTEGER, p_agotado BOOLEAN, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta', p_unidad_id);
    UPDATE core.producto_unidades SET agotado = p_agotado
     WHERE producto_id = p_producto_id AND unidad_id = p_unidad_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto % no se vende en la unidad %.', p_producto_id, p_unidad_id;
    END IF;
END;
$$;


/* ============================================================================
   4. MENÚ DEL DÍA
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_dia(
    p_unidad_id    INTEGER,
    p_fecha        DATE,
    p_tipo         VARCHAR,
    p_usuario_id   INTEGER,
    p_nombre       VARCHAR DEFAULT NULL,
    p_descripcion  VARCHAR DEFAULT NULL,
    p_precio       NUMERIC DEFAULT NULL,
    p_disponible   BOOLEAN DEFAULT TRUE,
    p_titulo       VARCHAR DEFAULT NULL,
    p_mensaje      VARCHAR DEFAULT NULL,
    INOUT p_menu_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu', p_unidad_id);

    INSERT INTO core.menus_dia (unidad_id, fecha, tipo_menu_id, nombre, descripcion, precio, disponible,
                                titulo_publico, mensaje_publico, creado_por_id)
    VALUES (p_unidad_id, p_fecha, core.fn_id_catalogo('tipos_menu', p_tipo), p_nombre, p_descripcion,
            p_precio, p_disponible, NULLIF(trim(p_titulo), ''), NULLIF(trim(p_mensaje), ''), p_usuario_id)
    ON CONFLICT (unidad_id, fecha) DO UPDATE
       SET tipo_menu_id    = EXCLUDED.tipo_menu_id,
           nombre          = EXCLUDED.nombre,
           descripcion     = EXCLUDED.descripcion,
           precio          = EXCLUDED.precio,
           disponible      = EXCLUDED.disponible,
           titulo_publico  = EXCLUDED.titulo_publico,
           mensaje_publico = EXCLUDED.mensaje_publico
    RETURNING id INTO p_menu_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_categoria(
    p_menu_dia_id    BIGINT,
    p_nombre         VARCHAR,
    p_usuario_id     INTEGER,
    p_max_seleccion  INTEGER  DEFAULT 1,
    p_obligatoria    BOOLEAN  DEFAULT TRUE,
    p_icono          VARCHAR  DEFAULT NULL,
    p_activa         BOOLEAN  DEFAULT TRUE,
    INOUT p_categoria_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT unidad_id FROM core.menus_dia WHERE id = p_menu_dia_id));

    IF p_categoria_id IS NULL THEN
        INSERT INTO core.menu_categorias (menu_dia_id, nombre, icono, orden, obligatoria, max_seleccion, activa)
        VALUES (p_menu_dia_id, trim(p_nombre), p_icono,
                (SELECT COALESCE(max(orden), 0) + 1 FROM core.menu_categorias WHERE menu_dia_id = p_menu_dia_id),
                p_obligatoria, p_max_seleccion, p_activa)
        RETURNING id INTO p_categoria_id;
    ELSE
        UPDATE core.menu_categorias
           SET nombre = trim(p_nombre), icono = p_icono, obligatoria = p_obligatoria,
               max_seleccion = p_max_seleccion, activa = p_activa
         WHERE id = p_categoria_id AND menu_dia_id = p_menu_dia_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_menu_opcion(
    p_menu_categoria_id BIGINT,
    p_nombre            VARCHAR,
    p_usuario_id        INTEGER,
    p_activa            BOOLEAN DEFAULT TRUE,
    INOUT p_opcion_id   BIGINT  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT m.unidad_id FROM core.menu_categorias c JOIN core.menus_dia m ON m.id = c.menu_dia_id
              WHERE c.id = p_menu_categoria_id));

    IF p_opcion_id IS NULL THEN
        INSERT INTO core.menu_opciones (menu_categoria_id, nombre, orden, activa)
        VALUES (p_menu_categoria_id, trim(p_nombre),
                (SELECT COALESCE(max(orden), 0) + 1 FROM core.menu_opciones WHERE menu_categoria_id = p_menu_categoria_id),
                p_activa)
        RETURNING id INTO p_opcion_id;
    ELSE
        UPDATE core.menu_opciones SET nombre = trim(p_nombre), activa = p_activa
         WHERE id = p_opcion_id AND menu_categoria_id = p_menu_categoria_id;
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
    INOUT p_plato_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu',
            (SELECT unidad_id FROM core.menus_dia WHERE id = p_menu_dia_id));

    IF p_plato_id IS NULL THEN
        INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, disponible, orden)
        VALUES (p_menu_dia_id, trim(p_nombre), p_descripcion, p_emoji, p_precio, p_cupos, p_disponible,
                (SELECT COALESCE(max(orden), 0) + 1 FROM core.platos_dia WHERE menu_dia_id = p_menu_dia_id))
        RETURNING id INTO p_plato_id;
    ELSE
        UPDATE core.platos_dia
           SET nombre = trim(p_nombre), descripcion = p_descripcion, emoji = p_emoji,
               precio = p_precio, cupos = p_cupos, disponible = p_disponible
         WHERE id = p_plato_id AND menu_dia_id = p_menu_dia_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_texto_menu_unidad(p_unidad_id INTEGER, p_titulo VARCHAR, p_mensaje VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'menu', p_unidad_id);
    INSERT INTO core.textos_menu_unidad (unidad_id, titulo, mensaje)
    VALUES (p_unidad_id, NULLIF(trim(p_titulo), ''), NULLIF(trim(p_mensaje), ''))
    ON CONFLICT (unidad_id) DO UPDATE
       SET titulo = EXCLUDED.titulo, mensaje = EXCLUDED.mensaje, actualizado_en = now();
END;
$$;

/* Copia el menú de una fecha a otra: modalidad, textos, categorías con sus
   opciones y platos del chef. Si el destino ya tiene menú, no lo pisa. */
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

    INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, disponible, orden)
    SELECT p_menu_id, nombre, descripcion, emoji, precio, cupos, disponible, orden
      FROM core.platos_dia WHERE menu_dia_id = v_origen.id;
END;
$$;


/* ============================================================================
   5. PEDIDOS / FACTURAS
   ============================================================================ */

/* Crea el pedido con sus ítems en una sola transacción.

   p_items (jsonb), una línea por elemento:
     [ {"producto_id": 12, "cantidad": 2, "notas": "sin cebolla"},
       {"plato_dia_id": 5, "cantidad": 1},
       {"menu_dia_id": 3, "cantidad": 1, "opciones": [10, 14, 15, 19]} ]

   El cliente del portal no tiene sesión: p_usuario_id NULL. */
CREATE OR REPLACE PROCEDURE api.sp_crear_pedido(
    p_unidad_id         INTEGER,
    p_tipo              VARCHAR,
    p_metodo_pago       VARCHAR,
    p_items             JSONB,
    p_usuario_id        INTEGER DEFAULT NULL,
    p_mesa              VARCHAR DEFAULT NULL,
    p_cliente_nombre    VARCHAR DEFAULT NULL,
    p_cliente_telefono  VARCHAR DEFAULT NULL,
    p_direccion         VARCHAR DEFAULT NULL,
    p_indicaciones      VARCHAR DEFAULT NULL,
    p_zona_id           INTEGER DEFAULT NULL,
    p_paga_con          NUMERIC DEFAULT NULL,
    INOUT p_pedido_id   BIGINT  DEFAULT NULL,
    INOUT p_codigo      VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa   INTEGER := core.fn_empresa_de_unidad(p_unidad_id);
    v_metodo    INTEGER := core.fn_id_catalogo('metodos_pago', p_metodo_pago);
    v_tipo      INTEGER := core.fn_id_catalogo('tipos_pedido', p_tipo);
    v_cliente   BIGINT;
    v_mesa      INTEGER;
    v_linea     JSONB;
    v_item      BIGINT;
    v_minimo    NUMERIC;
    v_falta     TEXT;
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, NULL, p_unidad_id);
    IF p_usuario_id IS NOT NULL THEN
        PERFORM core.fn_exigir_alguno(p_usuario_id, ARRAY['pedidos_mesa', 'pedidos_gestionar']);
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'El pedido está vacío.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago
                    WHERE empresa_id = v_empresa AND metodo_pago_id = v_metodo AND activo) THEN
        RAISE EXCEPTION 'El método de pago "%" no está disponible.', p_metodo_pago;
    END IF;

    IF p_tipo = 'domicilio' THEN
        IF length(trim(COALESCE(p_cliente_nombre, ''))) < 3 THEN
            RAISE EXCEPTION 'Escribe tu nombre completo.';
        END IF;
        IF regexp_replace(COALESCE(p_cliente_telefono, ''), '\D', '', 'g') !~ '^[0-9]{7,10}$' THEN
            RAISE EXCEPTION 'El celular debe tener entre 7 y 10 dígitos.';
        END IF;
        INSERT INTO core.clientes (empresa_id, nombre, telefono)
        VALUES (v_empresa, trim(p_cliente_nombre), regexp_replace(p_cliente_telefono, '\D', '', 'g'))
        ON CONFLICT (empresa_id, telefono) DO UPDATE SET nombre = EXCLUDED.nombre
        RETURNING id INTO v_cliente;
    ELSIF p_tipo = 'mesa' THEN
        SELECT id INTO v_mesa FROM core.mesas
         WHERE unidad_id = p_unidad_id AND numero = trim(p_mesa) AND activa;
        IF v_mesa IS NULL THEN
            RAISE EXCEPTION 'La mesa "%" no existe en esta unidad.', p_mesa;
        END IF;
    END IF;

    INSERT INTO core.pedidos (unidad_id, tipo_pedido_id, metodo_pago_id, mesa_id, cliente_id,
                              zona_domicilio_id, direccion_entrega, indicaciones, paga_con, tomado_por_id)
    VALUES (p_unidad_id, v_tipo, v_metodo, v_mesa, v_cliente, p_zona_id,
            NULLIF(trim(p_direccion), ''), NULLIF(trim(p_indicaciones), ''), p_paga_con, p_usuario_id)
    RETURNING id, codigo INTO p_pedido_id, p_codigo;

    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        INSERT INTO core.pedido_items (pedido_id, producto_id, plato_dia_id, menu_dia_id, cantidad, notas)
        VALUES (p_pedido_id,
                (v_linea ->> 'producto_id')::INTEGER,
                (v_linea ->> 'plato_dia_id')::BIGINT,
                (v_linea ->> 'menu_dia_id')::BIGINT,
                COALESCE((v_linea ->> 'cantidad')::INTEGER, 1),
                NULLIF(trim(v_linea ->> 'notas'), ''))
        RETURNING id INTO v_item;

        IF v_linea ? 'menu_dia_id' THEN
            INSERT INTO core.pedido_item_opciones (pedido_item_id, menu_opcion_id)
            SELECT v_item, x::BIGINT FROM jsonb_array_elements_text(COALESCE(v_linea -> 'opciones', '[]')) x;

            -- Toda categoría obligatoria con opciones activas debe tener al menos una elegida
            SELECT string_agg(c.nombre, ', ' ORDER BY c.orden) INTO v_falta
              FROM core.menu_categorias c
             WHERE c.menu_dia_id = (v_linea ->> 'menu_dia_id')::BIGINT
               AND c.activa AND c.obligatoria
               AND EXISTS (SELECT 1 FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id AND o.activa)
               AND NOT EXISTS (SELECT 1 FROM core.pedido_item_opciones x
                                 JOIN core.menu_opciones o ON o.id = x.menu_opcion_id
                                WHERE x.pedido_item_id = v_item AND o.menu_categoria_id = c.id);
            IF v_falta IS NOT NULL THEN
                RAISE EXCEPTION 'Te falta elegir: %.', v_falta;
            END IF;
        END IF;
    END LOOP;

    SELECT pedido_minimo INTO v_minimo FROM core.zonas_domicilio WHERE id = p_zona_id;
    IF v_minimo IS NOT NULL AND core.fn_subtotal_pedido(p_pedido_id) < v_minimo THEN
        RAISE EXCEPTION 'El pedido mínimo para esta zona es %.', v_minimo;
    END IF;
END;
$$;

/* Pasa al siguiente estado del flujo (una mesa no pasa por «en camino»). */
CREATE OR REPLACE PROCEDURE api.sp_avanzar_estado_pedido(p_pedido_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_siguiente INTEGER := core.fn_siguiente_estado(p_pedido_id);
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, NULL,
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    PERFORM core.fn_exigir_alguno(p_usuario_id,
            ARRAY['pedidos_gestionar', 'pedidos_cocina', 'pedidos_listos', 'pedidos_domicilio']);

    IF v_siguiente IS NULL THEN
        RAISE EXCEPTION 'El pedido % ya no tiene un estado siguiente.', p_pedido_id;
    END IF;
    UPDATE core.pedidos SET estado_pedido_id = v_siguiente WHERE id = p_pedido_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_cambiar_estado_pedido(p_pedido_id BIGINT, p_estado VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    IF p_estado IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'Para cancelar usa api.sp_cancelar_pedido y para anular api.sp_anular_pedido.';
    END IF;
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_gestionar',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', p_estado)
     WHERE id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_cancelar_pedido(p_pedido_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_cancelar',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    IF (SELECT e.codigo FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
         WHERE p.id = p_pedido_id) = 'entregado' THEN
        RAISE EXCEPTION 'Un pedido entregado ya es una venta: no se cancela, se anula.';
    END IF;
    UPDATE core.pedidos
       SET estado_pedido_id   = core.fn_id_catalogo('estados_pedido', 'cancelado'),
           motivo_cancelacion = trim(p_motivo)
     WHERE id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;
END;
$$;

/* ANULAR una factura: la venta se hizo y se echa atrás.
     · queda con motivo, quién y cuándo (core.anulaciones)
     · lo que consumió vuelve al inventario como entrada 'retorno_anulacion'
     · área por área: si esa jornada YA tiene cierre de inventario, el
       retorno se imputa a la jornada de hoy para no alterar un cierre hecho
     · nada se borra */
CREATE OR REPLACE PROCEDURE api.sp_anular_pedido(p_pedido_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_pedido     core.pedidos;
    v_estado     VARCHAR;
    v_hoy        DATE;
    v_retorno    DATE;
    v_diferido   BOOLEAN := FALSE;
    v_consumo    RECORD;
BEGIN
    SELECT * INTO v_pedido FROM core.pedidos WHERE id = p_pedido_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa factura no existe.';
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_anular', v_pedido.unidad_id);

    SELECT codigo INTO v_estado FROM core.estados_pedido WHERE id = v_pedido.estado_pedido_id;
    IF v_estado = 'anulado' THEN
        RAISE EXCEPTION 'Esa factura ya está anulada. No se puede anular dos veces.';
    ELSIF v_estado = 'cancelado' THEN
        RAISE EXCEPTION 'Ese pedido está cancelado: nunca fue una venta efectiva, no hay nada que anular.';
    ELSIF length(trim(COALESCE(p_motivo, ''))) < 3 THEN
        RAISE EXCEPTION 'Hay que escribir el motivo de la anulación.';
    END IF;

    v_hoy := core.fn_fecha_operativa(v_pedido.empresa_id, now());

    -- ¿Alguna área consumida ya tiene cierre en la jornada original?
    SELECT EXISTS (
        SELECT 1
          FROM core.pedido_items i
          JOIN core.producto_insumos pi ON pi.producto_id = i.producto_id
          JOIN core.insumos s           ON s.id = pi.insumo_id
          JOIN core.cierres_inventario c
            ON c.unidad_id = v_pedido.unidad_id AND c.area_id = s.area_id
           AND c.fecha_operativa = v_pedido.fecha_operativa
         WHERE i.pedido_id = p_pedido_id
    ) INTO v_diferido;

    /* El retorno nunca cae en la jornada ya cerrada: si se anula el mismo
       día del cierre, va a la jornada siguiente. */
    v_hoy     := GREATEST(v_hoy, v_pedido.fecha_operativa + 1);
    v_retorno := CASE WHEN v_diferido THEN v_hoy ELSE v_pedido.fecha_operativa END;

    INSERT INTO core.anulaciones (pedido_id, motivo, usuario_id, jornada_original, jornada_retorno)
    VALUES (p_pedido_id, trim(p_motivo), p_usuario_id, v_pedido.fecha_operativa, v_retorno);

    FOR v_consumo IN
        SELECT iu.id AS insumo_unidad_id, s.area_id,
               SUM(i.cantidad * pi.cantidad) AS cantidad,
               EXISTS (SELECT 1 FROM core.cierres_inventario c
                        WHERE c.unidad_id = v_pedido.unidad_id AND c.area_id = s.area_id
                          AND c.fecha_operativa = v_pedido.fecha_operativa) AS area_cerrada
          FROM core.pedido_items i
          JOIN core.producto_insumos pi ON pi.producto_id = i.producto_id
          JOIN core.insumos s           ON s.id = pi.insumo_id
          JOIN core.insumo_unidades iu  ON iu.insumo_id = s.id AND iu.unidad_id = v_pedido.unidad_id
         WHERE i.pedido_id = p_pedido_id
         GROUP BY iu.id, s.area_id
    LOOP
        /* Nunca las dos cosas a la vez, o el inventario vuelve dos veces:
             · área SIN cierre en esa jornada → basta con que la factura
               anulada deje de contar en las ventas (Z) de su jornada
             · área YA cerrada → ese cierre no se toca; la mercancía vuelve
               como entrada de la jornada de hoy */
        CONTINUE WHEN NOT v_consumo.area_cerrada;

        INSERT INTO core.entradas_inventario (insumo_unidad_id, tipo_entrada_id, fecha_operativa, cantidad,
                                              observacion, pedido_id, usuario_id)
        VALUES (v_consumo.insumo_unidad_id, core.fn_id_catalogo('tipos_entrada', 'retorno_anulacion'),
                v_hoy, v_consumo.cantidad,
                'Retorno por anulación de la factura ' || v_pedido.codigo ||
                ' (jornada ' || v_pedido.fecha_operativa || '). Motivo: ' || trim(p_motivo),
                p_pedido_id, p_usuario_id);
    END LOOP;

    UPDATE core.pedidos SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'anulado')
     WHERE id = p_pedido_id;

    INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
    VALUES (p_pedido_id, 'Factura ANULADA: ' || trim(p_motivo) ||
            CASE WHEN v_diferido THEN ' · retorno imputado a la jornada ' || v_retorno ELSE '' END,
            p_usuario_id);
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_actualizar_pago(p_pedido_id BIGINT, p_estado_pago VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pagos',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    UPDATE core.pedidos SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago)
     WHERE id = p_pedido_id;
    UPDATE core.comprobantes_pago
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago),
           revisado_por_id = p_usuario_id, revisado_en = now()
     WHERE pedido_id = p_pedido_id AND revisado_en IS NULL;
END;
$$;

/* El cliente adjunta el comprobante de su transferencia: el pago queda
   «reportado» hasta que caja lo confirme o lo rechace. */
CREATE OR REPLACE PROCEDURE api.sp_registrar_comprobante(p_pedido_id BIGINT, p_archivo_url VARCHAR, INOUT p_comprobante_id BIGINT DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_fijar_usuario(NULL);
    INSERT INTO core.comprobantes_pago (pedido_id, archivo_url, estado_pago_id)
    VALUES (p_pedido_id, p_archivo_url, core.fn_id_catalogo('estados_pago', 'reportado'))
    RETURNING id INTO p_comprobante_id;
    UPDATE core.pedidos SET estado_pago_id = core.fn_id_catalogo('estados_pago', 'reportado')
     WHERE id = p_pedido_id;
END;
$$;


/* ============================================================================
   6. INVENTARIO
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_registrar_entrada(
    p_unidad_id    INTEGER,
    p_insumo_id    INTEGER,
    p_tipo         VARCHAR,
    p_cantidad     NUMERIC,
    p_usuario_id   INTEGER,
    p_observacion  VARCHAR DEFAULT NULL,
    p_fecha        DATE    DEFAULT NULL,
    INOUT p_entrada_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_insumo_unidad INTEGER;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'entradas', p_unidad_id);

    IF (SELECT automatico FROM core.tipos_entrada WHERE codigo = p_tipo) THEN
        RAISE EXCEPTION 'Las entradas de tipo "%" las genera el sistema.', p_tipo;
    END IF;

    SELECT iu.id INTO v_insumo_unidad
      FROM core.insumo_unidades iu JOIN core.insumos i ON i.id = iu.insumo_id
     WHERE iu.insumo_id = p_insumo_id AND iu.unidad_id = p_unidad_id AND i.activo;
    IF v_insumo_unidad IS NULL THEN
        RAISE EXCEPTION 'El insumo % no está activo en la unidad %.', p_insumo_id, p_unidad_id;
    END IF;

    INSERT INTO core.entradas_inventario (insumo_unidad_id, tipo_entrada_id, fecha_operativa, cantidad, observacion, usuario_id)
    VALUES (v_insumo_unidad, core.fn_id_catalogo('tipos_entrada', p_tipo), p_fecha, p_cantidad,
            NULLIF(trim(p_observacion), ''), p_usuario_id)
    RETURNING id INTO p_entrada_id;
END;
$$;

/* Registra (o corrige, si no está revisado) el conteo físico de un área.
   p_detalle: [ {"insumo_id": 7, "saldo": 24}, … ] */
CREATE OR REPLACE PROCEDURE api.sp_registrar_cierre(
    p_unidad_id    INTEGER,
    p_area         VARCHAR,
    p_detalle      JSONB,
    p_usuario_id   INTEGER,
    p_fecha        DATE    DEFAULT NULL,
    p_observacion  VARCHAR DEFAULT NULL,
    INOUT p_cierre_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_area   INTEGER := core.fn_id_catalogo('areas_inventario', p_area);
    v_fecha  DATE    := COALESCE(p_fecha, core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now()));
    v_linea  JSONB;
    v_iu     INTEGER;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'cierres_registrar', p_unidad_id);

    IF p_detalle IS NULL OR jsonb_array_length(p_detalle) = 0 THEN
        RAISE EXCEPTION 'El cierre no tiene productos contados.';
    END IF;

    INSERT INTO core.cierres_inventario (unidad_id, area_id, estado_cierre_id, fecha_operativa, observacion, registrado_por_id)
    VALUES (p_unidad_id, v_area, core.fn_id_catalogo('estados_cierre', 'completado'), v_fecha,
            NULLIF(trim(p_observacion), ''), p_usuario_id)
    ON CONFLICT (unidad_id, area_id, fecha_operativa) DO UPDATE
       SET observacion = EXCLUDED.observacion, registrado_por_id = EXCLUDED.registrado_por_id,
           estado_cierre_id = EXCLUDED.estado_cierre_id
    RETURNING id INTO p_cierre_id;

    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_detalle) LOOP
        SELECT id INTO v_iu FROM core.insumo_unidades
         WHERE insumo_id = (v_linea ->> 'insumo_id')::INTEGER AND unidad_id = p_unidad_id;
        IF v_iu IS NULL THEN
            RAISE EXCEPTION 'El insumo % no es de esta unidad.', v_linea ->> 'insumo_id';
        END IF;

        INSERT INTO core.cierre_detalles (cierre_id, insumo_unidad_id, saldo_fisico)
        VALUES (p_cierre_id, v_iu, (v_linea ->> 'saldo')::NUMERIC)
        ON CONFLICT (cierre_id, insumo_unidad_id) DO UPDATE SET saldo_fisico = EXCLUDED.saldo_fisico;
    END LOOP;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_revisar_cierre(p_cierre_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'cierres_revisar',
            (SELECT unidad_id FROM core.cierres_inventario WHERE id = p_cierre_id));
    UPDATE core.cierres_inventario
       SET estado_cierre_id = core.fn_id_catalogo('estados_cierre', 'revisado'),
           revisado_por_id = p_usuario_id, revisado_en = now()
     WHERE id = p_cierre_id
       AND estado_cierre_id <> core.fn_id_catalogo('estados_cierre', 'revisado');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cierre % no existe o ya estaba revisado.', p_cierre_id;
    END IF;
END;
$$;

/* Lleva el stock actual al saldo físico contado. Es explícito a propósito:
   el sistema no descuenta stock por ventas porque aún no hay recetas. */
CREATE OR REPLACE PROCEDURE api.sp_aplicar_cierre_a_stock(p_cierre_id BIGINT, p_usuario_id INTEGER, INOUT p_aplicados INTEGER DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock',
            (SELECT unidad_id FROM core.cierres_inventario WHERE id = p_cierre_id));

    UPDATE core.insumo_unidades iu
       SET stock_actual = d.saldo_fisico, actualizado_en = now()
      FROM core.cierre_detalles d
     WHERE d.cierre_id = p_cierre_id AND d.insumo_unidad_id = iu.id;
    GET DIAGNOSTICS p_aplicados = ROW_COUNT;

    UPDATE core.cierres_inventario SET aplicado_a_stock = TRUE WHERE id = p_cierre_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_ajustar_stock_minimo(p_unidad_id INTEGER, p_insumo_id INTEGER, p_minimo NUMERIC, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock', p_unidad_id);
    UPDATE core.insumo_unidades SET stock_minimo = p_minimo
     WHERE unidad_id = p_unidad_id AND insumo_id = p_insumo_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El insumo % no está en la unidad %.', p_insumo_id, p_unidad_id;
    END IF;
END;
$$;


/* ============================================================================
   7. CAJA Y GASTOS
   ============================================================================ */

/* Registra la base de la jornada. Si ya había una, la nueva la REEMPLAZA y la
   anterior queda guardada como no vigente. */
CREATE OR REPLACE PROCEDURE api.sp_registrar_base_caja(
    p_unidad_id    INTEGER,
    p_monto        NUMERIC,
    p_usuario_id   INTEGER,
    p_fecha        DATE    DEFAULT NULL,
    p_observacion  VARCHAR DEFAULT NULL,
    INOUT p_base_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_fecha    DATE := COALESCE(p_fecha, core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now()));
    v_anterior BIGINT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'base_caja', p_unidad_id);

    UPDATE core.bases_caja SET vigente = FALSE
     WHERE unidad_id = p_unidad_id AND fecha_operativa = v_fecha AND vigente
    RETURNING id INTO v_anterior;

    IF v_anterior IS NOT NULL AND length(trim(COALESCE(p_observacion, ''))) < 3 THEN
        RAISE EXCEPTION 'Corregir la base exige escribir el motivo.';
    END IF;

    INSERT INTO core.bases_caja (unidad_id, fecha_operativa, monto, reemplaza_a_id, observacion, usuario_id)
    VALUES (p_unidad_id, v_fecha, p_monto, v_anterior, NULLIF(trim(p_observacion), ''), p_usuario_id)
    RETURNING id INTO p_base_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_registrar_gasto(
    p_unidad_id           INTEGER,
    p_categoria_gasto_id  INTEGER,
    p_metodo_pago         VARCHAR,
    p_descripcion         VARCHAR,
    p_monto               NUMERIC,
    p_usuario_id          INTEGER,
    p_fecha               DATE DEFAULT NULL,
    INOUT p_gasto_id      BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos', p_unidad_id);
    INSERT INTO core.gastos (unidad_id, categoria_gasto_id, metodo_pago_id, estado_gasto_id,
                             fecha_operativa, descripcion, monto, registrado_por_id)
    VALUES (p_unidad_id, p_categoria_gasto_id, core.fn_id_catalogo('metodos_pago', p_metodo_pago),
            core.fn_id_catalogo('estados_gasto', 'registrado'), p_fecha, trim(p_descripcion), p_monto, p_usuario_id)
    RETURNING id INTO p_gasto_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_confirmar_gasto(p_gasto_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos_confirmar',
            (SELECT unidad_id FROM core.gastos WHERE id = p_gasto_id));
    UPDATE core.gastos
       SET estado_gasto_id = core.fn_id_catalogo('estados_gasto', 'confirmado'), confirmado_por_id = p_usuario_id
     WHERE id = p_gasto_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_anular_gasto(p_gasto_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos_anular',
            (SELECT unidad_id FROM core.gastos WHERE id = p_gasto_id));
    UPDATE core.gastos
       SET estado_gasto_id = core.fn_id_catalogo('estados_gasto', 'anulado'),
           motivo_anulacion = trim(p_motivo), anulado_por_id = p_usuario_id
     WHERE id = p_gasto_id;
END;
$$;


/* ============================================================================
   8. LIMPIEZA DE PRUEBAS
   Única excepción a «las facturas no se borran». Sólo Admin, escribiendo
   BORRAR, y sólo la empresa indicada. La numeración vuelve a 00001.
   Se lleva también los retornos por anulación de esas facturas (y descuenta
   del stock lo que habían devuelto). Cierres, gastos y menús no se tocan.
   ============================================================================ */
CREATE OR REPLACE PROCEDURE api.sp_borrar_facturas_prueba(
    p_empresa_id    INTEGER,
    p_confirmacion  VARCHAR,
    p_usuario_id    INTEGER,
    INOUT p_borradas INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_anular');

    IF upper(trim(COALESCE(p_confirmacion, ''))) <> 'BORRAR' THEN
        RAISE EXCEPTION 'Escribe BORRAR para confirmar.';
    END IF;
    IF p_usuario_id IS NOT NULL
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario_id)
       AND NOT core.fn_tiene_permiso(p_usuario_id, 'plataforma') THEN
        RAISE EXCEPTION 'No puedes borrar facturas de otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    PERFORM set_config('taseca.borrado_pruebas', 'si', TRUE);

    UPDATE core.insumo_unidades iu
       SET stock_actual = GREATEST(iu.stock_actual - e.total, 0)
      FROM (SELECT en.insumo_unidad_id, SUM(en.cantidad) AS total
              FROM core.entradas_inventario en
              JOIN core.pedidos p ON p.id = en.pedido_id
             WHERE p.empresa_id = p_empresa_id
             GROUP BY en.insumo_unidad_id) e
     WHERE iu.id = e.insumo_unidad_id;

    DELETE FROM core.entradas_inventario en USING core.pedidos p
     WHERE p.id = en.pedido_id AND p.empresa_id = p_empresa_id;
    DELETE FROM core.anulaciones a USING core.pedidos p
     WHERE p.id = a.pedido_id AND p.empresa_id = p_empresa_id;
    DELETE FROM core.pedidos WHERE empresa_id = p_empresa_id;
    GET DIAGNOSTICS p_borradas = ROW_COUNT;

    DELETE FROM core.clientes c
     WHERE c.empresa_id = p_empresa_id
       AND NOT EXISTS (SELECT 1 FROM core.pedidos p WHERE p.cliente_id = c.id);

    UPDATE core.consecutivos SET ultimo_numero = 0 WHERE empresa_id = p_empresa_id AND tipo = 'pedido';

    PERFORM set_config('taseca.borrado_pruebas', '', TRUE);
END;
$$;
