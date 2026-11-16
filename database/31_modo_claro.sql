/* ============================================================================
   TASECA · 31 · CLARO U OSCURO, LO ELIGE LA EMPRESA
   ----------------------------------------------------------------------------
   Todo el sistema era oscuro. En un local iluminado, a mediodía, un panel
   negro se ve como una herramienta de informático y no como el software del
   restaurante; y hay marcas que sobre negro no son las suyas.

   Ahora cada empresa elige, junto a sus colores: `core.empresas.modo`.

   NO ES UNA PREFERENCIA DE QUIEN MIRA

     Es del NEGOCIO, como el logo o la tipografía: todos sus clientes lo ven
     igual. Por eso vive en core.empresas y no en el navegador de nadie.

   LO QUE CAMBIA EN EL CÓDIGO: NADA

     js/tema.js lo escribe en <html data-tema="claro">, y el bloque
     [data-tema='claro'] de css/styles.css cambia los VALORES de los tokens
     que ya estaban puestos. Ninguna pantalla tiene que saber en qué modo
     está, igual que pasa con `patron` desde 20_motivo_marca.sql.

   SIN DATO, OSCURO

     Las empresas que ya existen se quedan exactamente como estaban. El modo
     claro hay que pedirlo.

   Se puede ejecutar más de una vez.
   Requiere: 00 … 30 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. LA COLUMNA
   ============================================================================ */
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS modo VARCHAR(10);

COMMENT ON COLUMN core.empresas.modo IS
    'claro u oscuro. Lo ven igual todos los clientes de la empresa. Sin dato, oscuro.';

DO $blk$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_empresas_modo') THEN
        ALTER TABLE core.empresas
            ADD CONSTRAINT ck_empresas_modo CHECK (modo IS NULL OR modo IN ('claro', 'oscuro'));
    END IF;
END;
$blk$;

/* Lo que ya existe sigue oscuro, que es como se veía ayer. */
UPDATE core.empresas SET modo = 'oscuro' WHERE modo IS NULL;


/* ============================================================================
   2. LAS VISTAS

   OJO con el ORDEN: CREATE OR REPLACE VIEW no deja quitar columnas,
   renombrarlas ni meter una en medio — sólo añadir al final. Por eso `modo`
   va la última en las dos, detrás de `patron`.

   Y OJO con la lista: estas vistas NO son las de 15_fase2_configuracion_
   plataforma.sql. Han crecido (n_unidades, n_usuarios, patron, y el recargo
   de la 30). Lo de aquí es su forma REAL. Si vuelven a crecer:
     SELECT pg_get_viewdef('api.v_empresa_ficha'::regclass, true);
   ============================================================================ */
CREATE OR REPLACE VIEW api.v_empresa_ficha AS
SELECT e.id AS empresa_id,
       e.codigo,
       e.nombre_comercial,
       e.razon_social,
       e.nit,
       e.eslogan,
       e.descripcion,
       e.estado,
       e.hora_corte_operativa,
       e.telefono,
       e.whatsapp,
       e.email,
       e.direccion,
       e.horario_general,
       e.instagram_url,
       e.facebook_url,
       e.tiempo_mesa,
       e.tiempo_domicilio,
       e.color_primario,
       e.color_secundario,
       e.color_acento,
       e.color_fondo,
       e.tipografia,
       e.logo_texto,
       e.logo_acento,
       e.iniciales,
       e.lema,
       e.plantilla,
       e.creado_en,
       core.fn_fecha_operativa(e.id, now()) AS jornada_actual,
       (SELECT i.actualizado_en FROM core.empresa_imagenes i WHERE i.empresa_id = e.id) AS imagenes_version,
       (SELECT jsonb_object_agg(m.modulo, m.activo) FROM api.v_empresa_modulos m WHERE m.empresa_id = e.id) AS modulos,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', mp.codigo, 'nombre', mp.nombre, 'grupo', mp.grupo_caja,
                                                     'descripcion', emp.descripcion, 'activo', emp.activo,
                                                     'recargo', emp.recargo, 'recargo_tipo', emp.recargo_tipo)
                                  ORDER BY emp.orden, mp.id)
                   FROM core.empresa_metodos_pago emp
                   JOIN core.metodos_pago mp ON mp.id = emp.metodo_pago_id
                  WHERE emp.empresa_id = e.id), '[]'::jsonb) AS metodos_pago,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('entidad', c.entidad, 'numero', c.numero, 'titular', c.titular)
                                  ORDER BY c.id)
                   FROM core.cuentas_recaudo c
                  WHERE c.empresa_id = e.id AND c.activa), '[]'::jsonb) AS cuentas,
       (SELECT count(*) FROM core.unidades u  WHERE u.empresa_id  = e.id) AS n_unidades,
       (SELECT count(*) FROM core.usuarios us WHERE us.empresa_id = e.id) AS n_usuarios,
       e.patron,
       e.modo
  FROM core.empresas e;

