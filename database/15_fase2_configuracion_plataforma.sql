/* ============================================================================
   TASECA · 15 · FASE 2 · BLOQUE 5: CONFIGURACIÓN, AJUSTES Y PANEL DE TASECA
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 14. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · La EMPRESA completa para la aplicación: ficha, módulos, tema (colores,
       tipografía, logotipo, iniciales, lema, logo e ícono), contacto, cuentas
       para transferir, tiempos, hora de corte, redes y métodos de pago. Antes
       el portal y el panel los tomaban del navegador.
     · Configuración del Admin de la empresa: datos del negocio y métodos de
       pago (siempre al menos uno activo).
     · Facturas de prueba: contarlas y borrarlas desde Ajustes.
     · PANEL DE TASECA sobre la base: lista de empresas, alta completa en una
       transacción (ficha, primera unidad, módulos, tema, métodos de pago,
       categorías de gasto, numeración y administrador), edición, tema,
       módulos, activar/desactivar y ENTRAR a una empresa (token nuevo con esa
       empresa; el SuperAdmin sigue siendo SuperAdmin).

   SEGURIDAD
     Todo lo de plataforma exige el permiso 'plataforma' del usuario del token.
     El Admin de una empresa sólo cambia SU configuración, nunca módulos ni
     tema. Las imágenes van en su propia tabla y viajan sólo cuando cambian.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS tipografia  VARCHAR(30);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS logo_texto  VARCHAR(24);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS logo_acento VARCHAR(24);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS iniciales   VARCHAR(3);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS lema        VARCHAR(80);
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS plantilla   VARCHAR(30);
COMMENT ON COLUMN core.empresas.tipografia IS 'Id de la lista cerrada de tipografías de la aplicación (NASCAR.TIPOGRAFIAS).';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_empresas_tipografia') THEN
        ALTER TABLE core.empresas
            ADD CONSTRAINT ck_empresas_tipografia CHECK (tipografia IS NULL OR tipografia ~ '^[a-z0-9_-]{1,30}$');
    END IF;
END;
$$;

/* Logo e ícono de la empresa (1 a 1). Aparte, como los logos de unidad: la
   ficha de la empresa se consulta a menudo y las imágenes pesan. */
CREATE TABLE IF NOT EXISTS core.empresa_imagenes (
    id              SERIAL PRIMARY KEY,
    empresa_id      INTEGER     NOT NULL UNIQUE REFERENCES core.empresas (id) ON DELETE CASCADE,
    logo            TEXT,
    favicon         TEXT,
    actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_empresa_imagenes_logo    CHECK (logo    IS NULL OR (logo    ~ '^data:image/(png|jpeg|jpg|webp|gif);base64,' AND length(logo)    <= 200000)),
    CONSTRAINT ck_empresa_imagenes_favicon CHECK (favicon IS NULL OR (favicon ~ '^data:image/(png|jpeg|jpg|webp|gif);base64,' AND length(favicon) <= 60000))
);
REVOKE ALL ON core.empresa_imagenes FROM PUBLIC;

-- El tema con el que NASCAR ha funcionado siempre (antes vivía en data.js)
UPDATE core.empresas
   SET tipografia = 'barlow', logo_texto = 'NAS', logo_acento = 'CAR', iniciales = 'NA',
       lema = 'Parrilla, tradicional y domicilios'
 WHERE codigo = 'empresa_nascar' AND tipografia IS NULL;


