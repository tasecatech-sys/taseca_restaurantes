/* ============================================================================
   TASECA · 14 · FASE 2 · BLOQUE 4: BASE DE CAJA, GASTOS Y CRUCE DE CAJA
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 13. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · Gastos con todo lo que tiene la pantalla: concepto, proveedor o
       persona, observaciones, hora y consecutivo (G3-260915-001). Se editan
       mientras están registrados; confirmar y anular dejan quién y cuándo.
     · Base de caja con hora y motivo de corrección. Si ya hay una, no se
       reemplaza en silencio: hay que pedir la corrección y escribir el motivo.
     · rest.informe_caja: el cruce de caja de una jornada, calculado en la base.

   CORRIGE
     · El efectivo esperado (y el RC) se calculaba con lo VENDIDO. Ahora usa
       lo COBRADO, como la aplicación: un domicilio por transferencia sin
       confirmar no es plata que haya entrado. Lo vendido, lo cobrado, lo que
       falta por cobrar y las facturas anuladas se informan por separado.
     · Confirmar o anular un gasto no exigía que fuera de la empresa del
       usuario ni revisaba su estado.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS tercero         VARCHAR(160);
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS observaciones   VARCHAR(400);
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS hora            TIME;
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS consecutivo_dia SMALLINT;
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS confirmado_en   TIMESTAMPTZ;
ALTER TABLE core.gastos ADD COLUMN IF NOT EXISTS anulado_en      TIMESTAMPTZ;
COMMENT ON COLUMN core.gastos.descripcion IS 'El concepto del gasto (Carne de res 20 kg).';
COMMENT ON COLUMN core.gastos.consecutivo_dia IS 'Número del gasto en su unidad y jornada. El código G<unidad>-<AAMMDD>-<nnn> se arma en la vista.';

-- Los gastos anteriores reciben su número en el orden en que se crearon
UPDATE core.gastos g
   SET consecutivo_dia = x.n
  FROM (SELECT id, row_number() OVER (PARTITION BY unidad_id, fecha_operativa ORDER BY creado_en, id) AS n
          FROM core.gastos) x
 WHERE x.id = g.id AND g.consecutivo_dia IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_gastos_consecutivo ON core.gastos (unidad_id, fecha_operativa, consecutivo_dia);

ALTER TABLE core.bases_caja ADD COLUMN IF NOT EXISTS hora              TIME;
ALTER TABLE core.bases_caja ADD COLUMN IF NOT EXISTS motivo_correccion VARCHAR(300);
COMMENT ON COLUMN core.bases_caja.motivo_correccion IS 'Por qué esta base reemplaza a la anterior (reemplaza_a_id).';

-- Antes el motivo de la corrección se guardaba en observacion
UPDATE core.bases_caja
   SET motivo_correccion = observacion, observacion = NULL
 WHERE reemplaza_a_id IS NOT NULL AND motivo_correccion IS NULL;


/* ============================================================================
   2. VISTAS DE CAJA
   ============================================================================ */

-- Columnas nuevas al final (CREATE OR REPLACE no permite reordenar)
CREATE OR REPLACE VIEW api.v_gastos AS
SELECT g.id AS gasto_id, g.unidad_id, u.empresa_id, u.nombre AS unidad, g.fecha_operativa,
       cg.nombre AS categoria, cg.icono AS categoria_icono,
       mp.codigo AS metodo_pago, mp.nombre AS metodo_pago_nombre, mp.grupo_caja,
       eg.codigo AS estado, eg.nombre AS estado_nombre,
       g.descripcion, g.monto, g.motivo_anulacion,
       ur.nombre AS registrado_por, uc.nombre AS confirmado_por, ua.nombre AS anulado_por,
       g.creado_en,
       g.categoria_gasto_id, g.tercero, g.observaciones, g.hora,
       'G' || g.unidad_id || '-' || to_char(g.fecha_operativa, 'YYMMDD') || '-' || lpad(COALESCE(g.consecutivo_dia, 0)::TEXT, 3, '0') AS consecutivo,
       g.registrado_por_id, rr.codigo AS registrado_rol, g.confirmado_en, g.anulado_en, g.actualizado_en
  FROM core.gastos g
  JOIN core.unidades u          ON u.id = g.unidad_id
  JOIN core.categorias_gasto cg ON cg.id = g.categoria_gasto_id
  JOIN core.metodos_pago mp     ON mp.id = g.metodo_pago_id
  JOIN core.estados_gasto eg    ON eg.id = g.estado_gasto_id
  LEFT JOIN core.usuarios ur ON ur.id = g.registrado_por_id
  LEFT JOIN core.roles rr    ON rr.id = ur.rol_id
  LEFT JOIN core.usuarios uc ON uc.id = g.confirmado_por_id
  LEFT JOIN core.usuarios ua ON ua.id = g.anulado_por_id;