CREATE OR REPLACE VIEW rest.empresas AS
SELECT v.empresa_id, v.codigo, v.nombre_comercial, v.eslogan, v.telefono, v.whatsapp, v.email,
       v.direccion, v.horario_general, v.tiempo_mesa, v.tiempo_domicilio,
       v.color_primario, v.color_secundario, v.color_acento, v.color_fondo,
       e.logo_url, v.hora_corte_operativa, v.jornada_actual,
       v.razon_social, v.nit, v.descripcion, v.instagram_url, v.facebook_url,
       v.tipografia, v.logo_texto, v.logo_acento, v.iniciales, v.lema, v.plantilla,
       v.estado, v.creado_en, v.imagenes_version, v.modulos, v.metodos_pago, v.cuentas,
       v.patron,
       v.modo
  FROM api.v_empresa_ficha v
  JOIN core.empresas e ON e.id = v.empresa_id
 WHERE v.estado::TEXT = 'activa'::TEXT;

GRANT SELECT ON rest.empresas TO taseca_anon, taseca_app;


/* Y la que lee el PANEL DE TASECA.

   Se escapó la primera vez, y costó caro: el panel guardaba el modo pero
   al volver a abrir «Administrar tema» mostraba el de antes, porque lo
   leía de aquí. Y al guardar cualquier otra cosa, mandaba el modo que
   estaba viendo y deshacía el cambio sin avisar.

   La 20 la crea con `SELECT v.*`, que se expande AL CREARLA: añadir la
   columna a la ficha no basta, hay que volver a crear esta vista para
   que la vea. */
CREATE OR REPLACE VIEW rest.plataforma_empresas AS
SELECT v.*
  FROM api.v_empresa_ficha v
 WHERE api.fn_tiene_permiso(core.fn_jwt_usuario(), 'plataforma');


/* ============================================================================
   3. GUARDARLO

   El procedimiento del tema se parchea entero porque no hay forma de
   añadirle un campo a un UPDATE sin reescribirlo. Es el mismo que instaló
   20_motivo_marca.sql con una línea más.
   ============================================================================ */
