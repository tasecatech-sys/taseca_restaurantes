/* ============================================================================
   TASECA · 09 · API REST CON POSTGREST (fase 1)
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 07. Se puede volver a
   ejecutar: todo es idempotente.

   PostgREST publica SÓLO el esquema `rest`. Es una capa delgada sobre `api`:

     · vistas públicas  → carta, unidades, menú del día (cliente sin sesión)
     · vistas privadas  → pedidos de la empresa y unidades del usuario del JWT
     · funciones RPC    → envuelven los procedimientos de `api`

   PostgREST no ejecuta PROCEDURES (CALL), sólo funciones: por eso cada
   escritura tiene aquí su función. Y lo más importante: el usuario NUNCA
   llega como parámetro. Sale del token JWT firmado por la base, así que el
   navegador no puede hacerse pasar por otro.

   ROLES
     taseca_rest   usuario con el que se conecta PostgREST (LOGIN, NOINHERIT).
                   La contraseña la pones tú: ALTER ROLE taseca_rest PASSWORD '…';
     taseca_anon   quien no ha iniciado sesión (el cliente del portal)
     taseca_app    quien entró con usuario y PIN (el JWT dice role = taseca_app)

   FASE 1: login, portal, mesa, carta, menú del día, crear pedido, seguimiento,
   cocina, estados, cancelar, anular y pagos. Inventario, cierres, caja,
   gastos, usuarios y configuración siguen en la fase 2.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. AJUSTES AL MODELO QUE NECESITA LA API
   ============================================================================ */

-- El comprobante guarda la imagen (data URL) y la referencia que escribe el
-- cliente: la caja lo revisa desde otro equipo.
ALTER TABLE core.comprobantes_pago ALTER COLUMN archivo_url TYPE TEXT;
ALTER TABLE core.comprobantes_pago ALTER COLUMN archivo_url DROP NOT NULL;
ALTER TABLE core.comprobantes_pago ADD COLUMN IF NOT EXISTS referencia VARCHAR(120);
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_comprobantes_contenido') THEN
        ALTER TABLE core.comprobantes_pago
            ADD CONSTRAINT ck_comprobantes_contenido CHECK (archivo_url IS NOT NULL OR referencia IS NOT NULL);
    END IF;
END;
$$;

DROP PROCEDURE IF EXISTS api.sp_registrar_comprobante(BIGINT, VARCHAR, BIGINT);
CREATE OR REPLACE PROCEDURE api.sp_registrar_comprobante(
    p_pedido_id      BIGINT,
    p_archivo_url    TEXT    DEFAULT NULL,
    p_referencia     VARCHAR DEFAULT NULL,
    INOUT p_comprobante_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_pago VARCHAR;
BEGIN
    PERFORM core.fn_fijar_usuario(NULL);

    SELECT ep.codigo INTO v_pago
      FROM core.pedidos p JOIN core.estados_pago ep ON ep.id = p.estado_pago_id
     WHERE p.id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa factura no existe.';
    ELSIF v_pago = 'confirmado' THEN
        RAISE EXCEPTION 'El pago de esta factura ya fue confirmado.';
    END IF;
    IF p_archivo_url IS NULL AND NULLIF(trim(p_referencia), '') IS NULL THEN
        RAISE EXCEPTION 'Adjunta el comprobante o escribe la referencia de la transferencia.';
    END IF;
    IF length(p_archivo_url) > 900000 THEN
        RAISE EXCEPTION 'La imagen del comprobante es demasiado grande.';
    END IF;

    INSERT INTO core.comprobantes_pago (pedido_id, archivo_url, referencia, estado_pago_id)
    VALUES (p_pedido_id, p_archivo_url, left(NULLIF(trim(p_referencia), ''), 120),
            core.fn_id_catalogo('estados_pago', 'reportado'))
    RETURNING id INTO p_comprobante_id;

    UPDATE core.pedidos SET estado_pago_id = core.fn_id_catalogo('estados_pago', 'reportado')
     WHERE id = p_pedido_id;
END;
$$;

-- Confirmar / rechazar el pago con la referencia o el motivo en el historial
DROP PROCEDURE IF EXISTS api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER);
CREATE OR REPLACE PROCEDURE api.sp_actualizar_pago(
    p_pedido_id    BIGINT,
    p_estado_pago  VARCHAR,
    p_usuario_id   INTEGER,
    p_nota         VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pagos',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    UPDATE core.pedidos SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago)
     WHERE id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;
    UPDATE core.comprobantes_pago
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago),
           revisado_por_id = p_usuario_id, revisado_en = now()
     WHERE pedido_id = p_pedido_id AND revisado_en IS NULL;
    IF NULLIF(trim(p_nota), '') IS NOT NULL THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        VALUES (p_pedido_id,
                CASE WHEN p_estado_pago = 'confirmado' THEN 'Referencia del pago: ' ELSE 'Motivo: ' END || trim(p_nota),
                p_usuario_id);
    END IF;
