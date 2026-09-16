/* ============================================================================
   TASECA · 16 · TODOS LOS PAGOS SE CONFIRMAN EN CAJA
   ----------------------------------------------------------------------------
   Antes: al entregar un pedido en efectivo (en la mesa o el domiciliario) el
   pago quedaba confirmado solo, y contaba como dinero cobrado aunque la
   cajera no lo hubiera recibido. Además, un pedido de mesa se toma sin saber
   con qué va a pagar el cliente.

   Ahora:
     · "Entregado" es sólo el estado de la operación (para el cliente, el
       mesero y el domiciliario). El pago queda PENDIENTE.
     · Caja confirma cada pago —mesa o domicilio, cualquier método— y en ese
       momento registra el método real (efectivo, datáfono, transferencia).
     · Un pago confirmado ya no cambia: ni de estado ni de método. Si hubo un
       error, se anula la factura (queda la auditoría).
     · Una factura cancelada o anulada no se cobra.

   Lo que ya estaba confirmado en la base NO se toca.

   Requiere: 00 … 15 instalados. Se puede ejecutar más de una vez.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. TRIGGER: entregar ya no confirma el pago
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_pedidos_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ant       core.estados_pedido;
    v_nuevo     core.estados_pedido;
    v_tipo      VARCHAR;
    v_pago_ant  VARCHAR;
    v_pago_nvo  VARCHAR;
BEGIN
    IF NEW.empresa_id <> OLD.empresa_id OR NEW.unidad_id <> OLD.unidad_id
       OR NEW.codigo <> OLD.codigo OR NEW.fecha_operativa <> OLD.fecha_operativa
       OR NEW.tipo_pedido_id <> OLD.tipo_pedido_id OR NEW.creado_en <> OLD.creado_en THEN
        RAISE EXCEPTION 'La factura % no puede cambiar de empresa, unidad, código, tipo ni jornada.', OLD.codigo;
    END IF;

    SELECT * INTO v_ant   FROM core.estados_pedido WHERE id = OLD.estado_pedido_id;
    SELECT * INTO v_nuevo FROM core.estados_pedido WHERE id = NEW.estado_pedido_id;
    SELECT codigo INTO v_tipo     FROM core.tipos_pedido WHERE id = NEW.tipo_pedido_id;
    SELECT codigo INTO v_pago_ant FROM core.estados_pago WHERE id = OLD.estado_pago_id;
    SELECT codigo INTO v_pago_nvo FROM core.estados_pago WHERE id = NEW.estado_pago_id;

    IF v_ant.codigo IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'La factura % está % y ya no se puede modificar.', OLD.codigo, lower(v_ant.nombre);
    END IF;

    -- Un pago confirmado es definitivo: ni se "desconfirma" ni cambia de método
    IF v_pago_ant = 'confirmado'
       AND (NEW.estado_pago_id <> OLD.estado_pago_id OR NEW.metodo_pago_id <> OLD.metodo_pago_id) THEN
        RAISE EXCEPTION 'El pago de la factura % ya fue confirmado y no se puede cambiar.', OLD.codigo;
    END IF;

    IF NEW.estado_pedido_id <> OLD.estado_pedido_id THEN
        IF v_nuevo.codigo = 'anulado' AND NOT EXISTS (SELECT 1 FROM core.anulaciones WHERE pedido_id = OLD.id) THEN
            RAISE EXCEPTION 'Una factura sólo se anula con api.sp_anular_pedido (motivo y retorno de inventario).';
        END IF;
        IF v_nuevo.solo_domicilio AND v_tipo <> 'domicilio' THEN
            RAISE EXCEPTION 'El estado "%" sólo aplica a domicilios.', v_nuevo.nombre;
        END IF;
        IF v_nuevo.orden < 90 AND v_nuevo.orden <= v_ant.orden THEN
            RAISE EXCEPTION 'El pedido % no puede volver de "%" a "%".', OLD.codigo, v_ant.nombre, v_nuevo.nombre;
        END IF;
        IF v_ant.codigo = 'entregado' AND v_nuevo.codigo <> 'anulado' THEN
            RAISE EXCEPTION 'Un pedido entregado sólo puede anularse.';
        END IF;
        IF v_nuevo.codigo = 'cancelado' AND (NEW.motivo_cancelacion IS NULL OR length(trim(NEW.motivo_cancelacion)) < 3) THEN
            RAISE EXCEPTION 'Para cancelar hay que escribir el motivo.';
        END IF;
        -- (Antes: entregado en efectivo = pago confirmado. Ya no: lo confirma caja.)
    ELSIF v_ant.codigo = 'entregado'
          AND (NEW.cliente_id IS DISTINCT FROM OLD.cliente_id
               OR NEW.direccion_entrega IS DISTINCT FROM OLD.direccion_entrega
               OR NEW.costo_domicilio <> OLD.costo_domicilio
               -- el método sólo lo fija caja al confirmar el cobro
               OR (NEW.metodo_pago_id <> OLD.metodo_pago_id AND v_pago_nvo <> 'confirmado')) THEN
        RAISE EXCEPTION 'La factura % ya fue entregada: sólo caja puede registrar su pago.', OLD.codigo;
    END IF;

    RETURN NEW;
END;
$$;


/* ============================================================================
   2. HISTORIAL: el cambio de método queda escrito
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_pedidos_historial()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.estado_pedido_id <> OLD.estado_pedido_id THEN
        INSERT INTO core.pedido_historial (pedido_id, estado_pedido_id, descripcion, usuario_id)
        SELECT NEW.id, NEW.estado_pedido_id,
               'Estado: ' || e.nombre ||
               CASE WHEN e.codigo = 'cancelado' THEN ' · ' || NEW.motivo_cancelacion ELSE '' END,
               core.fn_usuario_actual()
          FROM core.estados_pedido e WHERE e.id = NEW.estado_pedido_id;
    END IF;
    IF NEW.metodo_pago_id <> OLD.metodo_pago_id THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        SELECT NEW.id, 'Método de pago: ' || a.nombre || ' → ' || n.nombre, core.fn_usuario_actual()
          FROM core.metodos_pago a, core.metodos_pago n
         WHERE a.id = OLD.metodo_pago_id AND n.id = NEW.metodo_pago_id;
    END IF;
    IF NEW.estado_pago_id <> OLD.estado_pago_id THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        SELECT NEW.id, 'Pago: ' || p.nombre, core.fn_usuario_actual()
          FROM core.estados_pago p WHERE p.id = NEW.estado_pago_id;
    END IF;
    RETURN NEW;
END;
$$;


/* ============================================================================
   3. PROCEDIMIENTO: caja confirma (con el método real) o rechaza
   ============================================================================ */

