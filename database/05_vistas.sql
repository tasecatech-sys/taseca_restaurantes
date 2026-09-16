/* ============================================================================
   TASECA · 05 · VISTAS (esquema api)
   ----------------------------------------------------------------------------
   Toda lectura de la aplicación sale de aquí. La vista resuelve los joins,
   los nombres de catálogo y los cálculos (subtotal, total, vendidos, cruce):
   la aplicación sólo filtra por empresa_id / unidad_id / fecha.

   · Lo calculado NO se guarda (3FN): subtotal, total, cupos restantes, IN,
     EN y Z del cruce se derivan cada vez de los datos fuente.
   · Los reportes pesados tienen además una VISTA MATERIALIZADA que se
     refresca con api.sp_refrescar_reportes() (p. ej. cada noche).
   · Ninguna vista expone el hash del PIN.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. EMPRESA Y CONFIGURACIÓN
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_empresas AS
SELECT e.id AS empresa_id, e.codigo, e.nombre_comercial, e.razon_social, e.nit, e.eslogan,
       e.descripcion, e.estado, e.zona_horaria, e.hora_corte_operativa,
       e.telefono, e.whatsapp, e.email, e.direccion, e.horario_general,
       e.instagram_url, e.facebook_url, e.tiempo_mesa, e.tiempo_domicilio,
       e.color_primario, e.color_secundario, e.color_acento, e.color_fondo, e.logo_url,
       core.fn_fecha_operativa(e.id, now()) AS jornada_actual,
       (SELECT count(*) FROM core.unidades u WHERE u.empresa_id = e.id AND u.estado = 'activa') AS unidades_activas,
       e.creado_en, e.actualizado_en
  FROM core.empresas e;

CREATE OR REPLACE VIEW api.v_empresa_modulos AS
SELECT e.id AS empresa_id, e.nombre_comercial AS empresa, m.id AS modulo_id, m.codigo AS modulo,
       m.nombre, m.obligatorio,
       COALESCE(em.activo, FALSE) OR m.obligatorio AS activo
  FROM core.empresas e
 CROSS JOIN core.modulos m
  LEFT JOIN core.empresa_modulos em ON em.empresa_id = e.id AND em.modulo_id = m.id;

CREATE OR REPLACE VIEW api.v_metodos_pago AS
SELECT emp.empresa_id, mp.id AS metodo_pago_id, mp.codigo, mp.nombre, mp.grupo_caja,
       emp.descripcion, emp.activo, emp.orden
  FROM core.empresa_metodos_pago emp
  JOIN core.metodos_pago mp ON mp.id = emp.metodo_pago_id;

CREATE OR REPLACE VIEW api.v_cuentas_recaudo AS
SELECT id AS cuenta_id, empresa_id, entidad, tipo_cuenta, numero, titular, activa
  FROM core.cuentas_recaudo;


/* ============================================================================
   2. UNIDADES, MESAS, ZONAS
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_unidades AS
SELECT u.id AS unidad_id, u.empresa_id, e.nombre_comercial AS empresa,
       u.nombre, u.nombre_corto, u.estado, (u.estado = 'activa') AS activa,
       t.codigo AS tipo_negocio, t.nombre AS tipo_negocio_nombre, t.icono AS tipo_negocio_icono,
       u.direccion, u.ciudad, u.telefono, u.whatsapp, u.horario, u.mapa_url, u.color, u.logo_url,
       (SELECT count(*) FROM core.mesas m WHERE m.unidad_id = u.id AND m.activa)                AS mesas,
       (SELECT count(*) FROM core.producto_unidades pu WHERE pu.unidad_id = u.id)               AS productos_carta,
       (SELECT count(*) FROM core.insumo_unidades iu WHERE iu.unidad_id = u.id)                 AS insumos_inventario,
       EXISTS (SELECT 1 FROM core.zonas_domicilio z WHERE z.unidad_id = u.id AND z.activa)      AS tiene_zonas,
       u.creado_en, u.actualizado_en
  FROM core.unidades u
  JOIN core.empresas e      ON e.id = u.empresa_id
  JOIN core.tipos_negocio t ON t.id = u.tipo_negocio_id;

CREATE OR REPLACE VIEW api.v_mesas AS
SELECT m.id AS mesa_id, m.unidad_id, u.empresa_id, u.nombre AS unidad, m.numero, m.activa
  FROM core.mesas m
  JOIN core.unidades u ON u.id = m.unidad_id;

CREATE OR REPLACE VIEW api.v_zonas_domicilio AS
SELECT z.id AS zona_id, z.unidad_id, u.empresa_id, z.nombre, z.costo, z.pedido_minimo, z.activa
  FROM core.zonas_domicilio z
  JOIN core.unidades u ON u.id = z.unidad_id;


/* ============================================================================
   3. USUARIOS Y PERMISOS
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_usuarios AS
SELECT us.id AS usuario_id, us.empresa_id, e.nombre_comercial AS empresa,
       us.nombre, us.usuario, r.codigo AS rol, r.nombre AS rol_nombre, r.alcance,
       us.activo, us.ultimo_acceso,
       COALESCE((SELECT array_agg(uu.unidad_id ORDER BY uu.unidad_id)
                   FROM core.usuario_unidades uu WHERE uu.usuario_id = us.id), '{}') AS unidades_asignadas,
       NOT EXISTS (SELECT 1 FROM core.usuario_unidades uu WHERE uu.usuario_id = us.id) AS todas_las_unidades,
       us.creado_en
  FROM core.usuarios us
  JOIN core.roles r ON r.id = us.rol_id
  LEFT JOIN core.empresas e ON e.id = us.empresa_id;

/* Los permisos EFECTIVOS: los del rol, filtrados por los módulos que tiene
   la empresa. Es lo que la aplicación consulta para mostrar u ocultar. */
