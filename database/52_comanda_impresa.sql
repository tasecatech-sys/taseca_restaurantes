/* ============================================================================
   52 · COMANDA IMPRESA: LA COCINA NO TOCA EL SISTEMA

   Lo que pidió el cliente: que el cocinero no tenga que manejar pedidos en
   una pantalla. El pedido llega impreso a la cocina; cuando la cocina avisa
   que está listo, CAJA lo marca en el sistema para que el cliente lo vea.

   ES OPCIONAL, POR SEDE (core.unidades.comanda_impresa, apagado)
     Apagado, todo sigue exactamente igual. Encendido:
       · Al crearse, el pedido pasa solo de «Nuevo» a «En preparación»
         (core.fn_comanda_al_crear, al final de rest.crear_pedido). El
         cliente ve «Pedido recibido · en preparación».
       · Una «estación de comandas» (el PC junto a la impresora, con el panel
         abierto) toma con rest.tomar_comandas los pedidos sin imprimir y los
         imprime. Tomar es atómico (FOR UPDATE SKIP LOCKED): aunque haya dos
         equipos encendidos, cada comanda sale una sola vez. Sólo van los
         pedidos con algo que preparar (una gaseosa sola no se imprime).
       · rest.comanda_lista: caja (o quien gestione o cocine) marca «Listo».
       · rest.reimprimir_comanda: la devuelve a la cola de la estación.
       · Cada vez que la estación pregunta deja un «latido»
         (core.estaciones_comanda) para avisar en caja si se apagó.
     Sólo se imprimen los pedidos creados DESPUÉS de encender la opción
     (comanda_desde): prenderla no vomita el atraso del día.

   Idempotente. Requiere: 25 (venta directa, requiere_preparacion), 30 y 45
   (rest.crear_pedido), 51 (fn_pedido_json).
   ============================================================================ */

SET search_path = core, public;

/* ============================================================================
   1. MODELO
   ============================================================================ */
ALTER TABLE core.unidades ADD COLUMN IF NOT EXISTS comanda_impresa BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE core.unidades ADD COLUMN IF NOT EXISTS comanda_desde   TIMESTAMPTZ;
COMMENT ON COLUMN core.unidades.comanda_impresa IS
    'La cocina trabaja con comanda impresa: el pedido entra directo a preparación y caja marca «Listo».';

ALTER TABLE core.pedidos ADD COLUMN IF NOT EXISTS comanda_impresa_en  TIMESTAMPTZ;
ALTER TABLE core.pedidos ADD COLUMN IF NOT EXISTS comanda_impresiones INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS ix_pedidos_comanda_pendiente ON core.pedidos (unidad_id, id) WHERE comanda_impresa_en IS NULL;

/* El latido de la estación: tabla aparte para no tocar core.unidades cada
   pocos segundos (sus cambios sí importan y se refrescan en el panel). */
CREATE TABLE IF NOT EXISTS core.estaciones_comanda (
    unidad_id   INTEGER     PRIMARY KEY REFERENCES core.unidades (id) ON DELETE CASCADE,
    visto_en    TIMESTAMPTZ NOT NULL DEFAULT now(),
    usuario_id  INTEGER     REFERENCES core.usuarios (id) ON DELETE SET NULL
);
ALTER TABLE core.estaciones_comanda ENABLE ROW LEVEL SECURITY;

/* ¿El pedido tiene algo que la cocina prepare? Los platos del día y el menú
   armado siempre; de la carta, lo que no se entrega en el acto. */
