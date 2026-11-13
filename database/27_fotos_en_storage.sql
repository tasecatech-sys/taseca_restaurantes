/* ============================================================================
   TASECA · 27 · LAS FOTOS DE LA CARTA VIVEN EN STORAGE
   ----------------------------------------------------------------------------
   `core.productos.imagen_url` guarda una dirección, y eso está bien. Lo que
   faltaba era un sitio donde poner la foto: hasta ahora había que subirla a
   algún lado por fuera y pegar la URL a mano, que es justo lo que nadie hace.

   POR QUÉ STORAGE Y NO LA BASE
     Ya está escrito en database/COSTOS_SUPABASE.md, sección 2: una foto
     dentro de la base cuesta $0,125 por GB y engorda CADA copia de
     seguridad; en Storage cuesta $0,0213 y hay 100 GB incluidos. Para UNA
     imagen por empresa -el logo, en core.empresa_imagenes- da igual. Una
     carta son 50 o 200 productos por empresa: ahí ya no da igual.

   POR QUÉ LA RUTA LLEVA EL CÓDIGO DE LA EMPRESA
     `carta/empresa_nascar/00123.jpg`

     Dos razones. La primera es que se lee: quien entre al panel de Supabase
     ve carpetas por empresa, no un montón de identificadores. La segunda es
     que la ruta ES el permiso — la política de abajo compara el primer
     tramo con la empresa del token, así que una empresa no puede escribir
     en la carpeta de otra ni equivocándose.

     Y como el nombre del archivo es el código del producto, volver a subir
     otro archivo con el mismo nombre cambia la foto en toda la carta sin
     tocar un solo registro.

   QUIÉN PUEDE SUBIR
     Los tokens de rest.login van firmados con el JWT secret del PROYECTO
     (ver database/18_supabase.sql, paso 3), así que Storage los da por
     buenos igual que PostgREST. Llevan `role` = taseca_app y `empresa_id`,
     que es todo lo que hace falta aquí.

     Leer no pide token: el bucket es público porque la carta es pública.
     Escribir sí, y sólo en la carpeta propia.

   OJO CON EL ORDEN
     Esto se ejecuta en el editor SQL de Supabase, NO contra un PostgreSQL
     propio: el esquema `storage` lo pone Supabase. Si da error diciendo que
     no existe, es que se está ejecutando en el sitio equivocado.

   No toca ningún dato existente. Se puede ejecutar más de una vez.
   Requiere: 00 … 26 instalados y el paso 3 de 18_supabase.sql hecho.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. EL BUCKET

   Público para leer: la carta la ve cualquiera, y si pidiera firma cada
   visita gastaría una petición por foto sin ganar nada.

   El tope de 2 MB y la lista de tipos son la última línea de defensa. La
   aplicación ya comprime antes de subir (U.comprimirImagen, js/ui.js), pero
   lo que protege de verdad es lo que comprueba el servidor.
   ============================================================================ */
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('carta', 'carta', TRUE, 2097152,
        ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
   SET public             = EXCLUDED.public,
       file_size_limit    = EXCLUDED.file_size_limit,
       allowed_mime_types = EXCLUDED.allowed_mime_types;


/* ============================================================================
   2. PERMISOS DE TABLA

   RLS decide QUÉ filas, pero antes hace falta poder tocar la tabla. Sin
   esto, las políticas de abajo no llegan ni a evaluarse.
   ============================================================================ */
GRANT USAGE ON SCHEMA storage TO taseca_app;
GRANT SELECT ON storage.buckets TO taseca_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO taseca_app;


/* ============================================================================
   3. QUÉ PUEDE ESCRIBIR CADA EMPRESA

   `storage.foldername(name)` parte la ruta: de 'empresa_nascar/00123.jpg'
   devuelve {empresa_nascar}. El primer tramo tiene que ser el código de la
   empresa que dice el token, y punto.

   Se compara contra core.empresas en vez de confiar en un código que venga
   en el token: el token trae el id, que es lo que la base controla.
   ============================================================================ */
CREATE OR REPLACE FUNCTION core.fn_storage_carpeta_propia(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM core.empresas e
         WHERE e.codigo = (storage.foldername(p_name))[1]
           AND e.id     = core.fn_jwt_empresa()
    );
$$;

COMMENT ON FUNCTION core.fn_storage_carpeta_propia(TEXT) IS
    'TRUE si el primer tramo de la ruta es el código de la empresa del token. Aísla las fotos de la carta por empresa dentro de Storage.';

GRANT EXECUTE ON FUNCTION core.fn_storage_carpeta_propia(TEXT) TO taseca_app;


DO $$
BEGIN
    /* Se recrean siempre: así una corrección de la regla se aplica al
       volver a ejecutar el archivo, en vez de quedar la versión vieja. */
    DROP POLICY IF EXISTS carta_subir     ON storage.objects;
    DROP POLICY IF EXISTS carta_reemplazar ON storage.objects;
    DROP POLICY IF EXISTS carta_borrar    ON storage.objects;
    DROP POLICY IF EXISTS carta_leer_app  ON storage.objects;

    CREATE POLICY carta_subir ON storage.objects
        FOR INSERT TO taseca_app
        WITH CHECK (bucket_id = 'carta' AND core.fn_storage_carpeta_propia(name));

    CREATE POLICY carta_reemplazar ON storage.objects
        FOR UPDATE TO taseca_app
        USING      (bucket_id = 'carta' AND core.fn_storage_carpeta_propia(name))
        WITH CHECK (bucket_id = 'carta' AND core.fn_storage_carpeta_propia(name));

    CREATE POLICY carta_borrar ON storage.objects
        FOR DELETE TO taseca_app
        USING (bucket_id = 'carta' AND core.fn_storage_carpeta_propia(name));

    /* Leer la carpeta propia con sesión. El público lee por la URL del
       bucket, que no pasa por aquí; esto es para que el panel pueda
       listar lo que ya subió. */
    CREATE POLICY carta_leer_app ON storage.objects
        FOR SELECT TO taseca_app
        USING (bucket_id = 'carta');
END;
$$;


/* ============================================================================
   4. COMPROBACIÓN

   Que quede instalado de verdad, no «sin error». Si algo falta, se dice
   aquí y no tres días después, cuando alguien no pueda subir una foto.
   ============================================================================ */
DO $$
DECLARE
    v_bucket   BOOLEAN;
    v_politicas INTEGER;
BEGIN
    SELECT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'carta') INTO v_bucket;
    SELECT count(*) INTO v_politicas
      FROM pg_policies
     WHERE schemaname = 'storage' AND tablename = 'objects'
       AND policyname IN ('carta_subir', 'carta_reemplazar', 'carta_borrar', 'carta_leer_app');

    IF NOT v_bucket THEN
        RAISE EXCEPTION 'El bucket «carta» no quedó creado: revisa el paso 1.';
    END IF;
    IF v_politicas <> 4 THEN
        RAISE EXCEPTION 'Faltan políticas de storage.objects: hay % de 4.', v_politicas;
    END IF;

    RAISE NOTICE '✔ Bucket «carta» listo y con sus 4 políticas.';
    RAISE NOTICE '  Las fotos van a  carta/<codigo_empresa>/<codigo_producto>.jpg';
END;
$$;