/* ============================================================================
   2. LA EMPRESA COMO LA USA LA APLICACIÓN
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_empresa_ficha AS
SELECT e.id AS empresa_id, e.codigo, e.nombre_comercial, e.razon_social, e.nit, e.eslogan, e.descripcion,
       e.estado, e.hora_corte_operativa, e.telefono, e.whatsapp, e.email, e.direccion, e.horario_general,
       e.instagram_url, e.facebook_url, e.tiempo_mesa, e.tiempo_domicilio,
       e.color_primario, e.color_secundario, e.color_acento, e.color_fondo,
       e.tipografia, e.logo_texto, e.logo_acento, e.iniciales, e.lema, e.plantilla, e.creado_en,
       core.fn_fecha_operativa(e.id, now()) AS jornada_actual,
       (SELECT i.actualizado_en FROM core.empresa_imagenes i WHERE i.empresa_id = e.id) AS imagenes_version,
       (SELECT jsonb_object_agg(m.modulo, m.activo) FROM api.v_empresa_modulos m WHERE m.empresa_id = e.id) AS modulos,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', mp.codigo, 'nombre', mp.nombre, 'grupo', mp.grupo_caja,
                                                     'descripcion', emp.descripcion, 'activo', emp.activo)
                                  ORDER BY emp.orden, mp.id)
                   FROM core.empresa_metodos_pago emp
                   JOIN core.metodos_pago mp ON mp.id = emp.metodo_pago_id
                  WHERE emp.empresa_id = e.id), '[]') AS metodos_pago,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('entidad', c.entidad, 'numero', c.numero, 'titular', c.titular)
                                  ORDER BY c.id)
                   FROM core.cuentas_recaudo c
                  WHERE c.empresa_id = e.id AND c.activa), '[]') AS cuentas,
       (SELECT count(*) FROM core.unidades u WHERE u.empresa_id = e.id) AS n_unidades,
       (SELECT count(*) FROM core.usuarios us WHERE us.empresa_id = e.id) AS n_usuarios
  FROM core.empresas e;

/* Portal y panel: sólo empresas activas. Columnas nuevas al final. */
CREATE OR REPLACE VIEW rest.empresas AS
SELECT v.empresa_id, v.codigo, v.nombre_comercial, v.eslogan, v.telefono, v.whatsapp, v.email, v.direccion,
       v.horario_general, v.tiempo_mesa, v.tiempo_domicilio, v.color_primario, v.color_secundario, v.color_acento,
       v.color_fondo, e.logo_url, v.hora_corte_operativa, v.jornada_actual,
       v.razon_social, v.nit, v.descripcion, v.instagram_url, v.facebook_url, v.tipografia, v.logo_texto,
       v.logo_acento, v.iniciales, v.lema, v.plantilla, v.estado, v.creado_en, v.imagenes_version,
       v.modulos, v.metodos_pago, v.cuentas
  FROM api.v_empresa_ficha v
  JOIN core.empresas e ON e.id = v.empresa_id
 WHERE v.estado = 'activa';

CREATE OR REPLACE VIEW rest.empresa_imagenes AS
SELECT i.empresa_id, i.logo, i.favicon, i.actualizado_en AS imagenes_version
  FROM core.empresa_imagenes i
  JOIN core.empresas e ON e.id = i.empresa_id;

/* Panel de Taseca: TODAS las empresas, con cuántas unidades y usuarios. */
CREATE OR REPLACE VIEW rest.plataforma_empresas AS
SELECT v.*
  FROM api.v_empresa_ficha v
 WHERE api.fn_tiene_permiso(core.fn_jwt_usuario(), 'plataforma');

CREATE OR REPLACE VIEW rest.plataforma_usuarios AS
SELECT u.usuario_id, u.empresa_id, e.codigo AS empresa_codigo, u.nombre, u.usuario, u.rol, u.activo,
       u.unidades_asignadas AS unidades
  FROM api.v_usuarios u
  JOIN core.empresas e ON e.id = u.empresa_id
 WHERE u.alcance = 'empresa'
   AND api.fn_tiene_permiso(core.fn_jwt_usuario(), 'plataforma');


/* ============================================================================
   3. CONFIGURACIÓN DE LA EMPRESA (Admin)
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_texto(p_valor TEXT, p_max INTEGER)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT NULLIF(left(regexp_replace(trim(COALESCE(p_valor, '')), '\s+', ' ', 'g'), p_max), '');
$$;

/* Datos del negocio. p_cuentas: [{"entidad": "Nequi", "numero": "300…", "titular": "…"}]
   reemplaza las cuentas activas (las que no vienen quedan inactivas). */