CREATE OR REPLACE FUNCTION core.fn_pedido_va_a_cocina(p_pedido_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SET search_path = core, public
AS $$
    SELECT EXISTS (SELECT 1 FROM core.pedido_items i
                     LEFT JOIN core.productos pr ON pr.id = i.producto_id
                    WHERE i.pedido_id = p_pedido_id
                      AND (i.plato_dia_id IS NOT NULL OR i.menu_dia_id IS NOT NULL
                           OR COALESCE(pr.requiere_preparacion, TRUE)));
$$;

/* Los ítems que van en la comanda de cocina. */
CREATE OR REPLACE FUNCTION core.fn_items_de_cocina(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
SET search_path = core, public
AS $$
    SELECT COALESCE(jsonb_agg(i.id ORDER BY i.id), '[]'::JSONB)
      FROM core.pedido_items i
      LEFT JOIN core.productos pr ON pr.id = i.producto_id
     WHERE i.pedido_id = p_pedido_id
       AND (i.plato_dia_id IS NOT NULL OR i.menu_dia_id IS NOT NULL OR COALESCE(pr.requiere_preparacion, TRUE));
$$;

/* Recién creado, en una sede con comanda: directo a preparación. Si la sede
   no la usa, o el pedido ya no está en «Nuevo» (una venta directa que nació
   entregada, un reintento con la misma clave), no hace nada. */
CREATE OR REPLACE FUNCTION core.fn_comanda_al_crear(p_pedido_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    UPDATE core.pedidos p
       SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'preparacion')
      FROM core.unidades u
     WHERE p.id = p_pedido_id
       AND u.id = p.unidad_id
       AND u.comanda_impresa
       AND p.estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'nuevo');
END;
$$;


/* ============================================================================
   2. CREAR PEDIDO: las dos firmas de producción, con UNA línea más al final
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.crear_pedido(p_unidad_id integer, p_tipo text, p_metodo_pago text, p_items jsonb, p_mesa text DEFAULT NULL::text, p_cliente_nombre text DEFAULT NULL::text, p_cliente_telefono text DEFAULT NULL::text, p_direccion text DEFAULT NULL::text, p_indicaciones text DEFAULT NULL::text, p_zona_id integer DEFAULT NULL::integer, p_paga_con numeric DEFAULT NULL::numeric, p_clave text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'public'
AS $function$
DECLARE
    v_id     BIGINT;
    v_codigo VARCHAR;
BEGIN
    CALL api.sp_crear_pedido(
        p_unidad_id => p_unidad_id, p_tipo => p_tipo, p_metodo_pago => p_metodo_pago, p_items => p_items,
        p_usuario_id => core.fn_jwt_usuario(), p_mesa => p_mesa,
        p_cliente_nombre => p_cliente_nombre, p_cliente_telefono => p_cliente_telefono,
        p_direccion => p_direccion, p_indicaciones => p_indicaciones, p_zona_id => p_zona_id,
        p_paga_con => p_paga_con, p_clave => NULLIF(trim(p_clave), ''),
        p_pedido_id => v_id, p_codigo => v_codigo);

    /* El recargo del método, congelado. Después del CALL porque necesita
       el subtotal, que no existe hasta que se insertan los ítems.

       Con `clave` repetida sp_crear_pedido devuelve el pedido que YA
       existía en vez de crear otro; el recargo que se recalcula entonces
       es el mismo, así que reintentar no lo mueve. */
    UPDATE core.pedidos p
       SET recargo_pago = core.fn_recargo_pago(
               p.empresa_id, p.metodo_pago_id,
               COALESCE((SELECT SUM(i.precio_unitario * i.cantidad)
                           FROM core.pedido_items i WHERE i.pedido_id = p.id), 0)
               + p.costo_domicilio)
     WHERE p.id = v_id
       AND p.recargo_pago IS DISTINCT FROM core.fn_recargo_pago(
               p.empresa_id, p.metodo_pago_id,
               COALESCE((SELECT SUM(i.precio_unitario * i.cantidad)
                           FROM core.pedido_items i WHERE i.pedido_id = p.id), 0)
               + p.costo_domicilio);

    -- (52) Sede con comanda impresa: directo a preparación
    PERFORM core.fn_comanda_al_crear(v_id);

    RETURN core.fn_pedido_json(v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION rest.crear_pedido(p_unidad_id integer, p_tipo text, p_metodo_pago text, p_items jsonb, p_mesa text DEFAULT NULL::text, p_cliente_nombre text DEFAULT NULL::text, p_cliente_telefono text DEFAULT NULL::text, p_direccion text DEFAULT NULL::text, p_indicaciones text DEFAULT NULL::text, p_zona_id integer DEFAULT NULL::integer, p_paga_con numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'public'
AS $function$
DECLARE
    v_id     BIGINT;
    v_codigo VARCHAR;
BEGIN
    CALL api.sp_crear_pedido(
        p_unidad_id => p_unidad_id, p_tipo => p_tipo, p_metodo_pago => p_metodo_pago, p_items => p_items,
        p_usuario_id => core.fn_jwt_usuario(), p_mesa => p_mesa,
        p_cliente_nombre => p_cliente_nombre, p_cliente_telefono => p_cliente_telefono,
        p_direccion => p_direccion, p_indicaciones => p_indicaciones, p_zona_id => p_zona_id,
        p_paga_con => p_paga_con, p_pedido_id => v_id, p_codigo => v_codigo);

    UPDATE core.pedidos p
       SET recargo_pago = core.fn_recargo_pago(
               p.empresa_id, p.metodo_pago_id,
               COALESCE((SELECT SUM(i.precio_unitario * i.cantidad)
                           FROM core.pedido_items i WHERE i.pedido_id = p.id), 0)
               + p.costo_domicilio)
     WHERE p.id = v_id;

    -- (52) Sede con comanda impresa: directo a preparación
    PERFORM core.fn_comanda_al_crear(v_id);

    RETURN core.fn_pedido_json(v_id);
END;
$function$;


/* ============================================================================
   3. LA VISTA DE SEDES: + la opción (al final, como pide CREATE OR REPLACE)
   ============================================================================ */
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
    cu.comanda_impresa
   FROM api.v_unidades u
     JOIN core.empresas e ON e.id = u.empresa_id
     JOIN core.unidades cu ON cu.id = u.unidad_id;


/* ============================================================================
   4. ENCENDER / APAGAR (permiso «config_sucursales»)
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.configurar_comanda(p_unidad_id INTEGER, p_activa BOOLEAN)
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
    UPDATE core.unidades
       SET comanda_impresa = COALESCE(p_activa, FALSE),
           comanda_desde = CASE WHEN COALESCE(p_activa, FALSE) AND NOT comanda_impresa THEN now() ELSE comanda_desde END
     WHERE id = p_unidad_id;
    RETURN (SELECT to_jsonb(u) FROM rest.unidades u WHERE u.unidad_id = p_unidad_id);
END;
$$;


/* ============================================================================
   5. LA ESTACIÓN DE COMANDAS
   ============================================================================ */
CREATE OR REPLACE FUNCTION core.fn_exigir_estacion(p_usuario INTEGER, p_unidad_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    IF core.fn_empresa_de_unidad(p_unidad_id) IS DISTINCT FROM core.fn_jwt_empresa() THEN
        RAISE EXCEPTION 'La unidad % no es de esta empresa.', p_unidad_id USING ERRCODE = 'insufficient_privilege';
    END IF;
    PERFORM core.fn_exigir_alguno(p_usuario, ARRAY['pagos', 'pedidos_gestionar', 'pedidos_cocina']);
    IF NOT core.fn_usuario_en_unidad(p_usuario, p_unidad_id) THEN
        RAISE EXCEPTION 'No trabajas en esa unidad.' USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;

/* Toma (y marca como impresas) las comandas pendientes de la sede. Devuelve
   [{ pedido, cocina: [ids de ítems a imprimir] }]. */
CREATE OR REPLACE FUNCTION rest.tomar_comandas(p_unidad_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_u       core.unidades;
    v_ids     BIGINT[];
BEGIN
    PERFORM core.fn_exigir_estacion(v_usuario, p_unidad_id);
    SELECT * INTO v_u FROM core.unidades WHERE id = p_unidad_id;

    INSERT INTO core.estaciones_comanda (unidad_id, visto_en, usuario_id) VALUES (p_unidad_id, now(), v_usuario)
    ON CONFLICT (unidad_id) DO UPDATE SET visto_en = now(), usuario_id = v_usuario;

    IF NOT v_u.comanda_impresa THEN
        RETURN '[]'::JSONB;
    END IF;

    WITH pendientes AS (
        SELECT p.id
          FROM core.pedidos p
          JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
         WHERE p.unidad_id = p_unidad_id
           AND p.comanda_impresa_en IS NULL
           AND p.creado_en >= COALESCE(v_u.comanda_desde, now())
           AND e.codigo IN ('nuevo', 'preparacion')
           AND core.fn_pedido_va_a_cocina(p.id)
         ORDER BY p.id
         LIMIT 20
           FOR UPDATE OF p SKIP LOCKED
    ), tomadas AS (
        UPDATE core.pedidos p
           SET comanda_impresa_en = now(), comanda_impresiones = p.comanda_impresiones + 1
          FROM pendientes x
         WHERE p.id = x.id
        RETURNING p.id
    )
    SELECT array_agg(id ORDER BY id) INTO v_ids FROM tomadas;

    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('pedido', core.fn_pedido_json(x), 'cocina', core.fn_items_de_cocina(x))
                                      ORDER BY x)
                       FROM unnest(v_ids) x), '[]'::JSONB);
END;
$$;

/* Caja marca «Listo» cuando la cocina avisa. */
CREATE OR REPLACE FUNCTION rest.comanda_lista(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_p       RECORD;
BEGIN
    SELECT p.id, p.codigo, p.unidad_id, e.codigo AS estado, e.nombre AS estado_nombre
      INTO v_p
      FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
     WHERE p.id = p_pedido_id AND p.empresa_id = core.fn_jwt_empresa();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el pedido.';
    END IF;
    PERFORM core.fn_exigir_estacion(v_usuario, v_p.unidad_id);
    IF v_p.estado NOT IN ('nuevo', 'preparacion') THEN
        RAISE EXCEPTION 'El pedido % ya está en «%».', v_p.codigo, v_p.estado_nombre;
    END IF;

    UPDATE core.pedidos
       SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'listo')
     WHERE id = p_pedido_id
       AND estado_pedido_id = core.fn_id_catalogo('estados_pedido', v_p.estado);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese pedido lo movió alguien más. Vuelve a intentarlo.';
    END IF;
    RETURN core.fn_pedido_json(p_pedido_id);
END;
$$;

/* Vuelve a la cola de la estación: sale de nuevo por la impresora. */
CREATE OR REPLACE FUNCTION rest.reimprimir_comanda(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_unidad  INTEGER;
BEGIN
    SELECT unidad_id INTO v_unidad FROM core.pedidos WHERE id = p_pedido_id AND empresa_id = core.fn_jwt_empresa();
    IF v_unidad IS NULL THEN
        RAISE EXCEPTION 'No se encontró el pedido.';
    END IF;
    PERFORM core.fn_exigir_estacion(v_usuario, v_unidad);
    UPDATE core.pedidos SET comanda_impresa_en = NULL WHERE id = p_pedido_id;
    INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
    VALUES (p_pedido_id, 'Comanda enviada de nuevo a la impresora', v_usuario);
    RETURN core.fn_pedido_json(p_pedido_id);
END;
$$;

/* Para caja: ¿la estación está viva? ¿cuántas esperan impresión? */
CREATE OR REPLACE FUNCTION rest.estado_comandas(p_unidad_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_u       core.unidades;
BEGIN
    PERFORM core.fn_exigir_estacion(v_usuario, p_unidad_id);
    SELECT * INTO v_u FROM core.unidades WHERE id = p_unidad_id;
    RETURN jsonb_build_object(
        'activa', v_u.comanda_impresa,
        'estacion_visto_en', (SELECT visto_en FROM core.estaciones_comanda WHERE unidad_id = p_unidad_id),
        'segundos_sin_estacion', (SELECT extract(epoch FROM now() - visto_en)::INTEGER FROM core.estaciones_comanda WHERE unidad_id = p_unidad_id),
        'sin_imprimir', (SELECT count(*) FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
                          WHERE p.unidad_id = p_unidad_id AND p.comanda_impresa_en IS NULL
                            AND p.creado_en >= COALESCE(v_u.comanda_desde, now())
                            AND e.codigo IN ('nuevo', 'preparacion')
                            AND core.fn_pedido_va_a_cocina(p.id)));
END;
$$;

GRANT EXECUTE ON FUNCTION rest.configurar_comanda(INTEGER, BOOLEAN), rest.tomar_comandas(INTEGER),
                          rest.comanda_lista(BIGINT), rest.reimprimir_comanda(BIGINT),
                          rest.estado_comandas(INTEGER) TO taseca_app;