CREATE OR REPLACE VIEW api.v_bases_caja AS
SELECT b.id AS base_id, b.unidad_id, u.empresa_id, b.fecha_operativa, b.monto, b.vigente,
       b.reemplaza_a_id, b.observacion, us.nombre AS registrada_por, b.creado_en,
       b.hora, b.motivo_correccion, b.usuario_id, r.codigo AS rol, u.nombre AS unidad
  FROM core.bases_caja b
  JOIN core.unidades u ON u.id = b.unidad_id
  LEFT JOIN core.usuarios us ON us.id = b.usuario_id
  LEFT JOIN core.roles r     ON r.id = us.rol_id;

/* Cruce de caja de la jornada.

     efectivo_esperado = base + lo COBRADO en efectivo − gastos en efectivo
     (= RC, reposición de caja)

   Las columnas de antes conservan su nombre; ventas_* sigue siendo lo
   vendido (facturado). Lo cobrado, lo pendiente y lo anulado van al final. */
CREATE OR REPLACE VIEW api.v_cruce_caja AS
WITH jornadas AS (
    SELECT unidad_id, fecha_operativa FROM core.bases_caja WHERE vigente
    UNION
    SELECT unidad_id, fecha_operativa FROM core.pedidos
    UNION
    SELECT unidad_id, fecha_operativa FROM core.gastos
),
ventas AS (
    SELECT unidad_id, fecha_operativa,
           count(*)::NUMERIC                                                              AS pedidos,
           SUM(total) FILTER (WHERE grupo_caja = 'efectivo')                              AS efectivo,
           SUM(total) FILTER (WHERE grupo_caja = 'transferencia')                         AS transferencia,
           SUM(total) FILTER (WHERE grupo_caja = 'otros')                                 AS otros,
           SUM(total)                                                                     AS total,
           SUM(total) FILTER (WHERE estado_pago = 'confirmado' AND grupo_caja = 'efectivo')      AS cob_efectivo,
           SUM(total) FILTER (WHERE estado_pago = 'confirmado' AND grupo_caja = 'transferencia') AS cob_transferencia,
           SUM(total) FILTER (WHERE estado_pago = 'confirmado' AND grupo_caja = 'otros')         AS cob_otros,
           SUM(total) FILTER (WHERE estado_pago NOT IN ('confirmado', 'rechazado'))              AS por_cobrar,
           count(*)   FILTER (WHERE estado_pago NOT IN ('confirmado', 'rechazado'))              AS n_por_cobrar,
           SUM(total) FILTER (WHERE estado_pago = 'rechazado')                                   AS rechazado
      FROM api.v_pedidos
     WHERE cuenta_como_venta
     GROUP BY unidad_id, fecha_operativa
),
anuladas AS (
    SELECT unidad_id, fecha_operativa, count(*) AS n, SUM(total) AS total
      FROM api.v_pedidos
     WHERE estado = 'anulado'
     GROUP BY unidad_id, fecha_operativa
),
gastos AS (
    SELECT unidad_id, fecha_operativa,
           SUM(monto) FILTER (WHERE grupo_caja = 'efectivo')      AS efectivo,
           SUM(monto) FILTER (WHERE grupo_caja = 'transferencia') AS transferencia,
           SUM(monto) FILTER (WHERE grupo_caja = 'otros')         AS otros,
           SUM(monto)                                             AS total,
           count(*)   FILTER (WHERE estado = 'registrado')        AS pendientes
      FROM api.v_gastos
     WHERE estado <> 'anulado'
     GROUP BY unidad_id, fecha_operativa
)
SELECT j.unidad_id, u.empresa_id, u.nombre AS unidad, j.fecha_operativa,
       COALESCE(b.monto, 0)             AS base,
       COALESCE(v.pedidos, 0)           AS pedidos,
       COALESCE(v.efectivo, 0)          AS ventas_efectivo,
       COALESCE(v.transferencia, 0)     AS ventas_transferencia,
       COALESCE(v.otros, 0)             AS ventas_otros,
       COALESCE(v.total, 0)             AS ventas_total,
       COALESCE(g.efectivo, 0)          AS gastos_efectivo,
       COALESCE(g.total, 0)             AS gastos_total,
       COALESCE(b.monto, 0) + COALESCE(v.cob_efectivo, 0) - COALESCE(g.efectivo, 0) AS efectivo_esperado,
       COALESCE(v.cob_efectivo, 0)      AS cobrado_efectivo,
       COALESCE(v.cob_transferencia, 0) AS cobrado_transferencia,
       COALESCE(v.cob_otros, 0)         AS cobrado_otros,
       COALESCE(v.por_cobrar, 0)        AS por_cobrar,
       COALESCE(v.n_por_cobrar, 0)      AS pedidos_por_cobrar,
       COALESCE(v.rechazado, 0)         AS rechazado,
       COALESCE(a.n, 0)                 AS anuladas,
       COALESCE(a.total, 0)             AS anuladas_total,
       COALESCE(g.transferencia, 0)     AS gastos_transferencia,
       COALESCE(g.otros, 0)             AS gastos_otros,
       COALESCE(g.pendientes, 0)        AS gastos_pendientes,
       COALESCE(v.cob_transferencia, 0) - COALESCE(g.transferencia, 0) AS transferencias_netas,
       COALESCE(v.cob_otros, 0) - COALESCE(g.otros, 0)                 AS otros_netos
  FROM jornadas j
  JOIN core.unidades u ON u.id = j.unidad_id
  LEFT JOIN core.bases_caja b ON b.unidad_id = j.unidad_id AND b.fecha_operativa = j.fecha_operativa AND b.vigente
  LEFT JOIN ventas v   ON v.unidad_id = j.unidad_id AND v.fecha_operativa = j.fecha_operativa
  LEFT JOIN anuladas a ON a.unidad_id = j.unidad_id AND a.fecha_operativa = j.fecha_operativa
  LEFT JOIN gastos g   ON g.unidad_id = j.unidad_id AND g.fecha_operativa = j.fecha_operativa;