CREATE OR REPLACE PROCEDURE api.sp_guardar_configuracion(
    p_empresa_id    INTEGER,
    p_usuario_id    INTEGER,
    p_datos         JSONB,
    p_cuentas       JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre  TEXT := core.fn_texto(p_datos ->> 'nombre_comercial', 120);
    v_corte   INTEGER;
    v_wa      TEXT := NULLIF(regexp_replace(COALESCE(p_datos ->> 'whatsapp', ''), '\D', '', 'g'), '');
    v_nit     TEXT := core.fn_texto(p_datos ->> 'nit', 20);
    v_cuenta  JSONB;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_local');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, p_empresa_id);

    IF v_nombre IS NULL OR length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'La empresa necesita un nombre comercial.';
    END IF;
    IF v_wa IS NOT NULL AND length(v_wa) < 10 THEN
        RAISE EXCEPTION 'El WhatsApp debe incluir el indicativo del país. Ej. 573001112233';
    END IF;
    v_corte := COALESCE(NULLIF(p_datos ->> 'hora_corte_operativa', '')::NUMERIC::INTEGER,
                        (SELECT hora_corte_operativa FROM core.empresas WHERE id = p_empresa_id));
    IF v_corte NOT BETWEEN 0 AND 23 THEN
        RAISE EXCEPTION 'La hora en que empieza el día siguiente debe estar entre 0 y 23.';
    END IF;
    IF v_nit IS NOT NULL AND EXISTS (SELECT 1 FROM core.empresas WHERE nit = v_nit AND id <> p_empresa_id) THEN
        RAISE EXCEPTION 'Ya hay otra empresa con el NIT %.', v_nit;
    END IF;

    UPDATE core.empresas
       SET nombre_comercial     = v_nombre,
           eslogan              = core.fn_texto(p_datos ->> 'eslogan', 120),
           descripcion          = core.fn_texto(p_datos ->> 'descripcion', 400),
           nit                  = v_nit,
           telefono             = core.fn_texto(p_datos ->> 'telefono', 20),
           whatsapp             = v_wa,
           email                = core.fn_texto(p_datos ->> 'email', 120),
           direccion            = core.fn_texto(p_datos ->> 'direccion', 160),
           horario_general      = core.fn_texto(p_datos ->> 'horario_general', 120),
           tiempo_mesa          = core.fn_texto(p_datos ->> 'tiempo_mesa', 30),
           tiempo_domicilio     = core.fn_texto(p_datos ->> 'tiempo_domicilio', 30),
           instagram_url        = CASE WHEN p_datos ? 'instagram_url' THEN core.fn_texto(p_datos ->> 'instagram_url', 250) ELSE instagram_url END,
           facebook_url         = CASE WHEN p_datos ? 'facebook_url'  THEN core.fn_texto(p_datos ->> 'facebook_url', 250)  ELSE facebook_url END,
           hora_corte_operativa = v_corte,
           actualizado_en       = now()
     WHERE id = p_empresa_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Esa empresa no existe.';
    END IF;

    IF p_cuentas IS NOT NULL THEN
        UPDATE core.cuentas_recaudo SET activa = FALSE WHERE empresa_id = p_empresa_id;
        FOR v_cuenta IN SELECT * FROM jsonb_array_elements(p_cuentas) LOOP
            CONTINUE WHEN core.fn_texto(v_cuenta ->> 'numero', 40) IS NULL;
            IF length(trim(v_cuenta ->> 'numero')) > 40 THEN
                RAISE EXCEPTION 'Los datos de % son demasiado largos (máximo 40 caracteres).', v_cuenta ->> 'entidad';
            END IF;
            INSERT INTO core.cuentas_recaudo (empresa_id, entidad, numero, titular, activa)
            VALUES (p_empresa_id, core.fn_texto(v_cuenta ->> 'entidad', 60), core.fn_texto(v_cuenta ->> 'numero', 40),
                    core.fn_texto(v_cuenta ->> 'titular', 160), TRUE)
            ON CONFLICT (empresa_id, entidad, numero) DO UPDATE SET titular = EXCLUDED.titular, activa = TRUE;
        END LOOP;
    END IF;
END;
$$;

/* Métodos de pago que se ofrecen. p_metodos: [{"codigo": "datafono", "activo": false}] */
CREATE OR REPLACE PROCEDURE api.sp_guardar_metodos_pago(p_empresa_id INTEGER, p_usuario_id INTEGER, p_metodos JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v JSONB;
    v_orden SMALLINT := 0;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_pagos');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, p_empresa_id);

    FOR v IN SELECT * FROM jsonb_array_elements(COALESCE(p_metodos, '[]')) LOOP
        v_orden := v_orden + 1;
        IF NOT EXISTS (SELECT 1 FROM core.metodos_pago WHERE codigo = v ->> 'codigo') THEN
            RAISE EXCEPTION 'El método de pago "%" no existe.', v ->> 'codigo';
        END IF;
        INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, descripcion, orden)
        VALUES (p_empresa_id, core.fn_id_catalogo('metodos_pago', v ->> 'codigo'),
                COALESCE((v ->> 'activo')::BOOLEAN, TRUE), core.fn_texto(v ->> 'descripcion', 250), v_orden)
        ON CONFLICT (empresa_id, metodo_pago_id) DO UPDATE
           SET activo = EXCLUDED.activo,
               descripcion = COALESCE(EXCLUDED.descripcion, core.empresa_metodos_pago.descripcion);
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago WHERE empresa_id = p_empresa_id AND activo) THEN
        RAISE EXCEPTION 'Tiene que quedar al menos un método de pago activo.';
    END IF;
