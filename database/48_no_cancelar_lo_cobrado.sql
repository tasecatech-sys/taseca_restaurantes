/* ============================================================================
   48 · UN PEDIDO COBRADO NO SE CANCELA, SE ANULA

   Lo encontró la prueba financiera (48_pruebas_financieras.sql): se cobraban
   $9.000 en efectivo, se cancelaba el pedido y la base lo dejaba. Un pedido
   cancelado no cuenta en ventas NI en anuladas, así que ese dinero salía del
   cruce de caja sin dejar rastro: el cajón sobraba $9.000 que nada explicaba.

   Además saltaba un control: ANULAR es sólo del dueño (permiso
   pedidos_anular), pero CANCELAR lo tiene también el perfil administrador.
   Cancelar un pedido cobrado era anularlo sin permiso y sin que quedara en
   el informe.

   Ahora: si el pago está confirmado, cancelar falla y pide anular. La factura
   anulada sí queda en el cruce, aparte, con su método y su valor.

   Es la MISMA api.sp_cancelar_pedido del 04 (corregida también allí, para las
   instalaciones nuevas, por eso esta no va en el instalador) con un chequeo
   más. Idempotente.
   ============================================================================ */
CREATE OR REPLACE PROCEDURE api.sp_cancelar_pedido(p_pedido_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_cancelar',
            (SELECT unidad_id FROM core.pedidos WHERE id = p_pedido_id));
    IF (SELECT e.codigo FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
         WHERE p.id = p_pedido_id) = 'entregado' THEN
        RAISE EXCEPTION 'Un pedido entregado ya es una venta: no se cancela, se anula.';
    END IF;
    /* Un pedido COBRADO tampoco se cancela: cancelado no cuenta en ventas ni
       en anuladas, así que su dinero desaparecería del cruce de caja. Se
       anula, y queda en el cruce como factura anulada (la 48). */
    IF (SELECT ep.codigo FROM core.pedidos p JOIN core.estados_pago ep ON ep.id = p.estado_pago_id
         WHERE p.id = p_pedido_id) = 'confirmado' THEN
        RAISE EXCEPTION 'Ese pedido ya se cobró: no se cancela, se anula (así queda en el cruce de caja como factura anulada).';
    END IF;
    UPDATE core.pedidos
       SET estado_pedido_id   = core.fn_id_catalogo('estados_pedido', 'cancelado'),
           motivo_cancelacion = trim(p_motivo)
     WHERE id = p_pedido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;
END;
$$;