/* ============================================================================
   3. BASE DE CAJA
   ============================================================================ */

/* Se reemplaza la versión de 04.
     p_corregir NULL  → como antes: si ya hay base, p_observacion es el motivo
     p_corregir FALSE → si ya hay base, error (no se pisa sin querer)
     p_corregir TRUE  → corrección: exige p_motivo */
DROP PROCEDURE IF EXISTS api.sp_registrar_base_caja(INTEGER, NUMERIC, INTEGER, DATE, VARCHAR, BIGINT);

CREATE OR REPLACE PROCEDURE api.sp_registrar_base_caja(
    p_unidad_id    INTEGER,
    p_monto        NUMERIC,
    p_usuario_id   INTEGER,
    p_fecha        DATE    DEFAULT NULL,
    p_observacion  VARCHAR DEFAULT NULL,
    p_hora         TIME    DEFAULT NULL,
    p_corregir     BOOLEAN DEFAULT NULL,
    p_motivo       VARCHAR DEFAULT NULL,
    INOUT p_base_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_hoy      DATE := core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now());
    v_fecha    DATE := COALESCE(p_fecha, v_hoy);
    v_anterior BIGINT;
    v_motivo   VARCHAR;
    v_obs      VARCHAR := NULLIF(trim(COALESCE(p_observacion, '')), '');
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'base_caja', p_unidad_id);
    PERFORM core.fn_exigir_unidad_operativa(p_unidad_id);

    IF p_monto IS NULL OR p_monto < 0 THEN
        RAISE EXCEPTION 'El valor de la base debe ser un número mayor o igual que cero.';
    END IF;
    IF v_fecha > v_hoy THEN
        RAISE EXCEPTION 'No se puede registrar la base de una jornada que todavía no llega.';
    END IF;

    SELECT id INTO v_anterior FROM core.bases_caja
     WHERE unidad_id = p_unidad_id AND fecha_operativa = v_fecha AND vigente
       FOR UPDATE;

    IF v_anterior IS NOT NULL THEN
        IF p_corregir IS FALSE THEN
            RAISE EXCEPTION 'Ya hay una base registrada para esa jornada. Para cambiarla hay que corregirla.';
        END IF;
        v_motivo := trim(COALESCE(CASE WHEN p_corregir THEN p_motivo ELSE p_observacion END, ''));
        IF length(v_motivo) < 3 THEN
            RAISE EXCEPTION 'Para corregir la base hay que escribir el motivo.';
        END IF;
        IF p_corregir IS NULL THEN
            v_obs := NULL; -- en la forma antigua la observación ERA el motivo
        END IF;
        UPDATE core.bases_caja SET vigente = FALSE WHERE id = v_anterior;
    ELSIF p_corregir THEN
        RAISE EXCEPTION 'No hay una base que corregir en esa jornada.';
    END IF;

    INSERT INTO core.bases_caja (unidad_id, fecha_operativa, monto, reemplaza_a_id, observacion, usuario_id,
                                 hora, motivo_correccion)
    VALUES (p_unidad_id, v_fecha, p_monto, v_anterior, left(v_obs, 300), p_usuario_id,
            COALESCE(p_hora, (now() AT TIME ZONE COALESCE((SELECT zona_horaria FROM core.empresas
                                                              WHERE id = core.fn_empresa_de_unidad(p_unidad_id)), 'America/Bogota'))::TIME(0)),
            left(v_motivo, 300))
    RETURNING id INTO p_base_id;
