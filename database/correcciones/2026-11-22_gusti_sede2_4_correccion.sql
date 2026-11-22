/* ============================================================================
   GUSTI BROASTER · SEDE 2 · PASO 4: CORRECCIÓN
   ----------------------------------------------------------------------------
   Deshace lo que el error del editor copió de la Sede principal (21) en
   GUSTI BROASTER 2 (22), que no ha cargado inventario:

     · stock_minimo  → 0
     · stock_actual  → lo que sumen las entradas vigentes de la sede 2
                       (0 si no tiene ninguna). Es lo que valdría si nunca
                       se hubiera tocado a mano: cada entrada le suma.

   Sólo productos que la sede 2 NUNCA ha contado en un cierre: los que ya
   tienen conteo no se tocan (ahí manda el conteo, y alguien lo hizo a
   propósito). Todo o nada.

   ANTES: ejecuta el PASO 3 para ver qué va a cambiar.
   ============================================================================ */

DO $$
DECLARE
    v_n INTEGER;
BEGIN
    IF (SELECT empresa_id FROM core.unidades WHERE id = 22) IS DISTINCT FROM 15 THEN
        RAISE EXCEPTION 'La unidad 22 no es de GUSTI BROASTER (empresa 15). No se toca nada.';
    END IF;

    UPDATE core.insumo_unidades iu
       SET stock_minimo = 0,
           stock_actual = COALESCE((SELECT sum(en.cantidad) FROM core.entradas_inventario en
                                     WHERE en.insumo_unidad_id = iu.id AND en.anulada_en IS NULL), 0),
           actualizado_en = now()
     WHERE iu.unidad_id = 22
       AND (iu.stock_actual > 0 OR iu.stock_minimo > 0)
       AND NOT EXISTS (SELECT 1 FROM core.cierre_detalles d WHERE d.insumo_unidad_id = iu.id);
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RAISE NOTICE 'Listo · GUSTI BROASTER 2: % productos devueltos a stock 0 (o sus entradas) y mínimo 0.', v_n;
END;
$$;


/* ---- Verificación -----------------------------------------------------------
   Vuelve a ejecutar el PASO 3. Sólo deberían quedar productos con conteos en
   la sede 2 o con entradas propias (stock_s2 = entradas_s2, mínimo 0). */
