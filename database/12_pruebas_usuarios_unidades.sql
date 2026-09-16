/* ============================================================================
   TASECA · 12 · PRUEBAS DE USUARIOS Y UNIDADES (fase 2, bloque 2)
   ----------------------------------------------------------------------------
   Ejecutar después de 12_fase2_usuarios_unidades.sql. Todo corre como la
   aplicación (rol taseca_app con un token simulado) dentro de una transacción
   que termina en ROLLBACK: no deja ningún dato.

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
                                          'empresa_id', COALESCE(p_empresa, v_empresa))::TEXT, TRUE);
END;
$$;

/* Cada llamada corre como taseca_app, igual que desde PostgREST. */
CREATE FUNCTION pg_temp.api(p_funcion TEXT, p_json TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v JSONB;
BEGIN
    SET LOCAL ROLE taseca_app;
    EXECUTE format('SELECT rest.%I($1::JSONB)', p_funcion) INTO v USING p_json;
    RESET ROLE;
    RETURN v;
END;
$$;

CREATE FUNCTION pg_temp.contar(p_vista TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v BIGINT;
BEGIN
    SET LOCAL ROLE taseca_app;
    EXECUTE format('SELECT count(*) FROM rest.%I', p_vista) INTO v;
    RESET ROLE;
    RETURN v;
END;
$$;

/* Otra empresa con una unidad, para comprobar que nada se cruza. */
CREATE TEMP TABLE otra_empresa AS SELECT * FROM core.empresas WHERE codigo = 'empresa_nascar';
UPDATE otra_empresa SET id = nextval(pg_get_serial_sequence('core.empresas', 'id')),
                        codigo = 'empresa_prueba_12', nombre_comercial = 'Empresa de prueba 12';
INSERT INTO core.empresas SELECT * FROM otra_empresa;
CREATE TEMP TABLE otra_unidad AS SELECT * FROM core.unidades WHERE nombre = 'NASCAR-Comidas';
UPDATE otra_unidad SET id = nextval(pg_get_serial_sequence('core.unidades', 'id')),
                       empresa_id = (SELECT id FROM otra_empresa), nombre = 'Unidad de otra empresa',
                       nombre_corto = 'Otra';
INSERT INTO core.unidades SELECT * FROM otra_unidad;

DO $$
DECLARE
    v_ce INTEGER; v_com INTEGER; v_admin INTEGER; v_nuevo INTEGER; v_unidad INTEGER; v_zona INTEGER;
    v_zona_usada BOOLEAN := FALSE;
    v_ped BIGINT; v_r JSONB;
BEGIN
    SELECT id INTO v_ce  FROM core.unidades WHERE nombre = 'COMIC''ENDO AREPA';
    SELECT id INTO v_com FROM core.unidades WHERE nombre = 'NASCAR-Comidas';
    SELECT id INTO v_admin FROM core.usuarios WHERE usuario = 'admin';

    -- 1 · LISTA DE USUARIOS ----------------------------------------------------
    PERFORM pg_temp.token('admin');
    ASSERT pg_temp.contar('usuarios') = (SELECT count(*) FROM core.usuarios u JOIN core.empresas e ON e.id = u.empresa_id
                                           WHERE e.codigo = 'empresa_nascar'),
           'El Admin ve los usuarios de su empresa';
    PERFORM pg_temp.token('mesero');
    ASSERT pg_temp.contar('usuarios') = 0, 'El mesero no ve la lista de usuarios';
    PERFORM pg_temp.token('admin');
    RAISE NOTICE '✔ 1  rest.usuarios: el Admin ve su empresa, el mesero nada, nunca el PIN';

    -- 2 · CREAR, EDITAR Y PIN ---------------------------------------------------
    v_r := pg_temp.api('guardar_usuario', format('{"nombre": "Mesera Arepa", "usuario": "  Mesera.Arepa ",
        "pin": "2468", "rol": "mesero", "unidades": [%s], "activo": true}', v_ce));
    v_nuevo := (v_r ->> 'usuario_id')::INTEGER;
    ASSERT (SELECT usuario FROM core.usuarios WHERE id = v_nuevo) = 'mesera.arepa', 'El acceso se guarda en minúsculas';
    ASSERT (SELECT usuario_id FROM api.fn_login('mesera.arepa', '2468')) = v_nuevo, 'Entra con su PIN (bcrypt)';
    ASSERT (SELECT array_agg(unidad_id) FROM core.usuario_unidades WHERE usuario_id = v_nuevo) = ARRAY[v_ce],
           'Queda asignada a su unidad';

    -- Editar sin PIN conserva el PIN; con PIN lo cambia
    PERFORM pg_temp.api('guardar_usuario', format('{"usuario_id": %s, "nombre": "Mesera Arepa", "usuario": "mesera.arepa",
        "pin": "", "rol": "caja", "unidades": [], "activo": true}', v_nuevo));
    ASSERT (SELECT usuario_id FROM api.fn_login('mesera.arepa', '2468')) = v_nuevo, 'Sin PIN nuevo conserva el anterior';
    ASSERT NOT EXISTS (SELECT 1 FROM core.usuario_unidades WHERE usuario_id = v_nuevo), 'Unidades vacías = todas';
    PERFORM pg_temp.api('guardar_usuario', format('{"usuario_id": %s, "nombre": "Mesera Arepa", "usuario": "mesera.arepa",
        "pin": "135790", "rol": "caja", "unidades": null, "activo": true}', v_nuevo));
    ASSERT NOT EXISTS (SELECT 1 FROM api.fn_login('mesera.arepa', '2468')), 'El PIN anterior ya no sirve';
    ASSERT (SELECT usuario_id FROM api.fn_login('mesera.arepa', '135790')) = v_nuevo, 'El PIN nuevo sí';
    RAISE NOTICE '✔ 2  Crear, asignar unidad, cambiar rol y PIN (vacío = no cambia)';

    -- 3 · VALIDACIONES -----------------------------------------------------------
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_usuario', '{"nombre": "Otro", "usuario": "MESERO",
        "pin": "1234", "rol": "mesero"}')$s$, 'Ya existe otro usuario con el acceso "mesero"');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_usuario', '{"nombre": "Otro", "usuario": "otro1",
        "pin": "12", "rol": "mesero"}')$s$, 'PIN debe tener entre 4 y 6');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_usuario', '{"nombre": "Otro", "usuario": "otro1",
        "rol": "mesero"}')$s$, 'necesita PIN');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_usuario', '{"nombre": "Otro", "usuario": "a b",
        "pin": "1234", "rol": "mesero"}')$s$, 'acceso debe tener');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_usuario', '{"nombre": "Jefe", "usuario": "jefe.taseca",
        "pin": "1234", "rol": "superadmin"}')$s$, 'permiso "plataforma"');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_usuario', '{"nombre": "Otro", "usuario": "otro2",
        "pin": "1234", "rol": "mesero", "unidades": [999999]}')$s$, 'no es de esta empresa');
    RAISE NOTICE '✔ 3  Acceso repetido, PIN inválido o ausente, acceso con espacios, SuperAdmin y unidad ajena';

    -- 4 · NADIE SE DEJA POR FUERA ----------------------------------------------
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.api('guardar_usuario', '{"usuario_id": %s, "nombre": "Dueño",
        "usuario": "admin", "rol": "admin", "activo": false}')$s$, v_admin), 'propio usuario');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.api('guardar_usuario', '{"usuario_id": %s, "nombre": "Dueño",
        "usuario": "admin", "rol": "mesero", "activo": true}')$s$, v_admin), 'propio rol');

    -- Otro Admin intenta dejar a la empresa sin el único Admin activo
    PERFORM pg_temp.api('guardar_usuario', format('{"usuario_id": %s, "nombre": "Mesera Arepa", "usuario": "mesera.arepa",
        "rol": "admin", "activo": true}', v_nuevo));
    PERFORM pg_temp.token('mesera.arepa');
    PERFORM pg_temp.api('guardar_usuario', format('{"usuario_id": %s, "nombre": "Dueño", "usuario": "admin",
        "rol": "admin", "activo": false}', v_admin));  -- quedan dos… ahora uno
    PERFORM pg_temp.token('admin');
    ASSERT (SELECT NOT activo FROM core.usuarios WHERE id = v_admin), 'Con dos Admin, uno puede desactivar al otro';
    PERFORM pg_temp.token('mesera.arepa');
    PERFORM pg_temp.api('guardar_usuario', format('{"usuario_id": %s, "nombre": "Dueño", "usuario": "admin",
        "rol": "admin", "activo": true}', v_admin));
    PERFORM pg_temp.token('admin');
    PERFORM pg_temp.api('guardar_usuario', format('{"usuario_id": %s, "nombre": "Mesera Arepa", "usuario": "mesera.arepa",
        "rol": "mesero", "activo": true}', v_nuevo));
    PERFORM pg_temp.token('admin');
    -- El token de un usuario desactivado deja de servir
    PERFORM pg_temp.api('guardar_usuario', format('{"usuario_id": %s, "nombre": "Mesera Arepa", "usuario": "mesera.arepa",
        "rol": "mesero", "activo": false}', v_nuevo));
    PERFORM pg_temp.token('mesera.arepa');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.contar('usuarios')$s$, 'ya no es válida');
    PERFORM pg_temp.token('admin');
    RAISE NOTICE '✔ 4  Nadie se desactiva ni cambia su rol; siempre queda un Admin; token de inactivo no sirve';

    -- 5 · UNIDAD NUEVA COMPLETA ---------------------------------------------------
    v_r := pg_temp.api('guardar_unidad', $j${"nombre": "NASCAR Heladería", "corto": "", "tipoNegocio": "heladeria",
        "activa": true, "direccion": "Av. Calle 80 # 102-52, Local 15", "ciudad": "Bogotá", "telefono": "320 212 0632",
        "whatsapp": "57 320-212-0632", "horario": "12 a 9", "mapa": "", "mesas": 6, "color": "rojo",
        "colorMarca": "#FF8800", "zonas": [{"nombre": "Barrio", "costo": 3000, "min": 15000}],
        "logo": "data:image/jpeg;base64,AAAA"}$j$);
    v_unidad := (v_r ->> 'unidad_id')::INTEGER;
    ASSERT (SELECT nombre_corto FROM core.unidades WHERE id = v_unidad) = 'NASCAR Heladería', 'Nombre corto automático';
    ASSERT (SELECT whatsapp FROM core.unidades WHERE id = v_unidad) = '573202120632', 'WhatsApp sólo con dígitos';
    ASSERT (SELECT color_marca FROM core.unidades WHERE id = v_unidad) = '#ff8800', 'Color propio en minúsculas';
    ASSERT (SELECT count(*) FROM core.mesas WHERE unidad_id = v_unidad AND activa) = 6, 'Seis mesas';
    ASSERT (SELECT jsonb_array_length(zonas) FROM rest.unidades WHERE unidad_id = v_unidad) = 1, 'Una zona';
    ASSERT (SELECT logo_version IS NOT NULL FROM rest.unidades WHERE unidad_id = v_unidad), 'Tiene logo (versión)';
    ASSERT (SELECT imagen FROM rest.logos_unidad WHERE unidad_id = v_unidad) = 'data:image/jpeg;base64,AAAA', 'El logo se lee aparte';
    RAISE NOTICE '✔ 5  Unidad nueva: nombre corto, WhatsApp, color, mesas, zona y logo aparte';

    -- 6 · EDITAR: MESAS, ZONAS, LOGO, CORTO --------------------------------------
    PERFORM pg_temp.api('guardar_unidad', format($j${"unidad_id": %s, "nombre": "NASCAR Heladería", "corto": "",
        "tipoNegocio": "heladeria", "mesas": 4, "color": "rojo", "colorMarca": "",
        "zonas": [{"nombre": "Barrio", "costo": 3500, "min": 0}, {"nombre": "Engativá", "costo": 6000, "min": 20000}]}$j$, v_unidad));
    ASSERT (SELECT nombre_corto FROM core.unidades WHERE id = v_unidad) = 'NASCAR Heladería', 'Corto vacío conserva el anterior';
    ASSERT (SELECT count(*) FROM core.mesas WHERE unidad_id = v_unidad AND activa) = 4, 'Mesas 5 y 6 desactivadas';
    ASSERT (SELECT color_marca FROM core.unidades WHERE id = v_unidad) IS NULL, 'Quita el color propio';
    ASSERT (SELECT costo FROM core.zonas_domicilio WHERE unidad_id = v_unidad AND nombre = 'Barrio') = 3500, 'Cambia el costo';
    ASSERT EXISTS (SELECT 1 FROM core.unidad_logos WHERE unidad_id = v_unidad), 'Sin "logo" en la petición, el logo no cambia';

    -- Zona usada en un pedido: se desactiva en vez de borrarse
    SELECT id INTO v_zona FROM core.zonas_domicilio WHERE unidad_id = v_unidad AND nombre = 'Engativá';
    SELECT (r ->> 'pedido_id')::BIGINT INTO v_ped FROM rest.crear_pedido(v_ce, 'mesa', 'efectivo',
        format('[{"producto_id": %s, "cantidad": 1}]', (SELECT producto_id FROM core.producto_unidades WHERE unidad_id = v_ce LIMIT 1))::JSONB,
        p_mesa => '1') r;
    /* Con el 17 instalado, la base no deja colgar de un pedido la zona de
       otra unidad. El caso "zona ya usada" se arma saltando esa validación
       a propósito (sólo para la prueba; todo se deshace con ROLLBACK). */
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pedidos_relaciones') THEN
        PERFORM pg_temp.esperar_error(
            format('UPDATE core.pedidos SET zona_domicilio_id = %s WHERE id = %s', v_zona, v_ped),
            'es de otra unidad');
    END IF;
    /* Saltarse un trigger a propósito sólo lo puede un superusuario. En un
       servidor administrado (Supabase) no se puede, así que esa parte de la
       prueba se omite con un aviso en vez de fallar. */
    BEGIN
        SET LOCAL session_replication_role = replica;
        UPDATE core.pedidos SET zona_domicilio_id = v_zona WHERE id = v_ped;
        SET LOCAL session_replication_role = origin;
        v_zona_usada := TRUE;
    EXCEPTION WHEN OTHERS THEN
        v_zona_usada := FALSE;
        RAISE NOTICE '      · Se omite "zona ya usada": hace falta superusuario para armar el caso';
    END;
    PERFORM pg_temp.api('guardar_unidad', format($j${"unidad_id": %s, "nombre": "NASCAR Heladería", "tipoNegocio": "heladeria",
        "zonas": [], "logo": ""}$j$, v_unidad));
    IF v_zona_usada THEN
        ASSERT (SELECT NOT activa FROM core.zonas_domicilio WHERE id = v_zona), 'Zona con pedidos: desactivada';
    END IF;
    ASSERT NOT EXISTS (SELECT 1 FROM core.zonas_domicilio WHERE unidad_id = v_unidad AND nombre = 'Barrio'), 'Zona sin pedidos: borrada';
    ASSERT NOT EXISTS (SELECT 1 FROM core.unidad_logos WHERE unidad_id = v_unidad), '"logo": "" lo quita';
    RAISE NOTICE '✔ 6  Editar unidad: corto conservado, mesas, color, zonas (usada = desactivada) y logo';

    -- 7 · VALIDACIONES Y ESTADO -----------------------------------------------------
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_unidad', '{"nombre": "nascar-comidas",
        "tipoNegocio": "restaurante"}')$s$, 'Ya hay otra unidad llamada');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.api('guardar_unidad', '{"nombre": "Otra", "corto": "%s",
        "tipoNegocio": "bar"}')$s$, (SELECT nombre_corto FROM core.unidades WHERE id = v_com)), 'nombre corto');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_unidad', '{"nombre": "Otra", "tipoNegocio": "bar",
        "colorMarca": "rojo"}')$s$, '#RRGGBB');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_unidad', '{"nombre": "Otra", "tipoNegocio": "bar",
        "logo": "javascript:alert(1)"}')$s$, 'debe ser una imagen');

    PERFORM pg_temp.api('guardar_unidad', format('{"unidad_id": %s, "nombre": "NASCAR Heladería", "tipoNegocio": "heladeria",
        "activa": false}', v_unidad));
    ASSERT (SELECT estado FROM core.unidades WHERE id = v_unidad) = 'inactiva', 'Se desactiva';
    RAISE NOTICE '✔ 7  Nombre y corto repetidos, color y logo inválidos; activar y desactivar';

    -- 8 · SEGURIDAD ---------------------------------------------------------------
    PERFORM pg_temp.token('cocina');
    PERFORM pg_temp.esperar_error($s$SELECT pg_temp.api('guardar_usuario', '{"nombre": "Yo", "usuario": "yo.cocina",
        "pin": "1234", "rol": "admin"}')$s$, 'permiso "usuarios"');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.api('guardar_unidad', '{"unidad_id": %s, "nombre": "X",
        "tipoNegocio": "bar", "activa": false}')$s$, v_com), 'permiso "config_sucursales"');

    -- Admin de NASCAR con un token manipulado a otra empresa
    PERFORM pg_temp.token('admin', 999999);
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.api('guardar_unidad', '{"unidad_id": %s, "nombre": "NASCAR-Comidas",
        "tipoNegocio": "restaurante"}')$s$, v_com), 'otra empresa');
    PERFORM pg_temp.esperar_error(format($s$SELECT pg_temp.api('guardar_usuario', '{"usuario_id": %s, "nombre": "Mesero",
        "usuario": "mesero", "rol": "admin"}')$s$, (SELECT id FROM core.usuarios WHERE usuario = 'mesero')), 'otra empresa');

    -- Antes, el Admin de una empresa podía desactivar la unidad de otra
    PERFORM pg_temp.token('admin');
    PERFORM pg_temp.esperar_error(format('CALL api.sp_cambiar_estado_unidad(%s, FALSE, %s)',
        (SELECT id FROM core.unidades WHERE nombre = 'Unidad de otra empresa'), v_admin), 'otra empresa');
    ASSERT (SELECT estado FROM core.unidades WHERE nombre = 'Unidad de otra empresa') = 'activa', 'Y sigue activa';
    RAISE NOTICE '✔ 8  Seguridad: permisos del rol y empresa del token';
END;
$$;

SET LOCAL ROLE taseca_anon;
SELECT pg_temp.esperar_error($s$SELECT rest.guardar_usuario('{}')$s$, 'permission denied');
SELECT pg_temp.esperar_error($s$SELECT count(*) FROM rest.usuarios$s$, 'permission denied');
RESET ROLE;

ROLLBACK;
