/* ============================================================================
   TASECA · 02 · FUNCIONES INTERNAS (esquema core)
   ----------------------------------------------------------------------------
   Piezas pequeñas que usan los triggers, los procedimientos y las vistas.
   La aplicación no las llama directamente.
   ============================================================================ */

SET search_path = core, public;


/* ---------------------------------------------------------------------------
   Usuario de la operación en curso
   Los procedimientos de api fijan `taseca.usuario_id` para la transacción;
   así los triggers de auditoría e historial saben quién hizo el cambio sin
   pedirlo en cada tabla.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_usuario_actual()
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT NULLIF(current_setting('taseca.usuario_id', TRUE), '')::INTEGER;
$$;

CREATE OR REPLACE FUNCTION core.fn_fijar_usuario(p_usuario_id INTEGER)
RETURNS VOID
LANGUAGE sql
AS $$
    SELECT set_config('taseca.usuario_id', COALESCE(p_usuario_id::TEXT, ''), TRUE);
$$;


/* ---------------------------------------------------------------------------
   Búsqueda de ids de catálogo por código
   Los procedimientos reciben códigos legibles ('entregado', 'efectivo') y
   las tablas guardan ids. Si el código no existe, error claro.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_id_catalogo(p_tabla TEXT, p_codigo TEXT)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_id INTEGER;
BEGIN
    IF p_tabla NOT IN ('modulos', 'tipos_negocio', 'roles', 'permisos', 'metodos_pago',
                       'tipos_pedido', 'estados_pedido', 'estados_pago', 'estados_gasto',
                       'estados_cierre', 'tipos_entrada', 'areas_inventario',
                       'unidades_medida', 'etiquetas_producto', 'tipos_menu') THEN
        RAISE EXCEPTION 'Catálogo no permitido: %', p_tabla;
    END IF;

    EXECUTE format('SELECT id FROM core.%I WHERE codigo = $1', p_tabla)
       INTO v_id USING p_codigo;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No existe "%" en el catálogo %.', p_codigo, p_tabla
              USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_id;
END;
$$;


/* ---------------------------------------------------------------------------
   Jornada operativa
   La jornada empieza a la hora de corte de la empresa: con corte a las 6,
   una venta a la 01:30 del 29 pertenece al día 28.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_fecha_operativa(p_empresa_id INTEGER, p_momento TIMESTAMPTZ DEFAULT now())
RETURNS DATE
LANGUAGE sql STABLE
AS $$
    SELECT ((p_momento AT TIME ZONE e.zona_horaria) - make_interval(hours => e.hora_corte_operativa))::DATE
      FROM core.empresas e
     WHERE e.id = p_empresa_id;
$$;


/* ---------------------------------------------------------------------------
   Consecutivo de facturas: 00001, 00002…
   UPDATE … RETURNING bloquea la fila de la empresa: dos pedidos simultáneos
   nunca reciben el mismo número. Si el número ya existiera (datos migrados)
   se salta al siguiente libre.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_siguiente_codigo_pedido(p_empresa_id INTEGER)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_numero  INTEGER;
    v_digitos SMALLINT;
    v_codigo  VARCHAR;
BEGIN
    INSERT INTO core.consecutivos (empresa_id, tipo)
    VALUES (p_empresa_id, 'pedido')
    ON CONFLICT (empresa_id, tipo) DO NOTHING;

    LOOP
        UPDATE core.consecutivos
           SET ultimo_numero = ultimo_numero + 1
         WHERE empresa_id = p_empresa_id AND tipo = 'pedido'
        RETURNING ultimo_numero, digitos INTO v_numero, v_digitos;

        v_codigo := lpad(v_numero::TEXT, GREATEST(v_digitos, length(v_numero::TEXT)), '0');

        EXIT WHEN NOT EXISTS (
            SELECT 1 FROM core.pedidos WHERE empresa_id = p_empresa_id AND codigo = v_codigo
        );
    END LOOP;

    RETURN v_codigo;
END;
$$;

/* El cliente escribe "27", "#27" o "00027": todos son la factura 00027. */
CREATE OR REPLACE FUNCTION core.fn_normalizar_codigo_pedido(p_empresa_id INTEGER, p_codigo TEXT)
RETURNS VARCHAR
LANGUAGE sql STABLE
AS $$
    SELECT CASE
             WHEN regexp_replace(upper(trim(p_codigo)), '^#', '') ~ '^[0-9]+$'
             THEN lpad(regexp_replace(trim(p_codigo), '^#', ''),
                       COALESCE((SELECT digitos FROM core.consecutivos
                                  WHERE empresa_id = p_empresa_id AND tipo = 'pedido'), 5),
                       '0')
             ELSE regexp_replace(upper(trim(p_codigo)), '^#', '')
           END;
$$;


