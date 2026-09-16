/* ============================================================================
   TASECA · 12 · FASE 2 · BLOQUE 2: USUARIOS Y UNIDADES / LOCALES
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 11. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · Usuarios: validaciones completas en la base (acceso único, PIN de 4 a
       6 dígitos, nadie se desactiva ni se cambia el rol a sí mismo y la
       empresa nunca se queda sin un Admin activo).
     · Unidades: color propio, logo, zonas de domicilio y mesas desde la
       aplicación. El logo vive en su propia tabla y se descarga aparte, sólo
       cuando cambia: no viaja en cada refresco del catálogo.
     · rest.usuarios (sólo para quien administra usuarios), rest.logos_unidad,
       rest.guardar_usuario y rest.guardar_unidad.

   CORRIGE
     · api.sp_cambiar_estado_unidad y api.sp_guardar_unidad no comprobaban que
       la unidad fuera de la empresa del usuario.

   SEGURIDAD
     El usuario y la empresa salen SIEMPRE del token. El PIN nunca se guarda en
     claro (bcrypt) ni sale de la base: rest.usuarios no lo publica.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

-- Color propio de la unidad (#RRGGBB). `color` sigue siendo el acento del portal.
ALTER TABLE core.unidades ADD COLUMN IF NOT EXISTS color_marca VARCHAR(7);
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_unidades_color_marca') THEN
        ALTER TABLE core.unidades
            ADD CONSTRAINT ck_unidades_color_marca CHECK (color_marca IS NULL OR color_marca ~ '^#[0-9a-f]{6}$');
    END IF;
END;
$$;

/* Logo de la unidad (1 a 1). Separado de core.unidades para que la fila de la
   unidad siga siendo liviana y el logo sólo viaje cuando cambia. Al pasar a
   Supabase, `imagen` se reemplaza por la ruta en Storage. */
CREATE TABLE IF NOT EXISTS core.unidad_logos (
    id              SERIAL PRIMARY KEY,
    unidad_id       INTEGER     NOT NULL UNIQUE REFERENCES core.unidades (id) ON DELETE CASCADE,
    imagen          TEXT        NOT NULL,
    actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_unidad_logos_imagen CHECK (imagen LIKE 'data:image/%' AND length(imagen) <= 200000)
);
COMMENT ON TABLE core.unidad_logos IS 'Logo propio de la unidad (data URL de hasta ~150 KB). Sin fila = identidad de la empresa.';

REVOKE ALL ON core.unidad_logos FROM PUBLIC;


/* ============================================================================
   2. USUARIOS
   ============================================================================ */

/* Misma firma que en 04; ahora valida todo lo que antes sólo validaba la
   pantalla. p_unidades: NULL = no cambiar · '{}' = todas las unidades. */
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
    v_rol      core.roles;
    v_nombre   VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
    v_acceso   VARCHAR := lower(trim(COALESCE(p_usuario, '')));
    v_pin      VARCHAR := NULLIF(trim(COALESCE(p_pin, '')), '');
    v_actual   core.usuarios;
    v_rol_act  VARCHAR;
    v_u        INTEGER;