END;
$$;


/* ============================================================================
   4. GASTOS
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_validar_gasto(p_unidad_id INTEGER, p_categoria_gasto_id INTEGER, p_metodo_pago VARCHAR,
                                                 p_descripcion VARCHAR, p_monto NUMERIC, p_fecha DATE)
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    PERFORM core.fn_exigir_unidad_operativa(p_unidad_id);
    IF p_fecha IS NULL THEN
        RAISE EXCEPTION 'El gasto necesita una fecha válida.';
    END IF;
    IF p_fecha > core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now()) THEN
        RAISE EXCEPTION 'El gasto no puede ser de una jornada futura.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.categorias_gasto
                    WHERE id = p_categoria_gasto_id AND empresa_id = core.fn_empresa_de_unidad(p_unidad_id)) THEN
        RAISE EXCEPTION 'Elige una categoría para el gasto.';
    END IF;
    IF length(trim(COALESCE(p_descripcion, ''))) < 3 THEN
        RAISE EXCEPTION 'Escribe en qué se gastó el dinero (mínimo 3 caracteres).';
    END IF;
    IF p_monto IS NULL OR p_monto <= 0 THEN
        RAISE EXCEPTION 'El valor debe ser un número mayor que cero.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.metodos_pago WHERE codigo = p_metodo_pago) THEN
        RAISE EXCEPTION 'Elige un método de pago válido.';
    END IF;
END;
$$;

/* Se reemplaza la versión de 04: más datos, validaciones y consecutivo. */
DROP PROCEDURE IF EXISTS api.sp_registrar_gasto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, BIGINT);

CREATE OR REPLACE PROCEDURE api.sp_registrar_gasto(
    p_unidad_id           INTEGER,
    p_categoria_gasto_id  INTEGER,
    p_metodo_pago         VARCHAR,
    p_descripcion         VARCHAR,
    p_monto               NUMERIC,
    p_usuario_id          INTEGER,
    p_fecha               DATE    DEFAULT NULL,
    p_hora                TIME    DEFAULT NULL,
    p_tercero             VARCHAR DEFAULT NULL,
    p_observaciones       VARCHAR DEFAULT NULL,
    INOUT p_gasto_id      BIGINT  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_fecha DATE := COALESCE(p_fecha, core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now()));
    v_n     SMALLINT;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos', p_unidad_id);
    PERFORM core.fn_validar_gasto(p_unidad_id, p_categoria_gasto_id, p_metodo_pago, p_descripcion, p_monto, v_fecha);

    -- Consecutivo del día en la unidad (el bloqueo evita dos iguales a la vez)
    PERFORM pg_advisory_xact_lock(hashtext('gasto|' || p_unidad_id || '|' || v_fecha));
    SELECT COALESCE(max(consecutivo_dia), 0) + 1 INTO v_n
      FROM core.gastos WHERE unidad_id = p_unidad_id AND fecha_operativa = v_fecha;

    INSERT INTO core.gastos (unidad_id, categoria_gasto_id, metodo_pago_id, estado_gasto_id, fecha_operativa,
                             descripcion, monto, registrado_por_id, hora, tercero, observaciones, consecutivo_dia)
    VALUES (p_unidad_id, p_categoria_gasto_id, core.fn_id_catalogo('metodos_pago', p_metodo_pago),
            core.fn_id_catalogo('estados_gasto', 'registrado'), v_fecha, left(trim(p_descripcion), 300), p_monto,
            p_usuario_id, p_hora, NULLIF(left(trim(COALESCE(p_tercero, '')), 160), ''),
            NULLIF(left(trim(COALESCE(p_observaciones, '')), 400), ''), v_n)
    RETURNING id INTO p_gasto_id;
END;
$$;

