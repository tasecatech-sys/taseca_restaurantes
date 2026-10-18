/* ============================================================================
   TASECA · 26 · AL ANULAR, QUÉ VUELVE Y QUÉ SE PIERDE
   ----------------------------------------------------------------------------
   Hasta ahora, anular una factura devolvía TODO al inventario. Pero no todo
   vuelve: si al cliente se le cayó el plato, o lo devolvió mordido, esa
   mercancía se perdió y el inventario tiene que saberlo.

   Ahora, al anular se elige plato por plato: vuelve al stock, o se da de
   baja. La decisión es por PLATO -lo que se vendió- y no por ingrediente:
   quien anula ve «1× Hamburguesa» y decide; la receta se encarga del resto.

   CÓMO SE REGISTRA LA BAJA
     Sin inventar movimientos de inventario: lo dado de baja simplemente
     SIGUE CONTANDO como consumido. Es la misma regla que ya existía para
     las jornadas cerradas, y es exacta: si el producto se perdió, se gastó.
     Queda constancia en core.anulacion_items y en el historial de la
     factura, con el nombre y la cantidad de cada cosa.

   POR QUÉ UNA TABLA Y NO UNA MARCA EN EL ÍTEM
     Los productos de una factura son inmutables en cuanto sale de «nuevo»,
     y media auditoría se apoya en eso. La baja no es un cambio del ítem: es
     un dato de la ANULACIÓN, y ahí es donde vive.

   Lo que ya está anulado no cambia: sin lista, se devuelve todo, igual que
   antes. Se puede ejecutar más de una vez.
   Requiere: 00 … 25 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

CREATE TABLE IF NOT EXISTS core.anulacion_items (
    id              BIGSERIAL PRIMARY KEY,
    anulacion_id    BIGINT NOT NULL REFERENCES core.anulaciones (id)   ON DELETE CASCADE,
    pedido_item_id  BIGINT NOT NULL REFERENCES core.pedido_items (id)  ON DELETE CASCADE,
    CONSTRAINT uq_anulacion_items UNIQUE (anulacion_id, pedido_item_id)
);
COMMENT ON TABLE core.anulacion_items IS
    'Qué productos de una factura anulada NO vuelven al inventario: se dieron de baja.';

ALTER TABLE core.anulacion_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON core.anulacion_items FROM PUBLIC;

CREATE INDEX IF NOT EXISTS ix_anulacion_items_pedido_item
    ON core.anulacion_items (pedido_item_id);

/* ¿Este producto de la factura se dio de baja? Se consulta desde el cálculo
   de lo vendido, que corre con los permisos de quien pregunta: por eso es
   SECURITY DEFINER y no una lectura directa de la tabla. */
CREATE OR REPLACE FUNCTION core.fn_item_dado_de_baja(p_pedido_item_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $fn$
    SELECT EXISTS (SELECT 1 FROM core.anulacion_items WHERE pedido_item_id = p_pedido_item_id);
$fn$;


/* ============================================================================
   2. ANULAR, ELIGIENDO QUÉ VUELVE
   ============================================================================ */

DROP PROCEDURE IF EXISTS api.sp_anular_pedido(BIGINT, VARCHAR, INTEGER);

CREATE OR REPLACE PROCEDURE api.sp_anular_pedido(p_pedido_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER,
                                                 p_items_baja BIGINT[] DEFAULT NULL)
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
    v_anulacion  BIGINT;
    v_baja       BIGINT[] := COALESCE(p_items_baja, '{}');
    v_nombres    TEXT;
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
           AND NOT (i.id = ANY (v_baja))
    ) INTO v_diferido;

    /* El retorno nunca cae en la jornada ya cerrada: si se anula el mismo
       día del cierre, va a la jornada siguiente. */
    v_hoy     := GREATEST(v_hoy, v_pedido.fecha_operativa + 1);
    v_retorno := CASE WHEN v_diferido THEN v_hoy ELSE v_pedido.fecha_operativa END;

    INSERT INTO core.anulaciones (pedido_id, motivo, usuario_id, jornada_original, jornada_retorno)
    VALUES (p_pedido_id, trim(p_motivo), p_usuario_id, v_pedido.fecha_operativa, v_retorno)
    RETURNING id INTO v_anulacion;

    /* Lo que NO vuelve al inventario. Tienen que ser ítems de esta factura:
       marcar el plato de otra sería dar de baja mercancía ajena. */
    IF array_length(v_baja, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM unnest(v_baja) x
                    WHERE x NOT IN (SELECT id FROM core.pedido_items WHERE pedido_id = p_pedido_id)) THEN
            RAISE EXCEPTION 'Sólo se pueden dar de baja productos de esta misma factura.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        INSERT INTO core.anulacion_items (anulacion_id, pedido_item_id)
        SELECT v_anulacion, x FROM unnest(v_baja) x;

        SELECT string_agg(i.cantidad || '× ' || i.nombre, ', ' ORDER BY i.id) INTO v_nombres
          FROM core.pedido_items i WHERE i.id = ANY (v_baja);
    END IF;

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
           AND NOT (i.id = ANY (v_baja))   -- lo dado de baja no vuelve
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
            CASE WHEN v_nombres IS NOT NULL THEN ' · dado de baja: ' || v_nombres ELSE '' END ||
            CASE WHEN v_diferido THEN ' · retorno imputado a la jornada ' || v_retorno ELSE '' END,
            p_usuario_id);
