/* ============================================================================
   60 · GRUPOS DE CAMBIO ADMINISTRABLES (sobre la 58 y la 59)

   Lo que pidió el cliente: que el grupo no se escriba a mano en cada
   insumo, donde un «Gaseosa 1.5» y un «Gaseosa 1,5» serían dos grupos
   distintos sin que nadie lo note, y que en Stock se vean y se manejen
   los grupos.

   El grupo sigue siendo el nombre en core.insumos.grupo_cambio: no hace
   falta otra tabla, y la 58 y la 59 no cambian. Lo nuevo:

     · rest.guardar_grupo_cambio: crea, renombra o cambia los integrantes
       de un grupo de un solo golpe. Sin integrantes, el grupo desaparece.
     · rest.guardar_insumo: si el nombre que llega ya existe con otras
       mayúsculas o espacios, guarda el que ya existe. Así nunca nacen dos
       grupos que en pantalla parecen uno.

   Idempotente. Requiere la 58.
   ============================================================================ */

SET search_path = core, public;

CREATE OR REPLACE FUNCTION rest.guardar_grupo_cambio(p_grupo JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_nombre   TEXT    := regexp_replace(trim(COALESCE(p_grupo ->> 'nombre', '')), '\s+', ' ', 'g');
    v_anterior TEXT    := NULLIF(regexp_replace(trim(COALESCE(p_grupo ->> 'anterior', '')), '\s+', ' ', 'g'), '');
    v_insumos  INTEGER[];
    v_otro     TEXT;
BEGIN
    PERFORM core.fn_preparar_operacion(v_usuario, 'stock');
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'Tu sesión no pertenece a una empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF length(v_nombre) < 2 OR length(v_nombre) > 40 THEN
        RAISE EXCEPTION 'El grupo necesita un nombre de 2 a 40 letras (por ejemplo «Gaseosa 1.5»).';
    END IF;

    v_insumos := ARRAY(SELECT DISTINCT x::INTEGER FROM jsonb_array_elements_text(COALESCE(p_grupo -> 'insumos', '[]')) x);
    IF EXISTS (SELECT 1 FROM unnest(v_insumos) x
                WHERE NOT EXISTS (SELECT 1 FROM core.insumos i WHERE i.id = x AND i.empresa_id = v_empresa)) THEN
        RAISE EXCEPTION 'Uno de los productos de stock no existe. Recarga la página.';
    END IF;

    -- Otro grupo con ese nombre (sin contar éste, si se está renombrando)
    SELECT grupo_cambio INTO v_otro FROM core.insumos
     WHERE empresa_id = v_empresa AND lower(regexp_replace(trim(grupo_cambio), '\s+', ' ', 'g')) = lower(v_nombre)
       AND (v_anterior IS NULL OR lower(regexp_replace(trim(grupo_cambio), '\s+', ' ', 'g')) <> lower(v_anterior))
     LIMIT 1;
    IF v_otro IS NOT NULL THEN
        RAISE EXCEPTION 'Ya hay un grupo «%». Edítalo en vez de crear otro.', v_otro;
    END IF;

    -- Los que salen del grupo (o todos, si el grupo se quita)
    UPDATE core.insumos
       SET grupo_cambio = NULL
     WHERE empresa_id = v_empresa
       AND lower(regexp_replace(trim(grupo_cambio), '\s+', ' ', 'g')) = lower(COALESCE(v_anterior, v_nombre))
       AND id <> ALL (v_insumos);

    -- Los que quedan, con el nombre nuevo (un insumo está en un solo grupo)
    UPDATE core.insumos
       SET grupo_cambio = v_nombre
     WHERE empresa_id = v_empresa AND id = ANY (v_insumos)
       AND grupo_cambio IS DISTINCT FROM v_nombre;

    RETURN jsonb_build_object('nombre', v_nombre, 'insumos', to_jsonb(v_insumos));
END;
$$;

REVOKE ALL ON FUNCTION rest.guardar_grupo_cambio(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.guardar_grupo_cambio(JSONB) TO taseca_app;

/* rest.guardar_insumo: la de la 58, con el nombre del grupo llevado al
   que ya existe (mismas letras, otras mayúsculas o espacios). */
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
    v_grupo     TEXT;
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

    -- (58) El grupo de cambio: sólo si viene; vacío lo quita.
    -- (60) Si ya existe con otras mayúsculas o espacios, se usa el que existe.
    IF p_insumo ? 'grupo_cambio' THEN
        v_grupo := NULLIF(regexp_replace(trim(p_insumo ->> 'grupo_cambio'), '\s+', ' ', 'g'), '');
        IF v_grupo IS NOT NULL THEN
            -- El que ya existe: el escrito igual si lo hay; si no, el más usado
            v_grupo := COALESCE((SELECT x.g
                                   FROM (SELECT regexp_replace(trim(grupo_cambio), '\s+', ' ', 'g') AS g
                                           FROM core.insumos
                                          WHERE empresa_id = v_empresa AND id <> v_id
                                            AND lower(regexp_replace(trim(grupo_cambio), '\s+', ' ', 'g')) = lower(v_grupo)) x
                                  GROUP BY x.g
                                  ORDER BY (x.g = v_grupo) DESC, count(*) DESC, x.g
                                  LIMIT 1), v_grupo);
        END IF;
        UPDATE core.insumos
           SET grupo_cambio = v_grupo
         WHERE id = v_id AND empresa_id = v_empresa
           AND grupo_cambio IS DISTINCT FROM v_grupo;
    END IF;

    RETURN jsonb_build_object('insumo_id', v_id);
END;
$function$;
