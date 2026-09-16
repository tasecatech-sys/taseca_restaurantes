/* ============================================================================
   TASECA · 17 · INTEGRIDAD MULTIEMPRESA
   ----------------------------------------------------------------------------
   Dos cosas:

     1. api.fn_chequeo_integridad() revisa TODA la base y dice, para cada
        relación, si hay filas mal enlazadas o sueltas:
          · ERROR = datos que se cruzan entre empresas o unidades, o registros
            incompletos. No debería haber ninguno.
          · AVISO = datos que no están mal, pero que no ve nadie (un producto
            que no está en ninguna unidad, un cliente sin pedidos…). Sirven
            para limpiar; no son un fallo.

     2. Triggers que impiden que eso vuelva a pasar en las tablas que aún no
        los tenían (pedidos, ítems, entradas, cierres y bases). Los
        procedimientos ya validaban casi todo; esto es la red de seguridad de
        la base, que se cumple venga el dato de donde venga.

   Cómo se usa el chequeo (en DBeaver, Alt+X):

       SELECT * FROM api.fn_chequeo_integridad();                  -- todo
       SELECT * FROM api.fn_chequeo_integridad() WHERE filas > 0;  -- sólo lo que hay que mirar

   No modifica datos. Se puede ejecutar más de una vez.
   Requiere: 00 … 16 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. CHEQUEO
   ============================================================================ */