/* Editar: sólo mientras el gasto está registrado. No cambia de unidad. */
CREATE OR REPLACE PROCEDURE api.sp_actualizar_gasto(
    p_gasto_id            BIGINT,
    p_categoria_gasto_id  INTEGER,
    p_metodo_pago         VARCHAR,
    p_descripcion         VARCHAR,
    p_monto               NUMERIC,
    p_usuario_id          INTEGER,
    p_fecha               DATE    DEFAULT NULL,
    p_hora                TIME    DEFAULT NULL,
    p_tercero             VARCHAR DEFAULT NULL,
    p_observaciones       VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_gasto  core.gastos;
    v_estado VARCHAR;
    v_fecha  DATE;
    v_n      SMALLINT;
BEGIN
    SELECT * INTO v_gasto FROM core.gastos WHERE id = p_gasto_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el gasto.';
    END IF;
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos', v_gasto.unidad_id);

    SELECT codigo INTO v_estado FROM core.estados_gasto WHERE id = v_gasto.estado_gasto_id;
    IF v_estado <> 'registrado' THEN
        RAISE EXCEPTION 'Un gasto % ya no se puede editar.', v_estado;
    END IF;

    v_fecha := COALESCE(p_fecha, v_gasto.fecha_operativa);
    PERFORM core.fn_validar_gasto(v_gasto.unidad_id, p_categoria_gasto_id, p_metodo_pago, p_descripcion, p_monto, v_fecha);

    v_n := v_gasto.consecutivo_dia;
    IF v_fecha <> v_gasto.fecha_operativa THEN
        PERFORM pg_advisory_xact_lock(hashtext('gasto|' || v_gasto.unidad_id || '|' || v_fecha));
        SELECT COALESCE(max(consecutivo_dia), 0) + 1 INTO v_n
          FROM core.gastos WHERE unidad_id = v_gasto.unidad_id AND fecha_operativa = v_fecha;
    END IF;

    UPDATE core.gastos
       SET categoria_gasto_id = p_categoria_gasto_id,
           metodo_pago_id     = core.fn_id_catalogo('metodos_pago', p_metodo_pago),
           descripcion        = left(trim(p_descripcion), 300),
           monto              = p_monto,
           fecha_operativa    = v_fecha,
           consecutivo_dia    = v_n,
           hora               = COALESCE(p_hora, hora),
           tercero            = NULLIF(left(trim(COALESCE(p_tercero, '')), 160), ''),
           observaciones      = NULLIF(left(trim(COALESCE(p_observaciones, '')), 400), ''),
           actualizado_en     = now()
     WHERE id = p_gasto_id;
END;
$$;

/* Misma firma que en 04; ahora revisa el estado y deja la fecha. */
CREATE OR REPLACE PROCEDURE api.sp_confirmar_gasto(p_gasto_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_estado VARCHAR;
    v_unidad INTEGER;
BEGIN
    SELECT eg.codigo, g.unidad_id INTO v_estado, v_unidad
      FROM core.gastos g JOIN core.estados_gasto eg ON eg.id = g.estado_gasto_id
     WHERE g.id = p_gasto_id FOR UPDATE OF g;
    IF v_unidad IS NULL THEN
        RAISE EXCEPTION 'No se encontró el gasto.';
    END IF;
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos_confirmar', v_unidad);

    IF v_estado = 'anulado' THEN
        RAISE EXCEPTION 'Un gasto anulado no se puede confirmar.';
    ELSIF v_estado = 'confirmado' THEN
        RETURN;
    END IF;
    UPDATE core.gastos
       SET estado_gasto_id = core.fn_id_catalogo('estados_gasto', 'confirmado'),
           confirmado_por_id = p_usuario_id, confirmado_en = now(), actualizado_en = now()
     WHERE id = p_gasto_id;
END;
$$;

/* Misma firma que en 04; ahora revisa el estado, el motivo y deja la fecha. */
CREATE OR REPLACE PROCEDURE api.sp_anular_gasto(p_gasto_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_estado VARCHAR;
    v_unidad INTEGER;
BEGIN
    SELECT eg.codigo, g.unidad_id INTO v_estado, v_unidad
      FROM core.gastos g JOIN core.estados_gasto eg ON eg.id = g.estado_gasto_id
     WHERE g.id = p_gasto_id FOR UPDATE OF g;
    IF v_unidad IS NULL THEN
        RAISE EXCEPTION 'No se encontró el gasto.';
    END IF;
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'gastos_anular', v_unidad);

    IF v_estado = 'anulado' THEN
        RETURN;
    END IF;
    IF length(trim(COALESCE(p_motivo, ''))) < 4 THEN
        RAISE EXCEPTION 'Escribe por qué se anula el gasto.';
    END IF;
    UPDATE core.gastos
       SET estado_gasto_id = core.fn_id_catalogo('estados_gasto', 'anulado'),
           motivo_anulacion = left(trim(p_motivo), 300), anulado_por_id = p_usuario_id,
           anulado_en = now(), actualizado_en = now()
     WHERE id = p_gasto_id;
END;
$$;


/* ============================================================================
   5. API REST · LECTURA
   Todo filtrado por la empresa del token, las unidades del usuario y sus
   permisos. Gastos y bases: los últimos 93 días (lo anterior, con ?desde).
   ============================================================================ */

CREATE OR REPLACE VIEW rest.categorias_gasto AS
SELECT c.id AS categoria_gasto_id, c.empresa_id, c.nombre, c.icono, c.activa
  FROM core.categorias_gasto c
 WHERE c.empresa_id = core.fn_jwt_empresa();

CREATE OR REPLACE VIEW rest.gastos AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT g.gasto_id, g.empresa_id, g.unidad_id, g.fecha_operativa, g.hora, g.consecutivo,
       g.categoria_gasto_id, g.metodo_pago, g.estado, g.descripcion, g.tercero, g.observaciones, g.monto,
       g.registrado_por_id, g.registrado_por, g.registrado_rol, g.confirmado_por, g.confirmado_en,
       g.anulado_por, g.anulado_en, g.motivo_anulacion, g.creado_en, g.actualizado_en
  FROM api.v_gastos g
  JOIN sesion s ON s.empresa_id = g.empresa_id
 WHERE core.fn_usuario_en_unidad(s.usuario_id, g.unidad_id)
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['gastos', 'gastos_confirmar', 'gastos_anular', 'informe']) p
                WHERE api.fn_tiene_permiso(s.usuario_id, p));