BEGIN
    SELECT * INTO v_rol FROM core.roles WHERE codigo = p_rol;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El rol "%" no existe.', p_rol;
    END IF;

    PERFORM core.fn_preparar_operacion(p_admin_id, CASE WHEN v_rol.alcance = 'plataforma' THEN 'plataforma' ELSE 'usuarios' END);

    -- El admin de una empresa sólo administra usuarios de SU empresa
    IF p_admin_id IS NOT NULL AND NOT core.fn_tiene_permiso(p_admin_id, 'plataforma')
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_admin_id) THEN
        RAISE EXCEPTION 'No puedes administrar usuarios de otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El usuario necesita un nombre.';
    END IF;
    IF v_acceso !~ '^[a-z0-9._-]{3,40}$' THEN
        RAISE EXCEPTION 'El acceso debe tener entre 3 y 40 caracteres: letras sin tildes, números, punto, guion o guion bajo.';
    END IF;
    IF v_pin IS NOT NULL AND v_pin !~ '^[0-9]{4,6}$' THEN
        RAISE EXCEPTION 'El PIN debe tener entre 4 y 6 dígitos.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.usuarios WHERE lower(usuario) = v_acceso AND id IS DISTINCT FROM p_usuario_id) THEN
        RAISE EXCEPTION 'Ya existe otro usuario con el acceso "%" (puede ser de otra empresa).', v_acceso;
    END IF;

    IF p_unidades IS NOT NULL THEN
        FOREACH v_u IN ARRAY p_unidades LOOP
            IF core.fn_empresa_de_unidad(v_u) IS DISTINCT FROM p_empresa_id THEN
                RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_u USING ERRCODE = 'insufficient_privilege';
            END IF;
        END LOOP;
    END IF;

    IF p_usuario_id IS NULL THEN
        IF v_pin IS NULL THEN
            RAISE EXCEPTION 'Un usuario nuevo necesita PIN.';
        END IF;
        INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash, activo)
        VALUES (CASE WHEN v_rol.alcance = 'plataforma' THEN NULL ELSE p_empresa_id END,
                v_rol.id, v_nombre, v_acceso, core.fn_hash_pin(v_pin), COALESCE(p_activo, TRUE))
        RETURNING id INTO p_usuario_id;
    ELSE
        SELECT * INTO v_actual FROM core.usuarios
         WHERE id = p_usuario_id
           AND (empresa_id = p_empresa_id OR (empresa_id IS NULL AND v_rol.alcance = 'plataforma'));
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese usuario no existe en esta empresa.';
        END IF;
        SELECT codigo INTO v_rol_act FROM core.roles WHERE id = v_actual.rol_id;

        -- Nadie se deja por fuera a sí mismo
        IF p_usuario_id = p_admin_id THEN
            IF NOT COALESCE(p_activo, TRUE) THEN
                RAISE EXCEPTION 'No puedes desactivar tu propio usuario.';
            END IF;
            IF v_rol.id <> v_actual.rol_id THEN
                RAISE EXCEPTION 'No puedes cambiar tu propio rol.';
            END IF;
        END IF;

        -- La empresa nunca se queda sin un Admin activo
        IF v_rol_act = 'admin' AND v_actual.activo AND (p_rol <> 'admin' OR NOT COALESCE(p_activo, TRUE))
           AND NOT EXISTS (SELECT 1 FROM core.usuarios x JOIN core.roles r ON r.id = x.rol_id
                            WHERE x.empresa_id = v_actual.empresa_id AND r.codigo = 'admin'
                              AND x.activo AND x.id <> p_usuario_id) THEN
            RAISE EXCEPTION 'Debe quedar al menos un Admin activo en la empresa.';
        END IF;

        UPDATE core.usuarios
           SET rol_id   = v_rol.id,
               nombre   = v_nombre,
               usuario  = v_acceso,
               activo   = COALESCE(p_activo, activo),
               pin_hash = CASE WHEN v_pin IS NULL THEN pin_hash ELSE core.fn_hash_pin(v_pin) END
         WHERE id = p_usuario_id;
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
   3. UNIDADES / LOCALES
   ============================================================================ */

/* ¿Puede este usuario administrar las unidades de esta empresa? */
CREATE OR REPLACE FUNCTION core.fn_exigir_empresa_propia(p_usuario_id INTEGER, p_empresa_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    IF p_usuario_id IS NOT NULL AND NOT core.fn_tiene_permiso(p_usuario_id, 'plataforma')
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario_id) THEN
        RAISE EXCEPTION 'No puedes administrar otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;

/* Se reemplaza la versión de 04: color acento y color propio, nombre corto
   que no se pierde al editar, mensajes claros y control de empresa. */