END;
$$;

/* ============================================================================
   3. LO QUE NO VOLVIÓ, SE CONSUMIÓ
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_z_insumo(p_insumo_unidad_id INTEGER, p_desde_excl DATE, p_hasta DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(it.cantidad * pi.cantidad), 0)
      FROM core.insumo_unidades iu
      JOIN core.producto_insumos pi ON pi.insumo_id = iu.insumo_id
      JOIN core.pedido_items it     ON it.producto_id = pi.producto_id
      JOIN core.pedidos p           ON p.id = it.pedido_id AND p.unidad_id = iu.unidad_id
      JOIN core.estados_pedido ep   ON ep.id = p.estado_pedido_id
     WHERE iu.id = p_insumo_unidad_id
       AND p.fecha_operativa >  p_desde_excl
       AND p.fecha_operativa <= p_hasta
       AND (ep.cuenta_como_venta
            /* Una factura anulada deja de contar… salvo que su mercancía NO
               haya vuelto: porque se dio de baja, o porque la jornada ya
               estaba cerrada y volvió como entrada de otro día. En los dos
               casos lo consumido se consumió. */
            OR (ep.codigo = 'anulado'
                AND (core.fn_item_dado_de_baja(it.id)
                     OR EXISTS (SELECT 1 FROM core.entradas_inventario e
                                 WHERE e.pedido_id = p.id AND e.insumo_unidad_id = iu.id))));
$$;

