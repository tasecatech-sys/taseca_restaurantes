/* ============================================================================
   42 · EL ESCAPARATE NO FILTRA DE MÁS

   QUÉ ESTABA MAL
   --------------
   El portal del cliente -sin sesión- arranca con rest.arranque(), que le
   entrega la ficha de la empresa. Esa ficha traía TODO lo de la vista
   `rest.empresas`, incluida la `razon_social` (el nombre legal) y el
   `email` del negocio. El cliente no los usa: el pie de la página muestra
   el NIT, no la razón social ni el correo. Eran datos que viajaban de más.

   Peor: `taseca_anon` tenía además SELECT DIRECTO sobre la vista
   `rest.empresas`. Por el Data API eso deja pedir, sin sesión,

       GET /rest/v1/empresas?select=razon_social,email,nit

   y sacar esos campos de TODAS las empresas activas de la plataforma de un
   tirón. Era herencia de antes de la migración 24: hasta entonces el cliente
   leía esas vistas una por una; desde la 24 todo pasa por rest.arranque()
   -SECURITY DEFINER- y ya nadie consulta la vista directamente. El permiso
   se quedó sin quitar.

   QUÉ SE HACE
   -----------
     1. Se le quita a `taseca_anon` el SELECT directo sobre `rest.empresas`.
        rest.arranque() es SECURITY DEFINER: corre como su dueño, así que
        sigue leyendo la vista y respondiendo igual. El cliente no se entera.
     2. rest.arranque(), cuando NO hay sesión, devuelve la ficha SIN
        `razon_social` ni `email`. Con sesión -el panel, que sí los edita en
        su configuración- la ficha sigue completa.

   QUÉ NO CAMBIA
   -------------
   · `nit` sigue yendo al cliente: lo pinta el pie de la página (dato público
     de confianza en Colombia).
   · `modulos`, `metodos_pago`, `cuentas` siguen yendo: la vitrina los
     necesita para saber qué ofrecer y a qué cuenta se paga.
   · `taseca_app` (el panel, con sesión) conserva lo que tenía.

   OJO para el futuro: si algún día se vuelve a recrear la vista
   `rest.empresas`, NO volver a darle SELECT a `taseca_anon`. El cliente llega
   por rest.arranque(), no por la vista.

   PENDIENTE APARTE (no es esto): la vista `rest.empresas` no filtra por la
   empresa del token, así que un `taseca_app` logueado podría ver la ficha de
   OTRAS empresas por consulta directa. Es alcance entre inquilinos, no fuga a
   anónimos; se anota para su propia revisión.

   Idempotente: se puede ejecutar dos veces.
   Requiere: 24 (rest.arranque) y la vista rest.empresas.
   ============================================================================ */

/* ----------------------------------------------------------------------------
   0. ANTES DE TOCAR NADA
   ---------------------------------------------------------------------------- */
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'rest' AND p.proname = 'arranque') THEN
        RAISE EXCEPTION 'Falta rest.arranque. Ejecuta antes database/24_arranque_en_un_viaje.sql.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'rest' AND c.relname = 'empresas') THEN
        RAISE EXCEPTION 'Falta la vista rest.empresas.';
    END IF;
END $$;


/* ----------------------------------------------------------------------------
   1. ANON YA NO LEE LA VISTA DIRECTAMENTE

   El acceso del cliente es por rest.arranque(), no por la vista. Quitarle el
   SELECT cierra el GET /empresas directo sin tocar el arranque. A taseca_app
   NO se le quita nada.
   ---------------------------------------------------------------------------- */
REVOKE SELECT ON rest.empresas FROM taseca_anon;