DROP PROCEDURE IF EXISTS api.sp_guardar_unidad(INTEGER, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
                                               VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER);

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
    p_color          VARCHAR DEFAULT NULL,
    p_color_marca    VARCHAR DEFAULT NULL,
    INOUT p_unidad_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
    v_corto  VARCHAR := NULLIF(regexp_replace(trim(COALESCE(p_nombre_corto, '')), '\s+', ' ', 'g'), '');
    v_marca  VARCHAR := NULLIF(lower(trim(COALESCE(p_color_marca, ''))), '');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, p_empresa_id);

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'La unidad necesita un nombre.';
    END IF;
    IF v_marca IS NOT NULL AND v_marca !~ '^#[0-9a-f]{6}$' THEN
        RAISE EXCEPTION 'El color propio debe tener el formato #RRGGBB.';
    END IF;
    IF p_mesas IS NOT NULL AND (p_mesas < 0 OR p_mesas > 200) THEN
        RAISE EXCEPTION 'El número de mesas debe estar entre 0 y 200.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.unidades WHERE empresa_id = p_empresa_id AND lower(nombre) = lower(v_nombre)
                                             AND id IS DISTINCT FROM p_unidad_id) THEN
        RAISE EXCEPTION 'Ya hay otra unidad llamada "%".', v_nombre;
    END IF;

    -- Sin nombre corto: el que ya tenía, o el nombre recortado
    v_corto := COALESCE(v_corto, (SELECT nombre_corto FROM core.unidades WHERE id = p_unidad_id), left(v_nombre, 40));
    IF EXISTS (SELECT 1 FROM core.unidades WHERE empresa_id = p_empresa_id AND lower(nombre_corto) = lower(v_corto)
                                             AND id IS DISTINCT FROM p_unidad_id) THEN
        RAISE EXCEPTION 'Ya hay otra unidad con el nombre corto "%".', v_corto;
    END IF;

    IF p_unidad_id IS NULL THEN
        INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto, direccion, ciudad,
                                   telefono, whatsapp, horario, mapa_url, color, color_marca)
        VALUES (p_empresa_id, core.fn_id_catalogo('tipos_negocio', p_tipo_negocio), v_nombre, v_corto,
                NULLIF(trim(p_direccion), ''), NULLIF(trim(p_ciudad), ''), NULLIF(trim(p_telefono), ''),
                NULLIF(trim(p_whatsapp), ''), NULLIF(trim(p_horario), ''), NULLIF(trim(p_mapa_url), ''),
                COALESCE(NULLIF(trim(p_color), ''), 'azul'), v_marca)
        RETURNING id INTO p_unidad_id;
    ELSE
        UPDATE core.unidades
           SET tipo_negocio_id = core.fn_id_catalogo('tipos_negocio', p_tipo_negocio),
               nombre = v_nombre, nombre_corto = v_corto,
               direccion = NULLIF(trim(p_direccion), ''), ciudad = NULLIF(trim(p_ciudad), ''),
               telefono = NULLIF(trim(p_telefono), ''), whatsapp = NULLIF(trim(p_whatsapp), ''),
               horario = NULLIF(trim(p_horario), ''), mapa_url = NULLIF(trim(p_mapa_url), ''),
               color = COALESCE(NULLIF(trim(p_color), ''), color), color_marca = v_marca
         WHERE id = p_unidad_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Esa unidad no existe en esta empresa. Recarga la página.';
        END IF;
    END IF;

    -- Mesas numeradas 1..N (las que sobran se desactivan: pueden tener pedidos)
    IF p_mesas IS NOT NULL THEN
        INSERT INTO core.mesas (unidad_id, numero)
        SELECT p_unidad_id, g::TEXT FROM generate_series(1, p_mesas) g
        ON CONFLICT (unidad_id, numero) DO UPDATE SET activa = TRUE;
        UPDATE core.mesas SET activa = FALSE
         WHERE unidad_id = p_unidad_id AND activa AND numero ~ '^[0-9]+$' AND numero::INTEGER > p_mesas;
    END IF;
END;
$$;

