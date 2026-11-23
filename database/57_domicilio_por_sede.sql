/* ============================================================================
   57 · DOMICILIOS POR SEDE: APAGAR Y PRENDER

   Lo que pidió el cliente: un botón en cada sede para dejar de recibir
   domicilios (no hay domiciliario, la cocina está llena, la sede todavía
   no reparte…) sin desactivar la sede entera: sigue vendiendo en mesa,
   en mostrador y para recoger.

   Opción por sede: core.unidades.domicilio_activo, encendida (así todas
   las sedes siguen como estaban). La cambia quien configura sedes, con
   rest.configurar_domicilio.

   Qué hace la base cuando está apagada:
     · la página pública ya no ofrece «Domicilio» en esa sede (lo decide el
       portal leyendo la opción en rest.unidades);
     · y si de todas formas llega un pedido a domicilio SIN sesión (la
       página vieja abierta, un envío a mano), se rechaza con un mensaje
       claro. El personal con sesión sí puede tomar un domicilio por
       teléfono: apagar es para el canal en línea.

   Idempotente. Requiere: 54 (rest.unidades con cajon_monedero).
   ============================================================================ */

SET search_path = core, public;

ALTER TABLE core.unidades ADD COLUMN IF NOT EXISTS domicilio_activo BOOLEAN NOT NULL DEFAULT TRUE;
COMMENT ON COLUMN core.unidades.domicilio_activo IS
    'La sede recibe domicilios por la página pública. Apagada, sólo mesa, mostrador y recoger.';

/* La vista de sedes: + la opción, al final (CREATE OR REPLACE VIEW sólo
   deja agregar columnas al final). Conserva los permisos. */
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
    cu.cajon_monedero,
    cu.domicilio_activo
   FROM api.v_unidades u
     JOIN core.empresas e ON e.id = u.empresa_id
     JOIN core.unidades cu ON cu.id = u.unidad_id;


/* ---- Prender / apagar (permiso «config_sucursales») ---------------------- */
CREATE OR REPLACE FUNCTION rest.configurar_domicilio(p_unidad_id INTEGER, p_activo BOOLEAN)
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
    UPDATE core.unidades SET domicilio_activo = COALESCE(p_activo, TRUE) WHERE id = p_unidad_id;
    RETURN (SELECT to_jsonb(u) FROM rest.unidades u WHERE u.unidad_id = p_unidad_id);
END;
$$;
GRANT EXECUTE ON FUNCTION rest.configurar_domicilio(INTEGER, BOOLEAN) TO taseca_app;


/* ---- La barrera: un domicilio en línea a una sede que no los recibe ------
   Va en la tabla y no en rest.crear_pedido para que valga por cualquier
   camino (las dos firmas de crear_pedido, y las que vengan). «En línea» =
   sin quien lo tome (tomado_por_id NULL): el portal del cliente no tiene
   sesión. */
CREATE OR REPLACE FUNCTION core.tg_pedidos_domicilio_de_sede()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    IF NEW.tomado_por_id IS NULL
       AND NEW.tipo_pedido_id = (SELECT id FROM core.tipos_pedido WHERE codigo = 'domicilio')
       AND EXISTS (SELECT 1 FROM core.unidades u WHERE u.id = NEW.unidad_id AND NOT u.domicilio_activo) THEN
        RAISE EXCEPTION 'Esta sede no está recibiendo domicilios en este momento. Puedes pedir para recoger o elegir otra sede.'
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pedidos_domicilio_de_sede ON core.pedidos;
CREATE TRIGGER trg_pedidos_domicilio_de_sede
    BEFORE INSERT ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_domicilio_de_sede();