END;
$$;


/* ============================================================================
   4. PLATAFORMA (SuperAdmin)
   ============================================================================ */

/* Ficha de una empresa. p_empresa_id NULL = nueva (código estable a partir
   del nombre, que después puede cambiar sin tocar el código). */
CREATE OR REPLACE PROCEDURE api.sp_guardar_empresa(
    p_usuario_id  INTEGER,
    p_datos       JSONB,
    INOUT p_empresa_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_nombre TEXT := core.fn_texto(p_datos ->> 'nombre_comercial', 120);
    v_nit    TEXT := core.fn_texto(p_datos ->> 'nit', 20);
    v_wa     TEXT := NULLIF(regexp_replace(COALESCE(p_datos ->> 'whatsapp', ''), '\D', '', 'g'), '');
    v_estado TEXT := CASE WHEN COALESCE((p_datos ->> 'activa')::BOOLEAN, TRUE) THEN 'activa' ELSE 'inactiva' END;
    v_codigo TEXT;
    v_n      INTEGER := 1;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'plataforma');

    IF v_nombre IS NULL OR length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'La empresa necesita un nombre comercial.';
    END IF;
    IF v_nit IS NOT NULL AND EXISTS (SELECT 1 FROM core.empresas WHERE nit = v_nit AND id IS DISTINCT FROM p_empresa_id) THEN
        RAISE EXCEPTION 'Ya hay otra empresa con el NIT %.', v_nit;
    END IF;
    IF v_wa IS NOT NULL AND length(v_wa) < 10 THEN
        RAISE EXCEPTION 'El WhatsApp debe incluir el indicativo del país. Ej. 573001112233';
    END IF;

    IF p_empresa_id IS NULL THEN
        v_codigo := 'empresa_' || left(trim(BOTH '_' FROM regexp_replace(lower(translate(v_nombre,
                        'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')), '[^a-z0-9]+', '_', 'g')), 28);
        IF v_codigo = 'empresa_' THEN
            v_codigo := 'empresa_' || substr(md5(random()::TEXT), 1, 8);
        END IF;
        WHILE EXISTS (SELECT 1 FROM core.empresas WHERE codigo = v_codigo || CASE WHEN v_n > 1 THEN '_' || v_n ELSE '' END) LOOP
            v_n := v_n + 1;
        END LOOP;
        IF v_n > 1 THEN
            v_codigo := v_codigo || '_' || v_n;
        END IF;

        INSERT INTO core.empresas (codigo, nombre_comercial, razon_social, nit, telefono, whatsapp, email, direccion,
                                   estado, plantilla)
        VALUES (v_codigo, v_nombre, core.fn_texto(p_datos ->> 'razon_social', 160), v_nit,
                core.fn_texto(p_datos ->> 'telefono', 20), v_wa, core.fn_texto(p_datos ->> 'email', 120),
                core.fn_texto(p_datos ->> 'direccion', 160), v_estado, core.fn_texto(p_datos ->> 'plantilla', 30))
        RETURNING id INTO p_empresa_id;
    ELSE
        UPDATE core.empresas
           SET nombre_comercial = v_nombre,
               razon_social     = core.fn_texto(p_datos ->> 'razon_social', 160),
               nit              = v_nit,
               telefono         = core.fn_texto(p_datos ->> 'telefono', 20),
               whatsapp         = v_wa,
               email            = core.fn_texto(p_datos ->> 'email', 120),
               estado           = CASE WHEN p_datos ? 'activa' THEN v_estado ELSE estado END,
               actualizado_en   = now()
         WHERE id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Esa empresa no existe.';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_guardar_tema_empresa(p_empresa_id INTEGER, p_usuario_id INTEGER, p_tema JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    c TEXT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'plataforma');
    IF NOT EXISTS (SELECT 1 FROM core.empresas WHERE id = p_empresa_id) THEN
        RAISE EXCEPTION 'Esa empresa no existe.';
    END IF;
    FOREACH c IN ARRAY ARRAY['primary', 'secondary', 'accent', 'background'] LOOP
        IF NULLIF(p_tema ->> c, '') IS NOT NULL AND (p_tema ->> c) !~ '^#[0-9A-Fa-f]{6}$' THEN
            RAISE EXCEPTION 'Los colores deben tener el formato #RRGGBB.';
        END IF;
    END LOOP;
    IF NULLIF(p_tema ->> 'fontFamily', '') IS NOT NULL AND (p_tema ->> 'fontFamily') !~ '^[a-z0-9_-]{1,30}$' THEN
        RAISE EXCEPTION 'Tipografía no válida.';
    END IF;

    UPDATE core.empresas
       SET color_primario   = COALESCE(NULLIF(p_tema ->> 'primary', ''), color_primario),
           color_secundario = COALESCE(NULLIF(p_tema ->> 'secondary', ''), color_secundario),
           color_acento     = COALESCE(NULLIF(p_tema ->> 'accent', ''), color_acento),
           color_fondo      = COALESCE(NULLIF(p_tema ->> 'background', ''), color_fondo),
           tipografia       = COALESCE(NULLIF(p_tema ->> 'fontFamily', ''), tipografia),
           logo_texto       = core.fn_texto(p_tema ->> 'logoTexto', 24),
           logo_acento      = core.fn_texto(p_tema ->> 'logoAcento', 24),
           iniciales        = upper(core.fn_texto(p_tema ->> 'iniciales', 3)),
           lema             = core.fn_texto(p_tema ->> 'lema', 80),
           actualizado_en   = now()
     WHERE id = p_empresa_id;

    -- Imágenes: sólo si vienen ("" = quitar)
    IF p_tema ? 'logo' OR p_tema ? 'favicon' THEN
        INSERT INTO core.empresa_imagenes (empresa_id) VALUES (p_empresa_id) ON CONFLICT (empresa_id) DO NOTHING;
        UPDATE core.empresa_imagenes
           SET logo    = CASE WHEN p_tema ? 'logo'    THEN NULLIF(p_tema ->> 'logo', '')    ELSE logo END,
               favicon = CASE WHEN p_tema ? 'favicon' THEN NULLIF(p_tema ->> 'favicon', '') ELSE favicon END,
               actualizado_en = now()
         WHERE empresa_id = p_empresa_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_modulo_empresa(p_empresa_id INTEGER, p_modulo VARCHAR, p_activo BOOLEAN, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_mod core.modulos;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'plataforma');
    SELECT * INTO v_mod FROM core.modulos WHERE codigo = p_modulo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El módulo "%" no existe.', p_modulo;
    END IF;
    IF v_mod.obligatorio AND NOT p_activo THEN
        RAISE EXCEPTION 'El módulo % siempre está incluido: no se puede apagar.', v_mod.nombre;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.empresas WHERE id = p_empresa_id) THEN
        RAISE EXCEPTION 'Esa empresa no existe.';
    END IF;
    INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo)
    VALUES (p_empresa_id, v_mod.id, p_activo)
    ON CONFLICT (empresa_id, modulo_id) DO UPDATE SET activo = EXCLUDED.activo;
