/* ============================================================================
   TASECA · 10 · OPTIMIZACIÓN PARA PRODUCCIÓN (Supabase)
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 09. Idempotente.

   Medido con una operación simulada de 30 días (260 pedidos/día en los 4
   locales, ver database/COSTOS_SUPABASE.md). Antes de este archivo:

       auditoria          42 MB   68 % de toda la base
       pedidos            7,8 MB  inflada por los cambios de estado
       total              61 MB por mes  ·  8,2 KB por pedido

   Qué hace:
     1. AUDITORÍA LIVIANA
        · guarda sólo las columnas que cambiaron, no la fila entera dos veces
        · deja de auditar lo que ya tiene su propio historial (pedidos →
          pedido_historial) y lo que no se modifica nunca (entradas,
          anulaciones): el registro mismo ES la auditoría
        · el INSERT de las tablas operativas no se audita: la fila ya dice
          quién y cuándo; se audita cuando alguien la CAMBIA
        · retención: api.sp_purgar_auditoria borra por lotes lo antiguo
        · índice BRIN por fecha (ocupa ~1 % de un B-tree)
     2. ÍNDICES
        · se quitan los índices de llaves hacia catálogos pequeños en tablas
          grandes (estado, método de pago, tipo…). Los catálogos nunca se
          borran, así que esos índices sólo costaban escritura y disco, y
          además impedían las actualizaciones HOT de pedidos.
     3. TABLAS QUE SE ACTUALIZAN MUCHO
        · fillfactor 85: deja espacio en la página para que el cambio de
          estado reescriba la fila en el mismo sitio (HOT) sin inflar índices
     4. VISTAS MÁS BARATAS
        · api.v_platos_dia calcula los vendidos una sola vez por plato
        · rest.pedidos resuelve la sesión y las unidades UNA vez por consulta
          y arma el JSON sólo de las filas que pasan el filtro (clave para el
          refresco incremental de la aplicación)
     5. MANTENIMIENTO PROGRAMADO (pg_cron, disponible en Supabase)
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. AUDITORÍA LIVIANA
   ============================================================================ */

-- 1.1 Una sola columna con los cambios: {"columna": {"de": …, "a": …}}
ALTER TABLE core.auditoria ADD COLUMN IF NOT EXISTS cambios JSONB;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'core' AND table_name = 'auditoria' AND column_name = 'datos_antes') THEN
        -- Lo ya registrado se convierte, no se pierde
        UPDATE core.auditoria a
           SET cambios = CASE
                   WHEN a.accion = 'INSERT' THEN a.datos_despues
                   WHEN a.accion = 'DELETE' THEN a.datos_antes
                   ELSE (SELECT jsonb_object_agg(k, jsonb_build_object('de', a.datos_antes -> k, 'a', a.datos_despues -> k))
                           FROM jsonb_object_keys(a.datos_despues) AS k
                          WHERE (a.datos_antes -> k) IS DISTINCT FROM (a.datos_despues -> k)
                            AND k <> 'actualizado_en')
               END
         WHERE a.cambios IS NULL;

        DROP VIEW IF EXISTS api.v_auditoria;
        ALTER TABLE core.auditoria DROP COLUMN datos_antes, DROP COLUMN datos_despues;
    END IF;
END;
$$;

COMMENT ON COLUMN core.auditoria.cambios IS
    'UPDATE: sólo lo que cambió {"col": {"de": x, "a": y}}. INSERT/DELETE: la fila. Nunca el hash del PIN ni imágenes.';

-- 1.2 El trigger guarda la diferencia
CREATE OR REPLACE FUNCTION core.tg_auditoria()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    c_fuera   CONSTANT TEXT[] := ARRAY['actualizado_en', 'pin_hash', 'archivo_url'];
    v_antes   JSONB;
    v_despues JSONB;
    v_cambios JSONB;
BEGIN
    IF TG_OP <> 'INSERT' THEN v_antes   := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN v_despues := to_jsonb(NEW); END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(k, jsonb_build_object('de', v_antes -> k, 'a', v_despues -> k))
          INTO v_cambios
          FROM jsonb_object_keys(v_despues - c_fuera) AS k
         WHERE (v_antes -> k) IS DISTINCT FROM (v_despues -> k);

        -- Cambió el PIN: se registra el hecho, jamás el valor
        IF (v_antes ->> 'pin_hash') IS DISTINCT FROM (v_despues ->> 'pin_hash') THEN
            v_cambios := COALESCE(v_cambios, '{}'::JSONB) || '{"pin": "cambiado"}'::JSONB;
        END IF;

        IF v_cambios IS NULL THEN
            RETURN NEW; -- nada relevante cambió
        END IF;
    ELSE
        v_cambios := COALESCE(v_despues, v_antes) - c_fuera;
    END IF;

    INSERT INTO core.auditoria (tabla, registro_id, accion, cambios, usuario_id)
    VALUES (TG_TABLE_NAME,
            (COALESCE(v_despues, v_antes) ->> 'id')::BIGINT,
            TG_OP, v_cambios, core.fn_usuario_actual());

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- 1.3 Qué se audita y cómo
DO $$
DECLARE
    t TEXT;
