/* ============================================================================
   TASECA · 06 · DATOS INICIALES
   ----------------------------------------------------------------------------
   Catálogos del sistema + la estructura REAL de NASCAR:

     NASCAR-Comidas       Restaurante  · sólo menú del día (3 platos de ejemplo)
     Chicharrón Mental    Restaurante  · sólo menú del día (2 platos de ejemplo)
     NASCAR Bar VIP       Bar          · carta de 29 productos (precio 0) + 29 insumos
     COMIC'ENDO AREPA     Arepera      · carta de 58 productos + 18 insumos

   Generado desde el catálogo de la aplicación (js/data.js). Todo se
   referencia por códigos, nunca por ids fijos: los SERIAL asignan los ids.

   Usuarios de prueba (PIN guardado con bcrypt):
     super / 9000       SuperAdmin de Taseca (sin empresa)
     admin / 2580       Admin de NASCAR
     gerencia / 1234    Administrador
     mesero / 1111      Mesero        · NASCAR-Comidas
     cocina / 2222      Cocinero      · NASCAR-Comidas
     domicilios / 3333  Domiciliario
     caja / 4444        Caja          · NASCAR-Comidas
   ⚠️ Son PIN de prueba: cámbialos antes de producción.
   ============================================================================ */

SET search_path = core, public;

BEGIN;

/* ---------------------------------------------------------------- CATÁLOGOS */

INSERT INTO core.modulos (codigo, nombre, descripcion, obligatorio) VALUES
    ('basico', 'Básico', 'La operación de punta a punta: carta, menú del día, pedidos, pagos, ventas, usuarios y gastos.', TRUE),
    ('stock', 'Stock', 'Catálogo de inventario y entradas de mercancía.', FALSE),
    ('cierre', 'Cierre', 'Cierre de inventario diario y cruce IN · EN · Z · SD.', FALSE);

INSERT INTO core.tipos_negocio (codigo, nombre, icono) VALUES
    ('restaurante', 'Restaurante', '🍽️'),
    ('bar', 'Bar', '🍺'),
    ('arepera', 'Arepera / Comidas', '🫓'),
    ('cafeteria', 'Cafetería', '☕'),
    ('fruteria', 'Frutería', '🍓'),
    ('comidas_rapidas', 'Comidas rápidas', '🍔'),
    ('heladeria', 'Heladería', '🍦'),
    ('otro', 'Otro', '🏪');

INSERT INTO core.roles (codigo, nombre, descripcion, alcance, icono) VALUES
    ('superadmin', 'SuperAdmin', 'Administra la plataforma Taseca: empresas, módulos y accesos.', 'plataforma', '🛠️'),
    ('admin', 'Admin', 'Control total del sistema y su configuración.', 'empresa', '👑'),
    ('administrador', 'Administrador', 'Opera el restaurante completo, sin tocar la configuración sensible.', 'empresa', '📋'),
    ('caja', 'Caja', 'Maneja el dinero del punto: confirma pagos, registra gastos y recibe mercancía.', 'empresa', '💵'),
    ('mesero', 'Mesero', 'Toma pedidos de mesa, lleva los que están listos y registra el cierre de inventario.', 'empresa', '🍽️'),
    ('cocinero', 'Cocinero', 'Prepara los pedidos y marca cuándo están listos.', 'empresa', '👨‍🍳'),
    ('domiciliario', 'Domiciliario', 'Ve los pedidos listos para entregar y los cierra.', 'empresa', '🛵');