CREATE OR REPLACE VIEW api.v_permisos_usuario AS
SELECT us.id AS usuario_id, us.empresa_id, p.codigo AS permiso, p.descripcion, m.codigo AS modulo
  FROM core.usuarios us
  JOIN core.roles r         ON r.id = us.rol_id
  JOIN core.rol_permisos rp ON rp.rol_id = r.id
  JOIN core.permisos p      ON p.id = rp.permiso_id
  LEFT JOIN core.modulos m  ON m.id = p.modulo_id
 WHERE us.activo
   AND (r.alcance = 'plataforma' OR m.id IS NULL OR core.fn_empresa_tiene_modulo(us.empresa_id, m.codigo));

CREATE OR REPLACE VIEW api.v_roles AS
SELECT r.id AS rol_id, r.codigo, r.nombre, r.descripcion, r.alcance, r.icono,
       array_agg(p.codigo ORDER BY p.codigo) FILTER (WHERE p.id IS NOT NULL) AS permisos
  FROM core.roles r
  LEFT JOIN core.rol_permisos rp ON rp.rol_id = r.id
  LEFT JOIN core.permisos p      ON p.id = rp.permiso_id
 GROUP BY r.id;


/* ============================================================================
   4. CARTA
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_categorias AS
SELECT c.id AS categoria_id, cu.unidad_id, c.empresa_id, c.nombre, c.icono, c.orden, c.activa,
       (SELECT count(*) FROM core.productos p
          JOIN core.producto_unidades pu ON pu.producto_id = p.id AND pu.unidad_id = cu.unidad_id
         WHERE p.categoria_id = c.id AND p.activo) AS productos_activos
  FROM core.categorias c
  JOIN core.categoria_unidades cu ON cu.categoria_id = c.id;

/* Una fila por producto y unidad que lo vende. `disponible` es lo que el
   portal usa para mostrar "+ Agregar" o "Agotado". */
CREATE OR REPLACE VIEW api.v_carta AS
SELECT p.id AS producto_id, pu.unidad_id, p.empresa_id, u.nombre AS unidad,
       c.id AS categoria_id, c.nombre AS categoria, c.icono AS categoria_icono, c.orden AS categoria_orden,
       p.codigo, p.nombre, p.descripcion, p.precio, p.imagen_url, p.orden,
       et.codigo AS etiqueta, et.nombre AS etiqueta_nombre,
       p.activo, pu.agotado,
       (p.activo AND c.activa AND NOT pu.agotado AND u.estado = 'activa') AS disponible,
       (p.precio = 0) AS sin_precio
  FROM core.productos p
  JOIN core.producto_unidades pu ON pu.producto_id = p.id
  JOIN core.unidades u           ON u.id = pu.unidad_id
  JOIN core.categorias c         ON c.id = p.categoria_id
  LEFT JOIN core.etiquetas_producto et ON et.id = p.etiqueta_id;


/* ============================================================================
   5. MENÚ DEL DÍA
   ============================================================================ */

/* Cabecera del menú con el texto público ya resuelto:
   el de la fecha → el de la unidad → el de fábrica. */
