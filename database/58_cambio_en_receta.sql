/* ============================================================================
   58 · CAMBIO EN LA RECETA: elegir la marca al vender

   El caso (Gusti Broaster, auditoría del 24/11): los combos traen «Gaseosa
   1.5» y la receta descontaba siempre Postobón, pero se entregaba Coca-Cola
   o Ginger según lo que pidiera el cliente o lo que hubiera. El cruce del
   bar salía con Postobón sobrando y Coca-Cola faltando, cuando en total
   las de 1.5 cuadraban.

   CÓMO SE ARMA (es de cualquier negocio, no de Gusti)
     · core.insumos.grupo_cambio: insumos con el mismo grupo se pueden
       cambiar uno por otro («Gaseosa 1.5»: Postobón, Coca-Cola, Ginger).
     · core.producto_insumos.cambiable: en ESA receta se elige al vender.
       Una Postobón 1.5 vendida sola no lleva la marca: ella es la marca.
       El combo sí.
     · core.pedido_item_cambios: lo que se eligió en cada renglón vendido.
       Se guarda también cuando se elige la misma del receta, para que la
       comanda y el ticket digan cuál va.

   QUÉ CAMBIA
     Lo que gasta un renglón es su receta, con cada insumo cambiado por el
     elegido: el cruce (fn_z_insumo y api.v_cruce_inventario) y el retorno
     de una anulación (sp_anular_pedido). El detalle del renglón dice
     «Gaseosa 1.5: Coca-Cola 1.5». Sin nada elegido todo sigue como antes.

   Idempotente. Construido sobre el texto de PRODUCCIÓN de cada objeto
   (comparado por md5 con una instalación limpia el 24/11/2026).
   ============================================================================ */

SET search_path = core, public;

/* ---------------------------------------------------------------- tablas */
ALTER TABLE core.insumos ADD COLUMN IF NOT EXISTS grupo_cambio VARCHAR(40);
COMMENT ON COLUMN core.insumos.grupo_cambio IS
    'Insumos con el mismo grupo (por empresa) se pueden cambiar uno por otro en una receta marcada como cambiable. Ej.: «Gaseosa 1.5».';

ALTER TABLE core.producto_insumos ADD COLUMN IF NOT EXISTS cambiable BOOLEAN NOT NULL DEFAULT FALSE;
COMMENT ON COLUMN core.producto_insumos.cambiable IS
    'Al vender el producto se elige cuál insumo del grupo de cambio va (el combo elige la gaseosa).';

CREATE TABLE IF NOT EXISTS core.pedido_item_cambios (
    id                  BIGSERIAL PRIMARY KEY,
    pedido_item_id      BIGINT  NOT NULL REFERENCES core.pedido_items (id) ON DELETE CASCADE,
    insumo_original_id  INTEGER NOT NULL REFERENCES core.insumos (id) ON DELETE CASCADE,
    insumo_elegido_id   INTEGER NOT NULL REFERENCES core.insumos (id) ON DELETE CASCADE,
    CONSTRAINT uq_pedido_item_cambio UNIQUE (pedido_item_id, insumo_original_id)
);
COMMENT ON TABLE core.pedido_item_cambios IS
    'Qué insumo se eligió, en un renglón vendido, en lugar del de la receta. Ver la migración 58.';
CREATE INDEX IF NOT EXISTS ix_pedido_item_cambios_elegido ON core.pedido_item_cambios (insumo_elegido_id);

-- Como pedido_item_opciones: sólo se escribe a través de los procedimientos
ALTER TABLE core.pedido_item_cambios ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON core.pedido_item_cambios FROM PUBLIC;

/* Lo elegido tiene que ser del grupo de un insumo que esa receta deja
   cambiar, de la misma empresa y activo. Y no se edita: es una venta. */