END;
$$;


/* ============================================================================
   2. ROLES DE POSTGREST
   ============================================================================ */

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_anon') THEN
        CREATE ROLE taseca_anon NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_rest') THEN
        CREATE ROLE taseca_rest LOGIN NOINHERIT;
    END IF;
END;
$$;

COMMENT ON ROLE taseca_anon IS 'PostgREST sin sesión: el cliente del portal. Sólo lo público de rest.';
COMMENT ON ROLE taseca_rest IS 'Usuario de conexión de PostgREST. Cambia al rol del JWT en cada petición.';

GRANT taseca_anon TO taseca_rest;
GRANT taseca_app  TO taseca_rest;


/* ============================================================================
   3. JWT
   El secreto vive en la base, no en un archivo: PostgREST lo lee al arrancar
   con core.fn_postgrest_pre_config() y la base lo usa para firmar el login.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS core.jwt_config (
    id              SERIAL PRIMARY KEY,
    secreto         TEXT        NOT NULL CHECK (length(secreto) >= 32),
    duracion_horas  SMALLINT    NOT NULL DEFAULT 12 CHECK (duracion_horas BETWEEN 1 AND 72),
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.jwt_config IS 'Secreto con el que se firman los tokens. Para invalidar todas las sesiones: inserta un secreto nuevo y reinicia PostgREST.';

INSERT INTO core.jwt_config (secreto)
SELECT encode(public.gen_random_bytes(32), 'hex')
 WHERE NOT EXISTS (SELECT 1 FROM core.jwt_config);

REVOKE ALL ON core.jwt_config FROM PUBLIC;

CREATE OR REPLACE FUNCTION core.fn_base64url(p_datos BYTEA)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT translate(encode(p_datos, 'base64'), E'+/=\n', '-_');
$$;

CREATE OR REPLACE FUNCTION core.fn_jwt_secreto()
RETURNS TEXT
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT secreto FROM core.jwt_config ORDER BY id DESC LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION core.fn_jwt_firmar(p_payload JSONB)
RETURNS TEXT
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_datos TEXT;
BEGIN
    v_datos := core.fn_base64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'UTF8')) || '.' ||
               core.fn_base64url(convert_to(p_payload::TEXT, 'UTF8'));
    RETURN v_datos || '.' ||
           core.fn_base64url(public.hmac(convert_to(v_datos, 'UTF8'), convert_to(core.fn_jwt_secreto(), 'UTF8'), 'sha256'));
END;
$$;

/* Lo que dice el token de la petición en curso (PostgREST ya verificó la
   firma y la expiración antes de llegar aquí). */
CREATE OR REPLACE FUNCTION core.fn_jwt_claims()
RETURNS JSONB
LANGUAGE sql STABLE
AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', TRUE), '')::JSONB;
$$;

/* Usuario del token. Si el usuario fue desactivado después de entrar, su
   token deja de servir aunque no haya vencido. */
CREATE OR REPLACE FUNCTION core.fn_jwt_usuario()
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER := (core.fn_jwt_claims() ->> 'usuario_id')::INTEGER;
BEGIN
    IF v_id IS NULL THEN
        RETURN NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.usuarios WHERE id = v_id AND activo) THEN
        RAISE EXCEPTION 'Tu sesión ya no es válida. Vuelve a entrar.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_jwt_empresa()
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT (core.fn_jwt_claims() ->> 'empresa_id')::INTEGER;
$$;

