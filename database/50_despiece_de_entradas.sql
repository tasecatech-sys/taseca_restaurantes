/* ============================================================================
   50 · DESPIECES: UNA ENTRADA QUE LLENA VARIOS INSUMOS

   Lo que pidió el cliente (un asadero): comprar un POLLO ENTERO y que el
   inventario de PRESAS se llene solo —2 pechugas, 2 alas, 2 piernas, 2 muslos—,
   o comprar PIERNA PERNIL y que llene pierna y muslo.

   EL MODELO
     · core.despieces              lo que se COMPRA (Pollo entero, Pierna pernil).
                                   No tiene stock propio: no se cuenta en el
                                   cierre, se reparte.
     · core.despiece_componentes   en qué insumos se reparte y cuántos por unidad.
     · Cada negocio arma los suyos desde el panel (Inventario → Entradas →
       Despieces). Ninguno viene escrito en el código.

   LA ENTRADA
     rest.registrar_entrada_despiece crea UNA entrada normal por componente
     (10 pollos → +20 pechuga, +20 ala, …) por la puerta de siempre
     (api.sp_registrar_entrada: permisos, unidad, tipo), y las ata con un
     mismo `lote_despiece`. Así el stock, el cruce (EN) y los cierres no
     cambian en nada: ven entradas como cualquier otra.

   EL LOTE SE MUEVE ENTERO
     · Eliminar una entrada del lote elimina el lote completo (todo o nada:
       si un cierre revisado congela una, no se elimina ninguna).
     · Una entrada de lote no se corrige suelta: se elimina el despiece y se
       registra de nuevo. Corregir una sola presa descuadraría el despiece.

   Idempotente. Requiere: 13 (entradas anulables) y 28 (rest.stock).
   ============================================================================ */

SET search_path = core, public;

/* ============================================================================
   1. MODELO
   ============================================================================ */

