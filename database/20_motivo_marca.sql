/* ============================================================================
   TASECA · 20 · MOTIVO DE MARCA DE CADA EMPRESA
   ----------------------------------------------------------------------------
   La banda decorativa que corta la portada bajo la primera pantalla —y las
   fichas que acompañan al logotipo— eran la bandera a cuadros de NASCAR,
   escrita a la fuerza en el CSS. Ahora son un dato más del tema de cada
   empresa: `core.empresas.patron`.

   Qué dibujo es cada motivo lo decide css/styles.css (`html[data-patron=…]`)
   y la lista de los que se pueden elegir está en js/data.js
   (NASCAR.PATRONES). La base sólo guarda CUÁL eligió la empresa: aquí no
   entra CSS de nadie, igual que con la tipografía.

   NADIE CAMBIA DE ASPECTO POR ESTE SCRIPT
     A todas las empresas que ya existen se les escribe 'cuadros', que es
     exactamente lo que se les ve hoy. Las empresas NUEVAS nacen con el
     motivo que traiga su plantilla, que nunca es el de carreras.

   No toca pedidos, ventas, pagos ni auditoría. Se puede ejecutar más de una
   vez sin efectos.
   Requiere: 00 … 15 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS patron VARCHAR(20);
COMMENT ON COLUMN core.empresas.patron IS
    'Id del motivo de marca, de la lista cerrada de la aplicación (NASCAR.PATRONES). NULL = el de siempre.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_empresas_patron') THEN
        ALTER TABLE core.empresas
            ADD CONSTRAINT ck_empresas_patron CHECK (patron IS NULL OR patron ~ '^[a-z0-9_-]{1,20}$');
    END IF;
END;
$$;

/* Lo que ya está publicado se queda como está. */
UPDATE core.empresas SET patron = 'cuadros' WHERE patron IS NULL;


/* ============================================================================
   2. VISTAS

   Columnas nuevas al final: CREATE OR REPLACE VIEW sólo deja añadir.
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
       (SELECT count(*) FROM core.usuarios us WHERE us.empresa_id = e.id) AS n_usuarios,
       e.patron
  FROM core.empresas e;

CREATE OR REPLACE VIEW rest.empresas AS
SELECT v.empresa_id, v.codigo, v.nombre_comercial, v.eslogan, v.telefono, v.whatsapp, v.email, v.direccion,
       v.horario_general, v.tiempo_mesa, v.tiempo_domicilio, v.color_primario, v.color_secundario, v.color_acento,
       v.color_fondo, e.logo_url, v.hora_corte_operativa, v.jornada_actual,
       v.razon_social, v.nit, v.descripcion, v.instagram_url, v.facebook_url, v.tipografia, v.logo_texto,
       v.logo_acento, v.iniciales, v.lema, v.plantilla, v.estado, v.creado_en, v.imagenes_version,
       v.modulos, v.metodos_pago, v.cuentas, v.patron
  FROM api.v_empresa_ficha v
  JOIN core.empresas e ON e.id = v.empresa_id
 WHERE v.estado = 'activa';

/* `SELECT v.*` se guarda ya expandido, así que hay que volver a crearla
   para que vea la columna nueva. */
CREATE OR REPLACE VIEW rest.plataforma_empresas AS
SELECT v.*
  FROM api.v_empresa_ficha v
 WHERE api.fn_tiene_permiso(core.fn_jwt_usuario(), 'plataforma');


/* ============================================================================
   3. GUARDAR EL TEMA

   Misma puerta de siempre: sólo la plataforma. Una empresa no cambia su
   propio tema desde su panel, y mucho menos el de otra.
   ============================================================================ */

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
    IF NULLIF(p_tema ->> 'patron', '') IS NOT NULL AND (p_tema ->> 'patron') !~ '^[a-z0-9_-]{1,20}$' THEN
        RAISE EXCEPTION 'Motivo de marca no válido.';
    END IF;

    UPDATE core.empresas
       SET color_primario   = COALESCE(NULLIF(p_tema ->> 'primary', ''), color_primario),
           color_secundario = COALESCE(NULLIF(p_tema ->> 'secondary', ''), color_secundario),
           color_acento     = COALESCE(NULLIF(p_tema ->> 'accent', ''), color_acento),
           color_fondo      = COALESCE(NULLIF(p_tema ->> 'background', ''), color_fondo),
           tipografia       = COALESCE(NULLIF(p_tema ->> 'fontFamily', ''), tipografia),
           patron           = COALESCE(NULLIF(p_tema ->> 'patron', ''), patron),
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


/* ============================================================================
   4. REVISIÓN
   ============================================================================ */

DO $$
DECLARE
    v_sin  INTEGER;
    v_col  BOOLEAN;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'core.empresas'::regclass AND attname = 'patron' AND NOT attisdropped)
      INTO v_col;
    SELECT count(*) INTO v_sin FROM core.empresas WHERE patron IS NULL;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'Columna core.empresas.patron ....... %', CASE WHEN v_col THEN 'sí' ELSE 'NO' END;
    RAISE NOTICE 'Empresas sin motivo definido ....... %', v_sin;
    RAISE NOTICE 'Motivo de cada empresa:';
    RAISE NOTICE '--------------------------------------------------';
END;
$$;

SELECT codigo, nombre_comercial, patron AS motivo_de_marca
  FROM core.empresas
 ORDER BY id;
