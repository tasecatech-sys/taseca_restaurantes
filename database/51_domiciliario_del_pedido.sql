/* ============================================================================
   51 · QUÉ DOMICILIARIO LLEVÓ CADA PEDIDO (para cobrarle el efectivo)

   Lo que pidió el cliente: saber qué domiciliario llevó cada domicilio, para
   cobrarle a él en caja el efectivo que recibió en la calle.

   CÓMO QUEDA ASIGNADO
     · Solo: cuando un usuario con rol DOMICILIARIO pasa el domicilio a
       «En camino» («🛵 Salgo con este pedido»), el pedido queda a su nombre.
       Lo hace un trigger, así que da igual por qué procedimiento cambie el
       estado (avanzar o cambiar).
     · A mano: caja (permiso «pagos») asigna o cambia el domiciliario con
       rest.asignar_domiciliario —para el que no usa el celular, o si salió
       otro—. Un pago ya cobrado no cambia de domiciliario: ese dinero ya se
       le cobró a alguien.
   Todo queda en el historial del pedido.

   QUIÉN ES DOMICILIARIO
     Un usuario activo de la empresa con rol «domiciliario» que trabaje en la
     sede del pedido. rest.domiciliarios los lista (sin datos de acceso) para
     caja, aunque caja no tenga permiso de ver usuarios.

   EL COBRO
     No hay dinero nuevo: el panel agrupa por domiciliario lo que falta cobrar
     y lo cobra con rest.confirmar_pagos (la 37), por la puerta de siempre.

   Idempotente. Requiere: 09 (fn_pedido_json) y 16 (pagos en caja).
   ============================================================================ */

SET search_path = core, public;

ALTER TABLE core.pedidos ADD COLUMN IF NOT EXISTS domiciliario_id INTEGER REFERENCES core.usuarios (id) ON DELETE RESTRICT;
ALTER TABLE core.pedidos ADD COLUMN IF NOT EXISTS domiciliario_asignado_en TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS ix_pedidos_domiciliario ON core.pedidos (domiciliario_id, fecha_operativa) WHERE domiciliario_id IS NOT NULL;
COMMENT ON COLUMN core.pedidos.domiciliario_id IS 'Quién llevó el domicilio: a él se le cobra en caja el efectivo que recibió.';

/* ¿Es domiciliario de esa empresa y trabaja en esa sede? */
CREATE OR REPLACE FUNCTION core.fn_es_domiciliario(p_usuario_id INTEGER, p_unidad_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SET search_path = core, public
AS $$
    SELECT EXISTS (SELECT 1 FROM core.usuarios u
                     JOIN core.roles r    ON r.id = u.rol_id
                     JOIN core.unidades un ON un.id = p_unidad_id
                    WHERE u.id = p_usuario_id AND u.activo AND r.codigo = 'domiciliario'
                      AND u.empresa_id = un.empresa_id
                      AND core.fn_usuario_en_unidad(u.id, p_unidad_id));
$$;


/* ============================================================================
   1. EL TRIGGER: se asigna solo al salir, y nunca a alguien de otra empresa
   ============================================================================ */
CREATE OR REPLACE FUNCTION core.tg_pedidos_domiciliario()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
DECLARE
    v_usr    INTEGER;
    v_nombre VARCHAR;
BEGIN
    -- Red de seguridad: un domiciliario de otra empresa o que no es domiciliario, nunca
    IF NEW.domiciliario_id IS DISTINCT FROM OLD.domiciliario_id AND NEW.domiciliario_id IS NOT NULL
       AND NOT core.fn_es_domiciliario(NEW.domiciliario_id, NEW.unidad_id) THEN
        RAISE EXCEPTION 'Ese usuario no es domiciliario activo de esta sede.';
    END IF;

    -- Sale a la calle: si lo saca un domiciliario y nadie lo tenía, queda a su nombre
    IF NEW.estado_pedido_id IS DISTINCT FROM OLD.estado_pedido_id
       AND NEW.estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'camino')
       AND NEW.domiciliario_id IS NULL THEN
        v_usr := NULLIF(core.fn_jwt_claims() ->> 'usuario_id', '')::INTEGER;
        IF v_usr IS NOT NULL AND core.fn_es_domiciliario(v_usr, NEW.unidad_id) THEN
            NEW.domiciliario_id := v_usr;
            NEW.domiciliario_asignado_en := now();
            SELECT nombre INTO v_nombre FROM core.usuarios WHERE id = v_usr;
            INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
            VALUES (NEW.id, 'Lo lleva: ' || v_nombre, v_usr);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pedidos_domiciliario ON core.pedidos;
CREATE TRIGGER trg_pedidos_domiciliario
    BEFORE UPDATE ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_domiciliario();