CREATE OR REPLACE FUNCTION api.fn_chequeo_integridad()
RETURNS TABLE (gravedad TEXT, tabla TEXT, chequeo TEXT, filas BIGINT, ejemplo TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $funcion$
DECLARE
    c    RECORD;
    v_n  BIGINT;
    v_ej TEXT;
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
        /* ---------- PEDIDOS: de qué empresa y de qué unidad es cada factura ---------- */
        ('ERROR', 'pedidos', 'La empresa de la factura no es la de su unidad',
         $q$SELECT p.id FROM core.pedidos p JOIN core.unidades u ON u.id = p.unidad_id
             WHERE p.empresa_id <> u.empresa_id$q$),
        ('ERROR', 'pedidos', 'La mesa es de otra unidad',
         $q$SELECT p.id FROM core.pedidos p JOIN core.mesas m ON m.id = p.mesa_id
             WHERE m.unidad_id <> p.unidad_id$q$),
        ('ERROR', 'pedidos', 'La zona de domicilio es de otra unidad',
         $q$SELECT p.id FROM core.pedidos p JOIN core.zonas_domicilio z ON z.id = p.zona_domicilio_id
             WHERE z.unidad_id <> p.unidad_id$q$),
        ('ERROR', 'pedidos', 'El cliente es de otra empresa',
         $q$SELECT p.id FROM core.pedidos p JOIN core.clientes cl ON cl.id = p.cliente_id
             WHERE cl.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'pedidos', 'Lo tomó un usuario de otra empresa',
         $q$SELECT p.id FROM core.pedidos p JOIN core.usuarios us ON us.id = p.tomado_por_id
             WHERE us.empresa_id IS NOT NULL AND us.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'pedidos', 'El método de pago no está habilitado en esa empresa',
         $q$SELECT p.id FROM core.pedidos p
             WHERE NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago emp
                                WHERE emp.empresa_id = p.empresa_id AND emp.metodo_pago_id = p.metodo_pago_id)$q$),
        ('ERROR', 'pedidos', 'Factura anulada sin registro de anulación',
         $q$SELECT p.id FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
             WHERE e.codigo = 'anulado'
               AND NOT EXISTS (SELECT 1 FROM core.anulaciones a WHERE a.pedido_id = p.id)$q$),
        ('ERROR', 'pedidos', 'Factura sin ningún ítem',
         $q$SELECT p.id FROM core.pedidos p
             WHERE NOT EXISTS (SELECT 1 FROM core.pedido_items i WHERE i.pedido_id = p.id)$q$),

        /* ---------- ÍTEMS: lo vendido existe en esa empresa y esa unidad ---------- */
        ('ERROR', 'pedido_items', 'El producto es de otra empresa',
         $q$SELECT i.id FROM core.pedido_items i JOIN core.pedidos p ON p.id = i.pedido_id
             JOIN core.productos pr ON pr.id = i.producto_id
             WHERE pr.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'pedido_items', 'El plato del día es de otra unidad',
         $q$SELECT i.id FROM core.pedido_items i JOIN core.pedidos p ON p.id = i.pedido_id
             JOIN core.platos_dia pd ON pd.id = i.plato_dia_id
             JOIN core.menus_dia md ON md.id = pd.menu_dia_id
             WHERE md.unidad_id <> p.unidad_id$q$),
        ('ERROR', 'pedido_items', 'El menú armado es de otra unidad',
         $q$SELECT i.id FROM core.pedido_items i JOIN core.pedidos p ON p.id = i.pedido_id
             JOIN core.menus_dia md ON md.id = i.menu_dia_id
             WHERE md.unidad_id <> p.unidad_id$q$),
        ('ERROR', 'pedido_item_opciones', 'La opción elegida no es del menú de ese ítem',
         $q$SELECT o.id FROM core.pedido_item_opciones o
             JOIN core.pedido_items i ON i.id = o.pedido_item_id
             JOIN core.menu_opciones mo ON mo.id = o.menu_opcion_id
             JOIN core.menu_categorias mc ON mc.id = mo.menu_categoria_id
             WHERE mc.menu_dia_id IS DISTINCT FROM i.menu_dia_id$q$),
        ('AVISO', 'pedido_items', 'Producto que hoy ya no está en esa unidad (histórico: normal si se retiró)',
         $q$SELECT i.id FROM core.pedido_items i JOIN core.pedidos p ON p.id = i.pedido_id
             WHERE i.producto_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM core.producto_unidades pu
                                WHERE pu.producto_id = i.producto_id AND pu.unidad_id = p.unidad_id)$q$),

        /* ---------- PAGOS, HISTORIAL Y ANULACIONES ---------- */
        ('ERROR', 'pedido_historial', 'Movimiento escrito por un usuario de otra empresa',
         $q$SELECT h.id FROM core.pedido_historial h JOIN core.pedidos p ON p.id = h.pedido_id
             JOIN core.usuarios u ON u.id = h.usuario_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'comprobantes_pago', 'Comprobante revisado por un usuario de otra empresa',
         $q$SELECT cp.id FROM core.comprobantes_pago cp JOIN core.pedidos p ON p.id = cp.pedido_id
             JOIN core.usuarios u ON u.id = cp.revisado_por_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> p.empresa_id$q$),
        ('ERROR', 'anulaciones', 'Anulación firmada por un usuario de otra empresa',
         $q$SELECT a.id FROM core.anulaciones a JOIN core.pedidos p ON p.id = a.pedido_id
             JOIN core.usuarios u ON u.id = a.usuario_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> p.empresa_id$q$),

        /* ---------- INVENTARIO ---------- */
        ('ERROR', 'insumo_unidades', 'Insumo de una empresa en la unidad de otra',
         $q$SELECT iu.id FROM core.insumo_unidades iu JOIN core.insumos s ON s.id = iu.insumo_id
             WHERE s.empresa_id <> core.fn_empresa_de_unidad(iu.unidad_id)$q$),
        ('ERROR', 'entradas_inventario', 'Entrada registrada por un usuario de otra empresa',
         $q$SELECT e.id FROM core.entradas_inventario e
             JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
             JOIN core.usuarios u ON u.id = e.usuario_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(iu.unidad_id)$q$),
        ('ERROR', 'entradas_inventario', 'Retorno de una factura de otra unidad',
         $q$SELECT e.id FROM core.entradas_inventario e
             JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
             JOIN core.pedidos p ON p.id = e.pedido_id
             WHERE p.unidad_id <> iu.unidad_id$q$),
        ('ERROR', 'cierres_inventario', 'Cierre firmado por un usuario de otra empresa',
         $q$SELECT ci.id FROM core.cierres_inventario ci
             JOIN core.usuarios u ON u.id IN (ci.registrado_por_id, ci.revisado_por_id)
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(ci.unidad_id)$q$),
        ('ERROR', 'cierre_detalles', 'Producto contado que no es de la unidad del cierre',
         $q$SELECT d.id FROM core.cierre_detalles d
             JOIN core.cierres_inventario ci ON ci.id = d.cierre_id
             JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
             WHERE iu.unidad_id <> ci.unidad_id$q$),
        ('AVISO', 'cierre_detalles', 'Producto contado de un área distinta a la del cierre',
         $q$SELECT d.id FROM core.cierre_detalles d
             JOIN core.cierres_inventario ci ON ci.id = d.cierre_id
             JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
             JOIN core.insumos s ON s.id = iu.insumo_id
             WHERE s.area_id <> ci.area_id$q$),

        /* ---------- CAJA Y GASTOS ---------- */
        ('ERROR', 'bases_caja', 'Base registrada por un usuario de otra empresa',
         $q$SELECT b.id FROM core.bases_caja b JOIN core.usuarios u ON u.id = b.usuario_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(b.unidad_id)$q$),
        ('ERROR', 'gastos', 'La categoría del gasto es de otra empresa',
         $q$SELECT g.id FROM core.gastos g JOIN core.categorias_gasto cg ON cg.id = g.categoria_gasto_id
             WHERE cg.empresa_id <> core.fn_empresa_de_unidad(g.unidad_id)$q$),
        ('ERROR', 'gastos', 'Gasto movido por un usuario de otra empresa',
         $q$SELECT g.id FROM core.gastos g
             JOIN core.usuarios u ON u.id IN (g.registrado_por_id, g.confirmado_por_id, g.anulado_por_id)
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(g.unidad_id)$q$),
        ('ERROR', 'gastos', 'El método de pago no está habilitado en esa empresa',
         $q$SELECT g.id FROM core.gastos g
             WHERE NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago emp
                                WHERE emp.empresa_id = core.fn_empresa_de_unidad(g.unidad_id)
                                  AND emp.metodo_pago_id = g.metodo_pago_id)$q$),

        /* ---------- CARTA, MENÚ Y CATÁLOGOS ---------- */
        ('ERROR', 'productos', 'La categoría del producto es de otra empresa',
         $q$SELECT pr.id FROM core.productos pr JOIN core.categorias ca ON ca.id = pr.categoria_id
             WHERE ca.empresa_id <> pr.empresa_id$q$),
        ('ERROR', 'producto_unidades', 'Producto de una empresa en la unidad de otra',
         $q$SELECT pu.id FROM core.producto_unidades pu JOIN core.productos pr ON pr.id = pu.producto_id
             WHERE pr.empresa_id <> core.fn_empresa_de_unidad(pu.unidad_id)$q$),
        ('ERROR', 'categoria_unidades', 'Categoría de una empresa en la unidad de otra',
         $q$SELECT cu.id FROM core.categoria_unidades cu JOIN core.categorias ca ON ca.id = cu.categoria_id
             WHERE ca.empresa_id <> core.fn_empresa_de_unidad(cu.unidad_id)$q$),
        ('ERROR', 'insumos', 'La categoría del insumo es de otra empresa',
         $q$SELECT s.id FROM core.insumos s JOIN core.categorias_insumo ci ON ci.id = s.categoria_insumo_id
             WHERE ci.empresa_id <> s.empresa_id$q$),
        ('ERROR', 'producto_insumos', 'Receta que une producto e insumo de empresas distintas',
         $q$SELECT pi.id FROM core.producto_insumos pi
             JOIN core.productos pr ON pr.id = pi.producto_id
             JOIN core.insumos s ON s.id = pi.insumo_id
             WHERE pr.empresa_id <> s.empresa_id$q$),
        ('ERROR', 'menus_dia', 'Menú creado por un usuario de otra empresa',
         $q$SELECT md.id FROM core.menus_dia md JOIN core.usuarios u ON u.id = md.creado_por_id
             WHERE u.empresa_id IS NOT NULL AND u.empresa_id <> core.fn_empresa_de_unidad(md.unidad_id)$q$),

        /* ---------- USUARIOS Y EMPRESAS ---------- */
        ('ERROR', 'usuarios', 'Usuario de empresa sin empresa, o de plataforma con empresa',
         $q$SELECT u.id FROM core.usuarios u
             WHERE (u.empresa_id IS NULL) <> EXISTS (SELECT 1 FROM core.rol_permisos rp
                                                       JOIN core.permisos pe ON pe.id = rp.permiso_id
                                                      WHERE rp.rol_id = u.rol_id AND pe.codigo = 'plataforma')$q$),
        ('ERROR', 'usuario_unidades', 'Usuario asignado a la unidad de otra empresa',
         $q$SELECT uu.id FROM core.usuario_unidades uu JOIN core.usuarios u ON u.id = uu.usuario_id
             WHERE u.empresa_id IS DISTINCT FROM core.fn_empresa_de_unidad(uu.unidad_id)$q$),
        ('ERROR', 'empresas', 'Empresa sin ninguna unidad',
         $q$SELECT e.id FROM core.empresas e
             WHERE NOT EXISTS (SELECT 1 FROM core.unidades un WHERE un.empresa_id = e.id)$q$),
        ('ERROR', 'empresas', 'Empresa sin ningún método de pago activo',
         $q$SELECT e.id FROM core.empresas e
             WHERE NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago emp
                                WHERE emp.empresa_id = e.id AND emp.activo)$q$),
        ('ERROR', 'empresas', 'Empresa sin numeración de facturas',
         $q$SELECT e.id FROM core.empresas e
             WHERE NOT EXISTS (SELECT 1 FROM core.consecutivos co
                                WHERE co.empresa_id = e.id AND co.tipo = 'pedido')$q$),

        /* ---------- DATOS SUELTOS: no es un fallo, es limpieza ---------- */
        ('AVISO', 'empresas', 'Empresa activa sin ningún administrador activo',
         $q$SELECT e.id FROM core.empresas e
             WHERE e.estado = 'activa'
               AND NOT EXISTS (SELECT 1 FROM core.usuarios u JOIN core.roles r ON r.id = u.rol_id
                                WHERE u.empresa_id = e.id AND u.activo
                                  AND r.codigo IN ('admin', 'administrador'))$q$),
        ('AVISO', 'unidades', 'Unidad activa sin ningún usuario asignado',
         $q$SELECT un.id FROM core.unidades un
             WHERE un.estado = 'activa'
               AND NOT EXISTS (SELECT 1 FROM core.usuario_unidades uu WHERE uu.unidad_id = un.id)$q$),
        ('AVISO', 'productos', 'Producto que no está en ninguna unidad: no lo ve nadie',
         $q$SELECT pr.id FROM core.productos pr
             WHERE NOT EXISTS (SELECT 1 FROM core.producto_unidades pu WHERE pu.producto_id = pr.id)$q$),
        ('AVISO', 'categorias', 'Categoría que no está en ninguna unidad',
         $q$SELECT ca.id FROM core.categorias ca
             WHERE NOT EXISTS (SELECT 1 FROM core.categoria_unidades cu WHERE cu.categoria_id = ca.id)$q$),
        ('AVISO', 'insumos', 'Insumo que no está en ninguna unidad',
         $q$SELECT s.id FROM core.insumos s
             WHERE NOT EXISTS (SELECT 1 FROM core.insumo_unidades iu WHERE iu.insumo_id = s.id)$q$),
        ('AVISO', 'insumos', 'Insumo activo sin enlace con la carta: su Z siempre será 0',
         $q$SELECT s.id FROM core.insumos s
             WHERE s.activo
               AND NOT EXISTS (SELECT 1 FROM core.producto_insumos pi WHERE pi.insumo_id = s.id)$q$),
        ('AVISO', 'menus_dia', 'Menú del día sin platos ni categorías',
         $q$SELECT md.id FROM core.menus_dia md
             WHERE NOT EXISTS (SELECT 1 FROM core.platos_dia pd WHERE pd.menu_dia_id = md.id)
               AND NOT EXISTS (SELECT 1 FROM core.menu_categorias mc WHERE mc.menu_dia_id = md.id)$q$),
        ('AVISO', 'menu_categorias', 'Categoría del menú armado sin opciones',
         $q$SELECT mc.id FROM core.menu_categorias mc
             WHERE NOT EXISTS (SELECT 1 FROM core.menu_opciones mo WHERE mo.menu_categoria_id = mc.id)$q$),
        ('AVISO', 'clientes', 'Cliente sin ninguna factura',
         $q$SELECT cl.id FROM core.clientes cl
             WHERE NOT EXISTS (SELECT 1 FROM core.pedidos p WHERE p.cliente_id = cl.id)$q$),
        ('AVISO', 'unidades', 'Unidad activa sin mesas configuradas (sólo importa si atiende en mesa)',
         $q$SELECT un.id FROM core.unidades un
             WHERE un.estado = 'activa'
               AND NOT EXISTS (SELECT 1 FROM core.mesas m WHERE m.unidad_id = un.id)$q$)
        ) AS x (g, t, ch, q)
    LOOP
        EXECUTE format('SELECT count(*) FROM (%s) AS z', c.q) INTO v_n;
        v_ej := NULL;
        IF v_n > 0 THEN
            EXECUTE format('SELECT string_agg(z.id::TEXT, '', '') FROM (%s LIMIT 5) AS z', c.q) INTO v_ej;
            IF v_n > 5 THEN
                v_ej := v_ej || ', …';
            END IF;
        END IF;
        gravedad := c.g;
        tabla    := c.t;
        chequeo  := c.ch;
        filas    := v_n;
        ejemplo  := v_ej;
        RETURN NEXT;
    END LOOP;