CREATE TABLE IF NOT EXISTS core.despieces (
    id              SERIAL PRIMARY KEY,
    empresa_id      INTEGER      NOT NULL REFERENCES core.empresas (id) ON DELETE RESTRICT,
    nombre          VARCHAR(80)  NOT NULL CHECK (length(trim(nombre)) >= 2),
    activo          BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actualizado_en  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_despieces_nombre ON core.despieces (empresa_id, lower(nombre));
COMMENT ON TABLE core.despieces IS
    'Lo que se compra y se reparte en varios insumos (Pollo entero → presas). No tiene stock propio.';

CREATE TABLE IF NOT EXISTS core.despiece_componentes (
    id           SERIAL PRIMARY KEY,
    despiece_id  INTEGER       NOT NULL REFERENCES core.despieces (id) ON DELETE CASCADE,
    insumo_id    INTEGER       NOT NULL REFERENCES core.insumos (id)   ON DELETE RESTRICT,
    cantidad     NUMERIC(12,2) NOT NULL CHECK (cantidad > 0 AND cantidad = trunc(cantidad)),
    CONSTRAINT uq_despiece_componentes UNIQUE (despiece_id, insumo_id)
);
COMMENT ON COLUMN core.despiece_componentes.cantidad IS 'Cuántos de ese insumo salen de UNA unidad del despiece (entero).';

ALTER TABLE core.despieces            ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.despiece_componentes ENABLE ROW LEVEL SECURITY;

CREATE SEQUENCE IF NOT EXISTS core.seq_lote_despiece;
ALTER TABLE core.entradas_inventario ADD COLUMN IF NOT EXISTS despiece_id   INTEGER REFERENCES core.despieces (id) ON DELETE RESTRICT;
ALTER TABLE core.entradas_inventario ADD COLUMN IF NOT EXISTS lote_despiece BIGINT;
CREATE INDEX IF NOT EXISTS ix_entradas_lote_despiece ON core.entradas_inventario (lote_despiece) WHERE lote_despiece IS NOT NULL;
COMMENT ON COLUMN core.entradas_inventario.lote_despiece IS
    'Las entradas que salieron de UNA misma entrada por despiece. Se eliminan juntas.';

/* Una entrada sigue sin editarse. Además de anularla UNA vez (la 13), ahora
   se permite SELLARLA con su despiece UNA vez, justo al nacer: sólo pasan
   despiece_id y lote_despiece de vacíos a llenos, y nada más cambia. Al
   anular, el sello tampoco puede cambiar. */
CREATE OR REPLACE FUNCTION core.tg_entradas_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    IF current_setting('taseca.borrado_pruebas', TRUE) = 'si' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    IF TG_OP = 'UPDATE'
       AND (NEW.insumo_unidad_id, NEW.tipo_entrada_id, NEW.fecha_operativa, NEW.cantidad, NEW.pedido_id, NEW.usuario_id, NEW.creado_en)
           IS NOT DISTINCT FROM
           (OLD.insumo_unidad_id, OLD.tipo_entrada_id, OLD.fecha_operativa, OLD.cantidad, OLD.pedido_id, OLD.usuario_id, OLD.creado_en)
       AND NEW.observacion IS NOT DISTINCT FROM OLD.observacion THEN
        -- Anular (la 13): el sello del despiece no se toca
        IF OLD.anulada_en IS NULL AND NEW.anulada_en IS NOT NULL
           AND (NEW.despiece_id, NEW.lote_despiece) IS NOT DISTINCT FROM (OLD.despiece_id, OLD.lote_despiece) THEN
            RETURN NEW;
        END IF;
        -- Sellar con el despiece (la 50): una vez, en una entrada viva
        IF OLD.anulada_en IS NULL AND NEW.anulada_en IS NULL
           AND OLD.lote_despiece IS NULL AND OLD.despiece_id IS NULL
           AND NEW.lote_despiece IS NOT NULL AND NEW.despiece_id IS NOT NULL
           AND (NEW.anulada_por_id, NEW.motivo_anulacion) IS NOT DISTINCT FROM (OLD.anulada_por_id, OLD.motivo_anulacion) THEN
            RETURN NEW;
        END IF;
    END IF;
    RAISE EXCEPTION 'Los registros de entradas_inventario no se modifican ni se borran: se anulan y se registra la correcta.';
END;
$$;


/* ============================================================================
   2. LECTURA
   ============================================================================ */

/* Los despieces de la empresa de la sesión, con sus componentes. */
CREATE OR REPLACE VIEW rest.despieces AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT d.id AS despiece_id, d.empresa_id, d.nombre, d.activo, d.actualizado_en,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('insumo_id', i.id, 'codigo', i.codigo, 'nombre', i.nombre,
                                                     'area', a.codigo, 'cantidad', dc.cantidad)
                                  ORDER BY i.nombre)
                   FROM core.despiece_componentes dc
                   JOIN core.insumos i ON i.id = dc.insumo_id
                   JOIN core.areas_inventario a ON a.id = i.area_id
                  WHERE dc.despiece_id = d.id), '[]'::JSONB) AS componentes
  FROM core.despieces d
  JOIN sesion s ON s.empresa_id = d.empresa_id
 WHERE EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'entradas', 'cierres']) p(p)
                WHERE api.fn_tiene_permiso(s.usuario_id, p.p::VARCHAR));

/* rest.entradas con el despiece del que salió (columnas nuevas AL FINAL). */
CREATE OR REPLACE VIEW rest.entradas AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT e.id AS entrada_id, i.empresa_id, iu.unidad_id, i.codigo, i.nombre, a.codigo AS area,
       e.cantidad, te.codigo AS tipo, e.observacion, e.fecha_operativa, e.usuario_id,
       us.nombre AS registrada_por, e.creado_en, p.codigo AS factura,
       e.lote_despiece, d.nombre AS despiece
  FROM core.entradas_inventario e
  JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
  JOIN core.insumos i ON i.id = iu.insumo_id
  JOIN sesion s ON s.empresa_id = i.empresa_id
  JOIN core.areas_inventario a ON a.id = i.area_id
  JOIN core.tipos_entrada te ON te.id = e.tipo_entrada_id
  LEFT JOIN core.usuarios us ON us.id = e.usuario_id
  LEFT JOIN core.pedidos p ON p.id = e.pedido_id
  LEFT JOIN core.despieces d ON d.id = e.despiece_id
 WHERE e.anulada_en IS NULL
   AND e.fecha_operativa >= (core.fn_fecha_operativa(i.empresa_id, now()) - 62)
   AND core.fn_usuario_en_unidad(s.usuario_id, iu.unidad_id)
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'entradas', 'cierres']) p2(p2)
                WHERE api.fn_tiene_permiso(s.usuario_id, p2.p2::VARCHAR));