END;
$$;

/* ALTA COMPLETA, todo o nada. p_datos: ficha + direccion, ciudad, tipo_negocio,
   modulos {stock, cierre}, tema {...}, admin {nombre, usuario, pin} (opcional). */
CREATE OR REPLACE PROCEDURE api.sp_alta_empresa(p_usuario_id INTEGER, p_datos JSONB, INOUT p_empresa_id INTEGER DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_unidad  INTEGER;
    v_admin   INTEGER;
    v_mod     RECORD;
    v_nombre  TEXT := core.fn_texto(p_datos ->> 'nombre_comercial', 120);
    v_tipo    TEXT := COALESCE(NULLIF(p_datos ->> 'tipo_negocio', ''), 'restaurante');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'plataforma');

    CALL api.sp_guardar_empresa(p_usuario_id, p_datos, p_empresa_id);

    -- Primera unidad, con los datos del alta
    IF NOT EXISTS (SELECT 1 FROM core.tipos_negocio WHERE codigo = v_tipo) THEN
        v_tipo := 'otro';
    END IF;
    CALL api.sp_guardar_unidad(
        p_empresa_id => p_empresa_id, p_nombre => left(v_nombre || ' · Sede principal', 120), p_tipo_negocio => v_tipo,
        p_usuario_id => p_usuario_id, p_nombre_corto => 'Principal',
        p_direccion => p_datos ->> 'direccion', p_ciudad => p_datos ->> 'ciudad',
        p_telefono => p_datos ->> 'telefono',
        p_whatsapp => regexp_replace(COALESCE(p_datos ->> 'whatsapp', ''), '\D', '', 'g'),
        p_mesas => 10, p_unidad_id => v_unidad);

    -- Módulos: los obligatorios siempre; los demás según el alta (por defecto, apagados)
    FOR v_mod IN SELECT * FROM core.modulos LOOP
        CALL api.sp_modulo_empresa(p_empresa_id, v_mod.codigo,
                                   v_mod.obligatorio OR COALESCE((p_datos -> 'modulos' ->> v_mod.codigo)::BOOLEAN, FALSE),
                                   p_usuario_id);
    END LOOP;

    IF jsonb_typeof(p_datos -> 'tema') = 'object' THEN
        CALL api.sp_guardar_tema_empresa(p_empresa_id, p_usuario_id, p_datos -> 'tema');
    END IF;

    -- Lo que toda empresa necesita para operar desde el primer día
    INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, descripcion, orden)
    SELECT p_empresa_id, mp.id, TRUE, x.descripcion, x.orden
      FROM (VALUES ('efectivo', 'Le pagas al domiciliario cuando recibas.', 1),
                   ('datafono', 'El domiciliario lleva datáfono. Tarjeta débito o crédito.', 2),
                   ('transferencia', 'Transfieres ahora y despachamos apenas confirmemos el pago.', 3)) AS x (metodo, descripcion, orden)
      JOIN core.metodos_pago mp ON mp.codigo = x.metodo
    ON CONFLICT (empresa_id, metodo_pago_id) DO NOTHING;

    INSERT INTO core.categorias_gasto (empresa_id, nombre, icono)
    SELECT p_empresa_id, x.nombre, x.icono
      FROM (VALUES ('Compra a proveedor', '🚚'), ('Nómina', '👥'), ('Vale', '🧾'),
                   ('Servicios', '💡'), ('Operación', '🔧'), ('Otros', '📌')) AS x (nombre, icono)
    ON CONFLICT (empresa_id, nombre) DO NOTHING;

    INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos)
    VALUES (p_empresa_id, 'pedido', 0, 5)
    ON CONFLICT (empresa_id, tipo) DO NOTHING;

    -- Administrador inicial (siempre rol de empresa, nunca SuperAdmin)
    IF jsonb_typeof(p_datos -> 'admin') = 'object' AND NULLIF(p_datos -> 'admin' ->> 'usuario', '') IS NOT NULL THEN
        CALL api.sp_guardar_usuario(
            p_empresa_id => p_empresa_id, p_rol => 'admin',
            p_nombre => p_datos -> 'admin' ->> 'nombre', p_usuario => p_datos -> 'admin' ->> 'usuario',
            p_admin_id => p_usuario_id, p_pin => p_datos -> 'admin' ->> 'pin',
            p_unidades => '{}', p_activo => TRUE, p_usuario_id => v_admin);
    END IF;