CREATE OR REPLACE FUNCTION core.tg_item_cambios_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'core', 'public'
AS $$
DECLARE
    v_producto INTEGER;
    v_empresa  INTEGER;
    v_grupo    TEXT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Lo elegido en una venta no se modifica.' USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    SELECT it.producto_id, p.empresa_id INTO v_producto, v_empresa
      FROM core.pedido_items it JOIN core.pedidos p ON p.id = it.pedido_id
     WHERE it.id = NEW.pedido_item_id;

    SELECT NULLIF(trim(i.grupo_cambio), '') INTO v_grupo
      FROM core.producto_insumos pi JOIN core.insumos i ON i.id = pi.insumo_id
     WHERE pi.producto_id = v_producto AND pi.insumo_id = NEW.insumo_original_id
       AND pi.cambiable AND i.empresa_id = v_empresa;
    IF v_grupo IS NULL THEN
        RAISE EXCEPTION 'Ese producto no deja elegir ese insumo.' USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM core.insumos a
                    WHERE a.id = NEW.insumo_elegido_id AND a.empresa_id = v_empresa
                      AND (a.activo OR a.id = NEW.insumo_original_id)
                      AND lower(trim(a.grupo_cambio)) = lower(v_grupo)) THEN
        RAISE EXCEPTION 'Esa opción no es de «%».', v_grupo USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_item_cambios_antes ON core.pedido_item_cambios;
CREATE TRIGGER trg_item_cambios_antes
    BEFORE INSERT OR UPDATE ON core.pedido_item_cambios
    FOR EACH ROW EXECUTE FUNCTION core.tg_item_cambios_antes();

/* Lo que manda el pedido en cada línea: "cambios": [{"de": 12, "a": 15}].
   Si llega dos veces el mismo «de», vale el primero. */
CREATE OR REPLACE FUNCTION core.fn_guardar_cambios_item(p_item BIGINT, p_cambios JSONB)
RETURNS VOID
LANGUAGE plpgsql
SET search_path TO 'core', 'public'
AS $$
BEGIN
    IF p_cambios IS NULL OR jsonb_typeof(p_cambios) <> 'array' THEN
        RETURN;
    END IF;
    INSERT INTO core.pedido_item_cambios (pedido_item_id, insumo_original_id, insumo_elegido_id)
    SELECT p_item, (c ->> 'de')::INTEGER, (c ->> 'a')::INTEGER
      FROM jsonb_array_elements(p_cambios) c
     WHERE NULLIF(c ->> 'de', '') IS NOT NULL AND NULLIF(c ->> 'a', '') IS NOT NULL
    ON CONFLICT (pedido_item_id, insumo_original_id) DO NOTHING;
END;
$$;

