/* ============================================================================
   GUSTI BROASTER · Coca-Cola 1.5 L · PASO 1: DIAGNÓSTICO (solo lectura)
   ----------------------------------------------------------------------------
   No cambia nada. Se ejecuta en Supabase → SQL Editor, una consulta a la vez,
   y con lo que salga se llenan los datos del PASO 2.

   Si el nombre del producto o de la empresa no coincide, ajusta los filtros
   ILIKE de abajo.
   ============================================================================ */

-- 1) La empresa, sus sedes y el producto en cada sede ---------------------------
--    Anota: insumo_unidad_id de la sede que hizo el cierre.
SELECT e.id   AS empresa_id, e.nombre_comercial,
       u.id   AS unidad_id,  u.nombre AS sede,
       iu.id  AS insumo_unidad_id,
       i.codigo, i.nombre AS producto, a.codigo AS area,
       iu.stock_actual AS stock_del_editor
  FROM core.empresas e
  JOIN core.unidades u         ON u.empresa_id = e.id
  JOIN core.insumo_unidades iu ON iu.unidad_id = u.id
  JOIN core.insumos i          ON i.id = iu.insumo_id
  JOIN core.areas_inventario a ON a.id = i.area_id
 WHERE e.nombre_comercial ILIKE '%gusti%'
   AND i.nombre ILIKE '%coca%'
 ORDER BY u.nombre, i.nombre;


-- 2) Los últimos conteos de ese producto ----------------------------------------
--    Anota: cierre_id del día que se equivocaron (saldo_contado = el número malo).
SELECT c.id AS cierre_id, c.fecha_operativa, u.nombre AS sede, ec.codigo AS estado,
       c.aplicado_a_stock, i.nombre AS producto, d.saldo_fisico AS saldo_contado,
       c.observacion
  FROM core.cierre_detalles d
  JOIN core.cierres_inventario c ON c.id = d.cierre_id
  JOIN core.estados_cierre ec    ON ec.id = c.estado_cierre_id
  JOIN core.insumo_unidades iu   ON iu.id = d.insumo_unidad_id
  JOIN core.insumos i            ON i.id = iu.insumo_id
  JOIN core.unidades u           ON u.id = iu.unidad_id
  JOIN core.empresas e           ON e.id = u.empresa_id
 WHERE e.nombre_comercial ILIKE '%gusti%'
   AND i.nombre ILIKE '%coca%'
 ORDER BY c.fecha_operativa DESC
 LIMIT 15;


-- 3) Las entradas recientes de ese producto -------------------------------------
--    Anota: entrada_id de la(s) entrada(s) que se hicieron para "corregir".
SELECT en.id AS entrada_id, en.fecha_operativa, u.nombre AS sede, i.nombre AS producto,
       te.codigo AS tipo, en.cantidad, en.observacion, us.nombre AS registrada_por,
       en.creado_en, en.anulada_en
  FROM core.entradas_inventario en
  JOIN core.tipos_entrada te   ON te.id = en.tipo_entrada_id
  JOIN core.insumo_unidades iu ON iu.id = en.insumo_unidad_id
  JOIN core.insumos i          ON i.id = iu.insumo_id
  JOIN core.unidades u         ON u.id = iu.unidad_id
  JOIN core.empresas e         ON e.id = u.empresa_id
  LEFT JOIN core.usuarios us   ON us.id = en.usuario_id
 WHERE e.nombre_comercial ILIKE '%gusti%'
   AND i.nombre ILIKE '%coca%'
 ORDER BY en.creado_en DESC
 LIMIT 15;