BEGIN
    -- Fuera todos los triggers de auditoría anteriores
    FOR t IN SELECT c.relname
               FROM pg_trigger g JOIN pg_class c ON c.oid = g.tgrelid
              WHERE g.tgname LIKE 'trg\_%\_auditoria' ESCAPE '\'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_auditoria ON core.%1$I', t);
    END LOOP;

    -- Configuración: pocas filas, se audita todo (alta, cambio y baja)
    FOREACH t IN ARRAY ARRAY['empresas', 'empresa_modulos', 'empresa_metodos_pago', 'unidades', 'zonas_domicilio',
                             'usuarios', 'usuario_unidades', 'rol_permisos', 'productos']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_auditoria AFTER INSERT OR UPDATE OR DELETE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_auditoria()', t);
    END LOOP;

    -- Operación: la fila nueva ya dice quién y cuándo; se audita si alguien la cambia
    FOREACH t IN ARRAY ARRAY['gastos', 'bases_caja', 'cierres_inventario', 'cierre_detalles']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_auditoria AFTER UPDATE OR DELETE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_auditoria()', t);
    END LOOP;

    /* Sin trigger, a propósito:
         pedidos, pedido_items    → pedido_historial registra cada cambio
         entradas_inventario      → inmutables: la fila es la auditoría
         anulaciones              → inmutables: la fila es la auditoría
         insumo_unidades          → el stock se deriva de entradas y cierres */
END;
$$;

-- 1.4 Índices: el de fecha pasa a BRIN (la tabla sólo crece en orden de fecha)
DROP INDEX IF EXISTS core.ix_auditoria_fecha;
CREATE INDEX IF NOT EXISTS ix_auditoria_fecha_brin ON core.auditoria USING BRIN (creado_en) WITH (pages_per_range = 32);

ALTER TABLE core.auditoria SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.05);

-- 1.5 La vista con la nueva forma
CREATE OR REPLACE VIEW api.v_auditoria AS
SELECT a.id AS auditoria_id, a.tabla, a.registro_id, a.accion,
       us.nombre AS usuario, us.empresa_id, a.usuario_db, a.cambios, a.creado_en
  FROM core.auditoria a
  LEFT JOIN core.usuarios us ON us.id = a.usuario_id;

/* Una fila por columna cambiada: lo mismo que `cambios`, pero en columnas,
   para filtrar y hacer JOIN sin tocar JSON. */
CREATE OR REPLACE VIEW api.v_auditoria_detalle AS
SELECT a.id AS auditoria_id, a.tabla, a.registro_id, a.accion, a.usuario_id,
       us.nombre AS usuario, us.empresa_id, a.creado_en,
       c.key AS columna,
       CASE WHEN a.accion = 'UPDATE' THEN c.value ->> 'de' END AS valor_anterior,
       CASE WHEN a.accion = 'UPDATE' THEN c.value ->> 'a' ELSE c.value #>> '{}' END AS valor_nuevo
  FROM core.auditoria a
  CROSS JOIN LATERAL jsonb_each(a.cambios) c
  LEFT JOIN core.usuarios us ON us.id = a.usuario_id;

-- 1.6 Retención por lotes (no bloquea la tabla ni infla el WAL de golpe)
CREATE OR REPLACE PROCEDURE api.sp_purgar_auditoria(p_conservar_dias INTEGER DEFAULT 365, INOUT p_borradas BIGINT DEFAULT 0)
LANGUAGE plpgsql
SET search_path = core, public
AS $$
DECLARE
    v_limite TIMESTAMPTZ;
    v_n      BIGINT;
BEGIN
    IF p_conservar_dias IS NULL OR p_conservar_dias < 30 THEN
        RAISE EXCEPTION 'Conserva al menos 30 días de auditoría.';
    END IF;
    v_limite := now() - make_interval(days => p_conservar_dias);
    p_borradas := 0;
    LOOP
        DELETE FROM core.auditoria
         WHERE id IN (SELECT id FROM core.auditoria WHERE creado_en < v_limite ORDER BY id LIMIT 5000);
        GET DIAGNOSTICS v_n = ROW_COUNT;
        p_borradas := p_borradas + v_n;
        EXIT WHEN v_n = 0;
        COMMIT; -- cada lote en su transacción
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE api.sp_purgar_auditoria(INTEGER, BIGINT) IS
    'Borra la auditoría más antigua que p_conservar_dias, de a 5.000 filas. Programar con pg_cron (ver sección 5).';


/* ============================================================================
   2. ÍNDICES QUE SOBRAN
   Llaves hacia catálogos que nunca se borran, en tablas que crecen. Se
   conservan los que sí usan las consultas (unidad + fecha, cliente,
   producto, plato, menú, historial).
   ============================================================================ */