/* ------------------------------------------------- crear el pedido (sp) */
CREATE OR REPLACE PROCEDURE api.sp_crear_pedido(IN p_unidad_id integer, IN p_tipo character varying, IN p_metodo_pago character varying, IN p_items jsonb, IN p_usuario_id integer DEFAULT NULL::integer, IN p_mesa character varying DEFAULT NULL::character varying, IN p_cliente_nombre character varying DEFAULT NULL::character varying, IN p_cliente_telefono character varying DEFAULT NULL::character varying, IN p_direccion character varying DEFAULT NULL::character varying, IN p_indicaciones character varying DEFAULT NULL::character varying, IN p_zona_id integer DEFAULT NULL::integer, IN p_paga_con numeric DEFAULT NULL::numeric, IN p_clave character varying DEFAULT NULL::character varying, INOUT p_pedido_id bigint DEFAULT NULL::bigint, INOUT p_codigo character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'public'
AS $procedure$
DECLARE
    v_empresa   INTEGER := core.fn_empresa_de_unidad(p_unidad_id);
    v_metodo    INTEGER := core.fn_id_catalogo('metodos_pago', p_metodo_pago);
    v_tipo      INTEGER := core.fn_id_catalogo('tipos_pedido', p_tipo);
    v_cliente   BIGINT;
    v_mesa      INTEGER;
    v_linea     JSONB;
    v_item      BIGINT;
    v_menu      BIGINT;
    v_minimo    NUMERIC;
    v_falta     TEXT;
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;

    /* ¿Este mismo envío ya entró? Entonces no es un pedido nuevo: es el
       mismo toque que llegó dos veces. Se devuelve el que ya existe. */
    IF p_clave IS NOT NULL THEN
        SELECT id, codigo INTO p_pedido_id, p_codigo
          FROM core.pedidos
         WHERE empresa_id = v_empresa AND clave_envio = p_clave;
        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, NULL, p_unidad_id);
    IF p_tipo = 'mostrador' THEN
        IF p_usuario_id IS NULL THEN
            RAISE EXCEPTION 'Una venta directa la registra quien está en caja: hace falta iniciar sesión.';
        END IF;
        PERFORM core.fn_exigir_permiso(p_usuario_id, 'pagos');
    ELSIF p_usuario_id IS NOT NULL THEN
        PERFORM core.fn_exigir_alguno(p_usuario_id, ARRAY['pedidos_mesa', 'pedidos_gestionar']);
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'El pedido está vacío.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago
                    WHERE empresa_id = v_empresa AND metodo_pago_id = v_metodo AND activo) THEN
        RAISE EXCEPTION 'El método de pago "%" no está disponible.', p_metodo_pago;
    END IF;

    IF p_tipo IN ('domicilio', 'recoger') THEN
        IF length(trim(COALESCE(p_cliente_nombre, ''))) < 3 THEN
            RAISE EXCEPTION 'Escribe tu nombre completo.';
        END IF;
        IF regexp_replace(COALESCE(p_cliente_telefono, ''), '\D', '', 'g') !~ '^[0-9]{7,10}$' THEN
            RAISE EXCEPTION 'El celular debe tener entre 7 y 10 dígitos.';
        END IF;
        INSERT INTO core.clientes (empresa_id, nombre, telefono)
        VALUES (v_empresa, trim(p_cliente_nombre), regexp_replace(p_cliente_telefono, '\D', '', 'g'))
        ON CONFLICT (empresa_id, telefono) DO UPDATE SET nombre = EXCLUDED.nombre
        RETURNING id INTO v_cliente;
    ELSIF p_tipo = 'mesa' THEN
        SELECT id INTO v_mesa FROM core.mesas
         WHERE unidad_id = p_unidad_id AND numero = trim(p_mesa) AND activa;
        IF v_mesa IS NULL THEN
            RAISE EXCEPTION 'La mesa "%" no existe en esta unidad.', p_mesa;
        END IF;
    END IF;

    BEGIN
        INSERT INTO core.pedidos (unidad_id, tipo_pedido_id, metodo_pago_id, mesa_id, cliente_id,
                                  zona_domicilio_id, direccion_entrega, indicaciones, paga_con, tomado_por_id,
                                  clave_envio)
        VALUES (p_unidad_id, v_tipo, v_metodo, v_mesa, v_cliente, p_zona_id,
                NULLIF(trim(p_direccion), ''), NULLIF(trim(p_indicaciones), ''), p_paga_con, p_usuario_id,
                p_clave)
        RETURNING id, codigo INTO p_pedido_id, p_codigo;
    EXCEPTION WHEN unique_violation THEN
        SELECT id, codigo INTO p_pedido_id, p_codigo
          FROM core.pedidos
         WHERE empresa_id = v_empresa AND clave_envio = p_clave;
        IF FOUND THEN
            RETURN;
        END IF;
        RAISE;
    END;

    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        INSERT INTO core.pedido_items (pedido_id, producto_id, plato_dia_id, menu_dia_id, cantidad, notas)
        VALUES (p_pedido_id,
                (v_linea ->> 'producto_id')::INTEGER,
                (v_linea ->> 'plato_dia_id')::BIGINT,
                (v_linea ->> 'menu_dia_id')::BIGINT,
                COALESCE((v_linea ->> 'cantidad')::INTEGER, 1),
                NULLIF(trim(v_linea ->> 'notas'), ''))
        RETURNING id INTO v_item;

        -- (58) Lo elegido en la receta: la gaseosa del combo
        IF v_linea ? 'cambios' THEN
            PERFORM core.fn_guardar_cambios_item(v_item, v_linea -> 'cambios');
        END IF;

        /* A qué menú pertenece la línea: el armado lo trae en menu_dia_id; el
           plato del chef lo hereda de su plato. */
        v_menu := COALESCE((v_linea ->> 'menu_dia_id')::BIGINT,
                           (SELECT menu_dia_id FROM core.platos_dia WHERE id = (v_linea ->> 'plato_dia_id')::BIGINT));

        /* Elige acompañamientos si es armado (siempre) o si es un plato del
           chef cuyo menú los pide. */
        IF v_menu IS NOT NULL AND (
               (v_linea ? 'menu_dia_id')
            OR EXISTS (SELECT 1 FROM core.menus_dia md WHERE md.id = v_menu AND md.pide_acompanamientos)
           ) THEN
            INSERT INTO core.pedido_item_opciones (pedido_item_id, menu_opcion_id)
            SELECT v_item, x::BIGINT FROM jsonb_array_elements_text(COALESCE(v_linea -> 'opciones', '[]')) x;

            -- Toda categoría obligatoria con opciones activas debe tener al menos una elegida
            SELECT string_agg(c.nombre, ', ' ORDER BY c.orden) INTO v_falta
              FROM core.menu_categorias c
             WHERE c.menu_dia_id = v_menu
               AND c.activa AND c.obligatoria
               AND EXISTS (SELECT 1 FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id AND o.activa)
               AND NOT EXISTS (SELECT 1 FROM core.pedido_item_opciones x
                                 JOIN core.menu_opciones o ON o.id = x.menu_opcion_id
                                WHERE x.pedido_item_id = v_item AND o.menu_categoria_id = c.id);
            IF v_falta IS NOT NULL THEN
                RAISE EXCEPTION 'Te falta elegir: %.', v_falta;
            END IF;
        END IF;
    END LOOP;

    SELECT pedido_minimo INTO v_minimo FROM core.zonas_domicilio WHERE id = p_zona_id;
    IF v_minimo IS NOT NULL AND core.fn_subtotal_pedido(p_pedido_id) < v_minimo THEN
        RAISE EXCEPTION 'El pedido mínimo para esta zona es %.', v_minimo;
    END IF;

    /* ---- VENTA DIRECTA (mostrador): entrega si nada se prepara, y cobra. --- */
    IF p_tipo = 'mostrador' THEN
        IF NOT EXISTS (
            SELECT 1 FROM core.pedido_items i
              JOIN core.productos pr ON pr.id = i.producto_id
             WHERE i.pedido_id = p_pedido_id AND pr.requiere_preparacion
        ) AND NOT EXISTS (
            SELECT 1 FROM core.pedido_items i
             WHERE i.pedido_id = p_pedido_id
               AND (i.plato_dia_id IS NOT NULL OR i.menu_dia_id IS NOT NULL)
        ) THEN
            UPDATE core.pedidos
               SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'entregado')
             WHERE id = p_pedido_id;
        END IF;

        -- (56) Con pago dividido lo cobra api.sp_pago_dividido, enseguida
        IF current_setting('taseca.pago_dividido', TRUE) IS DISTINCT FROM 'si' THEN
            CALL api.sp_actualizar_pago(p_pedido_id, 'confirmado', p_usuario_id, NULL, p_metodo_pago);
        END IF;
    END IF;
