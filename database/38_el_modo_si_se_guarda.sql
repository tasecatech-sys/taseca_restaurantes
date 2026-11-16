/* ============================================================================
   TASECA · 38 · EL MODO CLARO, QUE NUNCA LLEGÓ A GUARDARSE
   ----------------------------------------------------------------------------
   EL SÍNTOMA

     Se elige «☀️ Claro» en el panel de Taseca -al crear una empresa o en
     «Administrar tema» de una que ya existe-, se guarda, y la empresa
     sigue viéndose oscura. En las dos pantallas. Siempre.

   LA CAUSA, Y POR QUÉ LA 31 NO LA CAZÓ

     Hay DOS procedimientos que guardan un tema:

       api.sp_guardar_tema          ← lo parcheó la migración 31
       api.sp_guardar_tema_empresa  ← el que usa de verdad el panel

     El panel de Taseca llama a rest.guardar_tema_empresa, que llama al
     SEGUNDO. La 31 enseñó el `modo` al primero, que el panel no usa
     nunca. Así que la columna existía, el cliente mandaba el dato, el
     CSS sabía pintarlo... y el procedimiento que recibía el tema tiraba
     ese campo a la basura sin decir nada.

     Se vio en los datos: la empresa creada hoy quedó con `modo = NULL`
     aunque en el formulario se eligió claro.

     Lo mismo valía para las empresas ya creadas: no era que «ya están
     creadas», es que ese botón nunca funcionó para nadie.

   EL ARREGLO

     Enseñarle el `modo` a sp_guardar_tema_empresa: su validación y su
     UPDATE. Con eso quedan servidos los dos caminos -el alta y el
     editar- porque los dos pasan por aquí.

   POR QUÉ UN replace() Y NO REESCRIBIRLO

     El procedimiento viene de la migración 20 y hace más cosas -colores,
     tipografía, motivo, logotipo, imágenes-. Reescribirlo entero desde
     una copia de hoy perdería cualquier otro cambio. Se tocan dos
     líneas, y si no están, avisa.

   Se puede ejecutar más de una vez.
   Requiere: 00 … 37 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. EL PROCEDIMIENTO QUE SÍ USA EL PANEL
   ============================================================================ */
DO $blk$
DECLARE
    v_def   TEXT;
    v_nuevo TEXT;

    /* Las dos líneas que hay que encontrar. Van sin saltos de línea para
       no depender de si la base guarda el cuerpo con CRLF o con LF. */
    v_val_vieja CONSTANT TEXT :=
        'IF NULLIF(p_tema ->> ''patron'', '''') IS NOT NULL AND (p_tema ->> ''patron'') !~ ''^[a-z0-9_-]{1,20}$'' THEN';
    v_col_vieja CONSTANT TEXT :=
        'patron           = COALESCE(NULLIF(p_tema ->> ''patron'', ''''), patron),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'sp_guardar_tema_empresa';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'api.sp_guardar_tema_empresa no existe: falta la migración 15 o la 20.';
    END IF;

    IF position('''modo''' IN v_def) > 0 THEN
        RAISE NOTICE 'api.sp_guardar_tema_empresa ya guardaba el modo. No se toca.';
        RETURN;
    END IF;

    IF position(v_val_vieja IN v_def) = 0 OR position(v_col_vieja IN v_def) = 0 THEN
        RAISE EXCEPTION 'api.sp_guardar_tema_empresa cambió de forma: esta migración hay que revisarla a mano.';
    END IF;

    /* La validación del modo, delante de la del motivo de marca. */
    v_nuevo := replace(v_def, v_val_vieja,
        'IF NULLIF(p_tema ->> ''modo'', '''') IS NOT NULL AND (p_tema ->> ''modo'') NOT IN (''claro'', ''oscuro'') THEN' ||
        E'\n        RAISE EXCEPTION ''El modo sólo puede ser claro u oscuro.'';' ||
        E'\n    END IF;' ||
        E'\n    ' || v_val_vieja);

    /* Y la columna, detrás del motivo de marca. */
    v_nuevo := replace(v_nuevo, v_col_vieja,
        v_col_vieja || E'\n           modo             = COALESCE(NULLIF(p_tema ->> ''modo'', ''''), modo),');

    EXECUTE v_nuevo;
    RAISE NOTICE 'api.sp_guardar_tema_empresa: ahora guarda el modo.';
END;
$blk$;


/* ============================================================================
   2. REVISIÓN
   ============================================================================ */
DO $blk$
DECLARE
    v_def TEXT;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'sp_guardar_tema_empresa';

    IF position('modo             = COALESCE' IN v_def) = 0 THEN
        RAISE EXCEPTION 'El UPDATE no quedó guardando el modo.';
    END IF;

    IF position('El modo sólo puede ser claro u oscuro' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Falta la validación del modo: entraría cualquier texto en la columna.';
    END IF;

    /* La columna y su restricción vienen de la 31; sin ellas esto no
       serviría de nada. */
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'core' AND table_name = 'empresas' AND column_name = 'modo') THEN
        RAISE EXCEPTION 'No existe core.empresas.modo: falta la migración 31.';
    END IF;

    RAISE NOTICE 'OK · el panel de Taseca ya puede poner una empresa en claro.';
    RAISE NOTICE '  Taseca → Empresas → Ver → Administrar tema → Modo.';
END;
$blk$;


/* ============================================================================
   3. LO QUE QUEDÓ SIN MODO

   La empresa creada antes de este arreglo tiene `modo = NULL`. No es un
   error -sin dato se ve oscura, que es lo que se veía- pero deja la
   columna a medias. Se les pone el valor que de verdad tienen.
   ============================================================================ */
UPDATE core.empresas SET modo = 'oscuro' WHERE modo IS NULL;
