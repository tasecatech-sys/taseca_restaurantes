/* ============================================================================
   59 · LA DIFERENCIA DE PRECIO AL ELEGIR (sobre la 58)

   El caso (Gusti, 24/11): el combo trae Postobón 1.5 ($6.000 suelta) y el
   cliente elige Coca-Cola 1.5 ($7.000 suelta). El combo se cobraba igual;
   tiene que cobrar los $1.000 de diferencia.

   DE DÓNDE SALE EL VALOR DE CADA OPCIÓN
     De la carta: el precio del producto que vende ESE insumo solo (su
     receta es únicamente ese insumo, cantidad 1). Así no hay un segundo
     precio que mantener: si la Coca-Cola sube en la carta, la diferencia
     sube sola. Si un insumo no se vende solo, no hay con qué comparar y
     la diferencia es 0.

   LA REGLA
     diferencia = (suelta elegida − suelta de la receta) × cantidad en la
     receta, sólo si es positiva. Elegir una más barata no rebaja el combo.

   DÓNDE QUEDA
     · core.pedido_item_cambios.recargo: la diferencia de ese cambio, como
       foto (si mañana cambia la carta, la venta de hoy sigue diciendo lo
       que se cobró). La calcula la base; lo que mande la pantalla no cuenta.
     · core.pedido_items.precio_unitario: el del combo + las diferencias.
       El total, la caja y el informe salen de ahí, como siempre.
     · rest.carta: cada opción trae su "extra" para que la pantalla muestre
       «Coca-Cola 1.5 +$1.000» y el precio correcto antes de enviar.

   Idempotente. Requiere la 58.
   ============================================================================ */

SET search_path = core, public;

ALTER TABLE core.pedido_item_cambios ADD COLUMN IF NOT EXISTS recargo NUMERIC(12, 2) NOT NULL DEFAULT 0;
COMMENT ON COLUMN core.pedido_item_cambios.recargo IS
    'Lo que se cobró de más por elegir este insumo (precio suelto elegido − precio suelto de la receta). Foto de la venta.';

/* El precio del insumo vendido solo, en la carta de su empresa. Si varios
   productos lo venden solos, el más barato: nunca se cobra de más. */
CREATE OR REPLACE FUNCTION core.fn_precio_suelto(p_insumo_id INTEGER)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER   -- la llama rest.carta, que lee también el portal sin sesión
SET search_path TO 'core', 'public'
AS $$
    SELECT MIN(p.precio)
      FROM core.productos p
      JOIN core.insumos i ON i.id = p_insumo_id AND i.empresa_id = p.empresa_id
     WHERE p.activo
       AND EXISTS (SELECT 1 FROM core.producto_insumos x
                    WHERE x.producto_id = p.id AND x.insumo_id = p_insumo_id AND x.cantidad = 1)
       AND NOT EXISTS (SELECT 1 FROM core.producto_insumos x
                        WHERE x.producto_id = p.id AND x.insumo_id <> p_insumo_id);
$$;

/* Lo que cuesta de más cambiar «de» por «a» en una receta que gasta
   p_cantidad. Nunca negativo; sin precio con qué comparar, 0. */
CREATE OR REPLACE FUNCTION core.fn_diferencia_cambio(p_de INTEGER, p_a INTEGER, p_cantidad NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $$
    SELECT CASE WHEN p_de = p_a THEN 0
                ELSE COALESCE(GREATEST(core.fn_precio_suelto(p_a) - core.fn_precio_suelto(p_de), 0)
                              * COALESCE(p_cantidad, 1), 0)
           END;
$$;

/* Como core.fn_item_dado_de_baja: las usa una vista que leen la aplicación
   y el portal, así que los dos roles las pueden ejecutar. */
REVOKE ALL ON FUNCTION core.fn_precio_suelto(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION core.fn_diferencia_cambio(INTEGER, INTEGER, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_precio_suelto(INTEGER) TO taseca_app, taseca_anon;
GRANT EXECUTE ON FUNCTION core.fn_diferencia_cambio(INTEGER, INTEGER, NUMERIC) TO taseca_app, taseca_anon;

/* El trigger de la 58, ahora también pone la diferencia (la calcula la
   base; un recargo que venga en el INSERT se ignora). */
CREATE OR REPLACE FUNCTION core.tg_item_cambios_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'core', 'public'
AS $$
DECLARE
    v_producto INTEGER;
    v_empresa  INTEGER;
    v_grupo    TEXT;
    v_cantidad NUMERIC;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Lo elegido en una venta no se modifica.' USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    SELECT it.producto_id, p.empresa_id INTO v_producto, v_empresa
      FROM core.pedido_items it JOIN core.pedidos p ON p.id = it.pedido_id
     WHERE it.id = NEW.pedido_item_id;

    SELECT NULLIF(trim(i.grupo_cambio), ''), pi.cantidad INTO v_grupo, v_cantidad
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

    -- (59) La diferencia de precio la pone la base
    NEW.recargo := core.fn_diferencia_cambio(NEW.insumo_original_id, NEW.insumo_elegido_id, v_cantidad);
    RETURN NEW;
END;
$$;

/* Guarda lo elegido y sube el precio del renglón con las diferencias.
   Se llama una vez, al crear el renglón (el pedido todavía es «nuevo»). */
CREATE OR REPLACE FUNCTION core.fn_guardar_cambios_item(p_item BIGINT, p_cambios JSONB)
RETURNS VOID
LANGUAGE plpgsql
SET search_path TO 'core', 'public'
AS $$
DECLARE
    v_extra NUMERIC;
BEGIN
    IF p_cambios IS NULL OR jsonb_typeof(p_cambios) <> 'array' THEN
        RETURN;
    END IF;
    INSERT INTO core.pedido_item_cambios (pedido_item_id, insumo_original_id, insumo_elegido_id)
    SELECT p_item, (c ->> 'de')::INTEGER, (c ->> 'a')::INTEGER
      FROM jsonb_array_elements(p_cambios) c
     WHERE NULLIF(c ->> 'de', '') IS NOT NULL AND NULLIF(c ->> 'a', '') IS NOT NULL
    ON CONFLICT (pedido_item_id, insumo_original_id) DO NOTHING;

    -- (59) El combo con Coca-Cola cuesta la diferencia de más
    SELECT COALESCE(SUM(recargo), 0) INTO v_extra FROM core.pedido_item_cambios WHERE pedido_item_id = p_item;
    IF v_extra > 0 THEN
        UPDATE core.pedido_items SET precio_unitario = precio_unitario + v_extra WHERE id = p_item;
    END IF;
END;
$$;

/* La carta: cada opción con su "extra" (la de la receta, 0). */
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
       (la de la receta primero). Sólo si hay de verdad entre qué elegir.
       (59) Cada opción con lo que cuesta de más. */
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('de', i.id, 'grupo', trim(i.grupo_cambio), 'opciones', ops.lista) ORDER BY i.grupo_cambio, i.id)
           FROM core.producto_insumos pi
             JOIN core.insumos i ON i.id = pi.insumo_id
             CROSS JOIN LATERAL ( SELECT jsonb_agg(jsonb_build_object('id', a.id, 'nombre', a.nombre,
                                                   'extra', core.fn_diferencia_cambio(i.id, a.id, pi.cantidad)) ORDER BY (a.id <> i.id), a.nombre) AS lista,
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