CREATE OR REPLACE VIEW api.v_menu_dia AS
SELECT m.id AS menu_dia_id, m.unidad_id, u.empresa_id, u.nombre AS unidad, m.fecha,
       t.codigo AS tipo, t.nombre AS tipo_nombre,
       m.nombre, m.descripcion, m.precio, m.disponible,
       COALESCE(m.titulo_publico, tx.titulo, 'Menú del día')                          AS titulo_publico,
       COALESCE(m.mensaje_publico, tx.mensaje, 'Consulta las opciones disponibles para hoy.') AS mensaje_publico,
       CASE WHEN m.titulo_publico IS NOT NULL THEN 'fecha'
            WHEN tx.titulo IS NOT NULL THEN 'unidad' ELSE 'defecto' END                AS origen_texto,
       CASE
           WHEN NOT m.disponible THEN FALSE
           WHEN t.codigo = 'armado' THEN m.precio IS NOT NULL AND EXISTS (
                SELECT 1 FROM core.menu_categorias c JOIN core.menu_opciones o ON o.menu_categoria_id = c.id
                 WHERE c.menu_dia_id = m.id AND c.activa AND o.activa)
           ELSE EXISTS (SELECT 1 FROM core.platos_dia pd WHERE pd.menu_dia_id = m.id AND pd.disponible)
       END AS publicado,
       m.creado_en, m.actualizado_en
  FROM core.menus_dia m
  JOIN core.unidades u   ON u.id = m.unidad_id
  JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
  LEFT JOIN core.textos_menu_unidad tx ON tx.unidad_id = m.unidad_id;

CREATE OR REPLACE VIEW api.v_menu_opciones AS
SELECT c.menu_dia_id, m.unidad_id, m.fecha,
       c.id AS categoria_id, c.nombre AS categoria, c.icono, c.orden AS categoria_orden,
       c.obligatoria, c.max_seleccion, c.activa AS categoria_activa,
       CASE WHEN c.max_seleccion > 1 THEN 'Elige hasta ' || c.max_seleccion ELSE 'Elige 1' END ||
       CASE WHEN c.obligatoria THEN ' · Obligatorio' ELSE ' · Opcional' END AS regla,
       o.id AS opcion_id, o.nombre AS opcion, o.orden AS opcion_orden, o.activa AS opcion_activa
  FROM core.menu_categorias c
  JOIN core.menus_dia m ON m.id = c.menu_dia_id
  LEFT JOIN core.menu_opciones o ON o.menu_categoria_id = c.id;

CREATE OR REPLACE VIEW api.v_platos_dia AS
SELECT pd.id AS plato_dia_id, pd.menu_dia_id, m.unidad_id, m.fecha,
       pd.nombre, pd.descripcion, pd.emoji, pd.precio, pd.cupos, pd.disponible, pd.orden,
       core.fn_vendidos_plato(pd.id) AS vendidos,
       CASE WHEN pd.cupos IS NULL THEN NULL ELSE GREATEST(pd.cupos - core.fn_vendidos_plato(pd.id), 0) END AS cupos_restantes,
       (pd.disponible AND m.disponible
        AND (pd.cupos IS NULL OR core.fn_vendidos_plato(pd.id) < pd.cupos)) AS se_puede_pedir
  FROM core.platos_dia pd
  JOIN core.menus_dia m ON m.id = pd.menu_dia_id;

/* El menú completo de una unidad y fecha en UN documento JSON: lo que el
   portal necesita para pintar en una sola consulta. */
CREATE OR REPLACE VIEW api.v_menu_publico AS
SELECT md.unidad_id, md.unidad, md.empresa_id, md.fecha, md.tipo, md.publicado,
       md.titulo_publico, md.mensaje_publico,
       jsonb_build_object(
           'menu_dia_id', md.menu_dia_id,
           'tipo', md.tipo,
           'nombre', md.nombre,
           'descripcion', md.descripcion,
           'precio', md.precio,
           'categorias', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'categoria_id', c.id, 'nombre', c.nombre, 'icono', c.icono,
                          'obligatoria', c.obligatoria, 'max_seleccion', c.max_seleccion,
                          'opciones', (SELECT COALESCE(jsonb_agg(jsonb_build_object('opcion_id', o.id, 'nombre', o.nombre)
                                                                 ORDER BY o.orden), '[]')
                                         FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id AND o.activa))
                      ORDER BY c.orden)
                 FROM core.menu_categorias c
                WHERE c.menu_dia_id = md.menu_dia_id AND c.activa
                  AND EXISTS (SELECT 1 FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id AND o.activa)
           ), '[]'),
           'platos', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'plato_dia_id', p.plato_dia_id, 'nombre', p.nombre, 'descripcion', p.descripcion,
                          'emoji', p.emoji, 'precio', p.precio, 'cupos_restantes', p.cupos_restantes,
                          'se_puede_pedir', p.se_puede_pedir)
                      ORDER BY p.orden)
                 FROM api.v_platos_dia p
                WHERE p.menu_dia_id = md.menu_dia_id AND p.disponible
           ), '[]')
       ) AS menu
  FROM api.v_menu_dia md;