/* ============================================================================
   2. ASIGNAR O CAMBIAR A MANO (caja)

   POST /rpc/asignar_domiciliario { p_pedido_id, p_domiciliario_id }
   p_domiciliario_id NULL = quitarlo.
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.asignar_domiciliario(p_pedido_id BIGINT, p_domiciliario_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_p       RECORD;
    v_antes   VARCHAR;
    v_nuevo   VARCHAR;
BEGIN
    SELECT p.id, p.codigo, p.unidad_id, p.empresa_id, p.domiciliario_id, tp.codigo AS tipo,
           ep.codigo AS estado, pg.codigo AS pago
      INTO v_p
      FROM core.pedidos p
      JOIN core.tipos_pedido tp   ON tp.id = p.tipo_pedido_id
      JOIN core.estados_pedido ep ON ep.id = p.estado_pedido_id
      JOIN core.estados_pago pg   ON pg.id = p.estado_pago_id
     WHERE p.id = p_pedido_id AND p.empresa_id = core.fn_jwt_empresa();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el pedido.';
    END IF;

    PERFORM core.fn_preparar_operacion(v_usuario, 'pagos', v_p.unidad_id);

    IF v_p.tipo <> 'domicilio' THEN
        RAISE EXCEPTION 'La factura % no es un domicilio.', v_p.codigo;
    END IF;
    IF v_p.estado IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'La factura % está %: ya no se asigna.', v_p.codigo, v_p.estado;
    END IF;
    IF v_p.pago = 'confirmado' THEN
        RAISE EXCEPTION 'El pago de la factura % ya se cobró: no cambia de domiciliario.', v_p.codigo;
    END IF;
    IF p_domiciliario_id IS NOT DISTINCT FROM v_p.domiciliario_id THEN
        RETURN core.fn_pedido_json(p_pedido_id);  -- nada que cambiar
    END IF;
    IF p_domiciliario_id IS NOT NULL AND NOT core.fn_es_domiciliario(p_domiciliario_id, v_p.unidad_id) THEN
        RAISE EXCEPTION 'Ese usuario no es domiciliario activo de esta sede.';
    END IF;

    SELECT nombre INTO v_antes FROM core.usuarios WHERE id = v_p.domiciliario_id;
    SELECT nombre INTO v_nuevo FROM core.usuarios WHERE id = p_domiciliario_id;

    UPDATE core.pedidos
       SET domiciliario_id = p_domiciliario_id,
           domiciliario_asignado_en = CASE WHEN p_domiciliario_id IS NULL THEN NULL ELSE now() END
     WHERE id = p_pedido_id;

    INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
    VALUES (p_pedido_id,
            CASE WHEN v_nuevo IS NULL THEN 'Domiciliario quitado (era ' || v_antes || ')'
                 WHEN v_antes IS NULL THEN 'Domiciliario: ' || v_nuevo
                 ELSE 'Domiciliario: ' || v_antes || ' → ' || v_nuevo END,
            v_usuario);

    RETURN core.fn_pedido_json(p_pedido_id);
END;
$$;
GRANT EXECUTE ON FUNCTION rest.asignar_domiciliario(BIGINT, INTEGER) TO taseca_app;


/* ============================================================================
   3. LA LISTA DE DOMICILIARIOS (sólo nombre y sedes, sin datos de acceso)
   ============================================================================ */
CREATE OR REPLACE VIEW rest.domiciliarios AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT u.id AS usuario_id, u.empresa_id, u.nombre,
       COALESCE((SELECT jsonb_agg(uu.unidad_id ORDER BY uu.unidad_id)
                   FROM core.usuario_unidades uu WHERE uu.usuario_id = u.id), '[]'::JSONB) AS unidades
  FROM core.usuarios u
  JOIN core.roles r ON r.id = u.rol_id
  JOIN sesion s ON s.empresa_id = u.empresa_id
 WHERE u.activo AND r.codigo = 'domiciliario'
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['pagos', 'pedidos_gestionar', 'pedidos_domicilio']) x(p)
                WHERE api.fn_tiene_permiso(s.usuario_id, x.p::VARCHAR));
GRANT SELECT ON rest.domiciliarios TO taseca_app;


/* ============================================================================
   4. EL PEDIDO COMO LO VE EL PANEL: + domiciliario
   (la misma fn_pedido_json de la 09, con dos claves más al final)
   ============================================================================ */
CREATE OR REPLACE FUNCTION core.fn_pedido_json(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
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
                               FROM core.anulaciones a WHERE a.pedido_id = vp.pedido_id),
               'domiciliario_id', p.domiciliario_id,
               'domiciliario', (SELECT u.nombre FROM core.usuarios u WHERE u.id = p.domiciliario_id)
           )
      FROM api.v_pedidos vp
      JOIN core.pedidos p  ON p.id = vp.pedido_id
      JOIN core.empresas e ON e.id = vp.empresa_id
     WHERE vp.pedido_id = p_pedido_id;
$$;
