/* ============================================================================
   TASECA · 20 · PRUEBAS DEL MOTIVO DE MARCA
   ----------------------------------------------------------------------------
   Ejecutar después de 20_motivo_marca.sql. Todo corre como la aplicación
   (rol taseca_app con un token simulado) dentro de una transacción que
   termina en ROLLBACK: no deja ningún dato.

   Lo que se comprueba:
     1. Ninguna empresa se quedó sin motivo y NASCAR conserva el suyo.
     2. El portal recibe el motivo junto con el resto del tema.
     3. La plataforma lo cambia, y sólo en la empresa que toca.
     4. Guardar el tema sin mencionarlo no lo borra.
     5. Un motivo con cosas raras dentro se rechaza.
     6. El Admin de una empresa no cambia su propio tema.

   En DBeaver: Alt+X y mira la pestaña «Salida». Cada prueba escribe ✔.
   ============================================================================ */

BEGIN;

/* ---------------------------------------------------------------------------
   ANTES DE NADA: ¿con qué usuario estás conectado?

   Esta prueba lee y escribe las tablas de `core` directamente, así que hay que
   correrla con el usuario DUEÑO de la base. Con cualquier otro, PostgreSQL
   corta a mitad con «permission denied for table …» y no explica por qué.

     · En Supabase  → el SQL Editor del panel ya entra como el dueño.
     · En DBeaver   → usa la conexión del usuario `postgres`, no la de
                      `taseca_rest` ni la de `taseca_app`, que son las que usa
                      la aplicación y a propósito no pueden tocar `core`.
   --------------------------------------------------------------------------- */

DO $guardia$
BEGIN
    IF NOT has_table_privilege(current_user, 'core.usuarios', 'SELECT') THEN
        RAISE EXCEPTION E'Esta prueba hay que correrla con el usuario dueño de la base.\n'
            'Estás conectado como «%», que no puede leer core.usuarios.\n'
            'En Supabase usa el SQL Editor; en DBeaver, la conexión de postgres.',
            current_user
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$guardia$;

/* ¿Está puesta la columna que se va a probar? */
DO $falta$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute
         WHERE attrelid = 'core.empresas'::regclass AND attname = 'patron' AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION E'Falta correr database/20_motivo_marca.sql antes de esta prueba.\n'
            'core.empresas todavía no tiene la columna patron.'
            USING ERRCODE = 'undefined_column';
    END IF;
END;
$falta$;


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
    v_nascar INTEGER; v_otra INTEGER; v_r JSONB; v_n INTEGER;
BEGIN
    SELECT id INTO v_nascar FROM core.empresas WHERE codigo = 'empresa_nascar';

    -- 1 · NADIE SE QUEDÓ SIN MOTIVO ----------------------------------------------------
    SELECT count(*) INTO v_n FROM core.empresas WHERE patron IS NULL;
    ASSERT v_n = 0, format('%s empresa(s) sin motivo de marca', v_n);
    ASSERT (SELECT patron FROM core.empresas WHERE id = v_nascar) = 'cuadros',
           'NASCAR tiene que seguir con su bandera a cuadros';
    RAISE NOTICE '✔ 1  Toda empresa tiene motivo y NASCAR conserva el de siempre';

    -- 2 · EL PORTAL LO RECIBE CON EL RESTO DEL TEMA ------------------------------------
    PERFORM pg_temp.token('mesero');
    v_r := pg_temp.app('SELECT to_jsonb(e) FROM rest.empresas e WHERE codigo = ''empresa_nascar''');
    ASSERT v_r ->> 'patron' = 'cuadros' AND v_r ->> 'tipografia' = 'barlow',
           format('rest.empresas no publica el motivo (salió %s)', v_r ->> 'patron');
    RAISE NOTICE '✔ 2  rest.empresas publica el motivo junto al resto del tema';

    -- 3 · LA PLATAFORMA LO CAMBIA, Y SÓLO DONDE TOCA -----------------------------------
    INSERT INTO core.empresas (codigo, nombre_comercial, patron)
    VALUES ('empresa_motivo', 'Empresa motivo', 'degradado') RETURNING id INTO v_otra;

    PERFORM pg_temp.token('super', -1);
    v_r := pg_temp.app($s$SELECT rest.guardar_tema_empresa('empresa_motivo', '{"patron": "puntos"}')$s$);
    ASSERT v_r ->> 'patron' = 'puntos', format('No se guardó el motivo (salió %s)', v_r ->> 'patron');
    ASSERT (SELECT patron FROM core.empresas WHERE id = v_nascar) = 'cuadros',
           'Cambiar el motivo de una empresa no puede tocar el de otra';
    RAISE NOTICE '✔ 3  La plataforma cambia el motivo de una empresa sin tocar el de las demás';

    -- 4 · GUARDAR EL TEMA SIN MENCIONARLO NO LO BORRA ----------------------------------
    v_r := pg_temp.app($s$SELECT rest.guardar_tema_empresa('empresa_motivo', '{"primary": "#112233"}')$s$);
    ASSERT v_r ->> 'patron' = 'puntos' AND v_r ->> 'color_primario' = '#112233',
           'Un tema que no habla del motivo tiene que dejarlo como estaba';
    RAISE NOTICE '✔ 4  Guardar el tema sin mencionar el motivo no lo borra';

    -- 5 · NO ENTRA CSS POR AHÍ ---------------------------------------------------------
    PERFORM pg_temp.esperar_error(
        $s$SELECT pg_temp.app('SELECT rest.guardar_tema_empresa(''empresa_motivo'', ''{"patron": "url(javascript:1)"}'')')$s$,
        'Motivo de marca no válido');
    PERFORM pg_temp.esperar_error(
        $s$SELECT pg_temp.app('SELECT rest.guardar_tema_empresa(''empresa_motivo'', ''{"patron": "CUADROS; drop"}'')')$s$,
        'Motivo de marca no válido');
    ASSERT (SELECT patron FROM core.empresas WHERE id = v_otra) = 'puntos', 'Y no quedó nada escrito';
    RAISE NOTICE '✔ 5  Un motivo con caracteres raros se rechaza y no se guarda';

    -- 6 · EL ADMIN DE UNA EMPRESA NO TOCA SU TEMA --------------------------------------
    PERFORM pg_temp.token('admin');
    PERFORM pg_temp.esperar_error(
        $s$SELECT pg_temp.app('SELECT rest.guardar_tema_empresa(''empresa_nascar'', ''{"patron": "liso"}'')')$s$,
        'Sólo la plataforma');
    ASSERT (SELECT patron FROM core.empresas WHERE id = v_nascar) = 'cuadros', 'Y NASCAR sigue igual';
    RAISE NOTICE '✔ 6  El Admin de una empresa no cambia su motivo: eso es de la plataforma';
END;
$$;

ROLLBACK;
