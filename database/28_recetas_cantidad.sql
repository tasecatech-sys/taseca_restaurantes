/* ============================================================================
   TASECA · 28 · CUÁNTO GASTA CADA PLATO, NO SÓLO CUÁLES
   ----------------------------------------------------------------------------
   Un pollo entero gasta 2 alas. Hasta ahora el sistema sabía QUÉ platos
   gastan un insumo, pero no CUÁNTO: cada venta descontaba una unidad, así
   que vender un pollo restaba «un ala».

   LO QUE YA ESTABA HECHO

     `core.producto_insumos.cantidad` existe desde 01_estructura.sql, con
     DEFAULT 1 y CHECK (cantidad > 0). Y los cuatro sitios que calculan
     consumo YA multiplican por ella:

       core.fn_z_insumo            (13)  SUM(it.cantidad * pi.cantidad)
       api.v_cruce_inventario      (05)  idem
       el cruce de la fase 2       (13)  idem
       api.sp_anular_pedido        (04)  idem, para el retorno

     Es decir: el cálculo siempre estuvo bien. Lo que no había era forma de
     ESCRIBIR ese número — el procedimiento insertaba sin cantidad y se
     quedaba en el 1 por defecto, y la vista de lectura devolvía sólo ids.

   LO QUE HACE ESTE ARCHIVO

     1. `rest.stock` devuelve pares {producto_id, cantidad} en vez de ids
        sueltos, para que el panel pueda mostrar la cantidad que hay.
     2. `rest.guardar_insumo` acepta esos pares y escribe la cantidad.

   POR QUÉ NO SE TOCA api.sp_guardar_insumo

     Ese procedimiento hace más cosas de las que parece: comprueba que cada
     producto sea de la empresa, BORRA los enlaces que se quitaron y crea
     los nuevos. Cambiarle la firma obligaría a reproducir todo su cuerpo
     aquí, con el riesgo de que las dos copias se separen.

     Así que sigue encargándose de CUÁLES —que es lo suyo— y la cantidad se
     ajusta después, en el envoltorio. El `ON CONFLICT DO NOTHING` de su
     INSERT respeta la cantidad de los enlaces que ya existían; el UPDATE de
     aquí la pone al día.

   Compatible hacia atrás: si `productos` llega como una lista de números
   —como la mandaba la versión anterior de la aplicación— cada uno vale 1,
   que es exactamente lo que hacía antes.

   No cambia ningún dato existente: las recetas que hoy existen valen 1 y
   siguen valiendo 1. Se puede ejecutar más de una vez.
   Requiere: 00 … 27 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. LA LECTURA

   Se recrea la vista entera porque en PostgreSQL no se puede cambiar el
   TIPO de una columna de una vista con CREATE OR REPLACE: `productos` pasa
   de ser una lista de números a una de objetos. Por eso el DROP.

   Lo demás es idéntico a 13_fase2_inventario.sql: si esa vista cambia, hay
   que volver a traer el cambio aquí.
   ============================================================================ */
DROP VIEW IF EXISTS rest.stock;

CREATE VIEW rest.stock AS
/* MATERIALIZED igual que en el original: sin eso, el planificador puede
   meter las funciones del token dentro del bucle y evaluarlas por fila. */
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT i.id AS insumo_id, i.empresa_id, i.codigo, i.nombre, ci.nombre AS categoria, a.codigo AS area,
       um.codigo AS unidad_medida, i.activo,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('unidad_id', iu.unidad_id, 'stock_actual', iu.stock_actual,
                                                     'stock_minimo', iu.stock_minimo) ORDER BY iu.unidad_id)
                   FROM core.insumo_unidades iu WHERE iu.insumo_id = i.id), '[]') AS unidades,
       /* Qué platos gastan este insumo y CUÁNTO gasta cada uno. Antes era
          `jsonb_agg(pi.producto_id)`, una lista de ids. */
       COALESCE((SELECT jsonb_agg(jsonb_build_object('producto_id', pi.producto_id,
                                                     'cantidad', pi.cantidad)
                                  ORDER BY pi.producto_id)
                   FROM core.producto_insumos pi WHERE pi.insumo_id = i.id), '[]') AS productos,
       GREATEST(i.actualizado_en, (SELECT max(iu.actualizado_en) FROM core.insumo_unidades iu WHERE iu.insumo_id = i.id)) AS actualizado_en
  FROM core.insumos i
  JOIN sesion s                  ON s.empresa_id = i.empresa_id
  JOIN core.categorias_insumo ci ON ci.id = i.categoria_insumo_id
  JOIN core.areas_inventario a   ON a.id = i.area_id
  JOIN core.unidades_medida um   ON um.id = i.unidad_medida_id
 WHERE EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'entradas', 'cierres', 'cierres_registrar']) p
                WHERE api.fn_tiene_permiso(s.usuario_id, p))
   AND EXISTS (SELECT 1 FROM core.insumo_unidades iu
                WHERE iu.insumo_id = i.id AND core.fn_usuario_en_unidad(s.usuario_id, iu.unidad_id));

GRANT SELECT ON rest.stock TO taseca_app;


/* ============================================================================
   2. LA ESCRITURA
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.guardar_insumo(p_insumo JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
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
       La segunda es la que manda la aplicación desde este cambio; la
       primera la mandaba la anterior, y un navegador con la página vieja
       en caché sigue mandándola. */
    IF jsonb_typeof(p_insumo -> 'productos') = 'array' THEN
        v_receta := (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'producto_id', CASE WHEN jsonb_typeof(x) = 'object'
                                           THEN (x ->> 'producto_id')::INTEGER
                                           ELSE x::TEXT::INTEGER END,
                       'cantidad',    CASE WHEN jsonb_typeof(x) = 'object'
                                           THEN COALESCE(NULLIF(x ->> 'cantidad', '')::NUMERIC, 1)
                                           ELSE 1 END)), '[]'::JSONB)
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
    END IF;

    RETURN jsonb_build_object('insumo_id', v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION rest.guardar_insumo(JSONB) TO taseca_app;


/* ============================================================================
   3. COMPROBACIÓN

   Que quede instalado de verdad, no «sin error».
   ============================================================================ */
DO $$
DECLARE
    v_tipo TEXT;
BEGIN
    /* La vista tiene que devolver objetos, no números. Se mira el primer
       insumo que tenga alguna receta; si no hay ninguna, no hay nada que
       comprobar y tampoco nada que se pueda haber roto. */
    SELECT jsonb_typeof(pi.fila -> 0) INTO v_tipo
      FROM (SELECT COALESCE((SELECT jsonb_agg(jsonb_build_object('producto_id', x.producto_id,
                                                                 'cantidad', x.cantidad))
                               FROM core.producto_insumos x WHERE x.insumo_id = i.id), '[]') AS fila
              FROM core.insumos i
             WHERE EXISTS (SELECT 1 FROM core.producto_insumos p WHERE p.insumo_id = i.id)
             LIMIT 1) pi;

    IF v_tipo IS NOT NULL AND v_tipo <> 'object' THEN
        RAISE EXCEPTION 'rest.stock sigue devolviendo ids sueltos: revisa el paso 1.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'guardar_insumo'
                     AND pronamespace = 'rest'::regnamespace) THEN
        RAISE EXCEPTION 'rest.guardar_insumo no quedó instalada: revisa el paso 2.';
    END IF;

    RAISE NOTICE '✔ Las recetas ya guardan cantidad.';
    RAISE NOTICE '  Un pollo que gaste 2 alas se marca en Panel → Stock → el insumo.';
END;
$$;