DO $blk$
BEGIN
EXECUTE $sql$
CREATE OR REPLACE PROCEDURE api.sp_guardar_tema(p_empresa_id INTEGER, p_usuario_id INTEGER, p_tema JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $pr$
DECLARE
    c TEXT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'ajustes');

    FOREACH c IN ARRAY ARRAY['primary', 'secondary', 'accent', 'background'] LOOP
        IF NULLIF(p_tema ->> c, '') IS NOT NULL AND (p_tema ->> c) !~ '^#[0-9A-Fa-f]{6}$' THEN
            RAISE EXCEPTION 'Los colores deben tener el formato #RRGGBB.';
        END IF;
    END LOOP;
    IF NULLIF(p_tema ->> 'fontFamily', '') IS NOT NULL AND (p_tema ->> 'fontFamily') !~ '^[a-z0-9_-]{1,30}$' THEN
        RAISE EXCEPTION 'Tipografía no válida.';
    END IF;
    IF NULLIF(p_tema ->> 'patron', '') IS NOT NULL AND (p_tema ->> 'patron') !~ '^[a-z0-9_-]{1,20}$' THEN
        RAISE EXCEPTION 'Motivo de marca no válido.';
    END IF;
    IF NULLIF(p_tema ->> 'modo', '') IS NOT NULL AND (p_tema ->> 'modo') NOT IN ('claro', 'oscuro') THEN
        RAISE EXCEPTION 'El modo sólo puede ser claro u oscuro.';
    END IF;

    UPDATE core.empresas
       SET color_primario   = COALESCE(NULLIF(p_tema ->> 'primary', ''), color_primario),
           color_secundario = COALESCE(NULLIF(p_tema ->> 'secondary', ''), color_secundario),
           color_acento     = COALESCE(NULLIF(p_tema ->> 'accent', ''), color_acento),
           color_fondo      = COALESCE(NULLIF(p_tema ->> 'background', ''), color_fondo),
           tipografia       = COALESCE(NULLIF(p_tema ->> 'fontFamily', ''), tipografia),
           patron           = COALESCE(NULLIF(p_tema ->> 'patron', ''), patron),
           modo             = COALESCE(NULLIF(p_tema ->> 'modo', ''), modo),
           logo_texto       = core.fn_texto(p_tema ->> 'logoTexto', 24),
           logo_acento      = core.fn_texto(p_tema ->> 'logoAcento', 24),
           iniciales        = upper(core.fn_texto(p_tema ->> 'iniciales', 3)),
           lema             = core.fn_texto(p_tema ->> 'lema', 80),
           actualizado_en   = now()
     WHERE id = p_empresa_id;

    IF p_tema ? 'logo' OR p_tema ? 'favicon' THEN
        INSERT INTO core.empresa_imagenes (empresa_id) VALUES (p_empresa_id) ON CONFLICT (empresa_id) DO NOTHING;
        UPDATE core.empresa_imagenes
           SET logo    = CASE WHEN p_tema ? 'logo'    THEN NULLIF(p_tema ->> 'logo', '')    ELSE logo END,
               favicon = CASE WHEN p_tema ? 'favicon' THEN NULLIF(p_tema ->> 'favicon', '') ELSE favicon END,
               actualizado_en = now()
         WHERE empresa_id = p_empresa_id;
    END IF;
END;
$pr$;
$sql$;
END;
$blk$;


/* ============================================================================
   4. REVISIÓN

   Por SQL dinámico, igual que en la 20: en el editor de Supabase, que habla
   con la base por el pooler, un bloque PL/pgSQL puede compilarse contra el
   plan en caché de la tabla ANTERIOR al ALTER y quejarse de que «column modo
   does not exist» aunque ya esté creada.
   ============================================================================ */
DO $blk$
DECLARE
    v_sin INTEGER;
    v_tot INTEGER;
BEGIN
    EXECUTE 'SELECT count(*) FROM core.empresas WHERE modo IS NULL' INTO v_sin;
    EXECUTE 'SELECT count(*) FROM core.empresas' INTO v_tot;

    IF v_sin <> 0 THEN
        RAISE EXCEPTION '% de % empresas se quedaron sin modo.', v_sin, v_tot;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'rest' AND table_name = 'empresas'
                      AND column_name = 'modo') THEN
        RAISE EXCEPTION 'rest.empresas no expone el modo: la aplicación no lo vería.';
    END IF;

    RAISE NOTICE 'OK · % empresas con modo, todas en oscuro.', v_tot;
    RAISE NOTICE '  Se cambia en el panel de Taseca, en el tema de cada empresa.';
END;
$blk$;