DROP PROCEDURE IF EXISTS api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR);

CREATE OR REPLACE PROCEDURE api.sp_actualizar_pago(
    p_pedido_id    BIGINT,
    p_estado_pago  VARCHAR,
    p_usuario_id   INTEGER,
    p_nota         VARCHAR DEFAULT NULL,
    p_metodo_pago  VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa  INTEGER;
    v_estado   VARCHAR;
    v_pago     VARCHAR;
    v_codigo   VARCHAR;
    v_metodo   INTEGER;
BEGIN
    SELECT p.empresa_id, e.codigo, ep.codigo, p.codigo, p.metodo_pago_id
      INTO v_empresa, v_estado, v_pago, v_codigo, v_metodo
      FROM core.pedidos p
      JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
      JOIN core.estados_pago ep  ON ep.id = p.estado_pago_id
     WHERE p.id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pagos',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));

    IF p_estado_pago NOT IN ('confirmado', 'rechazado') THEN
        RAISE EXCEPTION 'Caja sólo confirma o rechaza pagos.';
    END IF;
    IF v_estado IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'La factura % está %: no hay pago que registrar.', v_codigo, v_estado;
    END IF;
    IF v_pago = 'confirmado' THEN
        RAISE EXCEPTION 'El pago de la factura % ya fue confirmado.', v_codigo;
    END IF;

    IF NULLIF(trim(p_metodo_pago), '') IS NOT NULL THEN
        IF p_estado_pago <> 'confirmado' THEN
            RAISE EXCEPTION 'El método de pago se registra al confirmar el cobro.';
        END IF;
        v_metodo := core.fn_id_catalogo('metodos_pago', trim(p_metodo_pago));
        IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago
                        WHERE empresa_id = v_empresa AND metodo_pago_id = v_metodo AND activo) THEN
            RAISE EXCEPTION 'El método de pago "%" no está disponible.', p_metodo_pago;
        END IF;
    END IF;

    UPDATE core.pedidos
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', p_estado_pago),
           metodo_pago_id = v_metodo
     WHERE id = p_pedido_id;

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
   4. API REST
   ============================================================================ */

DROP FUNCTION IF EXISTS rest.confirmar_pago(BIGINT, TEXT);

CREATE OR REPLACE FUNCTION rest.confirmar_pago(p_pedido_id BIGINT, p_referencia TEXT DEFAULT NULL, p_metodo TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_actualizar_pago(p_pedido_id, 'confirmado', core.fn_exigir_sesion(), p_referencia, p_metodo);
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


/* ============================================================================
   5. PERMISOS
   ============================================================================ */

REVOKE ALL ON PROCEDURE api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_actualizar_pago(BIGINT, VARCHAR, INTEGER, VARCHAR, VARCHAR) TO taseca_app;

REVOKE ALL ON FUNCTION rest.confirmar_pago(BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.confirmar_pago(BIGINT, TEXT, TEXT) TO taseca_app;

NOTIFY pgrst, 'reload schema';