CREATE OR REPLACE FUNCTION core.fn_exigir_sesion()
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER := core.fn_jwt_usuario();
BEGIN
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'Tienes que iniciar sesión.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_id;
END;
$$;

/* PostgREST la ejecuta al arrancar y al recargar la configuración
   (db-pre-config). Deja el secreto sólo en la memoria del servidor. */
CREATE OR REPLACE FUNCTION core.fn_postgrest_pre_config()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM set_config('pgrst.jwt_secret', core.fn_jwt_secreto(), TRUE);
END;
$$;


/* ============================================================================
   4. ARMADO DE UN PEDIDO COMPLETO EN JSON
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_pedido_json(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT to_jsonb(vp)
        || jsonb_build_object(
               'empresa_codigo', e.codigo,
               'mesa_id', p.mesa_id,
               'zona_id', p.zona_domicilio_id,
               'tomado_por_id', p.tomado_por_id,
               'items', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'pedido_item_id', i.pedido_item_id, 'origen', i.origen,
                               'producto_id', i.producto_id, 'plato_dia_id', i.plato_dia_id,
                               'menu_dia_id', i.menu_dia_id, 'nombre', i.nombre,
                               'precio_unitario', i.precio_unitario, 'cantidad', i.cantidad,
                               'notas', i.notas, 'detalle', i.detalle,
                               'opciones', COALESCE((SELECT jsonb_agg(x.menu_opcion_id ORDER BY x.menu_opcion_id)
                                                       FROM core.pedido_item_opciones x
                                                      WHERE x.pedido_item_id = i.pedido_item_id), '[]'))
                           ORDER BY i.pedido_item_id)
                      FROM api.v_pedido_items i WHERE i.pedido_id = vp.pedido_id), '[]'),
               'historial', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object('ts', h.creado_en, 'texto', h.descripcion) ORDER BY h.id)
                      FROM core.pedido_historial h WHERE h.pedido_id = vp.pedido_id), '[]'),
               'tiene_comprobante', EXISTS (SELECT 1 FROM core.comprobantes_pago c
                                             WHERE c.pedido_id = vp.pedido_id AND c.archivo_url IS NOT NULL),
               'referencia_pago', (SELECT c.referencia FROM core.comprobantes_pago c
                                    WHERE c.pedido_id = vp.pedido_id ORDER BY c.id DESC LIMIT 1),
               'anulacion', (SELECT jsonb_build_object('motivo', a.motivo, 'jornada_original', a.jornada_original,
                                                       'jornada_retorno', a.jornada_retorno,
                                                       'diferido', a.jornada_retorno <> a.jornada_original,
                                                       'creado_en', a.creado_en)
                               FROM core.anulaciones a WHERE a.pedido_id = vp.pedido_id)
           )
      FROM api.v_pedidos vp
      JOIN core.pedidos p  ON p.id = vp.pedido_id
      JOIN core.empresas e ON e.id = vp.empresa_id
     WHERE vp.pedido_id = p_pedido_id;
$$;

/* Pedido de la empresa y unidades del usuario de la sesión; si no, error. */
CREATE OR REPLACE FUNCTION core.fn_pedido_de_sesion(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.pedidos p
                    WHERE p.id = p_pedido_id
                      AND p.empresa_id = core.fn_jwt_empresa()
                      AND core.fn_usuario_en_unidad(v_usuario, p.unidad_id)) THEN
        RAISE EXCEPTION 'Esa factura no existe.' USING ERRCODE = 'no_data_found';
    END IF;
    RETURN core.fn_pedido_json(p_pedido_id);
END;
$$;


/* ============================================================================
   5. ESQUEMA REST · LECTURA PÚBLICA (con o sin sesión)
   ============================================================================ */

CREATE SCHEMA IF NOT EXISTS rest;
COMMENT ON SCHEMA rest IS 'Lo que publica PostgREST. Capa delgada sobre api; el usuario sale siempre del JWT.';