INSERT INTO core.permisos (codigo, descripcion, modulo_id) VALUES
    ('pedidos_ver', 'Ver el tablero de pedidos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_gestionar', 'Cambiar el estado de cualquier pedido', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_cocina', 'Trabajar los pedidos en cocina', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_domicilio', 'Entregar domicilios', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_mesa', 'Tomar pedidos de mesa', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_listos', 'Ver y entregar los pedidos listos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_cancelar', 'Cancelar pedidos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pedidos_anular', 'Anular facturas ya vendidas, con retorno de inventario', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('cierres_registrar', 'Registrar el inventario del cierre', (SELECT id FROM core.modulos WHERE codigo = 'cierre')),
    ('cierres', 'Consultar los cierres y el cruce', (SELECT id FROM core.modulos WHERE codigo = 'cierre')),
    ('cierres_revisar', 'Dar un cierre por revisado', (SELECT id FROM core.modulos WHERE codigo = 'cierre')),
    ('entradas', 'Registrar y consultar entradas de mercancía', (SELECT id FROM core.modulos WHERE codigo = 'stock')),
    ('gastos', 'Registrar y consultar gastos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('gastos_confirmar', 'Confirmar gastos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('gastos_anular', 'Anular gastos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('informe', 'Ver el cruce de información y la caja del día', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('base_caja', 'Registrar la base de caja de la jornada', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('pagos', 'Confirmar y rechazar pagos', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('menu', 'Publicar el menú del día', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('carta', 'Administrar la carta y las categorías', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('stock', 'Administrar el stock', (SELECT id FROM core.modulos WHERE codigo = 'stock')),
    ('ventas', 'Ver los reportes de ventas', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('ajustes', 'Respaldos y enlaces de mesa', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('usuarios', 'Crear y editar usuarios', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('config_local', 'Cambiar los datos del restaurante', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('config_sucursales', 'Configurar las unidades / locales', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('config_pagos', 'Configurar los métodos de pago', (SELECT id FROM core.modulos WHERE codigo = 'basico')),
    ('plataforma', 'Administrar la plataforma y sus empresas', NULL);

-- superadmin: todo · admin: todo menos 'plataforma' (el comodín del MVP no la concede)
INSERT INTO core.rol_permisos (rol_id, permiso_id)
SELECT r.id, p.id FROM core.roles r CROSS JOIN core.permisos p
 WHERE r.codigo = 'superadmin' OR (r.codigo = 'admin' AND p.codigo <> 'plataforma');

INSERT INTO core.rol_permisos (rol_id, permiso_id)
SELECT r.id, p.id
  FROM (VALUES
        ('administrador', 'pedidos_ver'),
        ('administrador', 'pedidos_gestionar'),
        ('administrador', 'pedidos_cancelar'),
        ('administrador', 'pagos'),
        ('administrador', 'menu'),
        ('administrador', 'carta'),
        ('administrador', 'stock'),
        ('administrador', 'ventas'),
        ('administrador', 'ajustes'),
        ('administrador', 'cierres_registrar'),
        ('administrador', 'cierres'),
        ('administrador', 'cierres_revisar'),
        ('administrador', 'entradas'),
        ('administrador', 'gastos'),
        ('administrador', 'gastos_confirmar'),
        ('administrador', 'gastos_anular'),
        ('administrador', 'informe'),
        ('administrador', 'base_caja'),
        ('caja', 'pagos'),
        ('caja', 'gastos'),
        ('caja', 'gastos_confirmar'),
        ('caja', 'entradas'),
        ('caja', 'informe'),
        ('caja', 'base_caja'),
        ('mesero', 'pedidos_mesa'),
        ('mesero', 'pedidos_listos'),
        ('mesero', 'cierres_registrar'),
        ('cocinero', 'pedidos_cocina'),
        ('domiciliario', 'pedidos_domicilio')
  ) AS x (rol, permiso)
  JOIN core.roles r    ON r.codigo = x.rol
  JOIN core.permisos p ON p.codigo = x.permiso;

INSERT INTO core.metodos_pago (codigo, nombre, grupo_caja) VALUES
    ('efectivo', 'Efectivo contra entrega', 'efectivo'),
    ('datafono', 'Datáfono en la puerta', 'otros'),
    ('transferencia', 'Transferencia · Nequi, Daviplata o Bancolombia', 'transferencia');

INSERT INTO core.tipos_pedido (codigo, nombre) VALUES
    ('mesa', 'Mesa'),
    ('domicilio', 'Domicilio');

INSERT INTO core.estados_pedido (codigo, nombre, orden, solo_domicilio, es_final, cuenta_como_venta) VALUES
    ('nuevo', 'Nuevo', 10, FALSE, FALSE, TRUE),
    ('preparacion', 'En preparación', 20, FALSE, FALSE, TRUE),
    ('listo', 'Listo', 30, FALSE, FALSE, TRUE),
    ('camino', 'En camino', 40, TRUE, FALSE, TRUE),
    ('entregado', 'Entregado', 50, FALSE, TRUE, TRUE),
    ('cancelado', 'Cancelado', 90, FALSE, TRUE, FALSE),
    ('anulado', 'Anulada', 91, FALSE, TRUE, FALSE);

INSERT INTO core.estados_pago (codigo, nombre) VALUES
    ('pendiente', 'Pendiente'),
    ('reportado', 'Reportado, por confirmar'),
    ('confirmado', 'Confirmado'),
    ('rechazado', 'Rechazado');

INSERT INTO core.estados_gasto (codigo, nombre) VALUES
    ('registrado', 'Registrado'),
    ('confirmado', 'Confirmado'),
    ('anulado', 'Anulado');

INSERT INTO core.estados_cierre (codigo, nombre, orden) VALUES
    ('borrador', 'Borrador', 1),
    ('completado', 'Completado', 2),
    ('revisado', 'Revisado', 3);

INSERT INTO core.tipos_entrada (codigo, nombre, automatico) VALUES
    ('compra', 'Compra a proveedor', FALSE),
    ('traslado', 'Traslado entre unidades', FALSE),
    ('devolucion', 'Devolución de cliente', FALSE),
    ('ajuste', 'Ajuste de inventario', FALSE),
    ('retorno_anulacion', 'Retorno por anulación de factura', TRUE);

INSERT INTO core.areas_inventario (codigo, nombre, icono) VALUES
    ('comidas', 'Comidas', '🍽️'),
    ('bar', 'Bar', '🍺');

INSERT INTO core.unidades_medida (codigo, nombre) VALUES
    ('unidad', 'Unidad'),
    ('botella', 'Botella'),
    ('media', 'Media'),
    ('caja', 'Caja'),
    ('paquete', 'Paquete'),
    ('porcion', 'Porción'),
    ('vaso', 'Vaso');

INSERT INTO core.etiquetas_producto (codigo, nombre) VALUES
    ('popular', '★ El más pedido'),
    ('nuevo', 'Nuevo'),
    ('picante', '🌶 Picante'),
    ('compartir', 'Para compartir');

INSERT INTO core.tipos_menu (codigo, nombre, descripcion) VALUES
    ('armado', 'Menú armado', 'El cliente arma su menú eligiendo opciones de cada categoría: sopa, principio, proteína, jugo… Un solo precio.'),
    ('chef', 'Menú del chef', 'Platos completos, cada uno con su nombre, descripción, precio y emoji.');


/* ---------------------------------------------------------------- EMPRESA NASCAR */
INSERT INTO core.empresas (codigo, nombre_comercial, razon_social, eslogan, descripcion, estado,
                           zona_horaria, hora_corte_operativa, telefono, whatsapp, email, direccion,
                           horario_general, tiempo_mesa, tiempo_domicilio,
                           color_primario, color_secundario, color_acento, color_fondo)
VALUES ('empresa_nascar', 'NASCAR', 'NASCAR Restaurante S.A.S.', 'Cocina de alta velocidad',
        'Cuatro locales en la misma zona: dos restaurantes con menú del día, el bar y la arepera.',
        'activa', 'America/Bogota', 6, '320 212 0632', '573202120632', 'contacto@nascar.com.co',
        'Av. Calle 80 # 102-52, Local 14, Bogotá D.C.', 'Lunes a Domingo · 11:00 a.m. – 10:00 p.m.',
        '15 - 25 min', '35 - 50 min', '#0b5fff', '#e4002b', '#4d8cff', '#06080c');

INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo)
SELECT e.id, m.id, TRUE FROM core.empresas e CROSS JOIN core.modulos m WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, descripcion, orden)
SELECT e.id, mp.id, TRUE, x.descripcion, x.orden
  FROM core.empresas e
 CROSS JOIN (VALUES ('efectivo', 'Le pagas al domiciliario cuando recibas.', 1),
                    ('datafono', 'El domiciliario lleva datáfono. Tarjeta débito o crédito.', 2),
                    ('transferencia', 'Transfieres ahora y despachamos apenas confirmemos el pago.', 3)
           ) AS x (metodo, descripcion, orden)
  JOIN core.metodos_pago mp ON mp.codigo = x.metodo
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos)
SELECT id, 'pedido', 0, 5 FROM core.empresas WHERE codigo = 'empresa_nascar';

INSERT INTO core.categorias_gasto (empresa_id, nombre, icono)
SELECT e.id, x.nombre, x.icono
  FROM core.empresas e
 CROSS JOIN (VALUES ('Compra a proveedor', '🚚'), ('Nómina', '👥'), ('Vale', '🧾'),
                    ('Servicios', '💡'), ('Operación', '🔧'), ('Otros', '📌')) AS x (nombre, icono)
 WHERE e.codigo = 'empresa_nascar';


/* ---------------------------------------------------------------- UNIDADES / LOCALES
   Sin zonas de domicilio: los domicilios salen sin costo ni pedido mínimo. */
INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto, estado, direccion, ciudad,
                           telefono, whatsapp, horario, mapa_url, color)
SELECT e.id, t.id, x.nombre, x.corto, 'activa', 'Av. Calle 80 # 102-52, Local 14', 'Bogotá D.C.', '320 212 0632', '573202120632',
       x.horario, 'https://maps.app.goo.gl/p4XjmGHuxHqEPfzo8', x.color
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('NASCAR-Comidas', 'Comidas', 'restaurante', 'Lunes a Domingo · 11:00 a.m. – 10:00 p.m.', 'rojo', 12),
        ('Chicharrón Mental', 'Chicharrón', 'restaurante', 'Lunes a Domingo · 11:00 a.m. – 10:00 p.m.', 'ambar', 10),
        ('NASCAR Bar VIP', 'Bar VIP', 'bar', 'Jueves a Domingo · 6:00 p.m. – 2:00 a.m.', 'azul', 14),
        ('COMIC''ENDO AREPA', 'COMIC''ENDO', 'arepera', 'Lunes a Domingo · 4:00 p.m. – 11:00 p.m.', 'verde', 8)
  ) AS x (nombre, corto, tipo, horario, color, mesas)
  JOIN core.tipos_negocio t ON t.codigo = x.tipo
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.mesas (unidad_id, numero)
SELECT u.id, g::TEXT
  FROM (VALUES
        ('NASCAR-Comidas', 12),
        ('Chicharrón Mental', 10),
        ('NASCAR Bar VIP', 14),
        ('COMIC''ENDO AREPA', 8)
  ) AS x (nombre, mesas)
  JOIN core.unidades u ON u.nombre = x.nombre
 CROSS JOIN LATERAL generate_series(1, x.mesas) g;


/* ---------------------------------------------------------------- USUARIOS */
INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
SELECT NULL, r.id, 'Plataforma', 'super', core.fn_hash_pin('9000')
  FROM core.roles r WHERE r.codigo = 'superadmin';

INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
SELECT e.id, r.id, x.nombre, x.usuario, core.fn_hash_pin(x.pin)
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('Dueño', 'admin', 'admin', '2580'),
        ('Administradora', 'gerencia', 'administrador', '1234'),
        ('Mesero Comidas', 'mesero', 'mesero', '1111'),
        ('Cocina Comidas', 'cocina', 'cocinero', '2222'),
        ('Domiciliario', 'domicilios', 'domiciliario', '3333'),
        ('Caja Comidas', 'caja', 'caja', '4444')
  ) AS x (nombre, usuario, rol, pin)
  JOIN core.roles r ON r.codigo = x.rol
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.usuario_unidades (usuario_id, unidad_id)
SELECT us.id, un.id
  FROM core.usuarios us
  JOIN core.unidades un ON un.nombre = 'NASCAR-Comidas'
 WHERE us.usuario IN ('mesero', 'cocina', 'caja');


/* ---------------------------------------------------------------- CARTA */
INSERT INTO core.categorias (empresa_id, nombre, icono, orden)
SELECT e.id, x.nombre, x.icono, x.orden
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('Arepas tradicionales', '🫓', 10),
        ('Arepas especiales', '⭐', 20),
        ('Mazorcada y pataconazo', '🌽', 30),
        ('Hamburguesas', '🍔', 40),
        ('Perros', '🌭', 50),
        ('Salchipapas', '🍟', 60),
        ('Platos a la carta', '🍽️', 70),
        ('Porciones y adiciones', '➕', 80),
        ('Bebidas', '🥤', 90),
        ('Cervezas', '🍺', 110),
        ('Licores', '🥃', 120),
        ('Snacks y dulces', '🍿', 130),
        ('Cigarrillos y varios', '🚬', 140),
        ('Sin alcohol', '🥤', 150)
  ) AS x (nombre, icono, orden)
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.categoria_unidades (categoria_id, unidad_id)
SELECT c.id, u.id
  FROM (VALUES
        ('Arepas tradicionales', 'COMIC''ENDO AREPA'),
        ('Arepas especiales', 'COMIC''ENDO AREPA'),
        ('Mazorcada y pataconazo', 'COMIC''ENDO AREPA'),
        ('Hamburguesas', 'COMIC''ENDO AREPA'),
        ('Perros', 'COMIC''ENDO AREPA'),
        ('Salchipapas', 'COMIC''ENDO AREPA'),
        ('Platos a la carta', 'COMIC''ENDO AREPA'),
        ('Porciones y adiciones', 'COMIC''ENDO AREPA'),
        ('Bebidas', 'COMIC''ENDO AREPA'),
        ('Cervezas', 'NASCAR Bar VIP'),
        ('Licores', 'NASCAR Bar VIP'),
        ('Snacks y dulces', 'NASCAR Bar VIP'),
        ('Cigarrillos y varios', 'NASCAR Bar VIP'),
        ('Sin alcohol', 'NASCAR Bar VIP')
  ) AS x (categoria, unidad)
  JOIN core.categorias c ON c.nombre = x.categoria
  JOIN core.unidades u   ON u.nombre = x.unidad;

-- COMIC'ENDO: carta 2025-2026. Bar: nombres de la planilla, PRECIO 0 hasta que el admin lo ponga.
INSERT INTO core.productos (empresa_id, categoria_id, etiqueta_id, codigo, nombre, descripcion, precio, orden)
SELECT e.id, c.id, et.id, x.codigo, x.nombre, x.descripcion, x.precio, x.orden
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('CE01', 'Arepas tradicionales', 'Chorizo queso', NULL, 9000, NULL, 10, 'COMIC''ENDO AREPA'),
        ('CE02', 'Arepas tradicionales', 'Jamón queso', NULL, 9000, NULL, 20, 'COMIC''ENDO AREPA'),
        ('CE03', 'Arepas tradicionales', 'Huevos al gusto', NULL, 10000, NULL, 30, 'COMIC''ENDO AREPA'),
        ('CE04', 'Arepas tradicionales', 'Hawallana', NULL, 10000, NULL, 40, 'COMIC''ENDO AREPA'),
        ('CE05', 'Arepas tradicionales', 'Carne o pollo · Mixta', NULL, 14000, 'popular', 50, 'COMIC''ENDO AREPA'),
        ('CE06', 'Arepas tradicionales', 'Vegetariana', NULL, 12000, NULL, 60, 'COMIC''ENDO AREPA'),
        ('CE07', 'Arepas especiales', 'Arepa Norteña', 'Maíz tierno · Chorizo · Champiñones · Queso · Carne desmechada · Huevo de codorniz', 17000, NULL, 70, 'COMIC''ENDO AREPA'),
        ('CE08', 'Arepas especiales', 'Arepa Avengers', 'Chicharrón · Tocineta · Chorizo · Champiñones · Queso · Carne · Pollo · Jamón · Huevo de codorniz', 17000, 'popular', 80, 'COMIC''ENDO AREPA'),
        ('CE09', 'Arepas especiales', 'Arepa Paisa', 'Frijol · Chicharrón · Plátano · Chorizo · Carne desmechada · Aguacate · Huevo de codorniz', 17000, NULL, 90, 'COMIC''ENDO AREPA'),
        ('CE10', 'Arepas especiales', 'Arepa Ranchera', 'Tocineta · Salchicha · Chorizo · Carne desmechada · Champiñones · Queso · Huevo de codorniz', 17000, NULL, 100, 'COMIC''ENDO AREPA'),
        ('CE11', 'Arepas especiales', 'Arepa Criolla', 'Carne desmechada · Maíz tierno · Plátano · Hogado · Chicharrón · Queso · Huevo de codorniz', 17000, NULL, 110, 'COMIC''ENDO AREPA'),
        ('CE12', 'Arepas especiales', 'Arepa Mexicana', 'Frijol · Carne desmechada · Pico de gallo · Nachos · Queso · Aguacate · Huevo de codorniz', 17000, NULL, 120, 'COMIC''ENDO AREPA'),
        ('CE13', 'Mazorcada y pataconazo', 'Mazorcada', 'Maíz tierno · Chorizo · Salchicha · Pollo y carne desmechada · Queso · Papá chip · Huevo de codorniz', 18000, NULL, 130, 'COMIC''ENDO AREPA'),
        ('CE14', 'Mazorcada y pataconazo', 'Pataconazo', 'Maíz tierno · Chorizo · Salchicha · Pollo · Carne desmechada · Queso · Hogado · Huevo de codorniz', 18000, NULL, 140, 'COMIC''ENDO AREPA'),
        ('CE15', 'Hamburguesas', 'Hamburguesa 100% res', 'Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz', 13000, NULL, 150, 'COMIC''ENDO AREPA'),
        ('CE16', 'Hamburguesas', 'Hamburguesa de pollo apanada', 'Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz', 14000, NULL, 160, 'COMIC''ENDO AREPA'),
        ('CE17', 'Hamburguesas', 'Hamburguesa doble carne', 'Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz', 18000, 'popular', 170, 'COMIC''ENDO AREPA'),
        ('CE18', 'Hamburguesas', 'Hamburguesa mixta', 'Lechuga · Cebolla · Tomate · Queso · Papá chip · Salsas · Huevo de codorniz', 20000, NULL, 180, 'COMIC''ENDO AREPA'),
        ('CE19', 'Hamburguesas', 'Hamburguesa especial Mexicana', 'Frijol · Carne desmechada · Pico de gallo · Nachos · Queso · Aguacate · Huevo de codorniz. Pídela de res o de pollo apanado.', 25000, NULL, 190, 'COMIC''ENDO AREPA'),
        ('CE20', 'Hamburguesas', 'Hamburguesa especial Norteña', 'Maíz tierno · Chorizo · Champiñones · Queso · Carne desmechada · Huevo de codorniz. Pídela de res o de pollo apanado.', 25000, NULL, 200, 'COMIC''ENDO AREPA'),
        ('CE21', 'Hamburguesas', 'Hamburguesa especial Paisa', 'Frijol · Chicharrón · Plátano · Chorizo · Carne · Aguacate · Huevo frito. Pídela de res o de pollo apanado.', 25000, NULL, 210, 'COMIC''ENDO AREPA'),
        ('CE22', 'Hamburguesas', 'Hamburguesa especial Comic''', 'Chicharrón · Tocineta · Chorizo · Champiñones · Carne y pollo desmechado · Jamón · Queso · Huevo frito. Pídela de res o de pollo apanado.', 25000, NULL, 220, 'COMIC''ENDO AREPA'),
        ('CE23', 'Hamburguesas', 'Hamburguesa especial Ranchera', 'Tocineta · Salchicha · Chorizo · Carne desmechada · Champiñones · Queso · Huevo de codorniz. Pídela de res o de pollo apanado.', 25000, NULL, 230, 'COMIC''ENDO AREPA'),
        ('CE24', 'Hamburguesas', 'Hamburguesa especial Criolla', 'Carne desmechada · Maíz tierno · Plátano · Hogado · Chicharrón · Queso · Huevo frito. Pídela de res o de pollo apanado.', 25000, NULL, 240, 'COMIC''ENDO AREPA'),
        ('CE25', 'Perros', 'Perro sencillo', 'Salchicha americana · Jamón · Queso · Cebolla · Papá chip · Salsas · Huevo de codorniz', 14000, NULL, 250, 'COMIC''ENDO AREPA'),
        ('CE26', 'Perros', 'Perro especial', 'Pollo y carne · Salchicha americana · Jamón · Queso · Cebolla · Papá chip · Salsas · Huevo de codorniz', 18000, NULL, 260, 'COMIC''ENDO AREPA'),
        ('CE27', 'Perros', 'Perro de la casa', 'Salchicha americana · Chicharrón · Tocineta · Chorizo · Champiñones · Carne y pollo desmechado · Jamón · Queso · Huevo frito', 22000, 'popular', 270, 'COMIC''ENDO AREPA'),
        ('CE28', 'Salchipapas', 'Salchipapa Comic''', 'Salchicha · Chicharrón · Tocineta · Chorizo · Champiñones · Carne y pollo desmechado · Huevo de codorniz', 22000, 'popular', 280, 'COMIC''ENDO AREPA'),
        ('CE29', 'Salchipapas', 'Salchipapa Ranchera', 'Tocineta · Salchicha · Chorizo · Carne desmechada · Champiñones · Huevo de codorniz', 22000, NULL, 290, 'COMIC''ENDO AREPA'),
        ('CE30', 'Salchipapas', 'Salchipapa Norteña', 'Salchicha · Maíz tierno · Chorizo · Champiñones · Carne desmechada · Huevo de codorniz', 22000, NULL, 300, 'COMIC''ENDO AREPA'),
        ('CE31', 'Salchipapas', 'Salchipapa Criolla', 'Carne desmechada · Maíz tierno · Plátano · Chicharrón · Queso · Huevo de codorniz', 22000, NULL, 310, 'COMIC''ENDO AREPA'),
        ('CE32', 'Platos a la carta', 'Bandeja de carne asada', 'Arroz · Papá francesa · Aguacate · Gaseosa o limonada natural', 18000, NULL, 320, 'COMIC''ENDO AREPA'),
        ('CE33', 'Platos a la carta', 'Bandeja de lomo de cerdo', 'Arroz · Papá francesa · Aguacate · Gaseosa o limonada natural', 18000, NULL, 330, 'COMIC''ENDO AREPA'),
        ('CE34', 'Platos a la carta', 'Bandeja de pechuga', 'Arroz · Papá francesa · Aguacate · Gaseosa o limonada natural', 18000, NULL, 340, 'COMIC''ENDO AREPA'),
        ('CE35', 'Platos a la carta', 'Encebollado de carne asada', 'Arroz · Papá francesa · Gaseosa o limonada natural', 29000, NULL, 350, 'COMIC''ENDO AREPA'),
        ('CE36', 'Platos a la carta', 'Encebollado de lomo de cerdo', 'Arroz · Papá francesa · Gaseosa o limonada natural', 29000, NULL, 360, 'COMIC''ENDO AREPA'),
        ('CE37', 'Platos a la carta', 'Encebollado de pechuga', 'Arroz · Papá francesa · Gaseosa o limonada natural', 29000, NULL, 370, 'COMIC''ENDO AREPA'),
        ('CE38', 'Platos a la carta', 'Churrasco a lo grande', 'Arroz · Papá francesa · Plátano · Gaseosa o limonada natural', 29000, NULL, 380, 'COMIC''ENDO AREPA'),
        ('CE39', 'Platos a la carta', 'Churrasco ranchero', 'Arroz · Papá francesa · Plátano · Gaseosa o limonada natural', 29000, NULL, 390, 'COMIC''ENDO AREPA'),
        ('CE40', 'Platos a la carta', 'Costillas BBQ', 'Arroz · Papá francesa · Plátano · Gaseosa o limonada natural', 29000, NULL, 400, 'COMIC''ENDO AREPA'),
        ('CE41', 'Platos a la carta', 'Trimixta', 'Arroz · Papá francesa · Plátano · Gaseosa o limonada natural', 29000, NULL, 410, 'COMIC''ENDO AREPA'),
        ('CE42', 'Platos a la carta', 'Picada', 'Carne · Pechuga · Lomo · Chorizo · Francesa · Plátano · Arepa', 42000, 'compartir', 420, 'COMIC''ENDO AREPA'),
        ('CE43', 'Porciones y adiciones', 'Papá francesa', NULL, 8000, NULL, 430, 'COMIC''ENDO AREPA'),
        ('CE44', 'Porciones y adiciones', 'Huevos de codorniz', NULL, 5000, NULL, 440, 'COMIC''ENDO AREPA'),
        ('CE45', 'Porciones y adiciones', 'Adición de su preferencia', NULL, 4000, NULL, 450, 'COMIC''ENDO AREPA'),
        ('CE46', 'Bebidas', 'Limonada natural', NULL, 6000, NULL, 460, 'COMIC''ENDO AREPA'),
        ('CE47', 'Bebidas', 'Limonada de coco', NULL, 8000, NULL, 470, 'COMIC''ENDO AREPA'),
        ('CE48', 'Bebidas', 'Limonada cerezada', NULL, 8000, NULL, 480, 'COMIC''ENDO AREPA'),
        ('CE49', 'Bebidas', 'Jugo en agua', NULL, 7000, NULL, 490, 'COMIC''ENDO AREPA'),
        ('CE50', 'Bebidas', 'Jugo en leche', NULL, 9000, NULL, 500, 'COMIC''ENDO AREPA'),
        ('CE51', 'Bebidas', 'Gaseosa personal', NULL, 4500, NULL, 510, 'COMIC''ENDO AREPA'),
        ('CE52', 'Bebidas', 'Gaseosa 250', NULL, 3000, NULL, 520, 'COMIC''ENDO AREPA'),
        ('CE53', 'Bebidas', 'Gaseosa 1.5', NULL, 8000, NULL, 530, 'COMIC''ENDO AREPA'),
        ('CE54', 'Bebidas', 'Agua botella', NULL, 4000, NULL, 540, 'COMIC''ENDO AREPA'),
        ('CE55', 'Bebidas', 'Gatorade', NULL, 5000, NULL, 550, 'COMIC''ENDO AREPA'),
        ('CE56', 'Bebidas', 'Vive Cien', NULL, 4000, NULL, 560, 'COMIC''ENDO AREPA'),
        ('CE57', 'Bebidas', 'Jugo Hit', NULL, 4000, NULL, 570, 'COMIC''ENDO AREPA'),
        ('CE58', 'Bebidas', 'Bretaña', NULL, 4000, NULL, 580, 'COMIC''ENDO AREPA'),
        ('BR01', 'Cervezas', 'Cerveza', NULL, 0, NULL, 10, 'NASCAR Bar VIP'),
        ('BR02', 'Cervezas', 'Águila Light', NULL, 0, NULL, 20, 'NASCAR Bar VIP'),
        ('BR03', 'Cervezas', 'Club Colombia', NULL, 0, NULL, 30, 'NASCAR Bar VIP'),
        ('BR04', 'Cervezas', 'Corona', NULL, 0, NULL, 40, 'NASCAR Bar VIP'),
        ('BR05', 'Cervezas', 'Coronita', NULL, 0, NULL, 50, 'NASCAR Bar VIP'),
        ('BR06', 'Licores', 'Smirnoff', NULL, 0, NULL, 60, 'NASCAR Bar VIP'),
        ('BR07', 'Licores', 'Media de verde', NULL, 0, NULL, 70, 'NASCAR Bar VIP'),
        ('BR08', 'Licores', 'Caja verde', NULL, 0, NULL, 80, 'NASCAR Bar VIP'),
        ('BR09', 'Licores', 'Media de Antioqueño', NULL, 0, NULL, 90, 'NASCAR Bar VIP'),
        ('BR10', 'Licores', 'Botella de Antioqueño', NULL, 0, NULL, 100, 'NASCAR Bar VIP'),
        ('BR11', 'Licores', 'Botella de whisky', NULL, 0, NULL, 110, 'NASCAR Bar VIP'),
        ('BR12', 'Licores', 'Botella de ron', NULL, 0, NULL, 120, 'NASCAR Bar VIP'),
        ('BR13', 'Licores', 'Media de ron', NULL, 0, NULL, 130, 'NASCAR Bar VIP'),
        ('BR14', 'Licores', 'Old Parr', NULL, 0, NULL, 140, 'NASCAR Bar VIP'),
        ('BR15', 'Licores', 'Botella de tequila', NULL, 0, NULL, 150, 'NASCAR Bar VIP'),
        ('BR16', 'Licores', 'Media de tequila', NULL, 0, NULL, 160, 'NASCAR Bar VIP'),
        ('BR17', 'Licores', 'Media de amarillo', NULL, 0, NULL, 170, 'NASCAR Bar VIP'),
        ('BR18', 'Licores', 'Amarillo y rosado', NULL, 0, NULL, 180, 'NASCAR Bar VIP'),
        ('BR19', 'Cigarrillos y varios', 'Cigarrillos', NULL, 0, NULL, 190, 'NASCAR Bar VIP'),
        ('BR20', 'Cigarrillos y varios', 'Encendedores', NULL, 0, NULL, 200, 'NASCAR Bar VIP'),
        ('BR21', 'Snacks y dulces', 'Traiden grande', NULL, 0, NULL, 210, 'NASCAR Bar VIP'),
        ('BR22', 'Snacks y dulces', 'Traiden mediano', NULL, 0, NULL, 220, 'NASCAR Bar VIP'),
        ('BR23', 'Snacks y dulces', 'Traiden personal', NULL, 0, NULL, 230, 'NASCAR Bar VIP'),
        ('BR24', 'Snacks y dulces', 'Papas grandes', NULL, 0, NULL, 240, 'NASCAR Bar VIP'),
        ('BR25', 'Snacks y dulces', 'Papas pequeñas', NULL, 0, NULL, 250, 'NASCAR Bar VIP'),
        ('BR26', 'Snacks y dulces', 'Chokis', NULL, 0, NULL, 260, 'NASCAR Bar VIP'),
        ('BR27', 'Snacks y dulces', 'Bombombum', NULL, 0, NULL, 270, 'NASCAR Bar VIP'),
        ('BR28', 'Snacks y dulces', 'Dulces', NULL, 0, NULL, 280, 'NASCAR Bar VIP'),
        ('BR29', 'Sin alcohol', 'Gatorade, agua y jugos', NULL, 0, NULL, 290, 'NASCAR Bar VIP')
  ) AS x (codigo, categoria, nombre, descripcion, precio, etiqueta, orden, unidad)
  JOIN core.categorias c ON c.empresa_id = e.id AND c.nombre = x.categoria
  LEFT JOIN core.etiquetas_producto et ON et.codigo = x.etiqueta
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.producto_unidades (producto_id, unidad_id)
SELECT p.id, u.id
  FROM (VALUES
        ('CE01', 'COMIC''ENDO AREPA'),
        ('CE02', 'COMIC''ENDO AREPA'),
        ('CE03', 'COMIC''ENDO AREPA'),
        ('CE04', 'COMIC''ENDO AREPA'),
        ('CE05', 'COMIC''ENDO AREPA'),
        ('CE06', 'COMIC''ENDO AREPA'),
        ('CE07', 'COMIC''ENDO AREPA'),
        ('CE08', 'COMIC''ENDO AREPA'),
        ('CE09', 'COMIC''ENDO AREPA'),
        ('CE10', 'COMIC''ENDO AREPA'),
        ('CE11', 'COMIC''ENDO AREPA'),
        ('CE12', 'COMIC''ENDO AREPA'),
        ('CE13', 'COMIC''ENDO AREPA'),
        ('CE14', 'COMIC''ENDO AREPA'),
        ('CE15', 'COMIC''ENDO AREPA'),
        ('CE16', 'COMIC''ENDO AREPA'),
        ('CE17', 'COMIC''ENDO AREPA'),
        ('CE18', 'COMIC''ENDO AREPA'),
        ('CE19', 'COMIC''ENDO AREPA'),
        ('CE20', 'COMIC''ENDO AREPA'),
        ('CE21', 'COMIC''ENDO AREPA'),
        ('CE22', 'COMIC''ENDO AREPA'),
        ('CE23', 'COMIC''ENDO AREPA'),
        ('CE24', 'COMIC''ENDO AREPA'),
        ('CE25', 'COMIC''ENDO AREPA'),
        ('CE26', 'COMIC''ENDO AREPA'),
        ('CE27', 'COMIC''ENDO AREPA'),
        ('CE28', 'COMIC''ENDO AREPA'),
        ('CE29', 'COMIC''ENDO AREPA'),
        ('CE30', 'COMIC''ENDO AREPA'),
        ('CE31', 'COMIC''ENDO AREPA'),
        ('CE32', 'COMIC''ENDO AREPA'),
        ('CE33', 'COMIC''ENDO AREPA'),
        ('CE34', 'COMIC''ENDO AREPA'),
        ('CE35', 'COMIC''ENDO AREPA'),
        ('CE36', 'COMIC''ENDO AREPA'),
        ('CE37', 'COMIC''ENDO AREPA'),
        ('CE38', 'COMIC''ENDO AREPA'),
        ('CE39', 'COMIC''ENDO AREPA'),
        ('CE40', 'COMIC''ENDO AREPA'),
        ('CE41', 'COMIC''ENDO AREPA'),
        ('CE42', 'COMIC''ENDO AREPA'),
        ('CE43', 'COMIC''ENDO AREPA'),
        ('CE44', 'COMIC''ENDO AREPA'),
        ('CE45', 'COMIC''ENDO AREPA'),
        ('CE46', 'COMIC''ENDO AREPA'),
        ('CE47', 'COMIC''ENDO AREPA'),
        ('CE48', 'COMIC''ENDO AREPA'),
        ('CE49', 'COMIC''ENDO AREPA'),
        ('CE50', 'COMIC''ENDO AREPA'),
        ('CE51', 'COMIC''ENDO AREPA'),
        ('CE52', 'COMIC''ENDO AREPA'),
        ('CE53', 'COMIC''ENDO AREPA'),
        ('CE54', 'COMIC''ENDO AREPA'),
        ('CE55', 'COMIC''ENDO AREPA'),
        ('CE56', 'COMIC''ENDO AREPA'),
        ('CE57', 'COMIC''ENDO AREPA'),
        ('CE58', 'COMIC''ENDO AREPA'),
        ('BR01', 'NASCAR Bar VIP'),
        ('BR02', 'NASCAR Bar VIP'),
        ('BR03', 'NASCAR Bar VIP'),
        ('BR04', 'NASCAR Bar VIP'),
        ('BR05', 'NASCAR Bar VIP'),
        ('BR06', 'NASCAR Bar VIP'),
        ('BR07', 'NASCAR Bar VIP'),
        ('BR08', 'NASCAR Bar VIP'),
        ('BR09', 'NASCAR Bar VIP'),
        ('BR10', 'NASCAR Bar VIP'),
        ('BR11', 'NASCAR Bar VIP'),
        ('BR12', 'NASCAR Bar VIP'),
        ('BR13', 'NASCAR Bar VIP'),
        ('BR14', 'NASCAR Bar VIP'),
        ('BR15', 'NASCAR Bar VIP'),
        ('BR16', 'NASCAR Bar VIP'),
        ('BR17', 'NASCAR Bar VIP'),
        ('BR18', 'NASCAR Bar VIP'),
        ('BR19', 'NASCAR Bar VIP'),
        ('BR20', 'NASCAR Bar VIP'),
        ('BR21', 'NASCAR Bar VIP'),
        ('BR22', 'NASCAR Bar VIP'),
        ('BR23', 'NASCAR Bar VIP'),
        ('BR24', 'NASCAR Bar VIP'),
        ('BR25', 'NASCAR Bar VIP'),
        ('BR26', 'NASCAR Bar VIP'),
        ('BR27', 'NASCAR Bar VIP'),
        ('BR28', 'NASCAR Bar VIP'),
        ('BR29', 'NASCAR Bar VIP')
  ) AS x (codigo, unidad)
  JOIN core.productos p ON p.codigo = x.codigo
  JOIN core.unidades u  ON u.nombre = x.unidad;