DROP INDEX IF EXISTS core.ix_pedidos_estado;
DROP INDEX IF EXISTS core.ix_pedidos_estado_pago;
DROP INDEX IF EXISTS core.ix_pedidos_metodo;
DROP INDEX IF EXISTS core.ix_pedidos_tipo;
DROP INDEX IF EXISTS core.ix_pedidos_mesa;
DROP INDEX IF EXISTS core.ix_pedidos_zona;
DROP INDEX IF EXISTS core.ix_gastos_estado;
DROP INDEX IF EXISTS core.ix_gastos_metodo;
DROP INDEX IF EXISTS core.ix_gastos_categoria;
DROP INDEX IF EXISTS core.ix_entradas_tipo;
DROP INDEX IF EXISTS core.ix_cierres_estado;
DROP INDEX IF EXISTS core.ix_cierres_area;
DROP INDEX IF EXISTS core.ix_menus_dia_tipo;
DROP INDEX IF EXISTS core.ix_bases_caja_unidad_fecha;   -- lo cubre uq_bases_caja_vigente
DROP INDEX IF EXISTS core.ix_pedidos_empresa_fecha;     -- lo cubren uq_pedidos_codigo + ix_pedidos_unidad_fecha

-- El filtro de rest.pedidos: empresa + jornada
CREATE INDEX IF NOT EXISTS ix_pedidos_empresa_jornada ON core.pedidos (empresa_id, fecha_operativa);


/* ============================================================================
   3. TABLAS QUE SE ACTUALIZAN MUCHO: espacio para actualizaciones HOT
   ============================================================================ */
ALTER TABLE core.pedidos            SET (fillfactor = 85);
ALTER TABLE core.consecutivos       SET (fillfactor = 50);
ALTER TABLE core.insumo_unidades    SET (fillfactor = 80);
ALTER TABLE core.cierres_inventario SET (fillfactor = 85);
ALTER TABLE core.gastos             SET (fillfactor = 90);
ALTER TABLE core.pedido_historial   SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.05);


/* ============================================================================
   4. VISTAS MÁS BARATAS
   ============================================================================ */

-- Vendidos calculados UNA vez por plato (antes: tres llamadas por fila)
CREATE OR REPLACE VIEW api.v_platos_dia AS
SELECT pd.id AS plato_dia_id, pd.menu_dia_id, m.unidad_id, m.fecha,
       pd.nombre, pd.descripcion, pd.emoji, pd.precio, pd.cupos, pd.disponible, pd.orden,
       v.vendidos,
       CASE WHEN pd.cupos IS NULL THEN NULL ELSE GREATEST(pd.cupos - v.vendidos, 0) END AS cupos_restantes,
       (pd.disponible AND m.disponible AND (pd.cupos IS NULL OR v.vendidos < pd.cupos)) AS se_puede_pedir
  FROM core.platos_dia pd
  JOIN core.menus_dia m ON m.id = pd.menu_dia_id
  CROSS JOIN LATERAL (SELECT core.fn_vendidos_plato(pd.id) AS vendidos) v;

/* Sesión y unidades permitidas resueltas una sola vez; el JSON se arma
   después de filtrar. Con ?actualizado_en=gt.… sólo viajan los cambios. */
CREATE OR REPLACE VIEW rest.pedidos AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
),
unidades AS MATERIALIZED (
    SELECT u.id
      FROM core.unidades u, sesion s
     WHERE u.empresa_id = s.empresa_id
       AND core.fn_usuario_en_unidad(s.usuario_id, u.id)
)
SELECT p.id AS pedido_id, p.empresa_id, p.unidad_id, p.codigo, e.codigo AS estado, p.fecha_operativa,
       p.actualizado_en, core.fn_pedido_json(p.id) AS pedido
  FROM core.pedidos p
  JOIN sesion s             ON s.empresa_id = p.empresa_id
  JOIN unidades un          ON un.id = p.unidad_id
  JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
 WHERE p.fecha_operativa >= core.fn_fecha_operativa(p.empresa_id, now()) - 31;


/* ============================================================================
   5. PERMISOS Y MANTENIMIENTO
   ============================================================================ */
REVOKE ALL ON PROCEDURE api.sp_purgar_auditoria(INTEGER, BIGINT) FROM PUBLIC, taseca_app;
GRANT SELECT ON api.v_auditoria, api.v_auditoria_detalle TO taseca_lectura;
GRANT SELECT ON rest.pedidos TO taseca_app;
GRANT SELECT ON api.v_platos_dia TO taseca_app, taseca_lectura;

/* En Supabase (Database → Extensions → pg_cron), programa el mantenimiento:

   SELECT cron.schedule('purgar-auditoria', '30 3 * * *',
                        $$CALL api.sp_purgar_auditoria(365)$$);
   SELECT cron.schedule('reportes-mensuales', '0 4 * * *',
                        $$CALL api.sp_refrescar_reportes()$$);
*/

ANALYZE core.auditoria;
ANALYZE core.pedidos;
NOTIFY pgrst, 'reload schema';
