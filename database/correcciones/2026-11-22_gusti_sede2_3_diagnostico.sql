/* ============================================================================
   GUSTI BROASTER · SEDE 2 · PASO 3: DIAGNÓSTICO (solo lectura)
   ----------------------------------------------------------------------------
   Error del editor de stock (corregido en js/remoto.js): al guardar un
   producto que está en las dos sedes, el «stock actual» y el «stock mínimo»
   se escribían en LAS DOS, no sólo en la que se estaba mirando.

   Esta consulta lista los productos que GUSTI BROASTER 2 (unidad 22) comparte
   con la Sede principal (unidad 21), con los números de cada sede y lo que la
   sede 2 ha movido de verdad (entradas vigentes y conteos).

     · stock_s2 > 0 sin entradas ni conteos en la sede 2  → casi seguro copiado
     · stock_s2 = entradas_s2                              → está bien
   ============================================================================ */
SELECT i.codigo, i.nombre AS producto,
       s1.stock_actual AS stock_s1,  s2.stock_actual AS stock_s2,
       s1.stock_minimo AS minimo_s1, s2.stock_minimo AS minimo_s2,
       COALESCE((SELECT sum(en.cantidad) FROM core.entradas_inventario en
                  WHERE en.insumo_unidad_id = s2.id AND en.anulada_en IS NULL), 0) AS entradas_s2,
       (SELECT count(*) FROM core.cierre_detalles d WHERE d.insumo_unidad_id = s2.id) AS conteos_s2,
       s2.actualizado_en AT TIME ZONE 'America/Bogota' AS s2_modificado,
       s2.id AS insumo_unidad_id_s2
  FROM core.insumos i
  JOIN core.insumo_unidades s2 ON s2.insumo_id = i.id AND s2.unidad_id = 22
  LEFT JOIN core.insumo_unidades s1 ON s1.insumo_id = i.id AND s1.unidad_id = 21
 WHERE i.empresa_id = 15
   AND (s2.stock_actual > 0 OR s2.stock_minimo > 0)
 ORDER BY s2.actualizado_en DESC, i.codigo;