/* Misma firma que en 04; ahora exige que la unidad sea de la empresa del usuario. */
CREATE OR REPLACE PROCEDURE api.sp_cambiar_estado_unidad(p_unidad_id INTEGER, p_activa BOOLEAN, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa INTEGER := core.fn_empresa_de_unidad(p_unidad_id);
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, v_empresa);

    UPDATE core.unidades SET estado = CASE WHEN p_activa THEN 'activa' ELSE 'inactiva' END
     WHERE id = p_unidad_id
       AND estado IS DISTINCT FROM CASE WHEN p_activa THEN 'activa' ELSE 'inactiva' END;
END;
$$;

/* Zona de domicilio. Si existe una con ese nombre (activa o no) se actualiza
   y queda activa. */
CREATE OR REPLACE PROCEDURE api.sp_guardar_zona(
    p_unidad_id      INTEGER,
    p_nombre         VARCHAR,
    p_costo          NUMERIC,
    p_pedido_minimo  NUMERIC,
    p_usuario_id     INTEGER,
    INOUT p_zona_id  INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, core.fn_empresa_de_unidad(p_unidad_id));

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'Cada zona necesita un nombre.';
    END IF;
    IF COALESCE(p_costo, 0) < 0 OR COALESCE(p_pedido_minimo, 0) < 0 THEN
        RAISE EXCEPTION 'El costo y el pedido mínimo de "%" no pueden ser negativos.', v_nombre;
    END IF;

    INSERT INTO core.zonas_domicilio (unidad_id, nombre, costo, pedido_minimo, activa)
    VALUES (p_unidad_id, v_nombre, COALESCE(p_costo, 0), COALESCE(p_pedido_minimo, 0), TRUE)
    ON CONFLICT (unidad_id, nombre) DO UPDATE
       SET costo = EXCLUDED.costo, pedido_minimo = EXCLUDED.pedido_minimo, activa = TRUE
    RETURNING id INTO p_zona_id;
END;
$$;

/* Quita una zona: se borra si ningún pedido la usó; si no, se desactiva. */
CREATE OR REPLACE PROCEDURE api.sp_retirar_zona(p_zona_id INTEGER, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_unidad INTEGER := (SELECT unidad_id FROM core.zonas_domicilio WHERE id = p_zona_id);
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    IF v_unidad IS NULL THEN
        RETURN;
    END IF;
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, core.fn_empresa_de_unidad(v_unidad));

    IF EXISTS (SELECT 1 FROM core.pedidos WHERE zona_domicilio_id = p_zona_id) THEN
        UPDATE core.zonas_domicilio SET activa = FALSE WHERE id = p_zona_id;
    ELSE
        DELETE FROM core.zonas_domicilio WHERE id = p_zona_id;
    END IF;
END;
$$;

/* Logo: NULL o vacío lo quita. */
CREATE OR REPLACE PROCEDURE api.sp_guardar_logo_unidad(p_unidad_id INTEGER, p_imagen TEXT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_sucursales');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, core.fn_empresa_de_unidad(p_unidad_id));

    IF NULLIF(p_imagen, '') IS NULL THEN
        DELETE FROM core.unidad_logos WHERE unidad_id = p_unidad_id;
        RETURN;
    END IF;
    IF p_imagen NOT LIKE 'data:image/%' THEN
        RAISE EXCEPTION 'El logo debe ser una imagen.';
    END IF;
    IF length(p_imagen) > 200000 THEN
        RAISE EXCEPTION 'El logo es demasiado pesado (máximo unos 150 KB). Usa una imagen más pequeña.';
    END IF;

    INSERT INTO core.unidad_logos (unidad_id, imagen)
    VALUES (p_unidad_id, p_imagen)
    ON CONFLICT (unidad_id) DO UPDATE SET imagen = EXCLUDED.imagen, actualizado_en = now();
END;
$$;


/* ============================================================================
   4. API REST · LECTURA
   ============================================================================ */

/* Unidades: se agregan al final el color propio y la versión del logo (la
   imagen NO va aquí; ver rest.logos_unidad). */
CREATE OR REPLACE VIEW rest.unidades AS
SELECT u.unidad_id, u.empresa_id, e.codigo AS empresa_codigo, u.nombre, u.nombre_corto, u.estado, u.activa,
       u.tipo_negocio, u.direccion, u.ciudad, u.telefono, u.whatsapp, u.horario, u.mapa_url, u.color,
       u.logo_url, u.mesas, u.creado_en,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('zona_id', z.id, 'nombre', z.nombre, 'costo', z.costo,
                                                     'pedido_minimo', z.pedido_minimo) ORDER BY z.nombre)
                   FROM core.zonas_domicilio z WHERE z.unidad_id = u.unidad_id AND z.activa), '[]') AS zonas,
       cu.color_marca,
       (SELECT l.actualizado_en FROM core.unidad_logos l WHERE l.unidad_id = u.unidad_id) AS logo_version
  FROM api.v_unidades u
  JOIN core.empresas e  ON e.id = u.empresa_id
  JOIN core.unidades cu ON cu.id = u.unidad_id;

