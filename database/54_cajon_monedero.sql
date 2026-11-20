/* ============================================================================
   54 · CAJÓN MONEDERO: RECIBO AL COBRAR EN EFECTIVO

   Lo que pidió el cliente: en la caja tienen computador + impresora térmica
   (Epson) + cajón monedero conectado a la impresora. El cajón se abre cuando
   la impresora imprime (lo configura el driver de Windows: «abrir el cajón
   al imprimir»). Así que basta con que el sistema IMPRIMA al recibir
   efectivo: sale el comprobante y se abre el cajón.

   Opcional y por sede (no todos los restaurantes tienen cajón):
   core.unidades.cajon_monedero, apagado. Lo enciende quien configura sedes
   con rest.configurar_cajon. El recibo lo imprime el panel (js/caja.js); la
   base sólo guarda y publica la opción.

   Idempotente. Requiere: 52 (rest.unidades con comanda_impresa).
   ============================================================================ */

SET search_path = core, public;

ALTER TABLE core.unidades ADD COLUMN IF NOT EXISTS cajon_monedero BOOLEAN NOT NULL DEFAULT FALSE;
COMMENT ON COLUMN core.unidades.cajon_monedero IS
    'La caja tiene impresora con cajón monedero: al cobrar en efectivo se imprime el comprobante y se abre el cajón.';

/* La vista de sedes: + la opción, al final. */
CREATE OR REPLACE VIEW rest.unidades AS
 SELECT u.unidad_id,
    u.empresa_id,
    e.codigo AS empresa_codigo,
    u.nombre,
    u.nombre_corto,
    u.estado,
    u.activa,
    u.tipo_negocio,
    u.direccion,
    u.ciudad,
    u.telefono,
    u.whatsapp,
    u.horario,
    u.mapa_url,
    u.color,
    u.logo_url,
    u.mesas,
    u.creado_en,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('zona_id', z.id, 'nombre', z.nombre, 'costo', z.costo, 'pedido_minimo', z.pedido_minimo) ORDER BY z.nombre) AS jsonb_agg
           FROM core.zonas_domicilio z
          WHERE z.unidad_id = u.unidad_id AND z.activa), '[]'::jsonb) AS zonas,
    cu.color_marca,
    ( SELECT l.actualizado_en
           FROM core.unidad_logos l
          WHERE l.unidad_id = u.unidad_id) AS logo_version,
    cu.comanda_impresa,
    cu.cajon_monedero
   FROM api.v_unidades u
     JOIN core.empresas e ON e.id = u.empresa_id
     JOIN core.unidades cu ON cu.id = u.unidad_id;

CREATE OR REPLACE FUNCTION rest.configurar_cajon(p_unidad_id INTEGER, p_activo BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    IF core.fn_empresa_de_unidad(p_unidad_id) IS DISTINCT FROM core.fn_jwt_empresa() THEN
        RAISE EXCEPTION 'La unidad % no es de esta empresa.', p_unidad_id USING ERRCODE = 'insufficient_privilege';
    END IF;
    PERFORM core.fn_preparar_operacion(v_usuario, 'config_sucursales');
    UPDATE core.unidades SET cajon_monedero = COALESCE(p_activo, FALSE) WHERE id = p_unidad_id;
    RETURN (SELECT to_jsonb(u) FROM rest.unidades u WHERE u.unidad_id = p_unidad_id);
END;
$$;
GRANT EXECUTE ON FUNCTION rest.configurar_cajon(INTEGER, BOOLEAN) TO taseca_app;