CREATE OR REPLACE VIEW rest.bases_caja AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT b.base_id, b.empresa_id, b.unidad_id, b.unidad, b.fecha_operativa, b.hora, b.monto, b.vigente,
       b.reemplaza_a_id, b.observacion, b.motivo_correccion, b.usuario_id, b.registrada_por, b.rol, b.creado_en
  FROM api.v_bases_caja b
  JOIN sesion s ON s.empresa_id = b.empresa_id
 WHERE core.fn_usuario_en_unidad(s.usuario_id, b.unidad_id)
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['base_caja', 'informe']) p
                WHERE api.fn_tiene_permiso(s.usuario_id, p));

/* Última modificación de gastos y bases de la empresa: la app recarga sólo si cambió. */
CREATE OR REPLACE VIEW rest.caja_marca AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_empresa() AS empresa_id
)
SELECT s.empresa_id,
       GREATEST(
           (SELECT max(g.actualizado_en) FROM core.gastos g JOIN core.unidades u ON u.id = g.unidad_id
             WHERE u.empresa_id = s.empresa_id),
           (SELECT max(b.creado_en) FROM core.bases_caja b JOIN core.unidades u ON u.id = b.unidad_id
             WHERE u.empresa_id = s.empresa_id)
       ) AS marca
  FROM sesion s
 WHERE s.empresa_id IS NOT NULL;