/* ---------------------------------------------------------------- INVENTARIO
   Los códigos son los de las planillas de papel (CD). En el bar el 18 y el 21
   no existen en la planilla y aquí tampoco. Los insumos de cocina no se
   venden tal cual (no tienen producto_insumos); las bebidas y todo el bar sí. */
INSERT INTO core.categorias_insumo (empresa_id, nombre)
SELECT e.id, x.nombre
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('Panes y arepas'),
        ('Insumos'),
        ('Carnes y embutidos'),
        ('Bebidas'),
        ('Cervezas'),
        ('Licores'),
        ('Cigarrillos y varios'),
        ('Snacks y dulces'),
        ('Sin alcohol')
  ) AS x (nombre)
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
SELECT e.id, ci.id, a.id, um.id, x.codigo, x.nombre
  FROM core.empresas e
 CROSS JOIN (VALUES
        ('CE-01', 'Pan hamburguesa', 'Panes y arepas', 'comidas', 'unidad'),
        ('CE-02', 'Pan perro', 'Panes y arepas', 'comidas', 'unidad'),
        ('CE-03', 'Arepas', 'Panes y arepas', 'comidas', 'unidad'),
        ('CE-04', 'Francesa', 'Insumos', 'comidas', 'unidad'),
        ('CE-05', 'Maíz', 'Insumos', 'comidas', 'unidad'),
        ('CE-06', 'Quesos', 'Insumos', 'comidas', 'unidad'),
        ('CE-07', 'Jamón', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-08', 'Tocineta', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-09', 'Salchichas', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-10', 'Chorizos', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-11', 'Carne hamburguesa', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-12', 'Carne pollo', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-13', 'Churrascos', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-14', 'Costillas', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-15', 'Tocino', 'Carnes y embutidos', 'comidas', 'unidad'),
        ('CE-16', 'Gaseosa 1.5', 'Bebidas', 'comidas', 'botella'),
        ('CE-17', 'Gaseosa 400', 'Bebidas', 'comidas', 'botella'),
        ('CE-18', 'Gaseosa 250', 'Bebidas', 'comidas', 'botella'),
        ('BAR-01', 'Cerveza', 'Cervezas', 'bar', 'botella'),
        ('BAR-02', 'Águila Light', 'Cervezas', 'bar', 'botella'),
        ('BAR-03', 'Club Colombia', 'Cervezas', 'bar', 'botella'),
        ('BAR-04', 'Corona', 'Cervezas', 'bar', 'botella'),
        ('BAR-05', 'Coronita', 'Cervezas', 'bar', 'botella'),
        ('BAR-06', 'Smirnoff', 'Licores', 'bar', 'botella'),
        ('BAR-07', 'Media de verde', 'Licores', 'bar', 'media'),
        ('BAR-08', 'Caja verde', 'Licores', 'bar', 'caja'),
        ('BAR-09', 'Media de Antioqueño', 'Licores', 'bar', 'media'),
        ('BAR-10', 'Botella de Antioqueño', 'Licores', 'bar', 'botella'),
        ('BAR-11', 'Botella de whisky', 'Licores', 'bar', 'botella'),
        ('BAR-12', 'Botella de ron', 'Licores', 'bar', 'botella'),
        ('BAR-13', 'Media de ron', 'Licores', 'bar', 'media'),
        ('BAR-14', 'Old Parr', 'Licores', 'bar', 'botella'),
        ('BAR-15', 'Botella de tequila', 'Licores', 'bar', 'botella'),
        ('BAR-16', 'Media de tequila', 'Licores', 'bar', 'media'),
        ('BAR-17', 'Media de amarillo', 'Licores', 'bar', 'media'),
        ('BAR-19', 'Cigarrillos', 'Cigarrillos y varios', 'bar', 'unidad'),
        ('BAR-20', 'Traiden grande', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-22', 'Traiden mediano', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-23', 'Traiden personal', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-24', 'Encendedores', 'Cigarrillos y varios', 'bar', 'unidad'),
        ('BAR-25', 'Papas grandes', 'Snacks y dulces', 'bar', 'paquete'),
        ('BAR-26', 'Papas pequeñas', 'Snacks y dulces', 'bar', 'paquete'),
        ('BAR-27', 'Chokis', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-28', 'Bombombum', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-29', 'Dulces', 'Snacks y dulces', 'bar', 'unidad'),
        ('BAR-30', 'Gatorade, agua y jugos', 'Sin alcohol', 'bar', 'unidad'),
        ('BAR-31', 'Amarillo y rosado', 'Licores', 'bar', 'botella')
  ) AS x (codigo, nombre, categoria, area, medida)
  JOIN core.categorias_insumo ci ON ci.empresa_id = e.id AND ci.nombre = x.categoria
  JOIN core.areas_inventario a   ON a.codigo = x.area
  JOIN core.unidades_medida um   ON um.codigo = x.medida
 WHERE e.codigo = 'empresa_nascar';

INSERT INTO core.insumo_unidades (insumo_id, unidad_id)
SELECT i.id, u.id
  FROM (VALUES
        ('CE-01', 'COMIC''ENDO AREPA'),
        ('CE-02', 'COMIC''ENDO AREPA'),
        ('CE-03', 'COMIC''ENDO AREPA'),
        ('CE-04', 'COMIC''ENDO AREPA'),
        ('CE-05', 'COMIC''ENDO AREPA'),
        ('CE-06', 'COMIC''ENDO AREPA'),
        ('CE-07', 'COMIC''ENDO AREPA'),
        ('CE-08', 'COMIC''ENDO AREPA'),
        ('CE-09', 'COMIC''ENDO AREPA'),
        ('CE-10', 'COMIC''ENDO AREPA'),
        ('CE-11', 'COMIC''ENDO AREPA'),
        ('CE-12', 'COMIC''ENDO AREPA'),
        ('CE-13', 'COMIC''ENDO AREPA'),
        ('CE-14', 'COMIC''ENDO AREPA'),
        ('CE-15', 'COMIC''ENDO AREPA'),
        ('CE-16', 'COMIC''ENDO AREPA'),
        ('CE-17', 'COMIC''ENDO AREPA'),
        ('CE-18', 'COMIC''ENDO AREPA'),
        ('BAR-01', 'NASCAR Bar VIP'),
        ('BAR-02', 'NASCAR Bar VIP'),
        ('BAR-03', 'NASCAR Bar VIP'),
        ('BAR-04', 'NASCAR Bar VIP'),
        ('BAR-05', 'NASCAR Bar VIP'),
        ('BAR-06', 'NASCAR Bar VIP'),
        ('BAR-07', 'NASCAR Bar VIP'),
        ('BAR-08', 'NASCAR Bar VIP'),
        ('BAR-09', 'NASCAR Bar VIP'),
        ('BAR-10', 'NASCAR Bar VIP'),
        ('BAR-11', 'NASCAR Bar VIP'),
        ('BAR-12', 'NASCAR Bar VIP'),
        ('BAR-13', 'NASCAR Bar VIP'),
        ('BAR-14', 'NASCAR Bar VIP'),
        ('BAR-15', 'NASCAR Bar VIP'),
        ('BAR-16', 'NASCAR Bar VIP'),
        ('BAR-17', 'NASCAR Bar VIP'),
        ('BAR-19', 'NASCAR Bar VIP'),
        ('BAR-20', 'NASCAR Bar VIP'),
        ('BAR-22', 'NASCAR Bar VIP'),
        ('BAR-23', 'NASCAR Bar VIP'),
        ('BAR-24', 'NASCAR Bar VIP'),
        ('BAR-25', 'NASCAR Bar VIP'),
        ('BAR-26', 'NASCAR Bar VIP'),
        ('BAR-27', 'NASCAR Bar VIP'),
        ('BAR-28', 'NASCAR Bar VIP'),
        ('BAR-29', 'NASCAR Bar VIP'),
        ('BAR-30', 'NASCAR Bar VIP'),
        ('BAR-31', 'NASCAR Bar VIP')
  ) AS x (codigo, unidad)
  JOIN core.insumos i  ON i.codigo = x.codigo
  JOIN core.unidades u ON u.nombre = x.unidad;

INSERT INTO core.producto_insumos (producto_id, insumo_id, cantidad)
SELECT p.id, i.id, 1
  FROM (VALUES
        ('CE-16', 'CE53'),
        ('CE-17', 'CE51'),
        ('CE-18', 'CE52'),
        ('BAR-01', 'BR01'),
        ('BAR-02', 'BR02'),
        ('BAR-03', 'BR03'),
        ('BAR-04', 'BR04'),
        ('BAR-05', 'BR05'),
        ('BAR-06', 'BR06'),
        ('BAR-07', 'BR07'),
        ('BAR-08', 'BR08'),
        ('BAR-09', 'BR09'),
        ('BAR-10', 'BR10'),
        ('BAR-11', 'BR11'),
        ('BAR-12', 'BR12'),
        ('BAR-13', 'BR13'),
        ('BAR-14', 'BR14'),
        ('BAR-15', 'BR15'),
        ('BAR-16', 'BR16'),
        ('BAR-17', 'BR17'),
        ('BAR-19', 'BR19'),
        ('BAR-20', 'BR21'),
        ('BAR-22', 'BR22'),
        ('BAR-23', 'BR23'),
        ('BAR-24', 'BR20'),
        ('BAR-25', 'BR24'),
        ('BAR-26', 'BR25'),
        ('BAR-27', 'BR26'),
        ('BAR-28', 'BR27'),
        ('BAR-29', 'BR28'),
        ('BAR-30', 'BR29'),
        ('BAR-31', 'BR18')
  ) AS x (insumo, producto)
  JOIN core.insumos i   ON i.codigo = x.insumo
  JOIN core.productos p ON p.codigo = x.producto;


/* ---------------------------------------------------------------- MENÚ DEL DÍA
   Los restaurantes trabajan sólo con menú del día. Cinco platos del chef de
   EJEMPLO para la jornada de hoy: se cambian cada mañana desde la aplicación. */
INSERT INTO core.menus_dia (unidad_id, tipo_menu_id, fecha)
SELECT u.id, t.id, core.fn_fecha_operativa(u.empresa_id, now())
  FROM core.unidades u
  JOIN core.tipos_menu t ON t.codigo = 'chef'
 WHERE u.nombre IN ('NASCAR-Comidas', 'Chicharrón Mental');

INSERT INTO core.platos_dia (menu_dia_id, nombre, descripcion, emoji, precio, cupos, orden)
SELECT m.id, x.nombre, x.descripcion, x.emoji, x.precio, x.cupos, x.orden
  FROM (VALUES
        ('NASCAR-Comidas', 'Almuerzo ejecutivo', 'Sancocho de costilla · Arroz + fríjol · Carne asada · Limonada natural', '🥩', 18000, 40, 1),
        ('NASCAR-Comidas', 'Almuerzo del día', 'Crema de ahuyama · Arroz + papa a la francesa · Pollo apanado · Jugo de mora en agua', '🍗', 16000, 40, 2),
        ('NASCAR-Comidas', 'Almuerzo especial', 'Sopa de pasta · Arroz + ensalada · Churrasco 200 g · Limonada de panela', '🔥', 24000, 20, 3),
        ('Chicharrón Mental', 'Corrientazo', 'Consomé de pollo · Arroz + plátano · Chicharrón · Refresco de panela', '🍲', 15000, 50, 1),
        ('Chicharrón Mental', 'Bandeja del día', 'Crema de verduras · Arroz + fríjol + plátano · Chicharrón y carne molida · Limonada natural', '🫘', 22000, 25, 2)
  ) AS x (unidad, nombre, descripcion, emoji, precio, cupos, orden)
  JOIN core.unidades u  ON u.nombre = x.unidad
  JOIN core.menus_dia m ON m.unidad_id = u.id AND m.fecha = core.fn_fecha_operativa(u.empresa_id, now());

COMMIT;

/* Resumen de lo cargado */
SELECT u.nombre AS unidad, t.nombre AS tipo,
       (SELECT count(*) FROM core.producto_unidades pu WHERE pu.unidad_id = u.id) AS carta,
       (SELECT count(*) FROM core.insumo_unidades iu WHERE iu.unidad_id = u.id)   AS inventario,
       (SELECT count(*) FROM core.platos_dia pd JOIN core.menus_dia m ON m.id = pd.menu_dia_id
         WHERE m.unidad_id = u.id) AS platos_dia
  FROM core.unidades u JOIN core.tipos_negocio t ON t.id = u.tipo_negocio_id
 ORDER BY u.id;
