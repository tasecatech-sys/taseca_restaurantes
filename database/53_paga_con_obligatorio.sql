/* ============================================================================
   53 · DOMICILIO EN EFECTIVO: EL CLIENTE DICE CON CUÁNTO PAGA

   Lo que pidió el cliente: si quien pide a domicilio elige «Efectivo contra
   entrega», tiene que decir con cuánto va a pagar, para que el domiciliario
   salga con las vueltas contadas.

   El portal ya lo exige (y que alcance para el total). Esto es la red de la
   base: aunque un navegador tenga abierta la página vieja, donde el campo
   era opcional, el pedido no entra sin el dato.

   SÓLO aplica al pedido que hace el CLIENTE (sin sesión de empleado:
   tomado_por_id nulo), a domicilio y en efectivo. No toca los domicilios que
   toma caja por teléfono, ni los de recoger, ni los de mesa, ni los que se
   pagan por Nequi, datáfono, etc.

   Idempotente.
   ============================================================================ */

SET search_path = core, public;

CREATE OR REPLACE FUNCTION core.tg_pedidos_paga_con()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    IF NEW.tomado_por_id IS NULL
       AND NEW.tipo_pedido_id = core.fn_id_catalogo('tipos_pedido', 'domicilio')
       AND NEW.metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'efectivo')
       AND COALESCE(NEW.paga_con, 0) <= 0 THEN
        RAISE EXCEPTION 'Indica con cuánto vas a pagar en efectivo, para que el domiciliario lleve tus vueltas.';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pedidos_paga_con ON core.pedidos;
CREATE TRIGGER trg_pedidos_paga_con
    BEFORE INSERT ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_paga_con();