/* ============================================================================
   6. API REST · FUNCIONES
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_gasto_json(p_gasto_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT to_jsonb(g) FROM rest.gastos g WHERE g.gasto_id = p_gasto_id;
$$;

CREATE OR REPLACE FUNCTION core.fn_unidad_de_sesion(p_unidad_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    IF core.fn_empresa_de_unidad(p_unidad_id) IS DISTINCT FROM core.fn_jwt_empresa() THEN
        RAISE EXCEPTION 'La unidad % no es de esta empresa.', p_unidad_id USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN p_unidad_id;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_gasto_de_sesion(p_gasto_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.gastos g JOIN core.unidades u ON u.id = g.unidad_id
                    WHERE g.id = p_gasto_id AND u.empresa_id = core.fn_jwt_empresa()) THEN
        RAISE EXCEPTION 'No se encontró el gasto.';
    END IF;
    RETURN p_gasto_id;
END;
$$;

/* POST /rpc/registrar_base { "p_base": { unidad_id, fecha, monto, hora, observaciones, corregir, motivo } } */
CREATE OR REPLACE FUNCTION rest.registrar_base(p_base JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_unidad  INTEGER := core.fn_unidad_de_sesion(NULLIF(p_base ->> 'unidad_id', '')::INTEGER);
    v_id      BIGINT;
BEGIN
    CALL api.sp_registrar_base_caja(
        p_unidad_id   => v_unidad,
        p_monto       => NULLIF(p_base ->> 'monto', '')::NUMERIC,
        p_usuario_id  => v_usuario,
        p_fecha       => NULLIF(p_base ->> 'fecha', '')::DATE,
        p_observacion => p_base ->> 'observaciones',
        p_hora        => NULLIF(p_base ->> 'hora', '')::TIME,
        p_corregir    => COALESCE((p_base ->> 'corregir')::BOOLEAN, FALSE),
        p_motivo      => p_base ->> 'motivo',
        p_base_id     => v_id);
    RETURN (SELECT to_jsonb(b) FROM rest.bases_caja b WHERE b.base_id = v_id);
END;
$$;

/* POST /rpc/guardar_gasto { "p_gasto": { gasto_id|null, unidad_id, fecha, hora, categoria_gasto_id,
   metodo_pago, descripcion, tercero, observaciones, monto } } */
CREATE OR REPLACE FUNCTION rest.guardar_gasto(p_gasto JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_id      BIGINT  := NULLIF(p_gasto ->> 'gasto_id', '')::BIGINT;
    v_unidad  INTEGER;
BEGIN
    IF v_id IS NULL THEN
        v_unidad := core.fn_unidad_de_sesion(NULLIF(p_gasto ->> 'unidad_id', '')::INTEGER);
        CALL api.sp_registrar_gasto(
            p_unidad_id          => v_unidad,
            p_categoria_gasto_id => NULLIF(p_gasto ->> 'categoria_gasto_id', '')::INTEGER,
            p_metodo_pago        => p_gasto ->> 'metodo_pago',
            p_descripcion        => p_gasto ->> 'descripcion',
            p_monto              => NULLIF(p_gasto ->> 'monto', '')::NUMERIC,
            p_usuario_id         => v_usuario,
            p_fecha              => NULLIF(p_gasto ->> 'fecha', '')::DATE,
            p_hora               => NULLIF(p_gasto ->> 'hora', '')::TIME,
            p_tercero            => p_gasto ->> 'tercero',
            p_observaciones      => p_gasto ->> 'observaciones',
            p_gasto_id           => v_id);
    ELSE
        PERFORM core.fn_gasto_de_sesion(v_id);
        CALL api.sp_actualizar_gasto(
            p_gasto_id           => v_id,
            p_categoria_gasto_id => NULLIF(p_gasto ->> 'categoria_gasto_id', '')::INTEGER,
            p_metodo_pago        => p_gasto ->> 'metodo_pago',
            p_descripcion        => p_gasto ->> 'descripcion',
            p_monto              => NULLIF(p_gasto ->> 'monto', '')::NUMERIC,
            p_usuario_id         => v_usuario,
            p_fecha              => NULLIF(p_gasto ->> 'fecha', '')::DATE,
            p_hora               => NULLIF(p_gasto ->> 'hora', '')::TIME,
            p_tercero            => p_gasto ->> 'tercero',
            p_observaciones      => p_gasto ->> 'observaciones');
    END IF;
    RETURN core.fn_gasto_json(v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.confirmar_gasto(p_gasto_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_confirmar_gasto(core.fn_gasto_de_sesion(p_gasto_id), core.fn_exigir_sesion());
    RETURN core.fn_gasto_json(p_gasto_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.anular_gasto(p_gasto_id BIGINT, p_motivo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_anular_gasto(core.fn_gasto_de_sesion(p_gasto_id), p_motivo, core.fn_exigir_sesion());
    RETURN core.fn_gasto_json(p_gasto_id);
END;
$$;

/* EL CRUCE DE CAJA de una jornada, en la forma que usa la aplicación.
   p_unidad_id NULL = todas las unidades del usuario (la base es la suma). */
CREATE OR REPLACE FUNCTION rest.informe_caja(p_fecha DATE, p_unidad_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_unidades INTEGER[];
    v_ventas   JSONB;
    v_anuladas JSONB;
    v_gastos   JSONB;
    v_base     JSONB;
    v_valor    NUMERIC;
BEGIN
    IF NOT (core.fn_tiene_permiso(v_usuario, 'informe') OR core.fn_tiene_permiso(v_usuario, 'base_caja')) THEN
        RAISE EXCEPTION 'Tu perfil no puede ver el cruce de caja.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_unidad_id IS NOT NULL THEN
        PERFORM core.fn_unidad_de_sesion(p_unidad_id);
        IF NOT core.fn_usuario_en_unidad(v_usuario, p_unidad_id) THEN
            RAISE EXCEPTION 'No trabajas en esa unidad.' USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;

    SELECT array_agg(u.id) INTO v_unidades
      FROM core.unidades u
     WHERE u.empresa_id = v_empresa
       AND (p_unidad_id IS NULL OR u.id = p_unidad_id)
       AND core.fn_usuario_en_unidad(v_usuario, u.id);

    -- Ventas efectivas por método: vendido, cobrado, pendiente y rechazado
    SELECT COALESCE(jsonb_object_agg(metodo_pago, jsonb_build_object(
               'grupo', grupo_caja, 'n', n, 'vendido', vendido, 'cobrado', cobrado,
               'pendiente', pendiente, 'nPendiente', n_pendiente, 'rechazado', rechazado)), '{}')
      INTO v_ventas
      FROM (SELECT metodo_pago, grupo_caja, count(*) AS n, SUM(total) AS vendido,
                   COALESCE(SUM(total) FILTER (WHERE estado_pago = 'confirmado'), 0) AS cobrado,
                   COALESCE(SUM(total) FILTER (WHERE estado_pago NOT IN ('confirmado', 'rechazado')), 0) AS pendiente,
                   count(*) FILTER (WHERE estado_pago NOT IN ('confirmado', 'rechazado')) AS n_pendiente,
                   COALESCE(SUM(total) FILTER (WHERE estado_pago = 'rechazado'), 0) AS rechazado
              FROM api.v_pedidos
             WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND cuenta_como_venta
             GROUP BY metodo_pago, grupo_caja) x;

    SELECT COALESCE(jsonb_object_agg(metodo_pago, jsonb_build_object('grupo', grupo_caja, 'n', n, 'total', total)), '{}')
      INTO v_anuladas
      FROM (SELECT metodo_pago, grupo_caja, count(*) AS n, SUM(total) AS total
              FROM api.v_pedidos
             WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND estado = 'anulado'
             GROUP BY metodo_pago, grupo_caja) x;

    SELECT COALESCE(jsonb_object_agg(metodo_pago, jsonb_build_object(
               'grupo', grupo_caja, 'n', n, 'total', total, 'pendientes', pendientes, 'montoPendiente', monto_pendiente)), '{}')
      INTO v_gastos
      FROM (SELECT metodo_pago, grupo_caja, count(*) AS n, SUM(monto) AS total,
                   count(*) FILTER (WHERE estado = 'registrado') AS pendientes,
                   COALESCE(SUM(monto) FILTER (WHERE estado = 'registrado'), 0) AS monto_pendiente
              FROM api.v_gastos
             WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND estado <> 'anulado'
             GROUP BY metodo_pago, grupo_caja) x;

    SELECT COALESCE(SUM(monto), 0) INTO v_valor
      FROM core.bases_caja WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND vigente;
    IF p_unidad_id IS NOT NULL THEN
        SELECT to_jsonb(b) INTO v_base FROM rest.bases_caja b
         WHERE b.unidad_id = p_unidad_id AND b.fecha_operativa = p_fecha AND b.vigente;
    END IF;

    RETURN jsonb_build_object(
        'jornada', p_fecha, 'unidad_id', p_unidad_id,
        'base', jsonb_build_object('valor', v_valor, 'registro', v_base),
        'ventas', v_ventas, 'anuladas', v_anuladas, 'gastos', v_gastos);
END;
$$;


/* ============================================================================
   7. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_validar_gasto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, DATE),
                       core.fn_gasto_json(BIGINT), core.fn_unidad_de_sesion(INTEGER), core.fn_gasto_de_sesion(BIGINT)
       FROM PUBLIC;

REVOKE ALL ON PROCEDURE api.sp_registrar_base_caja(INTEGER, NUMERIC, INTEGER, DATE, VARCHAR, TIME, BOOLEAN, VARCHAR, BIGINT),
                        api.sp_registrar_gasto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, TIME, VARCHAR, VARCHAR, BIGINT),
                        api.sp_actualizar_gasto(BIGINT, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, TIME, VARCHAR, VARCHAR),
                        api.sp_confirmar_gasto(BIGINT, INTEGER),
                        api.sp_anular_gasto(BIGINT, VARCHAR, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_registrar_base_caja(INTEGER, NUMERIC, INTEGER, DATE, VARCHAR, TIME, BOOLEAN, VARCHAR, BIGINT),
                           api.sp_registrar_gasto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, TIME, VARCHAR, VARCHAR, BIGINT),
                           api.sp_actualizar_gasto(BIGINT, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER, DATE, TIME, VARCHAR, VARCHAR),
                           api.sp_confirmar_gasto(BIGINT, INTEGER),
                           api.sp_anular_gasto(BIGINT, VARCHAR, INTEGER)
      TO taseca_app;
GRANT SELECT ON api.v_gastos, api.v_bases_caja, api.v_cruce_caja TO taseca_app, taseca_lectura;

GRANT SELECT ON rest.categorias_gasto, rest.gastos, rest.bases_caja, rest.caja_marca TO taseca_app;

REVOKE ALL ON FUNCTION rest.registrar_base(JSONB), rest.guardar_gasto(JSONB), rest.confirmar_gasto(BIGINT),
                       rest.anular_gasto(BIGINT, TEXT), rest.informe_caja(DATE, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.registrar_base(JSONB), rest.guardar_gasto(JSONB), rest.confirmar_gasto(BIGINT),
                          rest.anular_gasto(BIGINT, TEXT), rest.informe_caja(DATE, INTEGER)
      TO taseca_app;

NOTIFY pgrst, 'reload schema';