CREATE OR REPLACE VIEW rest.empresas AS
SELECT empresa_id, codigo, nombre_comercial, eslogan, telefono, whatsapp, email, direccion, horario_general,
       tiempo_mesa, tiempo_domicilio, color_primario, color_secundario, color_acento, color_fondo, logo_url,
       hora_corte_operativa, jornada_actual
  FROM api.v_empresas
 WHERE estado = 'activa';

CREATE OR REPLACE VIEW rest.unidades AS
SELECT u.unidad_id, u.empresa_id, e.codigo AS empresa_codigo, u.nombre, u.nombre_corto, u.estado, u.activa,
       u.tipo_negocio, u.direccion, u.ciudad, u.telefono, u.whatsapp, u.horario, u.mapa_url, u.color,
       u.logo_url, u.mesas, u.creado_en,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('zona_id', z.id, 'nombre', z.nombre, 'costo', z.costo,
                                                     'pedido_minimo', z.pedido_minimo) ORDER BY z.nombre)
                   FROM core.zonas_domicilio z WHERE z.unidad_id = u.unidad_id AND z.activa), '[]') AS zonas
  FROM api.v_unidades u
  JOIN core.empresas e ON e.id = u.empresa_id;

CREATE OR REPLACE VIEW rest.categorias AS
SELECT c.id AS categoria_id, c.empresa_id, c.nombre, c.icono, c.orden, c.activa,
       COALESCE(array_agg(cu.unidad_id ORDER BY cu.unidad_id) FILTER (WHERE cu.unidad_id IS NOT NULL), '{}') AS unidades
  FROM core.categorias c
  LEFT JOIN core.categoria_unidades cu ON cu.categoria_id = c.id
 GROUP BY c.id;

CREATE OR REPLACE VIEW rest.carta AS
SELECT p.id AS producto_id, p.empresa_id, p.codigo, p.categoria_id, p.nombre, p.descripcion, p.precio,
       et.codigo AS etiqueta, p.imagen_url, p.orden, p.activo,
       COALESCE(jsonb_agg(jsonb_build_object('unidad_id', pu.unidad_id, 'agotado', pu.agotado)
                          ORDER BY pu.unidad_id) FILTER (WHERE pu.id IS NOT NULL), '[]') AS unidades
  FROM core.productos p
  LEFT JOIN core.etiquetas_producto et ON et.id = p.etiqueta_id
  LEFT JOIN core.producto_unidades pu  ON pu.producto_id = p.id
 GROUP BY p.id, et.codigo;

/* Menús de una semana atrás a dos adelante, cada uno con sus categorías,
   opciones y platos del chef ya armados. */
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
                          'disponible', p.disponible, 'orden', p.orden)
                      ORDER BY p.orden)
                   FROM api.v_platos_dia p WHERE p.menu_dia_id = m.id), '[]') AS platos
  FROM core.menus_dia m
  JOIN core.unidades u   ON u.id = m.unidad_id
  JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
 WHERE m.fecha BETWEEN core.fn_fecha_operativa(u.empresa_id, now()) - 7
                   AND core.fn_fecha_operativa(u.empresa_id, now()) + 14;

CREATE OR REPLACE VIEW rest.textos_menu AS
SELECT t.unidad_id, u.empresa_id, t.titulo, t.mensaje
  FROM core.textos_menu_unidad t
  JOIN core.unidades u ON u.id = t.unidad_id;

CREATE OR REPLACE VIEW rest.metodos_pago AS
SELECT empresa_id, codigo, nombre, grupo_caja, descripcion, activo, orden
  FROM api.v_metodos_pago;


/* ============================================================================
   6. ESQUEMA REST · LECTURA CON SESIÓN
   ============================================================================ */

/* Pedidos de los últimos 31 días de la empresa del token, sólo de las
   unidades en las que trabaja el usuario. `pedido` trae todo armado. */