END;
$funcion$;

COMMENT ON FUNCTION api.fn_chequeo_integridad() IS
    'Revisión de relaciones: ERROR = datos cruzados entre empresas o unidades; AVISO = datos sueltos que no ve nadie. No modifica nada.';

REVOKE ALL ON FUNCTION api.fn_chequeo_integridad() FROM PUBLIC;


/* ============================================================================
   2. RED DE SEGURIDAD: LO QUE YA NO PODRÁ CRUZARSE

   Un usuario de plataforma (empresa NULL) sí puede operar dentro de la
   empresa que está administrando: por eso sus comparaciones se saltan.
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_relaciones_empresa()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_empresa INTEGER;   -- empresa a la que pertenece la fila
    v_unidad  INTEGER;   -- unidad a la que pertenece la fila
    v_otra    INTEGER;
BEGIN
    CASE TG_TABLE_NAME

    WHEN 'pedidos' THEN
        IF NEW.empresa_id <> core.fn_empresa_de_unidad(NEW.unidad_id) THEN
            RAISE EXCEPTION 'La factura % sería de una empresa distinta a la de su unidad.', NEW.codigo
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.mesa_id IS NOT NULL
           AND (SELECT unidad_id FROM core.mesas WHERE id = NEW.mesa_id) <> NEW.unidad_id THEN
            RAISE EXCEPTION 'Esa mesa es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.zona_domicilio_id IS NOT NULL
           AND (SELECT unidad_id FROM core.zonas_domicilio WHERE id = NEW.zona_domicilio_id) <> NEW.unidad_id THEN
            RAISE EXCEPTION 'Esa zona de domicilio es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.cliente_id IS NOT NULL
           AND (SELECT empresa_id FROM core.clientes WHERE id = NEW.cliente_id) <> NEW.empresa_id THEN
            RAISE EXCEPTION 'Ese cliente es de otra empresa.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.tomado_por_id;
        IF v_otra IS NOT NULL AND v_otra <> NEW.empresa_id THEN
            RAISE EXCEPTION 'Ese usuario no es de la empresa de la factura.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'pedido_items' THEN
        SELECT p.empresa_id, p.unidad_id INTO v_empresa, v_unidad
          FROM core.pedidos p WHERE p.id = NEW.pedido_id;
        IF NEW.producto_id IS NOT NULL
           AND (SELECT empresa_id FROM core.productos WHERE id = NEW.producto_id) <> v_empresa THEN
            RAISE EXCEPTION 'Ese producto es de otra empresa.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.plato_dia_id IS NOT NULL
           AND (SELECT md.unidad_id FROM core.platos_dia pd JOIN core.menus_dia md ON md.id = pd.menu_dia_id
                 WHERE pd.id = NEW.plato_dia_id) <> v_unidad THEN
            RAISE EXCEPTION 'Ese plato del día es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.menu_dia_id IS NOT NULL
           AND (SELECT unidad_id FROM core.menus_dia WHERE id = NEW.menu_dia_id) <> v_unidad THEN
            RAISE EXCEPTION 'Ese menú es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'pedido_item_opciones' THEN
        SELECT i.menu_dia_id INTO v_otra FROM core.pedido_items i WHERE i.id = NEW.pedido_item_id;
        IF (SELECT mc.menu_dia_id FROM core.menu_opciones mo
              JOIN core.menu_categorias mc ON mc.id = mo.menu_categoria_id
             WHERE mo.id = NEW.menu_opcion_id) IS DISTINCT FROM v_otra THEN
            RAISE EXCEPTION 'Esa opción no es del menú de ese ítem.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'entradas_inventario' THEN
        SELECT iu.unidad_id INTO v_unidad FROM core.insumo_unidades iu WHERE iu.id = NEW.insumo_unidad_id;
        IF NEW.pedido_id IS NOT NULL
           AND (SELECT unidad_id FROM core.pedidos WHERE id = NEW.pedido_id) <> v_unidad THEN
            RAISE EXCEPTION 'Esa factura es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.usuario_id;
        IF v_otra IS NOT NULL AND v_otra <> core.fn_empresa_de_unidad(v_unidad) THEN
            RAISE EXCEPTION 'Ese usuario no es de la empresa de la unidad.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'cierre_detalles' THEN
        SELECT ci.unidad_id INTO v_unidad FROM core.cierres_inventario ci WHERE ci.id = NEW.cierre_id;
        IF (SELECT unidad_id FROM core.insumo_unidades WHERE id = NEW.insumo_unidad_id) <> v_unidad THEN
            RAISE EXCEPTION 'Ese producto no es de la unidad del cierre.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'bases_caja' THEN
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.usuario_id;
        IF v_otra IS NOT NULL AND v_otra <> core.fn_empresa_de_unidad(NEW.unidad_id) THEN
            RAISE EXCEPTION 'Ese usuario no es de la empresa de la unidad.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    ELSE
        RAISE EXCEPTION 'tg_relaciones_empresa no está preparado para %', TG_TABLE_NAME;
    END CASE;

    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['pedidos', 'pedido_items', 'pedido_item_opciones',
                             'entradas_inventario', 'cierre_detalles', 'bases_caja']
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_relaciones ON core.%1$I', t);
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_relaciones BEFORE INSERT OR UPDATE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_relaciones_empresa()', t);
    END LOOP;
END;
$$;

NOTIFY pgrst, 'reload schema';