/* ============================================================================
   6. PEDIDOS / FACTURAS
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_pedidos AS
SELECT p.id AS pedido_id, p.empresa_id, p.unidad_id, u.nombre AS unidad, p.codigo,
       tp.codigo AS tipo, tp.nombre AS tipo_nombre,
       ep.codigo AS estado, ep.nombre AS estado_nombre, ep.orden AS estado_orden, ep.es_final,
       ep.cuenta_como_venta,
       pg.codigo AS estado_pago, pg.nombre AS estado_pago_nombre,
       mp.codigo AS metodo_pago, mp.nombre AS metodo_pago_nombre, mp.grupo_caja,
       me.numero AS mesa,
       cl.nombre AS cliente, cl.telefono AS cliente_telefono,
       p.direccion_entrega, p.indicaciones, z.nombre AS zona,
       COALESCE(it.subtotal, 0)                     AS subtotal,
       p.costo_domicilio,
       COALESCE(it.subtotal, 0) + p.costo_domicilio AS total,
       COALESCE(it.unidades, 0)                     AS productos,
       p.paga_con,
       CASE WHEN p.paga_con IS NOT NULL THEN p.paga_con - (COALESCE(it.subtotal, 0) + p.costo_domicilio) END AS cambio,
       p.fecha_operativa, p.motivo_cancelacion,
       us.nombre AS tomado_por,
       p.creado_en, p.actualizado_en
  FROM core.pedidos p
  JOIN core.unidades u        ON u.id = p.unidad_id
  JOIN core.tipos_pedido tp   ON tp.id = p.tipo_pedido_id
  JOIN core.estados_pedido ep ON ep.id = p.estado_pedido_id
  JOIN core.estados_pago pg   ON pg.id = p.estado_pago_id
  JOIN core.metodos_pago mp   ON mp.id = p.metodo_pago_id
  LEFT JOIN core.mesas me           ON me.id = p.mesa_id
  LEFT JOIN core.clientes cl        ON cl.id = p.cliente_id
  LEFT JOIN core.zonas_domicilio z  ON z.id = p.zona_domicilio_id
  LEFT JOIN core.usuarios us        ON us.id = p.tomado_por_id
  LEFT JOIN LATERAL (
        SELECT SUM(i.precio_unitario * i.cantidad) AS subtotal, SUM(i.cantidad) AS unidades
          FROM core.pedido_items i WHERE i.pedido_id = p.id
  ) it ON TRUE;

/* Líneas de la factura con el detalle del menú armado ya escrito:
   "Sopa: Sancocho · Principio: Arroz, Ensalada · Proteína: Pollo". */
CREATE OR REPLACE VIEW api.v_pedido_items AS
SELECT i.id AS pedido_item_id, i.pedido_id, p.codigo, p.unidad_id, p.fecha_operativa,
       CASE WHEN i.producto_id  IS NOT NULL THEN 'carta'
            WHEN i.plato_dia_id IS NOT NULL THEN 'chef'
            ELSE 'armado' END AS origen,
       i.producto_id, i.plato_dia_id, i.menu_dia_id,
       i.nombre, i.precio_unitario, i.cantidad, i.precio_unitario * i.cantidad AS total_linea,
       i.notas,
       (SELECT string_agg(g.categoria || ': ' || g.opciones, ' · ' ORDER BY g.orden)
          FROM (SELECT c.nombre AS categoria, c.orden,
                       string_agg(o.nombre, ', ' ORDER BY o.orden) AS opciones
                  FROM core.pedido_item_opciones x
                  JOIN core.menu_opciones o   ON o.id = x.menu_opcion_id
                  JOIN core.menu_categorias c ON c.id = o.menu_categoria_id
                 WHERE x.pedido_item_id = i.id
                 GROUP BY c.nombre, c.orden) g) AS detalle
  FROM core.pedido_items i
  JOIN core.pedidos p ON p.id = i.pedido_id;

CREATE OR REPLACE VIEW api.v_pedido_historial AS
SELECT h.id AS historial_id, h.pedido_id, p.codigo, h.descripcion,
       e.codigo AS estado, us.nombre AS usuario, h.creado_en
  FROM core.pedido_historial h
  JOIN core.pedidos p ON p.id = h.pedido_id
  LEFT JOIN core.estados_pedido e ON e.id = h.estado_pedido_id
  LEFT JOIN core.usuarios us      ON us.id = h.usuario_id;

/* Lo que ve el CLIENTE al seguir su pedido: sin teléfono, sin dirección, sin
   nada que no sea suyo de mostrar. Pasos ya calculados según el tipo. */