/* La marca del inventario también cambia al tocar un despiece. */
CREATE OR REPLACE VIEW rest.inventario_marca AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_empresa() AS empresa_id
)
SELECT s.empresa_id,
       GREATEST(
           (SELECT max(i.actualizado_en) FROM core.insumos i WHERE i.empresa_id = s.empresa_id),
           (SELECT max(iu.actualizado_en) FROM core.insumo_unidades iu JOIN core.unidades u ON u.id = iu.unidad_id
             WHERE u.empresa_id = s.empresa_id),
           (SELECT max(c.actualizado_en) FROM core.cierres_inventario c JOIN core.unidades u ON u.id = c.unidad_id
             WHERE u.empresa_id = s.empresa_id),
           (SELECT max(GREATEST(e.creado_en, COALESCE(e.anulada_en, e.creado_en)))
              FROM core.entradas_inventario e JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
              JOIN core.unidades u ON u.id = iu.unidad_id
             WHERE u.empresa_id = s.empresa_id),
           (SELECT max(d.actualizado_en) FROM core.despieces d WHERE d.empresa_id = s.empresa_id)
       ) AS marca
  FROM sesion s
 WHERE s.empresa_id IS NOT NULL;

GRANT SELECT ON rest.despieces, rest.entradas, rest.inventario_marca TO taseca_app;