END;
$$;


/* ============================================================================
   5. API REST
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_exigir_plataforma()
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    IF NOT core.fn_tiene_permiso(v_usuario, 'plataforma') THEN
        RAISE EXCEPTION 'Sólo la plataforma Taseca puede hacer esto.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_usuario;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_empresa_por_codigo(p_codigo TEXT)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id INTEGER := (SELECT id FROM core.empresas WHERE codigo = p_codigo);
BEGIN
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'La empresa "%" no existe.', p_codigo;
    END IF;
    RETURN v_id;
END;
$$;

/* ---- Configuración (Admin de la empresa) ---- */
CREATE OR REPLACE FUNCTION rest.guardar_configuracion(p_datos JSONB, p_cuentas JSONB DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    CALL api.sp_guardar_configuracion(v_empresa, v_usuario, p_datos, p_cuentas);
    RETURN (SELECT to_jsonb(v) FROM api.v_empresa_ficha v WHERE v.empresa_id = v_empresa);
END;
$$;

CREATE OR REPLACE FUNCTION rest.guardar_metodos_pago(p_metodos JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    CALL api.sp_guardar_metodos_pago(v_empresa, v_usuario, p_metodos);
    RETURN (SELECT metodos_pago FROM api.v_empresa_ficha WHERE empresa_id = v_empresa);
END;
$$;

/* ---- Facturas de prueba (Ajustes) ---- */
CREATE OR REPLACE FUNCTION rest.facturas_prueba()
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
BEGIN
    IF NOT core.fn_tiene_permiso(v_usuario, 'pedidos_anular') THEN
        RETURN jsonb_build_object('pedidos', 0, 'entradas', 0);
    END IF;
    RETURN jsonb_build_object(
        'pedidos', (SELECT count(*) FROM core.pedidos WHERE empresa_id = v_empresa),
        'entradas', (SELECT count(*) FROM core.entradas_inventario e JOIN core.pedidos p ON p.id = e.pedido_id
                      WHERE p.empresa_id = v_empresa));
END;
$$;

CREATE OR REPLACE FUNCTION rest.borrar_facturas_prueba(p_confirmacion TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_antes    JSONB   := rest.facturas_prueba();
    v_borradas INTEGER;
BEGIN
    CALL api.sp_borrar_facturas_prueba(v_empresa, p_confirmacion, v_usuario, v_borradas);
    RETURN jsonb_build_object('pedidos', v_borradas, 'entradas', (v_antes ->> 'entradas')::INTEGER);
END;
$$;

/* ---- Plataforma ---- */
CREATE OR REPLACE FUNCTION rest.guardar_empresa(p_empresa TEXT, p_datos JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER := core.fn_empresa_por_codigo(p_empresa);
BEGIN
    CALL api.sp_guardar_empresa(v_usuario, p_datos, v_id);
    RETURN (SELECT to_jsonb(v) FROM api.v_empresa_ficha v WHERE v.empresa_id = v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.guardar_tema_empresa(p_empresa TEXT, p_tema JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER := core.fn_empresa_por_codigo(p_empresa);
BEGIN
    CALL api.sp_guardar_tema_empresa(v_id, v_usuario, p_tema);
    RETURN (SELECT to_jsonb(v) FROM api.v_empresa_ficha v WHERE v.empresa_id = v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.modulo_empresa(p_empresa TEXT, p_modulo TEXT, p_activo BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER := core.fn_empresa_por_codigo(p_empresa);
BEGIN
    CALL api.sp_modulo_empresa(v_id, p_modulo, p_activo, v_usuario);
    RETURN (SELECT modulos FROM api.v_empresa_ficha WHERE empresa_id = v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.alta_empresa(p_datos JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER;
BEGIN
    CALL api.sp_alta_empresa(v_usuario, p_datos, v_id);
    RETURN (SELECT to_jsonb(v) FROM api.v_empresa_ficha v WHERE v.empresa_id = v_id);
END;
$$;

/* Entrar a administrar una empresa: token nuevo con esa empresa. El usuario
   sigue siendo SuperAdmin; sólo cambia qué empresa está mirando. */
CREATE OR REPLACE FUNCTION rest.entrar_empresa(p_empresa TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_plataforma();
    v_id      INTEGER;
    v_exp     BIGINT;
BEGIN
    IF p_empresa IS NOT NULL THEN
        v_id := core.fn_empresa_por_codigo(p_empresa);
        IF (SELECT estado FROM core.empresas WHERE id = v_id) <> 'activa' THEN
            RAISE EXCEPTION 'Esa empresa está desactivada: actívala primero.';
        END IF;
    END IF;
    v_exp := extract(epoch FROM now() + make_interval(hours => (SELECT duracion_horas FROM core.jwt_config ORDER BY id DESC LIMIT 1)))::BIGINT;
    RETURN jsonb_build_object(
        'token', core.fn_jwt_firmar(jsonb_build_object('role', 'taseca_app', 'usuario_id', v_usuario,
                                                      'empresa_id', v_id, 'rol', 'superadmin', 'exp', v_exp)),
        'expira', to_timestamp(v_exp),
        'empresa_codigo', p_empresa);
END;
$$;


/* ============================================================================
   6. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_texto(TEXT, INTEGER), core.fn_exigir_plataforma(), core.fn_empresa_por_codigo(TEXT) FROM PUBLIC;

REVOKE ALL ON PROCEDURE api.sp_guardar_configuracion(INTEGER, INTEGER, JSONB, JSONB),
                        api.sp_guardar_metodos_pago(INTEGER, INTEGER, JSONB),
                        api.sp_guardar_empresa(INTEGER, JSONB, INTEGER),
                        api.sp_guardar_tema_empresa(INTEGER, INTEGER, JSONB),
                        api.sp_modulo_empresa(INTEGER, VARCHAR, BOOLEAN, INTEGER),
                        api.sp_alta_empresa(INTEGER, JSONB, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_guardar_configuracion(INTEGER, INTEGER, JSONB, JSONB),
                           api.sp_guardar_metodos_pago(INTEGER, INTEGER, JSONB),
                           api.sp_guardar_empresa(INTEGER, JSONB, INTEGER),
                           api.sp_guardar_tema_empresa(INTEGER, INTEGER, JSONB),
                           api.sp_modulo_empresa(INTEGER, VARCHAR, BOOLEAN, INTEGER),
                           api.sp_alta_empresa(INTEGER, JSONB, INTEGER)
      TO taseca_app;

GRANT SELECT ON api.v_empresa_ficha TO taseca_app, taseca_lectura;
GRANT SELECT ON rest.empresas, rest.empresa_imagenes TO taseca_anon, taseca_app;
GRANT SELECT ON rest.plataforma_empresas, rest.plataforma_usuarios TO taseca_app;

REVOKE ALL ON FUNCTION rest.guardar_configuracion(JSONB, JSONB), rest.guardar_metodos_pago(JSONB),
                       rest.facturas_prueba(), rest.borrar_facturas_prueba(TEXT),
                       rest.guardar_empresa(TEXT, JSONB), rest.guardar_tema_empresa(TEXT, JSONB),
                       rest.modulo_empresa(TEXT, TEXT, BOOLEAN), rest.alta_empresa(JSONB), rest.entrar_empresa(TEXT)
       FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.guardar_configuracion(JSONB, JSONB), rest.guardar_metodos_pago(JSONB),
                          rest.facturas_prueba(), rest.borrar_facturas_prueba(TEXT),
                          rest.guardar_empresa(TEXT, JSONB), rest.guardar_tema_empresa(TEXT, JSONB),
                          rest.modulo_empresa(TEXT, TEXT, BOOLEAN), rest.alta_empresa(JSONB), rest.entrar_empresa(TEXT)
      TO taseca_app;

NOTIFY pgrst, 'reload schema';