CREATE OR REPLACE VIEW api.v_seguimiento_pedido AS
SELECT vp.empresa_id, e.codigo AS empresa_codigo, vp.pedido_id, vp.codigo, vp.unidad,
       vp.tipo, vp.estado, vp.estado_nombre, vp.total, vp.estado_pago_nombre, vp.metodo_pago_nombre,
       (SELECT count(*) FROM core.estados_pedido x
         WHERE x.orden < 90 AND (NOT x.solo_domicilio OR vp.tipo = 'domicilio'))             AS pasos_totales,
       CASE WHEN vp.estado_orden >= 90 THEN NULL ELSE
       (SELECT count(*) FROM core.estados_pedido x
         WHERE x.orden <= vp.estado_orden AND (NOT x.solo_domicilio OR vp.tipo = 'domicilio')) END AS paso_actual,
       (SELECT jsonb_agg(jsonb_build_object('estado', x.codigo, 'nombre', x.nombre,
                                            'hecho', x.orden <= vp.estado_orden AND vp.estado_orden < 90)
                         ORDER BY x.orden)
          FROM core.estados_pedido x
         WHERE x.orden < 90 AND (NOT x.solo_domicilio OR vp.tipo = 'domicilio'))              AS pasos,
       (SELECT max(h.creado_en) FROM core.pedido_historial h WHERE h.pedido_id = vp.pedido_id) AS ultimo_cambio,
       vp.creado_en
  FROM api.v_pedidos vp
  JOIN core.empresas e ON e.id = vp.empresa_id;

/* Tablero de cocina: pedidos vivos de la unidad, del más antiguo al más
   nuevo, con sus líneas listas para imprimir. */
CREATE OR REPLACE VIEW api.v_cocina AS
SELECT vp.unidad_id, vp.pedido_id, vp.codigo, vp.tipo, vp.mesa, vp.estado, vp.estado_nombre,
       vp.creado_en,
       floor(EXTRACT(EPOCH FROM (now() - vp.creado_en)) / 60)::INTEGER AS minutos_espera,
       (SELECT jsonb_agg(jsonb_build_object('cantidad', i.cantidad, 'nombre', i.nombre,
                                            'detalle', i.detalle, 'notas', i.notas) ORDER BY i.pedido_item_id)
          FROM api.v_pedido_items i WHERE i.pedido_id = vp.pedido_id) AS items
  FROM api.v_pedidos vp
 WHERE vp.estado IN ('nuevo', 'preparacion', 'listo');


/* ============================================================================
   7. VENTAS Y CAJA
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_ventas_diarias AS
SELECT vp.empresa_id, vp.unidad_id, vp.unidad, vp.fecha_operativa,
       vp.metodo_pago, vp.metodo_pago_nombre, vp.grupo_caja,
       count(*)                   AS pedidos,
       SUM(vp.subtotal)           AS subtotal,
       SUM(vp.costo_domicilio)    AS domicilios,
       SUM(vp.total)              AS total
  FROM api.v_pedidos vp
 WHERE vp.cuenta_como_venta
 GROUP BY vp.empresa_id, vp.unidad_id, vp.unidad, vp.fecha_operativa,
          vp.metodo_pago, vp.metodo_pago_nombre, vp.grupo_caja;

CREATE OR REPLACE VIEW api.v_ventas_producto AS
SELECT p.empresa_id, p.unidad_id, p.fecha_operativa, i.origen, i.nombre,
       SUM(i.cantidad)    AS cantidad,
       SUM(i.total_linea) AS total
  FROM api.v_pedido_items i
  JOIN core.pedidos p        ON p.id = i.pedido_id
  JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
 WHERE e.cuenta_como_venta
 GROUP BY p.empresa_id, p.unidad_id, p.fecha_operativa, i.origen, i.nombre;

CREATE OR REPLACE VIEW api.v_gastos AS
SELECT g.id AS gasto_id, g.unidad_id, u.empresa_id, u.nombre AS unidad, g.fecha_operativa,
       cg.nombre AS categoria, cg.icono AS categoria_icono,
       mp.codigo AS metodo_pago, mp.nombre AS metodo_pago_nombre, mp.grupo_caja,
       eg.codigo AS estado, eg.nombre AS estado_nombre,
       g.descripcion, g.monto, g.motivo_anulacion,
       ur.nombre AS registrado_por, uc.nombre AS confirmado_por, ua.nombre AS anulado_por,
       g.creado_en
  FROM core.gastos g
  JOIN core.unidades u          ON u.id = g.unidad_id
  JOIN core.categorias_gasto cg ON cg.id = g.categoria_gasto_id
  JOIN core.metodos_pago mp     ON mp.id = g.metodo_pago_id
  JOIN core.estados_gasto eg    ON eg.id = g.estado_gasto_id
  LEFT JOIN core.usuarios ur ON ur.id = g.registrado_por_id
  LEFT JOIN core.usuarios uc ON uc.id = g.confirmado_por_id
  LEFT JOIN core.usuarios ua ON ua.id = g.anulado_por_id;

CREATE OR REPLACE VIEW api.v_categorias_gasto AS
SELECT id AS categoria_gasto_id, empresa_id, nombre, icono, activa
  FROM core.categorias_gasto;

CREATE OR REPLACE VIEW api.v_bases_caja AS
SELECT b.id AS base_id, b.unidad_id, u.empresa_id, b.fecha_operativa, b.monto, b.vigente,
       b.reemplaza_a_id, b.observacion, us.nombre AS registrada_por, b.creado_en
  FROM core.bases_caja b
  JOIN core.unidades u ON u.id = b.unidad_id
  LEFT JOIN core.usuarios us ON us.id = b.usuario_id;

/* Cruce de caja de la jornada: con qué se abrió, qué entró por cada grupo de
   pago, qué salió en efectivo y cuánto efectivo debería haber en el cajón. */
