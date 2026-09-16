/* ============================================================================
   TASECA · 15 · PRUEBAS DE CONFIGURACIÓN, AJUSTES Y PLATAFORMA (fase 2, bloque 5)
   ----------------------------------------------------------------------------
   Ejecutar después de 15_fase2_configuracion_plataforma.sql. Todo corre como
   la aplicación (rol taseca_app con un token simulado) dentro de una
   transacción que termina en ROLLBACK: no deja ningún dato.

   En DBeaver: Alt+X y mira la pestaña «Salida». Cada prueba escribe ✔.
   ============================================================================ */

BEGIN;

CREATE FUNCTION pg_temp.esperar_error(p_sql TEXT, p_contiene TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM ILIKE '%' || p_contiene || '%' THEN
            RAISE NOTICE '      ✔ bloqueado como se esperaba: %', SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'Falló con otro error: «%» (se esperaba «%»)', SQLERRM, p_contiene;
    END;
    RAISE EXCEPTION 'Debió fallar y no falló: %', p_sql;
END;
$$;

/* Token simulado. p_empresa: NULL = la del usuario; -1 = ninguna. */
CREATE FUNCTION pg_temp.token(p_usuario TEXT, p_empresa INTEGER DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_id INTEGER;
    v_empresa INTEGER;
BEGIN
    SELECT id, empresa_id INTO v_id, v_empresa FROM core.usuarios WHERE usuario = p_usuario;
    PERFORM set_config('request.jwt.claims',
                       jsonb_build_object('role', 'taseca_app', 'usuario_id', v_id,
                                          'empresa_id', CASE WHEN p_empresa = -1 THEN NULL ELSE COALESCE(p_empresa, v_empresa) END)::TEXT, TRUE);
END;
$$;

CREATE FUNCTION pg_temp.app(p_sql TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v JSONB;
BEGIN
    SET LOCAL ROLE taseca_app;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
END;
$$;

DO $$
DECLARE
    v_nascar INTEGER; v_r JSONB; v_polo INTEGER; v_n INTEGER;
BEGIN
    SELECT id INTO v_nascar FROM core.empresas WHERE codigo = 'empresa_nascar';

    -- 1 · LA EMPRESA COMPLETA PARA LA APLICACIÓN -----------------------------------------
    PERFORM pg_temp.token('mesero');
    v_r := pg_temp.app('SELECT to_jsonb(e) FROM rest.empresas e WHERE codigo = ''empresa_nascar''');
    ASSERT v_r -> 'modulos' = '{"basico": true, "stock": true, "cierre": true}'::JSONB, format('Módulos (salió %s)', v_r -> 'modulos');
    ASSERT jsonb_array_length(v_r -> 'metodos_pago') = 3 AND v_r ->> 'tipografia' = 'barlow'
       AND v_r ->> 'logo_texto' = 'NAS' AND v_r ->> 'logo_acento' = 'CAR', 'Métodos de pago y tema';
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.plataforma_empresas')::TEXT::INTEGER = 0,
           'Un usuario de empresa no ve el listado de la plataforma';
    RAISE NOTICE '✔ 1  rest.empresas: módulos, métodos de pago y tema; la lista de plataforma no es para empresas';

    -- 2 · CONFIGURACIÓN DEL NEGOCIO ---------------------------------------------------------
    PERFORM pg_temp.token('admin');
    v_r := pg_temp.app($s$SELECT rest.guardar_configuracion('{"nombre_comercial": "NASCAR", "eslogan": "Cocina de alta velocidad",
        "nit": "901.554.221-3", "whatsapp": "57 320 212 0632", "telefono": "320 212 0632", "email": "hola@nascar.co",
        "direccion": "Av. Calle 80 # 102-52", "horario_general": "Todos los días", "tiempo_mesa": "15 min",
        "tiempo_domicilio": "40 min", "hora_corte_operativa": 5}',
        '[{"entidad": "Nequi", "numero": "300 000 0000", "titular": "NASCAR S.A.S."},
          {"entidad": "Bancolombia", "numero": "Ahorros 123", "titular": "NASCAR S.A.S."}]')$s$);
    ASSERT v_r ->> 'whatsapp' = '573202120632' AND (v_r ->> 'hora_corte_operativa')::INTEGER = 5
       AND jsonb_array_length(v_r -> 'cuentas') = 2 AND v_r ->> 'nit' = '901.554.221-3', 'Datos, corte y cuentas guardados';

    v_r := pg_temp.app($s$SELECT rest.guardar_configuracion('{"nombre_comercial": "NASCAR", "hora_corte_operativa": 6}',
        '[{"entidad": "Daviplata", "numero": "301 000 0000", "titular": "NASCAR"}]')$s$);
    ASSERT jsonb_array_length(v_r -> 'cuentas') = 1 AND v_r -> 'cuentas' -> 0 ->> 'entidad' = 'Daviplata',
           'Las cuentas que no vienen dejan de mostrarse (no se borran)';
    ASSERT (SELECT count(*) FROM core.cuentas_recaudo WHERE empresa_id = v_nascar) = 3, 'Las anteriores siguen guardadas, inactivas';

    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_configuracion(''{"nombre_comercial": "NASCAR", "whatsapp": "3001"}'')')$s$, 'indicativo');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_configuracion(''{"nombre_comercial": "NASCAR", "hora_corte_operativa": 30}'')')$s$, 'entre 0 y 23');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_configuracion(''{"nombre_comercial": "N"}'')')$s$, 'nombre comercial');
    PERFORM pg_temp.token('caja');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_configuracion(''{"nombre_comercial": "Caja S.A."}'')')$s$, 'permiso "config_local"');
    RAISE NOTICE '✔ 2  Configuración: datos, hora de corte y cuentas; WhatsApp, corte y nombre inválidos; caja no configura';

    -- 3 · MÉTODOS DE PAGO ------------------------------------------------------------------
    PERFORM pg_temp.token('admin');
    v_r := pg_temp.app($s$SELECT rest.guardar_metodos_pago('[{"codigo": "efectivo", "activo": true}, {"codigo": "datafono", "activo": false},
        {"codigo": "transferencia", "activo": true}]')$s$);
    ASSERT (SELECT count(*) FROM jsonb_array_elements(v_r) m WHERE (m ->> 'activo')::BOOLEAN) = 2, 'Datáfono apagado';
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_metodos_pago(''[{"codigo": "efectivo", "activo": false},
        {"codigo": "transferencia", "activo": false}]'')')$s$, 'al menos un método');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_metodos_pago(''[{"codigo": "bitcoin", "activo": true}]'')')$s$, 'no existe');
    RAISE NOTICE '✔ 3  Métodos de pago: se apagan y encienden, siempre queda uno, no se inventan';

    -- 4 · FACTURAS DE PRUEBA -------------------------------------------------------------
    PERFORM rest.crear_pedido((SELECT id FROM core.unidades WHERE nombre = 'COMIC''ENDO AREPA'), 'mesa', 'efectivo',
        format('[{"producto_id": %s, "cantidad": 1}]',
               (SELECT pu.producto_id FROM core.producto_unidades pu JOIN core.unidades u ON u.id = pu.unidad_id
                 WHERE u.nombre = 'COMIC''ENDO AREPA' LIMIT 1))::JSONB, p_mesa => '1');
    v_n := (pg_temp.app('SELECT rest.facturas_prueba()') ->> 'pedidos')::INTEGER;
    ASSERT v_n >= 1, 'Cuenta las facturas de la empresa';
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.borrar_facturas_prueba(''borrar no'')')$s$, 'BORRAR');
    v_r := pg_temp.app($s$SELECT rest.borrar_facturas_prueba('borrar')$s$);
    ASSERT (v_r ->> 'pedidos')::INTEGER = v_n AND (pg_temp.app('SELECT rest.facturas_prueba()') ->> 'pedidos')::INTEGER = 0,
           'Borra todas y la cuenta queda en cero';
    PERFORM pg_temp.token('caja');
    ASSERT (pg_temp.app('SELECT rest.facturas_prueba()') ->> 'pedidos')::INTEGER = 0, 'Sin permiso de anular, la cuenta es 0';
    RAISE NOTICE '✔ 4  Facturas de prueba: contar y borrar con la confirmación BORRAR';

    -- 5 · PLATAFORMA: ALTA COMPLETA ---------------------------------------------------------
    PERFORM pg_temp.token('admin');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.alta_empresa(''{"nombre_comercial": "Intrusa"}'')')$s$, 'Sólo la plataforma');

    PERFORM pg_temp.token('super', -1);
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.plataforma_empresas')::TEXT::INTEGER >= 1, 'La plataforma ve las empresas';

    -- Un alta que falla (acceso repetido) no deja nada a medias
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.alta_empresa(''{"nombre_comercial": "Empresa Rota",
        "admin": {"nombre": "Otro", "usuario": "admin", "pin": "1234"}}'')')$s$, 'Ya existe otro usuario');
    ASSERT NOT EXISTS (SELECT 1 FROM core.empresas WHERE nombre_comercial = 'Empresa Rota'), 'Sin empresa a medio montar';

    v_r := pg_temp.app($s$SELECT rest.alta_empresa('{"nombre_comercial": "Heladería Polo Norte", "razon_social": "Polo Norte SAS",
        "whatsapp": "573001234567", "direccion": "Cra 7 # 1-2", "ciudad": "Bogotá", "tipo_negocio": "heladeria",
        "plantilla": "heladeria", "modulos": {"stock": true},
        "tema": {"primary": "#FF3366", "secondary": "#2233AA", "accent": "#00CCFF", "background": "#101820",
                 "fontFamily": "inter", "logoTexto": "POLO", "logoAcento": "NORTE", "iniciales": "pn", "lema": "Frío del bueno"},
        "admin": {"nombre": "Admin Polo", "usuario": "polo.admin", "pin": "4321"}}')$s$);
    v_polo := (v_r ->> 'empresa_id')::INTEGER;
    ASSERT v_r ->> 'codigo' = 'empresa_heladeria_polo_norte', format('Código estable desde el nombre (salió %s)', v_r ->> 'codigo');
    ASSERT v_r -> 'modulos' = '{"basico": true, "stock": true, "cierre": false}'::JSONB, 'Básico siempre; stock sí; cierre no';
    ASSERT v_r ->> 'iniciales' = 'PN' AND v_r ->> 'color_primario' = '#FF3366', 'Con su tema';
    ASSERT (v_r ->> 'n_unidades')::INTEGER = 1 AND (v_r ->> 'n_usuarios')::INTEGER = 1, 'Una unidad y su administrador';
    ASSERT jsonb_array_length(v_r -> 'metodos_pago') = 3
       AND (SELECT count(*) FROM core.categorias_gasto WHERE empresa_id = v_polo) = 6
       AND EXISTS (SELECT 1 FROM core.consecutivos WHERE empresa_id = v_polo), 'Métodos, categorías de gasto y numeración';
    ASSERT (SELECT empresa_id FROM api.fn_login('polo.admin', '4321')) = v_polo, 'Su administrador entra con su PIN';
    ASSERT NOT EXISTS (SELECT 1 FROM core.productos WHERE empresa_id = v_polo)
       AND NOT EXISTS (SELECT 1 FROM core.insumos WHERE empresa_id = v_polo), 'No hereda carta ni inventario de nadie';

    v_r := pg_temp.app($s$SELECT rest.alta_empresa('{"nombre_comercial": "Heladería Polo Norte"}')$s$);
    ASSERT v_r ->> 'codigo' = 'empresa_heladeria_polo_norte_2', 'Mismo nombre: otro código';
    RAISE NOTICE '✔ 5  Alta completa en una transacción: ficha, unidad, módulos, tema, métodos, categorías, numeración y admin';

    -- 6 · PLATAFORMA: EDITAR, TEMA, MÓDULOS, ESTADO Y ENTRAR -----------------------------------
    PERFORM pg_temp.app($s$SELECT rest.guardar_empresa('empresa_heladeria_polo_norte', '{"nombre_comercial": "Polo Norte", "activa": false}')$s$);
    PERFORM pg_temp.token('mesero');
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.empresas WHERE codigo = ''empresa_heladeria_polo_norte''')::TEXT::INTEGER = 0,
           'Desactivada: el portal ya no la ofrece';
    ASSERT NOT EXISTS (SELECT 1 FROM api.fn_login('polo.admin', '4321')), 'Sus usuarios ya no entran';
    PERFORM pg_temp.token('super', -1);
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.entrar_empresa(''empresa_heladeria_polo_norte'')')$s$, 'desactivada');
    PERFORM pg_temp.app($s$SELECT rest.guardar_empresa('empresa_heladeria_polo_norte', '{"nombre_comercial": "Polo Norte", "activa": true}')$s$);

    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_tema_empresa(''empresa_heladeria_polo_norte'', ''{"primary": "rojo"}'')')$s$, '#RRGGBB');
    v_r := pg_temp.app($s$SELECT rest.guardar_tema_empresa('empresa_heladeria_polo_norte', '{"primary": "#112233", "logoTexto": "POLO",
        "logo": "data:image/png;base64,AAAA"}')$s$);
    ASSERT v_r ->> 'color_primario' = '#112233' AND v_r ->> 'imagenes_version' IS NOT NULL, 'Tema e imagen aparte';
    ASSERT pg_temp.app('SELECT to_jsonb(logo) FROM rest.empresa_imagenes WHERE empresa_id = ' || v_polo) #>> '{}' = 'data:image/png;base64,AAAA', 'El logo se lee aparte';
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_tema_empresa(''empresa_heladeria_polo_norte'', ''{"logo": "https://x.com/a.png"}'')')$s$, 'check');

    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.modulo_empresa(''empresa_heladeria_polo_norte'', ''basico'', false)')$s$, 'siempre está incluido');
    v_r := pg_temp.app($s$SELECT rest.modulo_empresa('empresa_heladeria_polo_norte', 'cierre', true)$s$);
    ASSERT (v_r ->> 'cierre')::BOOLEAN, 'Cierre habilitado';

    v_r := pg_temp.app($s$SELECT rest.entrar_empresa('empresa_heladeria_polo_norte')$s$);
    ASSERT array_length(string_to_array(v_r ->> 'token', '.'), 1) = 3, 'Entrar devuelve un token nuevo';
    PERFORM pg_temp.token('super', v_polo);   -- lo que dice ese token
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.usuarios')::TEXT::INTEGER = 1, 'Dentro de la empresa ve sus usuarios';
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.gastos')::TEXT::INTEGER = 0, 'Y nada de NASCAR';
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.plataforma_usuarios WHERE usuario = ''polo.admin''')::TEXT::INTEGER = 1
       AND pg_temp.app('SELECT to_jsonb(p) FROM rest.plataforma_usuarios p WHERE usuario = ''polo.admin''') ? 'pin' = FALSE,
           'La plataforma ve los usuarios de las empresas, sin PIN';
    RAISE NOTICE '✔ 6  Plataforma: desactivar corta el acceso, tema con imagen aparte, módulos, entrar a una empresa';

    -- 7 · SEGURIDAD ---------------------------------------------------------------------------
    PERFORM pg_temp.token('polo.admin');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.modulo_empresa(''empresa_heladeria_polo_norte'', ''cierre'', true)')$s$, 'Sólo la plataforma');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.entrar_empresa(''empresa_nascar'')')$s$, 'Sólo la plataforma');
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.usuarios')::TEXT::INTEGER = 1, 'El admin de Polo sólo ve su empresa';
    -- Su configuración es suya: no toca la de NASCAR aunque cambie el token
    PERFORM pg_temp.token('polo.admin', v_nascar);
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.app('SELECT rest.guardar_configuracion(''{"nombre_comercial": "Robada"}'')')$s$, 'otra empresa');
    RAISE NOTICE '✔ 7  Seguridad: el Admin de una empresa no toca módulos, no entra a otras ni cambia su configuración';
END;
$$;

SET LOCAL ROLE taseca_anon;
SELECT pg_temp.esperar_error($s$SELECT rest.alta_empresa('{}')$s$, 'permission denied');
SELECT pg_temp.esperar_error($s$SELECT count(*) FROM rest.plataforma_empresas$s$, 'permission denied');
RESET ROLE;

ROLLBACK;