/* Los logos, aparte: la aplicación los pide sólo cuando logo_version cambia. */
CREATE OR REPLACE VIEW rest.logos_unidad AS
SELECT l.unidad_id, u.empresa_id, l.imagen, l.actualizado_en AS logo_version
  FROM core.unidad_logos l
  JOIN core.unidades u ON u.id = l.unidad_id;

/* Usuarios de la empresa del token, sólo para quien puede administrarlos.
   Nunca el PIN. */
CREATE OR REPLACE VIEW rest.usuarios AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT u.usuario_id, u.empresa_id, u.nombre, u.usuario, u.rol, u.activo,
       u.unidades_asignadas AS unidades, u.ultimo_acceso, u.creado_en
  FROM api.v_usuarios u
  JOIN sesion s ON s.empresa_id = u.empresa_id
 WHERE u.alcance = 'empresa'
   AND api.fn_tiene_permiso(s.usuario_id, 'usuarios');


/* ============================================================================
   5. API REST · ESCRITURA
   ============================================================================ */

/* POST /rpc/guardar_usuario  { "p_usuario": { usuario_id|null, nombre, usuario,
   pin (opcional: vacío = no cambia), rol, unidades: [..] | null, activo } } */
CREATE OR REPLACE FUNCTION rest.guardar_usuario(p_usuario JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_admin    INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_id       INTEGER := NULLIF(p_usuario ->> 'usuario_id', '')::INTEGER;
    v_unidades INTEGER[];
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF jsonb_typeof(p_usuario -> 'unidades') = 'array' THEN
        v_unidades := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(p_usuario -> 'unidades') x);
    END IF;

    CALL api.sp_guardar_usuario(
        p_empresa_id => v_empresa,
        p_rol        => p_usuario ->> 'rol',
        p_nombre     => p_usuario ->> 'nombre',
        p_usuario    => p_usuario ->> 'usuario',
        p_admin_id   => v_admin,
        p_pin        => p_usuario ->> 'pin',
        p_unidades   => v_unidades,
        p_activo     => COALESCE((p_usuario ->> 'activo')::BOOLEAN, TRUE),
        p_usuario_id => v_id);

    RETURN jsonb_build_object('usuario_id', v_id);
END;
$$;

/* POST /rpc/guardar_unidad  { "p_unidad": { unidad_id|null, nombre, corto,
   tipoNegocio, activa, direccion, ciudad, telefono, whatsapp, horario, mapa,
   mesas, color, colorMarca, zonas: [{ nombre, costo, min }],
   logo (sólo si cambió: data URL, o "" para quitarlo) } } */