/* ---------------------------------------------------------------------------
   PIN
   bcrypt con sal propia. La comparación se hace re-cifrando con el hash
   guardado: el PIN nunca se desencripta porque no se puede.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_hash_pin(p_pin TEXT)
RETURNS TEXT
LANGUAGE plpgsql VOLATILE
AS $$
BEGIN
    IF p_pin IS NULL OR p_pin !~ '^[0-9]{4,8}$' THEN
        RAISE EXCEPTION 'El PIN debe tener entre 4 y 8 dígitos.';
    END IF;
    RETURN public.crypt(p_pin, public.gen_salt('bf', 8));
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_pin_valido(p_pin TEXT, p_hash TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT p_hash IS NOT NULL AND public.crypt(p_pin, p_hash) = p_hash;
$$;


/* ---------------------------------------------------------------------------
   Módulos y permisos
   Una persona puede hacer algo si su ROL tiene el permiso Y su EMPRESA
   contrató el módulo del que depende. Los usuarios de plataforma no
   dependen de módulos.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_empresa_tiene_modulo(p_empresa_id INTEGER, p_modulo TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM core.empresa_modulos em
          JOIN core.modulos m ON m.id = em.modulo_id
         WHERE em.empresa_id = p_empresa_id
           AND m.codigo = p_modulo
           AND (em.activo OR m.obligatorio)
    );
$$;

CREATE OR REPLACE FUNCTION core.fn_tiene_permiso(p_usuario_id INTEGER, p_permiso TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM core.usuarios u
          JOIN core.roles r         ON r.id = u.rol_id
          JOIN core.rol_permisos rp ON rp.rol_id = r.id
          JOIN core.permisos p      ON p.id = rp.permiso_id
          LEFT JOIN core.modulos m  ON m.id = p.modulo_id
         WHERE u.id = p_usuario_id
           AND u.activo
           AND p.codigo = p_permiso
           AND (
                 r.alcance = 'plataforma'
              OR m.id IS NULL
              OR core.fn_empresa_tiene_modulo(u.empresa_id, m.codigo)
           )
    );
$$;

/* Lanza un error si el usuario no puede. Sin usuario (NULL) se permite:
   es la carga de datos inicial y la consola del DBA, igual que en el MVP. */
CREATE OR REPLACE FUNCTION core.fn_exigir_permiso(p_usuario_id INTEGER, p_permiso TEXT)
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    IF p_usuario_id IS NOT NULL AND NOT core.fn_tiene_permiso(p_usuario_id, p_permiso) THEN
        RAISE EXCEPTION 'El usuario % no tiene el permiso "%".', p_usuario_id, p_permiso
              USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;

/* ¿El usuario trabaja en esta unidad? Sin unidades asignadas = todas las de
   su empresa. Los usuarios de plataforma, todas. */
CREATE OR REPLACE FUNCTION core.fn_usuario_en_unidad(p_usuario_id INTEGER, p_unidad_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT p_usuario_id IS NULL
        OR EXISTS (
            SELECT 1
              FROM core.usuarios u
              JOIN core.roles r    ON r.id = u.rol_id
              JOIN core.unidades d ON d.id = p_unidad_id
             WHERE u.id = p_usuario_id
               AND (   r.alcance = 'plataforma'
                    OR (u.empresa_id = d.empresa_id
                        AND (NOT EXISTS (SELECT 1 FROM core.usuario_unidades x WHERE x.usuario_id = u.id)
                             OR EXISTS (SELECT 1 FROM core.usuario_unidades x
                                         WHERE x.usuario_id = u.id AND x.unidad_id = p_unidad_id))))
        );
$$;


/* ---------------------------------------------------------------------------
   Unidades
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_empresa_de_unidad(p_unidad_id INTEGER)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT empresa_id FROM core.unidades WHERE id = p_unidad_id;
$$;

/* Una unidad inactiva conserva su historia pero no admite operación nueva. */
CREATE OR REPLACE FUNCTION core.fn_exigir_unidad_operativa(p_unidad_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_nombre  VARCHAR;
    v_estado  VARCHAR;
    v_empresa VARCHAR;
BEGIN
    SELECT u.nombre, u.estado, e.estado
      INTO v_nombre, v_estado, v_empresa
      FROM core.unidades u
      JOIN core.empresas e ON e.id = u.empresa_id
     WHERE u.id = p_unidad_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    ELSIF v_estado <> 'activa' THEN
        RAISE EXCEPTION 'La unidad "%" está inactiva: no admite operación nueva. Su información histórica se conserva.', v_nombre;
    ELSIF v_empresa <> 'activa' THEN
        RAISE EXCEPTION 'La empresa de la unidad "%" no está activa.', v_nombre;
    END IF;
END;
$$;


/* ---------------------------------------------------------------------------
   Pedidos: cálculos
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.fn_subtotal_pedido(p_pedido_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(precio_unitario * cantidad), 0)
      FROM core.pedido_items
     WHERE pedido_id = p_pedido_id;
$$;

/* Cuántas unidades de un plato del chef ya se vendieron (sin cancelados ni
   anulados). Los cupos restantes salen de aquí: no se guarda un contador
   que pueda desincronizarse. */
CREATE OR REPLACE FUNCTION core.fn_vendidos_plato(p_plato_dia_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(i.cantidad), 0)::INTEGER
      FROM core.pedido_items i
      JOIN core.pedidos p        ON p.id = i.pedido_id
      JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
     WHERE i.plato_dia_id = p_plato_dia_id
       AND e.cuenta_como_venta;
$$;

/* Siguiente estado del flujo según el tipo de pedido: una mesa no pasa por
   «en camino». NULL si ya está en el último. */
CREATE OR REPLACE FUNCTION core.fn_siguiente_estado(p_pedido_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT sig.id
      FROM core.pedidos p
      JOIN core.tipos_pedido t   ON t.id = p.tipo_pedido_id
      JOIN core.estados_pedido a ON a.id = p.estado_pedido_id
      JOIN LATERAL (
            SELECT e.id
              FROM core.estados_pedido e
             WHERE e.orden > a.orden
               AND e.orden < 90
               AND (NOT e.solo_domicilio OR t.codigo = 'domicilio')
             ORDER BY e.orden
             LIMIT 1
      ) sig ON TRUE
     WHERE p.id = p_pedido_id
       AND a.orden < 90;
$$;