CREATE OR REPLACE VIEW api.v_cruce_caja AS
WITH jornadas AS (
    SELECT unidad_id, fecha_operativa FROM core.bases_caja WHERE vigente
    UNION
    SELECT unidad_id, fecha_operativa FROM core.pedidos
    UNION
    SELECT unidad_id, fecha_operativa FROM core.gastos
),
ventas AS (
    SELECT unidad_id, fecha_operativa,
           SUM(total) FILTER (WHERE grupo_caja = 'efectivo')      AS efectivo,
           SUM(total) FILTER (WHERE grupo_caja = 'transferencia') AS transferencia,
           SUM(total) FILTER (WHERE grupo_caja = 'otros')         AS otros,
           SUM(total)                                             AS total,
           SUM(pedidos)                                           AS pedidos
      FROM api.v_ventas_diarias
     GROUP BY unidad_id, fecha_operativa
),
gastos AS (
    SELECT unidad_id, fecha_operativa,
           SUM(monto) FILTER (WHERE grupo_caja = 'efectivo') AS efectivo,
           SUM(monto)                                        AS total
      FROM api.v_gastos
     WHERE estado <> 'anulado'
     GROUP BY unidad_id, fecha_operativa
)
SELECT j.unidad_id, u.empresa_id, u.nombre AS unidad, j.fecha_operativa,
       COALESCE(b.monto, 0)             AS base,
       COALESCE(v.pedidos, 0)           AS pedidos,
       COALESCE(v.efectivo, 0)          AS ventas_efectivo,
       COALESCE(v.transferencia, 0)     AS ventas_transferencia,
       COALESCE(v.otros, 0)             AS ventas_otros,
       COALESCE(v.total, 0)             AS ventas_total,
       COALESCE(g.efectivo, 0)          AS gastos_efectivo,
       COALESCE(g.total, 0)             AS gastos_total,
       COALESCE(b.monto, 0) + COALESCE(v.efectivo, 0) - COALESCE(g.efectivo, 0) AS efectivo_esperado
  FROM jornadas j
  JOIN core.unidades u ON u.id = j.unidad_id
  LEFT JOIN core.bases_caja b ON b.unidad_id = j.unidad_id AND b.fecha_operativa = j.fecha_operativa AND b.vigente
  LEFT JOIN ventas v ON v.unidad_id = j.unidad_id AND v.fecha_operativa = j.fecha_operativa
  LEFT JOIN gastos g ON g.unidad_id = j.unidad_id AND g.fecha_operativa = j.fecha_operativa;

CREATE OR REPLACE VIEW api.v_anulaciones AS
SELECT a.id AS anulacion_id, p.empresa_id, p.unidad_id, p.codigo, a.motivo,
       us.nombre AS anulada_por, a.jornada_original, a.jornada_retorno,
       (a.jornada_retorno <> a.jornada_original) AS retorno_diferido,
       vp.total, vp.metodo_pago_nombre, a.creado_en
  FROM core.anulaciones a
  JOIN core.pedidos p    ON p.id = a.pedido_id
  JOIN api.v_pedidos vp  ON vp.pedido_id = p.id
  LEFT JOIN core.usuarios us ON us.id = a.usuario_id;