/* ============================================================================
   3. GUARDAR Y BORRAR UN DESPIECE (permiso «stock», como los insumos)

   POST /rpc/guardar_despiece { "p_despiece": { despiece_id?, nombre, activo,
        componentes: [{ codigo, cantidad }] } }
   Los componentes se REEMPLAZAN por los que lleguen.
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.guardar_despiece(p_despiece JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_id      INTEGER := NULLIF(p_despiece ->> 'despiece_id', '')::INTEGER;
    v_nombre  TEXT    := trim(COALESCE(p_despiece ->> 'nombre', ''));
    c         JSONB;
    v_insumo  INTEGER;
    v_cant    NUMERIC;
    v_vistos  INTEGER[] := '{}';
BEGIN
    PERFORM core.fn_preparar_operacion(v_usuario, 'stock');
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El despiece necesita un nombre (por ejemplo «Pollo entero»).';
    END IF;
    IF jsonb_typeof(p_despiece -> 'componentes') IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_despiece -> 'componentes') = 0 THEN
        RAISE EXCEPTION 'Di en qué productos de inventario se reparte «%».', v_nombre;
    END IF;
    IF v_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.despieces WHERE id = v_id AND empresa_id = v_empresa) THEN
        RAISE EXCEPTION 'Ese despiece ya no existe. Recarga la página.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.despieces WHERE empresa_id = v_empresa AND lower(nombre) = lower(v_nombre)
                                             AND id IS DISTINCT FROM v_id) THEN
        RAISE EXCEPTION 'Ya hay un despiece llamado «%».', v_nombre;
    END IF;

    IF v_id IS NULL THEN
        INSERT INTO core.despieces (empresa_id, nombre, activo)
        VALUES (v_empresa, v_nombre, COALESCE((p_despiece ->> 'activo')::BOOLEAN, TRUE))
        RETURNING id INTO v_id;
    ELSE
        UPDATE core.despieces
           SET nombre = v_nombre, activo = COALESCE((p_despiece ->> 'activo')::BOOLEAN, activo), actualizado_en = now()
         WHERE id = v_id;
        DELETE FROM core.despiece_componentes WHERE despiece_id = v_id;
    END IF;

    FOR c IN SELECT * FROM jsonb_array_elements(p_despiece -> 'componentes') LOOP
        SELECT id INTO v_insumo FROM core.insumos
         WHERE empresa_id = v_empresa AND codigo = upper(trim(c ->> 'codigo'));
        IF v_insumo IS NULL THEN
            RAISE EXCEPTION 'El producto de inventario «%» no existe.', c ->> 'codigo';
        END IF;
        IF v_insumo = ANY (v_vistos) THEN
            RAISE EXCEPTION 'El producto «%» está dos veces en el despiece.', c ->> 'codigo';
        END IF;
        v_vistos := v_vistos || v_insumo;
        v_cant := NULLIF(c ->> 'cantidad', '')::NUMERIC;
        PERFORM core.fn_cantidad_entera(v_cant, 'La cantidad de cada presa', FALSE);
        INSERT INTO core.despiece_componentes (despiece_id, insumo_id, cantidad) VALUES (v_id, v_insumo, v_cant);
    END LOOP;

    RETURN (SELECT to_jsonb(d) FROM rest.despieces d WHERE d.despiece_id = v_id);
END;
$$;

/* Un despiece con entradas no se borra: se apaga (las entradas lo nombran). */
CREATE OR REPLACE FUNCTION rest.borrar_despiece(p_despiece_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    PERFORM core.fn_preparar_operacion(v_usuario, 'stock');
    IF NOT EXISTS (SELECT 1 FROM core.despieces WHERE id = p_despiece_id AND empresa_id = core.fn_jwt_empresa()) THEN
        RAISE EXCEPTION 'Ese despiece ya no existe. Recarga la página.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.entradas_inventario WHERE despiece_id = p_despiece_id) THEN
        UPDATE core.despieces SET activo = FALSE, actualizado_en = now() WHERE id = p_despiece_id;
        RETURN jsonb_build_object('despiece_id', p_despiece_id, 'desactivado', TRUE);
    END IF;
    DELETE FROM core.despieces WHERE id = p_despiece_id;
    RETURN jsonb_build_object('despiece_id', p_despiece_id, 'borrado', TRUE);
END;
$$;


/* ============================================================================
   4. LA ENTRADA POR DESPIECE

   POST /rpc/registrar_entrada_despiece { "p_entrada": { unidad_id, despiece_id,
        cantidad, tipo, observacion, fecha } }
   Devuelve las entradas creadas (una por componente).
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.registrar_entrada_despiece(p_entrada JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_unidad   INTEGER := NULLIF(p_entrada ->> 'unidad_id', '')::INTEGER;
    v_desp     core.despieces;
    v_fecha    DATE    := NULLIF(p_entrada ->> 'fecha', '')::DATE;
    v_cant     NUMERIC := NULLIF(p_entrada ->> 'cantidad', '')::NUMERIC;
    v_lote     BIGINT;
    v_obs      TEXT;
    v_id       BIGINT;
    v_ids      BIGINT[] := '{}';
    r          RECORD;
BEGIN
    SELECT * INTO v_desp FROM core.despieces
     WHERE id = NULLIF(p_entrada ->> 'despiece_id', '')::INTEGER AND empresa_id = v_empresa;
    IF v_desp.id IS NULL THEN
        RAISE EXCEPTION 'Ese despiece no existe.';
    END IF;
    IF NOT v_desp.activo THEN
        RAISE EXCEPTION 'El despiece «%» está desactivado.', v_desp.nombre;
    END IF;
    IF v_fecha IS NULL THEN
        RAISE EXCEPTION 'La entrada necesita una fecha válida.';
    END IF;
    IF v_fecha > core.fn_fecha_operativa(v_empresa, now()) THEN
        RAISE EXCEPTION 'La entrada no puede ser de una jornada futura.';
    END IF;
    PERFORM core.fn_cantidad_entera(v_cant, 'La cantidad', FALSE);
    IF NOT EXISTS (SELECT 1 FROM core.despiece_componentes WHERE despiece_id = v_desp.id) THEN
        RAISE EXCEPTION 'El despiece «%» no dice en qué se reparte.', v_desp.nombre;
    END IF;

    v_lote := nextval('core.seq_lote_despiece');
    v_obs  := 'Despiece: ' || trim(to_char(v_cant, 'FM999999999')) || ' × ' || v_desp.nombre
              || COALESCE(' · ' || NULLIF(trim(p_entrada ->> 'observacion'), ''), '');

    FOR r IN SELECT dc.insumo_id, dc.cantidad, i.nombre
               FROM core.despiece_componentes dc JOIN core.insumos i ON i.id = dc.insumo_id
              WHERE dc.despiece_id = v_desp.id ORDER BY i.nombre LOOP
        IF NOT EXISTS (SELECT 1 FROM core.insumo_unidades iu JOIN core.insumos i ON i.id = iu.insumo_id
                        WHERE iu.insumo_id = r.insumo_id AND iu.unidad_id = v_unidad AND i.activo) THEN
            RAISE EXCEPTION '«%» no está activo en esta sede: actívalo en Stock o quítalo del despiece.', r.nombre;
        END IF;
        v_id := NULL;
        CALL api.sp_registrar_entrada(
            p_unidad_id   => v_unidad,
            p_insumo_id   => r.insumo_id,
            p_tipo        => COALESCE(NULLIF(p_entrada ->> 'tipo', ''), 'compra'),
            p_cantidad    => v_cant * r.cantidad,
            p_usuario_id  => v_usuario,
            p_observacion => left(v_obs, 400),
            p_fecha       => v_fecha,
            p_entrada_id  => v_id);
        UPDATE core.entradas_inventario SET despiece_id = v_desp.id, lote_despiece = v_lote WHERE id = v_id;
        v_ids := v_ids || v_id;
    END LOOP;

    RETURN jsonb_build_object(
        'lote_despiece', v_lote,
        'entradas', (SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.nombre), '[]'::JSONB)
                       FROM rest.entradas e WHERE e.entrada_id = ANY (v_ids)));
END;
$$;


/* ============================================================================
   5. ELIMINAR Y CORREGIR: EL LOTE VA ENTERO
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.anular_entrada(p_entrada_id BIGINT, p_motivo TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_lote    BIGINT;
    v_id      BIGINT;
    v_n       INTEGER := 0;
BEGIN
    SELECT e.lote_despiece INTO v_lote
      FROM core.entradas_inventario e
      JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
      JOIN core.insumos i ON i.id = iu.insumo_id
     WHERE e.id = p_entrada_id AND i.empresa_id = core.fn_jwt_empresa();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró la entrada.';
    END IF;

    /* Sin lote: la de siempre. Con lote: todas las vivas del lote (si una no
       se puede, el error deshace las demás). */
    FOR v_id IN SELECT id FROM core.entradas_inventario
                 WHERE (v_lote IS NULL AND id = p_entrada_id)
                    OR (v_lote IS NOT NULL AND lote_despiece = v_lote AND anulada_en IS NULL)
                 ORDER BY id LOOP
        CALL api.sp_anular_entrada(v_id, COALESCE(NULLIF(trim(p_motivo), ''), 'Eliminada desde el panel'), v_usuario);
        v_n := v_n + 1;
    END LOOP;
    RETURN jsonb_build_object('entrada_id', p_entrada_id, 'anulada', TRUE, 'entradas_anuladas', v_n, 'lote_despiece', v_lote);
END;
$$;

CREATE OR REPLACE FUNCTION rest.corregir_entrada(p_entrada_id BIGINT, p_datos JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_actual JSONB;
BEGIN
    SELECT to_jsonb(e) INTO v_actual FROM rest.entradas e WHERE e.entrada_id = p_entrada_id;
    IF v_actual IS NULL THEN
        RAISE EXCEPTION 'No se encontró la entrada (o ya no se puede corregir).';
    END IF;
    IF v_actual ->> 'lote_despiece' IS NOT NULL THEN
        RAISE EXCEPTION 'Esta entrada salió del despiece «%»: elimínala (se va el despiece completo) y regístralo de nuevo.',
              v_actual ->> 'despiece';
    END IF;

    PERFORM rest.anular_entrada(p_entrada_id, 'Corregida desde el panel');
    RETURN rest.registrar_entrada(
        jsonb_build_object('unidad_id', v_actual -> 'unidad_id', 'codigo', v_actual -> 'codigo',
                           'tipo', v_actual -> 'tipo', 'cantidad', v_actual -> 'cantidad',
                           'observacion', v_actual -> 'observacion', 'fecha', v_actual -> 'fecha_operativa')
        || jsonb_strip_nulls(COALESCE(p_datos, '{}')));
END;
$$;

GRANT EXECUTE ON FUNCTION rest.guardar_despiece(JSONB), rest.borrar_despiece(INTEGER),
                          rest.registrar_entrada_despiece(JSONB) TO taseca_app;