/* ----------------------------------------------------------------------------
   2. EL ARRANQUE SIN SESIÓN NO ENTREGA NOMBRE LEGAL NI CORREO

   Misma función de la 24, con un solo cambio: la ficha de la empresa sale sin
   `razon_social` ni `email` cuando no hay sesión. Con sesión, completa.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION rest.arranque(p_empresa TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_codigo  TEXT := NULLIF(trim(p_empresa), '');
    v_id      INTEGER;
    v_emp     JSONB;
    v_usuario INTEGER := core.fn_jwt_usuario();
    v_jornada DATE;
    v_salida  JSONB;
BEGIN
    /* De qué empresa es esta visita: la que pide la dirección o, si no dice,
       la del token. El portal del cliente no tiene token, por eso el
       parámetro. */
    IF v_codigo IS NULL THEN
        SELECT e.codigo INTO v_codigo FROM core.empresas e WHERE e.id = core.fn_jwt_empresa();
    END IF;
    IF v_codigo IS NULL THEN
        RAISE EXCEPTION 'Falta decir de qué negocio es esta página.';
    END IF;

    SELECT to_jsonb(e) INTO v_emp FROM rest.empresas e WHERE e.codigo = v_codigo;
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'La empresa "%" no existe en la base de datos o está desactivada.', v_codigo;
    END IF;

    v_id      := (v_emp ->> 'empresa_id')::INTEGER;
    v_jornada := core.fn_fecha_operativa(v_id, now());

    -- El catálogo: lo mismo que pedía una por una, de las mismas vistas.
    -- Sin sesión, la ficha va sin el nombre legal ni el correo: el cliente
    -- no los usa (el pie muestra el NIT). Con sesión, completa.
    v_salida := jsonb_build_object(
        'empresa', CASE WHEN v_usuario IS NULL
                        THEN v_emp - 'razon_social' - 'email'
                        ELSE v_emp END,
        'unidades', COALESCE((SELECT jsonb_agg(to_jsonb(u) ORDER BY u.nombre)
                                FROM rest.unidades u WHERE u.empresa_id = v_id), '[]'::JSONB),
        'categorias', COALESCE((SELECT jsonb_agg(to_jsonb(c))
                                  FROM rest.categorias c WHERE c.empresa_id = v_id), '[]'::JSONB),
        'carta', COALESCE((SELECT jsonb_agg(to_jsonb(p))
                             FROM rest.carta p WHERE p.empresa_id = v_id), '[]'::JSONB),
        'menus_dia', COALESCE((SELECT jsonb_agg(to_jsonb(m))
                                 FROM rest.menus_dia m WHERE m.empresa_id = v_id), '[]'::JSONB),
        'textos_menu', COALESCE((SELECT jsonb_agg(to_jsonb(t))
                                   FROM rest.textos_menu t WHERE t.empresa_id = v_id), '[]'::JSONB),
        'con_sesion', v_usuario IS NOT NULL
    );

    IF v_usuario IS NULL THEN
        RETURN v_salida;   -- el portal del cliente no necesita más
    END IF;

    /* Con sesión, lo que el panel pedía aparte. `rest.pedidos` y
       `rest.usuarios` siguen filtrando por el token: el alcance no cambia. */
    RETURN v_salida || jsonb_build_object(
        'usuarios', COALESCE((SELECT jsonb_agg(to_jsonb(u) ORDER BY u.nombre)
                                FROM rest.usuarios u), '[]'::JSONB),
        'pedidos', COALESCE((SELECT jsonb_agg(jsonb_build_object('pedido', p.pedido) ORDER BY p.pedido_id DESC)
                               FROM rest.pedidos p
                              WHERE p.fecha_operativa >= v_jornada - 1), '[]'::JSONB),
        /* El último cambio de los 31 días: sirve para saber desde dónde
           refrescar sin tener que bajar esos pedidos. Se mira sobre la vista
           sin el JSON de cada factura, que es lo caro. */
        'marca_pedidos', (SELECT max(vp.actualizado_en)
                            FROM api.v_pedidos vp
                           WHERE vp.empresa_id = v_id
                             AND core.fn_usuario_en_unidad(v_usuario, vp.unidad_id)
                             AND vp.fecha_operativa >= v_jornada - 31)
    );
END;
$$;

/* CREATE OR REPLACE conserva los permisos; se repite el del arranque por si
   esta migración corre sobre una base donde se recreó la función a mano. */
GRANT EXECUTE ON FUNCTION rest.arranque(TEXT) TO taseca_anon, taseca_app;


/* ----------------------------------------------------------------------------
   3. QUE QUEDÓ COMO SE QUERÍA (sólo mira texto y permisos; el comportamiento
      se prueba en 42_pruebas_escaparate.sql, aparte).
   ---------------------------------------------------------------------------- */
DO $$
DECLARE v_def TEXT;
BEGIN
    IF has_table_privilege('taseca_anon', 'rest.empresas', 'SELECT') THEN
        RAISE EXCEPTION 'taseca_anon todavía puede SELECT sobre rest.empresas.';
    END IF;

    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='rest' AND p.proname='arranque';
    IF v_def NOT LIKE '%- ''razon_social'' - ''email''%' THEN
        RAISE EXCEPTION 'rest.arranque no quedó recortando la ficha sin sesión.';
    END IF;

    RAISE NOTICE 'OK · el escaparate anónimo ya no entrega razón social ni correo, ni deja leer la vista directamente.';
END $$;

NOTIFY pgrst, 'reload schema';