CREATE OR REPLACE VIEW rest.pedidos AS
SELECT vp.pedido_id, vp.empresa_id, vp.unidad_id, vp.codigo, vp.estado, vp.fecha_operativa,
       vp.actualizado_en, core.fn_pedido_json(vp.pedido_id) AS pedido
  FROM api.v_pedidos vp
 WHERE vp.empresa_id = core.fn_jwt_empresa()
   AND core.fn_usuario_en_unidad(core.fn_jwt_usuario(), vp.unidad_id)
   AND vp.fecha_operativa >= core.fn_fecha_operativa(vp.empresa_id, now()) - 31;


/* ============================================================================
   7. ESQUEMA REST · FUNCIONES (RPC)
   POST /rpc/<nombre> con un JSON de parámetros.
   ============================================================================ */

/* Login: si el PIN es correcto devuelve el token y los datos de la sesión;
   si no, null (después de una pausa corta, para frenar la fuerza bruta). */
CREATE OR REPLACE FUNCTION rest.login(p_usuario TEXT, p_pin TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v      RECORD;
    v_exp  BIGINT;
    v_uni  INTEGER[];
BEGIN
    SELECT * INTO v FROM api.fn_login(p_usuario, p_pin) LIMIT 1;
    IF v.usuario_id IS NULL THEN
        PERFORM pg_sleep(0.6);
        RETURN NULL;
    END IF;

    v_exp := extract(epoch FROM now() + make_interval(hours => (SELECT duracion_horas FROM core.jwt_config ORDER BY id DESC LIMIT 1)))::BIGINT;
    SELECT COALESCE(array_agg(unidad_id ORDER BY unidad_id), '{}') INTO v_uni
      FROM core.usuario_unidades WHERE usuario_id = v.usuario_id;

    RETURN jsonb_build_object(
        'token', core.fn_jwt_firmar(jsonb_build_object(
                     'role', 'taseca_app', 'usuario_id', v.usuario_id, 'empresa_id', v.empresa_id,
                     'rol', v.rol, 'exp', v_exp)),
        'expira', to_timestamp(v_exp),
        'usuario_id', v.usuario_id, 'nombre', v.nombre, 'usuario', v.usuario,
        'rol', v.rol, 'alcance', v.alcance,
        'empresa_id', v.empresa_id,
        'empresa_codigo', (SELECT codigo FROM core.empresas WHERE id = v.empresa_id),
        'unidades', to_jsonb(v_uni));
END;
$$;

/* ¿Sigue siendo válida mi sesión? */
CREATE OR REPLACE FUNCTION rest.sesion()
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER := core.fn_exigir_sesion();
BEGIN
    RETURN (SELECT jsonb_build_object('usuario_id', u.usuario_id, 'nombre', u.nombre, 'rol', u.rol,
                                      'empresa_id', u.empresa_id, 'unidades', to_jsonb(u.unidades_asignadas))
              FROM api.v_usuarios u WHERE u.usuario_id = v_id);
END;
$$;

/* Crear pedido. Sin sesión = cliente del portal; con sesión = mesero. */
CREATE OR REPLACE FUNCTION rest.crear_pedido(
    p_unidad_id         INTEGER,
    p_tipo              TEXT,
    p_metodo_pago       TEXT,
    p_items             JSONB,
    p_mesa              TEXT    DEFAULT NULL,
    p_cliente_nombre    TEXT    DEFAULT NULL,
    p_cliente_telefono  TEXT    DEFAULT NULL,
    p_direccion         TEXT    DEFAULT NULL,
    p_indicaciones      TEXT    DEFAULT NULL,
    p_zona_id           INTEGER DEFAULT NULL,
    p_paga_con          NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id     BIGINT;
    v_codigo VARCHAR;
BEGIN
    CALL api.sp_crear_pedido(
        p_unidad_id => p_unidad_id, p_tipo => p_tipo, p_metodo_pago => p_metodo_pago, p_items => p_items,
        p_usuario_id => core.fn_jwt_usuario(), p_mesa => p_mesa,
        p_cliente_nombre => p_cliente_nombre, p_cliente_telefono => p_cliente_telefono,
        p_direccion => p_direccion, p_indicaciones => p_indicaciones, p_zona_id => p_zona_id,
        p_paga_con => p_paga_con, p_pedido_id => v_id, p_codigo => v_codigo);
    RETURN core.fn_pedido_json(v_id);
END;
$$;

/* Seguimiento público: sin teléfono ni dirección del cliente. */
CREATE OR REPLACE FUNCTION rest.seguimiento(p_codigo TEXT, p_empresa TEXT DEFAULT 'empresa_nascar')
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    SELECT s.pedido_id INTO v_id FROM api.fn_seguimiento_pedido(p_empresa, p_codigo) s;
    IF v_id IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN core.fn_pedido_json(v_id)
           - ARRAY['cliente', 'cliente_telefono', 'direccion_entrega', 'indicaciones', 'paga_con', 'cambio',
                   'tomado_por', 'tomado_por_id', 'referencia_pago'];
END;
$$;

/* El cliente reporta su transferencia (referencia y/o foto). Sólo pedidos
   por transferencia de las últimas 24 horas y sin pago confirmado. */
CREATE OR REPLACE FUNCTION rest.reportar_pago(p_codigo TEXT, p_referencia TEXT DEFAULT NULL,
                                              p_imagen TEXT DEFAULT NULL, p_empresa TEXT DEFAULT 'empresa_nascar')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id   BIGINT;
    v_comp BIGINT;
BEGIN
    SELECT p.id INTO v_id
      FROM core.pedidos p
      JOIN core.empresas e     ON e.id = p.empresa_id
      JOIN core.metodos_pago m ON m.id = p.metodo_pago_id
     WHERE e.codigo = p_empresa
       AND p.codigo = core.fn_normalizar_codigo_pedido(e.id, p_codigo)
       AND m.codigo = 'transferencia'
       AND p.creado_en > now() - INTERVAL '24 hours';
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un pedido por transferencia reciente con ese número.';
    END IF;
    CALL api.sp_registrar_comprobante(p_pedido_id => v_id, p_archivo_url => p_imagen, p_referencia => p_referencia,
                                      p_comprobante_id => v_comp);
    RETURN rest.seguimiento(p_codigo, p_empresa);
END;
$$;

CREATE OR REPLACE FUNCTION rest.pedido(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT core.fn_pedido_de_sesion(p_pedido_id);
$$;

CREATE OR REPLACE FUNCTION rest.avanzar_estado(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_avanzar_estado_pedido(p_pedido_id, core.fn_exigir_sesion());
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.cambiar_estado(p_pedido_id BIGINT, p_estado TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    /* El panel usa "cambiar estado" también para lo que sólo avanza un paso
       (cocina marca listo, domiciliario entrega). Si el estado pedido es el
       siguiente del flujo, basta con uno de los permisos de piso. */
    IF core.fn_id_catalogo('estados_pedido', p_estado) = core.fn_siguiente_estado(p_pedido_id) THEN
        CALL api.sp_avanzar_estado_pedido(p_pedido_id, v_usuario);
    ELSE
        CALL api.sp_cambiar_estado_pedido(p_pedido_id, p_estado, v_usuario);
    END IF;
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.cancelar_pedido(p_pedido_id BIGINT, p_motivo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_cancelar_pedido(p_pedido_id, p_motivo, core.fn_exigir_sesion());
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.anular_pedido(p_pedido_id BIGINT, p_motivo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_json JSONB;
BEGIN
    CALL api.sp_anular_pedido(p_pedido_id, p_motivo, core.fn_exigir_sesion());
    v_json := core.fn_pedido_de_sesion(p_pedido_id);
    RETURN jsonb_build_object(
        'pedido', v_json,
        'retorno', jsonb_build_object(
            'diferido', COALESCE((v_json -> 'anulacion' ->> 'diferido')::BOOLEAN, FALSE),
            'jornada_retorno', v_json -> 'anulacion' ->> 'jornada_retorno',
            'productos', COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', s.codigo, 'cantidad', e.cantidad))
                                     FROM core.entradas_inventario e
                                     JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
                                     JOIN core.insumos s ON s.id = iu.insumo_id
                                    WHERE e.pedido_id = p_pedido_id), '[]')));
END;
$$;

CREATE OR REPLACE FUNCTION rest.confirmar_pago(p_pedido_id BIGINT, p_referencia TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_actualizar_pago(p_pedido_id, 'confirmado', core.fn_exigir_sesion(), p_referencia);
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.rechazar_pago(p_pedido_id BIGINT, p_motivo TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_actualizar_pago(p_pedido_id, 'rechazado', core.fn_exigir_sesion(), p_motivo);
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

/* La imagen del comprobante, sólo para quien puede revisar pagos. */
CREATE OR REPLACE FUNCTION rest.comprobante(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    PERFORM core.fn_pedido_de_sesion(p_pedido_id);
    PERFORM core.fn_exigir_permiso(v_usuario, 'pagos');
    RETURN (SELECT jsonb_build_object('imagen', c.archivo_url, 'referencia', c.referencia, 'creado_en', c.creado_en,
                                      'peso_kb', round(length(c.archivo_url) / 1024.0))
              FROM core.comprobantes_pago c
             WHERE c.pedido_id = p_pedido_id AND c.archivo_url IS NOT NULL
             ORDER BY c.id DESC LIMIT 1);
END;
$$;


/* ============================================================================
   8. PERMISOS
   ============================================================================ */

REVOKE ALL ON SCHEMA rest FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA rest FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA rest FROM PUBLIC;

GRANT USAGE ON SCHEMA rest TO taseca_anon, taseca_app;

-- Lectura pública
GRANT SELECT ON rest.empresas, rest.unidades, rest.categorias, rest.carta,
                rest.menus_dia, rest.textos_menu, rest.metodos_pago
      TO taseca_anon, taseca_app;
-- Lectura con sesión
GRANT SELECT ON rest.pedidos TO taseca_app;

-- Funciones públicas
GRANT EXECUTE ON FUNCTION rest.login(TEXT, TEXT),
                          rest.crear_pedido(INTEGER, TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC),
                          rest.seguimiento(TEXT, TEXT),
                          rest.reportar_pago(TEXT, TEXT, TEXT, TEXT)
      TO taseca_anon, taseca_app;
-- Funciones con sesión
GRANT EXECUTE ON FUNCTION rest.sesion(), rest.pedido(BIGINT), rest.avanzar_estado(BIGINT),
                          rest.cambiar_estado(BIGINT, TEXT), rest.cancelar_pedido(BIGINT, TEXT),
                          rest.anular_pedido(BIGINT, TEXT), rest.confirmar_pago(BIGINT, TEXT),
                          rest.rechazar_pago(BIGINT, TEXT), rest.comprobante(BIGINT)
      TO taseca_app;

-- Las vistas llaman funciones de core: se revisan contra quien consulta
GRANT USAGE ON SCHEMA core TO taseca_anon, taseca_rest;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA core FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    core.fn_fecha_operativa(INTEGER, TIMESTAMPTZ),
    core.fn_empresa_tiene_modulo(INTEGER, TEXT),
    core.fn_vendidos_plato(BIGINT),
    core.fn_normalizar_codigo_pedido(INTEGER, TEXT),
    core.fn_empresa_de_unidad(INTEGER),
    core.fn_jwt_claims(),
    core.fn_jwt_empresa()
TO taseca_anon, taseca_app;
GRANT EXECUTE ON FUNCTION core.fn_jwt_usuario(), core.fn_usuario_en_unidad(INTEGER, INTEGER), core.fn_pedido_json(BIGINT)
      TO taseca_app;

-- PostgREST lee el secreto al arrancar
GRANT EXECUTE ON FUNCTION core.fn_postgrest_pre_config() TO taseca_rest;

-- Los procedimientos nuevos o recreados en este archivo
GRANT EXECUTE ON PROCEDURE api.sp_registrar_comprobante(BIGINT, TEXT, VARCHAR, BIGINT),
                           api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR)
      TO taseca_app;
REVOKE EXECUTE ON PROCEDURE api.sp_registrar_comprobante(BIGINT, TEXT, VARCHAR, BIGINT),
                            api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR)
      FROM PUBLIC;

-- Que PostgREST recargue su caché de esquema si ya estaba corriendo
NOTIFY pgrst, 'reload schema';