CREATE OR REPLACE FUNCTION rest.guardar_unidad(p_unidad JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_id       INTEGER := NULLIF(p_unidad ->> 'unidad_id', '')::INTEGER;
    v_zona     INTEGER;
    z          JSONB;
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    CALL api.sp_guardar_unidad(
        p_empresa_id   => v_empresa,
        p_nombre       => p_unidad ->> 'nombre',
        p_tipo_negocio => COALESCE(NULLIF(p_unidad ->> 'tipoNegocio', ''), 'restaurante'),
        p_usuario_id   => v_usuario,
        p_nombre_corto => p_unidad ->> 'corto',
        p_direccion    => p_unidad ->> 'direccion',
        p_ciudad       => p_unidad ->> 'ciudad',
        p_telefono     => p_unidad ->> 'telefono',
        p_whatsapp     => regexp_replace(COALESCE(p_unidad ->> 'whatsapp', ''), '\D', '', 'g'),
        p_horario      => p_unidad ->> 'horario',
        p_mapa_url     => p_unidad ->> 'mapa',
        p_mesas        => NULLIF(p_unidad ->> 'mesas', '')::NUMERIC::INTEGER,
        p_color        => p_unidad ->> 'color',
        p_color_marca  => p_unidad ->> 'colorMarca',
        p_unidad_id    => v_id);

    IF p_unidad ? 'activa' THEN
        CALL api.sp_cambiar_estado_unidad(v_id, COALESCE((p_unidad ->> 'activa')::BOOLEAN, TRUE), v_usuario);
    END IF;

    -- Zonas: las que no vienen se retiran; las que vienen se guardan por nombre
    IF jsonb_typeof(p_unidad -> 'zonas') = 'array' THEN
        FOR v_zona IN
            SELECT zd.id FROM core.zonas_domicilio zd
             WHERE zd.unidad_id = v_id AND zd.activa
               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_unidad -> 'zonas') x
                                WHERE lower(regexp_replace(trim(x ->> 'nombre'), '\s+', ' ', 'g')) = lower(zd.nombre))
        LOOP
            CALL api.sp_retirar_zona(v_zona, v_usuario);
        END LOOP;

        FOR z IN SELECT * FROM jsonb_array_elements(p_unidad -> 'zonas') LOOP
            v_zona := NULL;
            CALL api.sp_guardar_zona(v_id, z ->> 'nombre', NULLIF(z ->> 'costo', '')::NUMERIC,
                                     NULLIF(z ->> 'min', '')::NUMERIC, v_usuario, v_zona);
        END LOOP;
    END IF;

    IF p_unidad ? 'logo' THEN
        CALL api.sp_guardar_logo_unidad(v_id, p_unidad ->> 'logo', v_usuario);
    END IF;

    RETURN jsonb_build_object('unidad_id', v_id);
END;
$$;


/* ============================================================================
   6. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_exigir_empresa_propia(INTEGER, INTEGER) FROM PUBLIC;

REVOKE ALL ON PROCEDURE api.sp_guardar_usuario(INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, INTEGER[], BOOLEAN, INTEGER),
                        api.sp_guardar_unidad(INTEGER, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
                                              VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, INTEGER),
                        api.sp_cambiar_estado_unidad(INTEGER, BOOLEAN, INTEGER),
                        api.sp_guardar_zona(INTEGER, VARCHAR, NUMERIC, NUMERIC, INTEGER, INTEGER),
                        api.sp_retirar_zona(INTEGER, INTEGER),
                        api.sp_guardar_logo_unidad(INTEGER, TEXT, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_guardar_usuario(INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, INTEGER[], BOOLEAN, INTEGER),
                           api.sp_guardar_unidad(INTEGER, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
                                                 VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, INTEGER),
                           api.sp_cambiar_estado_unidad(INTEGER, BOOLEAN, INTEGER),
                           api.sp_guardar_zona(INTEGER, VARCHAR, NUMERIC, NUMERIC, INTEGER, INTEGER),
                           api.sp_retirar_zona(INTEGER, INTEGER),
                           api.sp_guardar_logo_unidad(INTEGER, TEXT, INTEGER)
      TO taseca_app;

GRANT SELECT ON rest.unidades, rest.logos_unidad TO taseca_anon, taseca_app;
GRANT SELECT ON rest.usuarios TO taseca_app;
GRANT EXECUTE ON FUNCTION api.fn_tiene_permiso(INTEGER, VARCHAR) TO taseca_app;

REVOKE ALL ON FUNCTION rest.guardar_usuario(JSONB), rest.guardar_unidad(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.guardar_usuario(JSONB), rest.guardar_unidad(JSONB) TO taseca_app;

NOTIFY pgrst, 'reload schema';