/* ============================================================================
   8. INVENTARIO
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_stock AS
SELECT iu.id AS insumo_unidad_id, iu.unidad_id, u.nombre AS unidad, i.empresa_id,
       i.id AS insumo_id, i.codigo, i.nombre,
       ci.nombre AS categoria, a.codigo AS area, a.nombre AS area_nombre,
       um.codigo AS unidad_medida, um.nombre AS unidad_medida_nombre,
       iu.stock_actual, iu.stock_minimo,
       (iu.stock_minimo > 0 AND iu.stock_actual <= iu.stock_minimo) AS bajo_minimo,
       i.activo,
       COALESCE((SELECT array_agg(pr.nombre ORDER BY pr.nombre)
                   FROM core.producto_insumos pi JOIN core.productos pr ON pr.id = pi.producto_id
                  WHERE pi.insumo_id = i.id), '{}') AS se_vende_como
  FROM core.insumo_unidades iu
  JOIN core.insumos i            ON i.id = iu.insumo_id
  JOIN core.unidades u           ON u.id = iu.unidad_id
  JOIN core.categorias_insumo ci ON ci.id = i.categoria_insumo_id
  JOIN core.areas_inventario a   ON a.id = i.area_id
  JOIN core.unidades_medida um   ON um.id = i.unidad_medida_id;

CREATE OR REPLACE VIEW api.v_entradas AS
SELECT en.id AS entrada_id, s.unidad_id, s.empresa_id, s.codigo, s.nombre AS insumo, s.area,
       te.codigo AS tipo, te.nombre AS tipo_nombre, te.automatico,
       en.fecha_operativa, en.cantidad, en.observacion,
       p.codigo AS factura, us.nombre AS registrada_por, en.creado_en
  FROM core.entradas_inventario en
  JOIN api.v_stock s          ON s.insumo_unidad_id = en.insumo_unidad_id
  JOIN core.tipos_entrada te  ON te.id = en.tipo_entrada_id
  LEFT JOIN core.pedidos p    ON p.id = en.pedido_id
  LEFT JOIN core.usuarios us  ON us.id = en.usuario_id;

CREATE OR REPLACE VIEW api.v_cierres AS
SELECT c.id AS cierre_id, c.unidad_id, u.empresa_id, u.nombre AS unidad, u.nombre_corto,
       u.nombre_corto || '-' || a.codigo || '-' || to_char(c.fecha_operativa, 'YYMMDD') AS codigo,
       a.codigo AS area, a.nombre AS area_nombre, c.fecha_operativa,
       ec.codigo AS estado, ec.nombre AS estado_nombre, c.observacion, c.aplicado_a_stock,
       ur.nombre AS registrado_por, uv.nombre AS revisado_por, c.revisado_en,
       (SELECT count(*) FROM core.cierre_detalles d WHERE d.cierre_id = c.id) AS productos_contados,
       c.creado_en, c.actualizado_en
  FROM core.cierres_inventario c
  JOIN core.unidades u         ON u.id = c.unidad_id
  JOIN core.areas_inventario a ON a.id = c.area_id
  JOIN core.estados_cierre ec  ON ec.id = c.estado_cierre_id
  LEFT JOIN core.usuarios ur ON ur.id = c.registrado_por_id
  LEFT JOIN core.usuarios uv ON uv.id = c.revisado_por_id;

/* CRUCE DE INVENTARIO — la planilla IN · EN · Z · SD de las meseras.

     IN  saldo físico del cierre ANTERIOR de ese insumo en la unidad
     EN  entradas desde el día siguiente a ese cierre hasta este
     Z   lo vendido en ese mismo tramo (ventas efectivas × insumo por venta)
     SD  el saldo contado en este cierre
     DIFERENCIA = IN + EN − Z − SD   (positivo = falta mercancía)

   Una factura anulada no cuenta en Z. Si su jornada ya estaba cerrada, la
   mercancía vuelve como entrada de hoy (tipo retorno_anulacion). */