CREATE OR REPLACE VIEW api.v_cruce_inventario AS
WITH base AS (
    SELECT d.id AS cierre_detalle_id, c.id AS cierre_id, c.unidad_id, c.area_id, c.fecha_operativa,
           d.insumo_unidad_id, iu.insumo_id, d.saldo_fisico,
           ant.saldo_fisico    AS saldo_anterior,
           ant.fecha_operativa AS fecha_anterior
      FROM core.cierre_detalles d
      JOIN core.cierres_inventario c ON c.id = d.cierre_id
      JOIN core.insumo_unidades iu   ON iu.id = d.insumo_unidad_id
      LEFT JOIN LATERAL (
            SELECT d2.saldo_fisico, c2.fecha_operativa
              FROM core.cierre_detalles d2
              JOIN core.cierres_inventario c2 ON c2.id = d2.cierre_id
             WHERE d2.insumo_unidad_id = d.insumo_unidad_id
               AND c2.fecha_operativa < c.fecha_operativa
             ORDER BY c2.fecha_operativa DESC
             LIMIT 1
      ) ant ON TRUE
)
SELECT b.cierre_id, b.cierre_detalle_id, b.unidad_id, u.empresa_id, u.nombre AS unidad,
       a.codigo AS area, b.fecha_operativa, b.fecha_anterior,
       i.codigo, i.nombre AS insumo,
       COALESCE(b.saldo_anterior, 0) AS inicial,
       (b.saldo_anterior IS NULL)    AS sin_cierre_anterior,
       x.en                          AS entradas,
       x.z                           AS ventas,
       b.saldo_fisico                AS saldo_fisico,
       COALESCE(b.saldo_anterior, 0) + x.en - x.z                  AS saldo_esperado,
       COALESCE(b.saldo_anterior, 0) + x.en - x.z - b.saldo_fisico AS diferencia
  FROM base b
  JOIN core.unidades u         ON u.id = b.unidad_id
  JOIN core.areas_inventario a ON a.id = b.area_id
  JOIN core.insumos i          ON i.id = b.insumo_id
  /* La misma regla que core.fn_en_insumo y core.fn_z_insumo, escrita aquí
     porque una vista lee las tablas con los permisos de su dueño y una
     función con los de quien consulta (la app no lee core). */
  CROSS JOIN LATERAL (
        SELECT (SELECT COALESCE(SUM(e.cantidad), 0)
                  FROM core.entradas_inventario e
                 WHERE e.insumo_unidad_id = b.insumo_unidad_id
                   AND e.anulada_en IS NULL
                   AND e.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
                   AND e.fecha_operativa <= b.fecha_operativa) AS en,
               (SELECT COALESCE(SUM(it.cantidad * pi.cantidad), 0)
                  FROM core.producto_insumos pi
                  JOIN core.pedido_items it   ON it.producto_id = pi.producto_id
                  JOIN core.pedidos p         ON p.id = it.pedido_id AND p.unidad_id = b.unidad_id
                  JOIN core.estados_pedido ep ON ep.id = p.estado_pedido_id
                 WHERE pi.insumo_id = b.insumo_id
                   AND p.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
                   AND p.fecha_operativa <= b.fecha_operativa
                   AND (ep.cuenta_como_venta
                        OR (ep.codigo = 'anulado'
                            AND (core.fn_item_dado_de_baja(it.id)
                                 OR EXISTS (SELECT 1 FROM core.entradas_inventario e2
                                             WHERE e2.pedido_id = p.id AND e2.insumo_unidad_id = b.insumo_unidad_id))))) AS z
  ) x;

/* ============================================================================
   4. LA PUERTA DE LA APLICACIÓN
   ============================================================================ */

DROP FUNCTION IF EXISTS rest.anular_pedido(BIGINT, TEXT);

CREATE OR REPLACE FUNCTION rest.anular_pedido(p_pedido_id BIGINT, p_motivo TEXT,
                                              p_items_baja BIGINT[] DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_json JSONB;
BEGIN
    CALL api.sp_anular_pedido(p_pedido_id, p_motivo, core.fn_exigir_sesion(), p_items_baja);
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

GRANT EXECUTE ON FUNCTION rest.anular_pedido(BIGINT, TEXT, BIGINT[]) TO taseca_app;
GRANT EXECUTE ON FUNCTION core.fn_item_dado_de_baja(BIGINT) TO taseca_app, taseca_anon;


/* ============================================================================
   5. REVISIÓN
   ============================================================================ */

DO $$
DECLARE
    v_tabla BOOLEAN;
    v_n     INTEGER;
BEGIN
    SELECT to_regclass('core.anulacion_items') IS NOT NULL INTO v_tabla;
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rest' AND p.proname = 'anular_pedido';

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'Tabla core.anulacion_items ......... %', CASE WHEN v_tabla THEN 'sí' ELSE 'NO' END;
    RAISE NOTICE 'Versiones de rest.anular_pedido .... % (tiene que ser 1)', v_n;
    RAISE NOTICE 'Lo dado de baja sigue contando ..... %',
        CASE WHEN (SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'core' AND p.proname = 'fn_z_insumo')
                  ILIKE '%fn_item_dado_de_baja%' THEN 'sí' ELSE 'NO' END;
    RAISE NOTICE '--------------------------------------------------';

    IF NOT v_tabla THEN
        RAISE EXCEPTION 'La baja por ítem no quedó instalada: revisa el paso 1.';
    END IF;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'Quedaron % versiones de rest.anular_pedido: la API no sabría cuál llamar.', v_n;
    END IF;
END;
$$;