END;
$procedure$;

/* ------------------------------------------------ lo vendido (Z) del cruce */
CREATE OR REPLACE FUNCTION core.fn_z_insumo(p_insumo_unidad_id integer, p_desde_excl date, p_hasta date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'core', 'public'
AS $function$
    /* (58) Cada línea de la receta gasta el insumo ELEGIDO al vender, si se
       eligió uno; si no, el de la receta. */
    SELECT COALESCE(SUM(it.cantidad * pi.cantidad), 0)
      FROM core.insumo_unidades iu
      JOIN core.pedidos p           ON p.unidad_id = iu.unidad_id
      JOIN core.pedido_items it     ON it.pedido_id = p.id
      JOIN core.producto_insumos pi ON pi.producto_id = it.producto_id
      LEFT JOIN core.pedido_item_cambios cb
             ON cb.pedido_item_id = it.id AND cb.insumo_original_id = pi.insumo_id
      JOIN core.estados_pedido ep   ON ep.id = p.estado_pedido_id
     WHERE iu.id = p_insumo_unidad_id
       AND COALESCE(cb.insumo_elegido_id, pi.insumo_id) = iu.insumo_id
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
$function$;

CREATE OR REPLACE VIEW api.v_cruce_inventario AS
 WITH base AS (
         SELECT d.id AS cierre_detalle_id,
            c.id AS cierre_id,
            c.unidad_id,
            c.area_id,
            c.fecha_operativa,
            d.insumo_unidad_id,
            iu.insumo_id,
            d.saldo_fisico,
            ant.saldo_fisico AS saldo_anterior,
            ant.fecha_operativa AS fecha_anterior
           FROM core.cierre_detalles d
             JOIN core.cierres_inventario c ON c.id = d.cierre_id
             JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
             LEFT JOIN LATERAL ( SELECT d2.saldo_fisico,
                    c2.fecha_operativa
                   FROM core.cierre_detalles d2
                     JOIN core.cierres_inventario c2 ON c2.id = d2.cierre_id
                  WHERE d2.insumo_unidad_id = d.insumo_unidad_id AND c2.fecha_operativa < c.fecha_operativa
                  ORDER BY c2.fecha_operativa DESC
                 LIMIT 1) ant ON true
        )
 SELECT b.cierre_id,
    b.cierre_detalle_id,
    b.unidad_id,
    u.empresa_id,
    u.nombre AS unidad,
    a.codigo AS area,
    b.fecha_operativa,
    b.fecha_anterior,
    i.codigo,
    i.nombre AS insumo,
    COALESCE(b.saldo_anterior, 0::numeric) AS inicial,
    b.saldo_anterior IS NULL AS sin_cierre_anterior,
    x.en AS entradas,
    x.z AS ventas,
    b.saldo_fisico,
    COALESCE(b.saldo_anterior, 0::numeric) + x.en - x.z AS saldo_esperado,
    COALESCE(b.saldo_anterior, 0::numeric) + x.en - x.z - b.saldo_fisico AS diferencia
   FROM base b
     JOIN core.unidades u ON u.id = b.unidad_id
     JOIN core.areas_inventario a ON a.id = b.area_id
     JOIN core.insumos i ON i.id = b.insumo_id
     CROSS JOIN LATERAL ( SELECT ( SELECT COALESCE(sum(e.cantidad), 0::numeric) AS "coalesce"
                   FROM core.entradas_inventario e
                  WHERE e.insumo_unidad_id = b.insumo_unidad_id AND e.anulada_en IS NULL AND e.fecha_operativa > COALESCE(b.fecha_anterior, b.fecha_operativa - 1) AND e.fecha_operativa <= b.fecha_operativa) AS en,
            ( SELECT COALESCE(sum(it.cantidad::numeric * pi.cantidad), 0::numeric) AS "coalesce"
                   FROM core.pedidos p
                     JOIN core.pedido_items it ON it.pedido_id = p.id
                     JOIN core.producto_insumos pi ON pi.producto_id = it.producto_id
                     LEFT JOIN core.pedido_item_cambios cb ON cb.pedido_item_id = it.id AND cb.insumo_original_id = pi.insumo_id
                     JOIN core.estados_pedido ep ON ep.id = p.estado_pedido_id
                  WHERE p.unidad_id = b.unidad_id AND COALESCE(cb.insumo_elegido_id, pi.insumo_id) = b.insumo_id AND p.fecha_operativa > COALESCE(b.fecha_anterior, b.fecha_operativa - 1) AND p.fecha_operativa <= b.fecha_operativa AND (ep.cuenta_como_venta OR ep.codigo::text = 'anulado'::text AND (core.fn_item_dado_de_baja(it.id) OR (EXISTS ( SELECT 1
                           FROM core.entradas_inventario e2
                          WHERE e2.pedido_id = p.id AND e2.insumo_unidad_id = b.insumo_unidad_id))))) AS z) x;

/* ------------------------------------------- el retorno de una anulación */
CREATE OR REPLACE PROCEDURE api.sp_anular_pedido(IN p_pedido_id bigint, IN p_motivo character varying, IN p_usuario_id integer, IN p_items_baja bigint[] DEFAULT NULL::bigint[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'public'
AS $procedure$
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
    -- (58) El insumo consumido es el elegido al vender, si se eligió
    SELECT EXISTS (
        SELECT 1
          FROM core.pedido_items i
          JOIN core.producto_insumos pi ON pi.producto_id = i.producto_id
          LEFT JOIN core.pedido_item_cambios cb ON cb.pedido_item_id = i.id AND cb.insumo_original_id = pi.insumo_id
          JOIN core.insumos s           ON s.id = COALESCE(cb.insumo_elegido_id, pi.insumo_id)
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
          LEFT JOIN core.pedido_item_cambios cb ON cb.pedido_item_id = i.id AND cb.insumo_original_id = pi.insumo_id
          JOIN core.insumos s           ON s.id = COALESCE(cb.insumo_elegido_id, pi.insumo_id)
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
$procedure$;

/* ------------------------------------- el detalle del renglón (ticket…) */
CREATE OR REPLACE VIEW api.v_pedido_items AS
 SELECT i.id AS pedido_item_id,
    i.pedido_id,
    p.codigo,
    p.unidad_id,
    p.fecha_operativa,
        CASE
            WHEN i.producto_id IS NOT NULL THEN 'carta'::text
            WHEN i.plato_dia_id IS NOT NULL THEN 'chef'::text
            ELSE 'armado'::text
        END AS origen,
    i.producto_id,
    i.plato_dia_id,
    i.menu_dia_id,
    i.nombre,
    i.precio_unitario,
    i.cantidad,
    i.precio_unitario * i.cantidad::numeric AS total_linea,
    i.notas,
    -- (58) Lo elegido de la receta va junto a los acompañamientos
    NULLIF(concat_ws(' · ',
        ( SELECT string_agg((g.categoria::text || ': '::text) || g.opciones, ' · '::text ORDER BY g.orden) AS string_agg
           FROM ( SELECT c.nombre AS categoria,
                    c.orden,
                    string_agg(o.nombre::text, ', '::text ORDER BY o.orden) AS opciones
                   FROM core.pedido_item_opciones x
                     JOIN core.menu_opciones o ON o.id = x.menu_opcion_id
                     JOIN core.menu_categorias c ON c.id = o.menu_categoria_id
                  WHERE x.pedido_item_id = i.id
                  GROUP BY c.nombre, c.orden) g),
        ( SELECT string_agg(COALESCE(NULLIF(trim(io.grupo_cambio), ''), io.nombre)::text || ': ' || ie.nombre::text, ' · '::text ORDER BY io.nombre)
           FROM core.pedido_item_cambios cb
             JOIN core.insumos io ON io.id = cb.insumo_original_id
             JOIN core.insumos ie ON ie.id = cb.insumo_elegido_id
          WHERE cb.pedido_item_id = i.id)), '') AS detalle
   FROM core.pedido_items i
     JOIN core.pedidos p ON p.id = i.pedido_id;

/* ----------------------------------------------- la carta: qué se elige */
CREATE OR REPLACE VIEW rest.carta AS
 SELECT p.id AS producto_id,
    p.empresa_id,
    p.codigo,
    p.categoria_id,
    p.nombre,
    p.descripcion,
    p.precio,
    et.codigo AS etiqueta,
    p.imagen_url,
    p.orden,
    p.activo,
    COALESCE(jsonb_agg(jsonb_build_object('unidad_id', pu.unidad_id, 'agotado', pu.agotado) ORDER BY pu.unidad_id) FILTER (WHERE pu.id IS NOT NULL), '[]'::jsonb) AS unidades,
    p.requiere_preparacion,
    p.solo_personal,
    /* (58) Por cada insumo cambiable de la receta: su grupo y las opciones
       (la de la receta primero). Sólo si hay de verdad entre qué elegir. */
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('de', i.id, 'grupo', trim(i.grupo_cambio), 'opciones', ops.lista) ORDER BY i.grupo_cambio, i.id)
           FROM core.producto_insumos pi
             JOIN core.insumos i ON i.id = pi.insumo_id
             CROSS JOIN LATERAL ( SELECT jsonb_agg(jsonb_build_object('id', a.id, 'nombre', a.nombre) ORDER BY (a.id <> i.id), a.nombre) AS lista,
                    count(*) AS n
                   FROM core.insumos a
                  WHERE a.empresa_id = i.empresa_id AND (a.activo OR a.id = i.id)
                    AND lower(trim(a.grupo_cambio)) = lower(trim(i.grupo_cambio))) ops
          WHERE pi.producto_id = p.id AND pi.cambiable AND NULLIF(trim(i.grupo_cambio), '') IS NOT NULL AND ops.n > 1), '[]'::jsonb) AS cambios
   FROM core.productos p
     LEFT JOIN core.etiquetas_producto et ON et.id = p.etiqueta_id
     LEFT JOIN core.producto_unidades pu ON pu.producto_id = p.id
  WHERE NOT p.solo_personal OR (core.fn_jwt_claims() ->> 'usuario_id'::text) IS NOT NULL AND ((core.fn_jwt_claims() ->> 'empresa_id'::text)::integer) = p.empresa_id
  GROUP BY p.id, et.codigo;

/* ------------------------------------------------ el stock: el grupo */
CREATE OR REPLACE VIEW rest.stock AS
 WITH sesion AS MATERIALIZED (
         SELECT core.fn_jwt_usuario() AS usuario_id,
            core.fn_jwt_empresa() AS empresa_id
        )
 SELECT i.id AS insumo_id,
    i.empresa_id,
    i.codigo,
    i.nombre,
    ci.nombre AS categoria,
    a.codigo AS area,
    um.codigo AS unidad_medida,
    i.activo,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('unidad_id', iu.unidad_id, 'stock_actual', iu.stock_actual, 'stock_minimo', iu.stock_minimo) ORDER BY iu.unidad_id) AS jsonb_agg
           FROM core.insumo_unidades iu
          WHERE iu.insumo_id = i.id), '[]'::jsonb) AS unidades,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('producto_id', pi.producto_id, 'cantidad', pi.cantidad, 'cambiable', pi.cambiable) ORDER BY pi.producto_id) AS jsonb_agg
           FROM core.producto_insumos pi
          WHERE pi.insumo_id = i.id), '[]'::jsonb) AS productos,
    GREATEST(i.actualizado_en, ( SELECT max(iu.actualizado_en) AS max
           FROM core.insumo_unidades iu
          WHERE iu.insumo_id = i.id)) AS actualizado_en,
    i.grupo_cambio
   FROM core.insumos i
     JOIN sesion s ON s.empresa_id = i.empresa_id
     JOIN core.categorias_insumo ci ON ci.id = i.categoria_insumo_id
     JOIN core.areas_inventario a ON a.id = i.area_id
     JOIN core.unidades_medida um ON um.id = i.unidad_medida_id
  WHERE (EXISTS ( SELECT 1
           FROM unnest(ARRAY['stock'::text, 'entradas'::text, 'cierres'::text, 'cierres_registrar'::text]) p(p)
          WHERE api.fn_tiene_permiso(s.usuario_id, p.p::character varying))) AND (EXISTS ( SELECT 1
           FROM core.insumo_unidades iu
          WHERE iu.insumo_id = i.id AND core.fn_usuario_en_unidad(s.usuario_id, iu.unidad_id)));