CREATE OR REPLACE VIEW api.v_cruce_inventario AS
WITH base AS (
    SELECT d.id AS cierre_detalle_id, c.id AS cierre_id, c.unidad_id, c.area_id, c.fecha_operativa,
           d.insumo_unidad_id, iu.insumo_id, d.saldo_fisico,
           ant.saldo_fisico    AS saldo_anterior,
           ant.fecha_operativa AS fecha_anterior
      FROM core.cierre_detalles d
      JOIN core.cierres_inventario c ON c.id = d.cierre_id
      JOIN core.insumo_unidades iu   ON iu.id = d.insumo_unidad_id
      LEFT JOIN LATERAL (
            SELECT d2.saldo_fisico, c2.fecha_operativa
              FROM core.cierre_detalles d2
              JOIN core.cierres_inventario c2 ON c2.id = d2.cierre_id
             WHERE d2.insumo_unidad_id = d.insumo_unidad_id
               AND c2.fecha_operativa < c.fecha_operativa
             ORDER BY c2.fecha_operativa DESC
             LIMIT 1
      ) ant ON TRUE
)
SELECT b.cierre_id, b.cierre_detalle_id, b.unidad_id, u.empresa_id, u.nombre AS unidad,
       a.codigo AS area, b.fecha_operativa, b.fecha_anterior,
       i.codigo, i.nombre AS insumo,
       COALESCE(b.saldo_anterior, 0) AS inicial,
       (b.saldo_anterior IS NULL)    AS sin_cierre_anterior,
       COALESCE(en.cantidad, 0)      AS entradas,
       COALESCE(z.cantidad, 0)       AS ventas,
       b.saldo_fisico                AS saldo_fisico,
       COALESCE(b.saldo_anterior, 0) + COALESCE(en.cantidad, 0) - COALESCE(z.cantidad, 0) AS saldo_esperado,
       COALESCE(b.saldo_anterior, 0) + COALESCE(en.cantidad, 0) - COALESCE(z.cantidad, 0) - b.saldo_fisico AS diferencia
  FROM base b
  JOIN core.unidades u         ON u.id = b.unidad_id
  JOIN core.areas_inventario a ON a.id = b.area_id
  JOIN core.insumos i          ON i.id = b.insumo_id
  LEFT JOIN LATERAL (
        SELECT SUM(e.cantidad) AS cantidad
          FROM core.entradas_inventario e
         WHERE e.insumo_unidad_id = b.insumo_unidad_id
           AND e.fecha_operativa <= b.fecha_operativa
           AND e.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
  ) en ON TRUE
  LEFT JOIN LATERAL (
        SELECT SUM(it.cantidad * pi.cantidad) AS cantidad
          FROM core.pedido_items it
          JOIN core.pedidos p           ON p.id = it.pedido_id
          JOIN core.estados_pedido ep   ON ep.id = p.estado_pedido_id
          JOIN core.producto_insumos pi ON pi.producto_id = it.producto_id
         WHERE pi.insumo_id = b.insumo_id
           AND p.unidad_id = b.unidad_id
           AND ep.cuenta_como_venta
           AND p.fecha_operativa <= b.fecha_operativa
           AND p.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
  ) z ON TRUE;


/* ============================================================================
   9. AUDITORÍA
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_auditoria AS
SELECT a.id AS auditoria_id, a.tabla, a.registro_id, a.accion,
       us.nombre AS usuario, us.empresa_id, a.usuario_db,
       a.datos_antes, a.datos_despues, a.creado_en
  FROM core.auditoria a
  LEFT JOIN core.usuarios us ON us.id = a.usuario_id;


/* ============================================================================
   10. REPORTES MATERIALIZADOS
   ============================================================================ */

CREATE MATERIALIZED VIEW IF NOT EXISTS api.mv_ventas_mensuales AS
SELECT empresa_id, unidad_id, unidad,
       date_trunc('month', fecha_operativa)::DATE AS mes,
       SUM(pedidos) AS pedidos, SUM(subtotal) AS subtotal, SUM(domicilios) AS domicilios, SUM(total) AS total
  FROM api.v_ventas_diarias
 GROUP BY empresa_id, unidad_id, unidad, date_trunc('month', fecha_operativa)
WITH DATA;

CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_ventas_mensuales ON api.mv_ventas_mensuales (unidad_id, mes);

CREATE OR REPLACE PROCEDURE api.sp_refrescar_reportes()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    -- CONCURRENTLY: los reportes siguen consultables mientras se recalculan
    REFRESH MATERIALIZED VIEW CONCURRENTLY api.mv_ventas_mensuales;
END;
$$;


/* ============================================================================
   11. FUNCIONES DE CONSULTA
   ============================================================================ */

/* Seguimiento público: el cliente escribe "27" y ve la factura 00027 de SU
   empresa. Nunca devuelve pedidos de otra empresa. */
CREATE OR REPLACE FUNCTION api.fn_seguimiento_pedido(p_empresa_codigo VARCHAR, p_codigo VARCHAR)
RETURNS SETOF api.v_seguimiento_pedido
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT s.*
      FROM api.v_seguimiento_pedido s
      JOIN core.empresas e ON e.id = s.empresa_id
     WHERE e.codigo = p_empresa_codigo
       AND s.codigo = core.fn_normalizar_codigo_pedido(e.id, p_codigo);
$$;

/* Carta disponible de una unidad, lista para el portal. */
CREATE OR REPLACE FUNCTION api.fn_carta_unidad(p_unidad_id INTEGER)
RETURNS SETOF api.v_carta
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT * FROM api.v_carta
     WHERE unidad_id = p_unidad_id AND activo
     ORDER BY categoria_orden, orden, nombre;
$$;

/* Menú de hoy (jornada operativa) de una unidad. */
CREATE OR REPLACE FUNCTION api.fn_menu_hoy(p_unidad_id INTEGER)
RETURNS SETOF api.v_menu_publico
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT * FROM api.v_menu_publico
     WHERE unidad_id = p_unidad_id
       AND fecha = core.fn_fecha_operativa(core.fn_empresa_de_unidad(p_unidad_id), now());
$$;
