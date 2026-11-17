/* ============================================================================
   41 · EL LOGIN SE FRENA SOLO

   QUÉ ESTÁ MAL
   ------------
   El ingreso es por usuario + PIN. El PIN se guarda con bcrypt -bien- pero
   es de 4 a 8 dígitos: uno de 4 son 10.000 combinaciones. Y no había NADA
   que frenara a quien las probara todas: ni contador de intentos ni
   bloqueo. La única defensa era un pg_sleep(0.6) por intento, y eso se
   esquiva lanzando las peticiones en paralelo.

   Con 10.000 combinaciones y sin freno, un PIN de 4 dígitos se adivina en
   minutos. Es la única puerta de verdad a la caja, los cierres y los datos
   de cada empresa.

   QUÉ SE HACE
   -----------
   Un freno suave, POR USUARIO, que se recupera solo:

     · Tras 5 PIN errados seguidos, la cuenta queda en espera 5 minutos.
     · Mientras espera, ni siquiera se comprueba el PIN: se responde
       «demasiados intentos» y se dice cuánto falta.
     · Acertar el PIN borra el contador. Que pase la espera da otros 5
       intentos frescos.

   Así el ataque queda limitado a ~5 pruebas cada 5 minutos por usuario
   -del orden de un intento por minuto- en vez de miles por segundo. Un PIN
   de 4 dígitos pasa de «minutos» a «semanas», y para entonces ya se vio en
   el acceso de la cuenta que algo raro pasa.

   POR QUÉ SUAVE Y NO UN BLOQUEO DURO
   ----------------------------------
   Un cajero que teclea mal con prisa no puede quedar fuera a mitad de turno
   esperando que alguien lo desbloquee a mano. Cinco minutos y se arregla
   solo: molesta a quien se equivoca, detiene a quien ataca.

   LO QUE NO CAMBIA
   ----------------
   · A un usuario que NO existe, o cuya empresa está suspendida, se le
     responde igual que antes -pausa y nada- y no se le lleva contador: no
     hay cuenta real que proteger y así no se puede averiguar qué usuarios
     existen probando a ver cuál se bloquea... salvo por el punto de abajo.
   · La respuesta de «bloqueado» sólo aparece para un usuario que existe.
     Eso deja entrever que el usuario existe, a cambio de poder decirle al
     cajero legítimo cuánto esperar. Es un intercambio consciente: en un
     punto de venta el nombre del cajero no es un secreto, y avisarle vale
     más que esconderlo. Si algún día se prefiere lo contrario, basta con
     devolver NULL también en el bloqueo.

   Idempotente: se puede ejecutar dos veces.
   ============================================================================ */

/* ----------------------------------------------------------------------------
   0. ANTES DE TOCAR NADA
   ---------------------------------------------------------------------------- */
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'rest' AND p.proname = 'login') THEN
        RAISE EXCEPTION 'Falta rest.login. Ejecuta antes database/09_postgrest.sql.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'api' AND p.proname = 'fn_login') THEN
        RAISE EXCEPTION 'Falta api.fn_login. Ejecuta antes database/04_procedimientos.sql.';
    END IF;
END $$;


/* ----------------------------------------------------------------------------
   1. DÓNDE SE ANOTAN LOS INTENTOS

   Dos columnas en la propia cuenta. No hace falta una tabla aparte: sólo
   interesa el estado ACTUAL -cuántos fallos seguidos y hasta cuándo
   espera-, no el histórico de cada intento.
   ---------------------------------------------------------------------------- */
ALTER TABLE core.usuarios
    ADD COLUMN IF NOT EXISTS intentos_fallidos SMALLINT     NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS bloqueado_hasta   TIMESTAMPTZ;

COMMENT ON COLUMN core.usuarios.intentos_fallidos IS
    'PIN errados seguidos. Se pone a 0 al acertar. Ver database/41_login_con_freno.sql.';
COMMENT ON COLUMN core.usuarios.bloqueado_hasta IS
    'Si está en el futuro, la cuenta espera y no se le comprueba el PIN. Se limpia al acertar.';


/* ----------------------------------------------------------------------------
   2. EL LOGIN CON FRENO

   Misma firma, mismo esquema, misma forma de respuesta en éxito y en
   fallo. Lo nuevo: mira el bloqueo antes de comprobar el PIN, y lleva el
   contador después.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION rest.login(p_usuario TEXT, p_pin TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    /* El freno, en dos números. Cambiarlos aquí cambia todo el
       comportamiento, a propósito: son la única perilla. */
    c_tope      CONSTANT SMALLINT  := 5;              -- fallos seguidos que disparan la espera
    c_espera    CONSTANT INTERVAL  := INTERVAL '5 minutes';

    v_pre       RECORD;   -- la cuenta, SIN comprobar el PIN todavía
    v           RECORD;   -- lo que devuelve fn_login si el PIN es correcto
    v_exp       BIGINT;
    v_uni       INTEGER[];
    v_nuevos    SMALLINT;