/* ------------------------------------- guardar el insumo: grupo y marca */
CREATE OR REPLACE FUNCTION rest.guardar_insumo(p_insumo jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'public'
AS $function$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_id      INTEGER := NULLIF(p_insumo ->> 'insumo_id', '')::INTEGER;
    v_unidades  INTEGER[];
    v_productos INTEGER[];
    v_receta    JSONB := NULL;
BEGIN
    v_unidades := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(COALESCE(p_insumo -> 'unidades', '[]')) x);

    /* `productos` viene de dos formas, y las dos valen:
         [12, 13]                                  -> cada uno gasta 1
         [{"producto_id":12,"cantidad":2}, …]      -> lo que diga cada uno
       La segunda es la que manda la aplicación; la primera la mandaba la
       anterior, y un navegador con la página vieja en caché sigue
       mandándola. (58) La segunda puede traer "cambiable". */
    IF jsonb_typeof(p_insumo -> 'productos') = 'array' THEN
        v_receta := (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'producto_id', CASE WHEN jsonb_typeof(x) = 'object'
                                           THEN (x ->> 'producto_id')::INTEGER
                                           ELSE x::TEXT::INTEGER END,
                       'cantidad',    CASE WHEN jsonb_typeof(x) = 'object'
                                           THEN COALESCE(NULLIF(x ->> 'cantidad', '')::NUMERIC, 1)
                                           ELSE 1 END,
                       'cambiable',   CASE WHEN jsonb_typeof(x) = 'object' AND x ? 'cambiable'
                                           THEN (x ->> 'cambiable')::BOOLEAN END)), '[]'::JSONB)
              FROM jsonb_array_elements(p_insumo -> 'productos') x
        );

        v_productos := ARRAY(SELECT (r ->> 'producto_id')::INTEGER
                               FROM jsonb_array_elements(v_receta) r);
    END IF;

    /* CUÁLES: el procedimiento comprueba la empresa de cada producto,
       borra los que se quitaron y crea los que faltan. */
    CALL api.sp_guardar_insumo(
        p_empresa_id    => v_empresa,
        p_codigo        => p_insumo ->> 'codigo',
        p_nombre        => p_insumo ->> 'nombre',
        p_categoria     => p_insumo ->> 'categoria',
        p_area          => p_insumo ->> 'area',
        p_unidad_medida => p_insumo ->> 'unidad',
        p_unidades      => v_unidades,
        p_usuario_id    => v_usuario,
        p_activo        => COALESCE((p_insumo ->> 'activo')::BOOLEAN, TRUE),
        p_stock_actual  => NULLIF(p_insumo ->> 'stock_actual', '')::NUMERIC,
        p_stock_minimo  => NULLIF(p_insumo ->> 'stock_minimo', '')::NUMERIC,
        p_productos     => v_productos,
        p_insumo_id     => v_id);

    /* CUÁNTO. Va después del CALL a propósito: antes los enlaces nuevos
       todavía no existen. Una cantidad que no sea positiva se queda en 1,
       que es lo que dice el CHECK de la tabla. */
    IF v_receta IS NOT NULL THEN
        UPDATE core.producto_insumos pi
           SET cantidad = GREATEST((r ->> 'cantidad')::NUMERIC, 0.001)
          FROM jsonb_array_elements(v_receta) r
         WHERE pi.insumo_id = v_id
           AND pi.producto_id = (r ->> 'producto_id')::INTEGER
           AND pi.cantidad IS DISTINCT FROM GREATEST((r ->> 'cantidad')::NUMERIC, 0.001);

        /* (58) Si en esa receta se elige al vender. Sin el dato (un panel
           viejo) se queda como estaba. */
        UPDATE core.producto_insumos pi
           SET cambiable = (r ->> 'cambiable')::BOOLEAN
          FROM jsonb_array_elements(v_receta) r
         WHERE pi.insumo_id = v_id
           AND pi.producto_id = (r ->> 'producto_id')::INTEGER
           AND r ->> 'cambiable' IS NOT NULL
           AND pi.cambiable IS DISTINCT FROM (r ->> 'cambiable')::BOOLEAN;
    END IF;

    -- (58) El grupo de cambio: sólo si viene; vacío lo quita
    IF p_insumo ? 'grupo_cambio' THEN
        UPDATE core.insumos
           SET grupo_cambio = NULLIF(trim(p_insumo ->> 'grupo_cambio'), '')
         WHERE id = v_id AND empresa_id = v_empresa
           AND grupo_cambio IS DISTINCT FROM NULLIF(trim(p_insumo ->> 'grupo_cambio'), '');
    END IF;

    RETURN jsonb_build_object('insumo_id', v_id);
END;
$function$;