BEGIN
    /* La cuenta, con EXACTAMENTE el mismo filtro que usa api.fn_login:
       activa y, si pertenece a una empresa, con la empresa activa. Si no
       casa, para fn_login no existe, así que aquí tampoco: ni contador ni
       bloqueo, para no delatar qué usuarios hay. */
    SELECT u.id, u.bloqueado_hasta, u.intentos_fallidos
      INTO v_pre
      FROM core.usuarios u
      LEFT JOIN core.empresas e ON e.id = u.empresa_id
     WHERE lower(u.usuario) = lower(trim(p_usuario))
       AND u.activo
       AND (e.id IS NULL OR e.estado = 'activa');

    IF v_pre.id IS NULL THEN
        PERFORM pg_sleep(0.6);
        RETURN NULL;
    END IF;

    /* ¿Está en espera? Entonces no se gasta un bcrypt ni se mira el PIN:
       se dice cuánto falta y se corta. */
    IF v_pre.bloqueado_hasta IS NOT NULL AND v_pre.bloqueado_hasta > now() THEN
        RETURN jsonb_build_object(
            'bloqueado', true,
            'minutos',   GREATEST(1, ceil(extract(epoch FROM (v_pre.bloqueado_hasta - now())) / 60))::INT,
            'mensaje',   'Demasiados intentos. Espera unos minutos y vuelve a probar.');
    END IF;

    /* La comprobación de siempre. */
    SELECT * INTO v FROM api.fn_login(p_usuario, p_pin) LIMIT 1;

    IF v.usuario_id IS NULL THEN
        /* PIN errado en una cuenta que existe y no está en espera: se
           cuenta. Si veníamos de una espera ya vencida (bloqueado_hasta en
           el pasado), el contador arranca de nuevo en 1. */
        v_nuevos := CASE WHEN v_pre.bloqueado_hasta IS NOT NULL THEN 1
                         ELSE v_pre.intentos_fallidos + 1 END;

        UPDATE core.usuarios
           SET intentos_fallidos = v_nuevos,
               bloqueado_hasta   = CASE WHEN v_nuevos >= c_tope THEN now() + c_espera ELSE NULL END
         WHERE id = v_pre.id;

        PERFORM pg_sleep(0.6);
        RETURN NULL;
    END IF;

    /* Acertó: se borra el freno. */
    UPDATE core.usuarios
       SET intentos_fallidos = 0, bloqueado_hasta = NULL
     WHERE id = v.usuario_id;

    v_exp := extract(epoch FROM now() + make_interval(hours => (SELECT duracion_horas FROM core.jwt_config ORDER BY id DESC LIMIT 1)))::BIGINT;
    SELECT COALESCE(array_agg(unidad_id ORDER BY unidad_id), '{}') INTO v_uni
      FROM core.usuario_unidades WHERE usuario_id = v.usuario_id;

    RETURN jsonb_build_object(
        'token', core.fn_jwt_firmar(jsonb_build_object(
                     'role', 'taseca_app', 'usuario_id', v.usuario_id, 'empresa_id', v.empresa_id,
                     'rol', v.rol, 'exp', v_exp)),
        'expira', to_timestamp(v_exp),
        'usuario_id', v.usuario_id, 'nombre', v.nombre, 'usuario', v.usuario,
        'rol', v.rol, 'alcance', v.alcance,
        'empresa_id', v.empresa_id,
        'empresa_codigo', (SELECT codigo FROM core.empresas WHERE id = v.empresa_id),
        'unidades', to_jsonb(v_uni));
END;
$$;

COMMENT ON FUNCTION rest.login(TEXT, TEXT) IS
    'Ingreso por usuario + PIN, con freno suave: 5 PIN errados seguidos dejan la cuenta en espera 5 minutos. Ver database/41_login_con_freno.sql.';

/* Los mismos roles que ya la podían llamar: el pre-login (taseca_anon) y la
   sesión (taseca_app). CREATE OR REPLACE conserva los permisos, pero se
   repiten por si esta migración corre sobre una base donde se recreó a mano.
   NO se revoca nada: una revocación mal puesta aquí deja a todos sin poder
   entrar. */
GRANT EXECUTE ON FUNCTION rest.login(TEXT, TEXT) TO taseca_anon, taseca_app;


/* ----------------------------------------------------------------------------
   3. QUE QUEDÓ COMO SE QUERÍA (sólo mira el texto; el comportamiento se
      prueba en 41_pruebas_login.sql, aparte, para no deshacerlo en la misma
      transacción del editor de Supabase).
   ---------------------------------------------------------------------------- */
DO $$
DECLARE v_def TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='core' AND table_name='usuarios' AND column_name='bloqueado_hasta') THEN
        RAISE EXCEPTION 'No se añadió core.usuarios.bloqueado_hasta.';
    END IF;

    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='rest' AND p.proname='login';
    IF v_def NOT LIKE '%bloqueado_hasta%' OR v_def NOT LIKE '%intentos_fallidos%' THEN
        RAISE EXCEPTION 'rest.login no quedó con el freno.';
    END IF;

    RAISE NOTICE 'OK · el login ahora se frena solo tras varios PIN errados.';
END $$;

NOTIFY pgrst, 'reload schema';
