/* ============================================================================
   44 · LA VITRINA PÚBLICA, COLUMNA A COLUMNA

   DE DÓNDE VIENE ESTO
   -------------------
   La migración 42 le quitó a `taseca_anon` TODO el SELECT sobre
   `rest.empresas` para cerrar el GET /empresas que sacaba razon_social y
   email de todas las empresas. Pero se pasó de ancho: el directorio público
   de Taseca (restaurantes.html / js/restaurantes.js) lee esa misma vista
   -con el apikey anónimo- para listar los restaurantes, pidiendo SÓLO
   columnas de marca:

       codigo, nombre_comercial, eslogan, lema, descripcion, logo_url,
       logo_texto, logo_acento, iniciales, color_primario, color_secundario

   Con la 42 esa página quedó sin poder leer nada. La 42 acertó en quitar el
   acceso a lo sensible; erró en quitar también lo público.

   Y midiendo eso salió un segundo agujero, de otro tipo: la vista
   `rest.empresas` NO filtra por la empresa del token, así que un `taseca_app`
   logueado -cualquier cajero- podía leer por consulta directa la ficha de
   OTRAS empresas (razon_social, email y cuentas de recaudo incluidas). Fuga
   ENTRE INQUILINOS, distinta de la de anónimos.

   QUÉ SE HACE
   -----------
     1. A `taseca_anon` se le devuelve el SELECT, pero COLUMNA A COLUMNA: sólo
        las 11 de marca que el directorio necesita. razon_social, email, nit,
        cuentas, metodos_pago, modulos… siguen fuera de su alcance por
        consulta directa. (El portal del cliente no usa esta vía: va por
        rest.arranque, SECURITY DEFINER.)
     2. A `taseca_app` se le QUITA el SELECT directo sobre la vista. El panel
        nunca la consulta directamente -su ficha llega por rest.arranque, que
        la filtra por el código/token- y el super-admin usa otra vista
        (rest.plataforma_empresas). Así un cajero deja de poder leer la ficha
        de otras empresas.

   Tras esto, el ÚNICO acceso directo a rest.empresas es el de anon a las 11
   columnas públicas; todo lo demás pasa por rest.arranque, con su alcance.

   OJO para el futuro: si se recrea la vista rest.empresas, estos permisos se
   pierden y hay que volver a correr esta migración (o repetir el GRANT por
   columnas y el REVOKE). NO darle a anon un GRANT de tabla entera otra vez.

   Idempotente. Requiere: la vista rest.empresas y la 42.
   ============================================================================ */

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'rest' AND c.relname = 'empresas') THEN
        RAISE EXCEPTION 'Falta la vista rest.empresas.';
    END IF;
END $$;

/* 1 · anon: sólo las 11 columnas de marca que pide el directorio público.
   REVOKE primero por si una corrida anterior dejó algún permiso de columna
   distinto; deja el estado en EXACTAMENTE estas 11. */
REVOKE SELECT ON rest.empresas FROM taseca_anon;
GRANT SELECT (codigo, nombre_comercial, eslogan, lema, descripcion, logo_url,
              logo_texto, logo_acento, iniciales, color_primario, color_secundario)
      ON rest.empresas TO taseca_anon;

/* 2 · taseca_app: ya no lee la ficha de otras empresas por consulta directa.
   Su ficha llega por rest.arranque (filtrada por token); el super-admin usa
   rest.plataforma_empresas. */
REVOKE SELECT ON rest.empresas FROM taseca_app;


/* ----------------------------------------------------------------------------
   REVISIÓN
   ---------------------------------------------------------------------------- */
DO $$
BEGIN
    -- anon puede leer una pública…
    IF NOT has_column_privilege('taseca_anon', 'rest.empresas', 'nombre_comercial', 'SELECT') THEN
        RAISE EXCEPTION 'taseca_anon no quedó pudiendo leer las columnas públicas del directorio.';
    END IF;
    -- …pero NO una sensible…
    IF has_column_privilege('taseca_anon', 'rest.empresas', 'razon_social', 'SELECT')
       OR has_column_privilege('taseca_anon', 'rest.empresas', 'email', 'SELECT') THEN
        RAISE EXCEPTION 'taseca_anon todavía puede leer razon_social o email.';
    END IF;
    -- …y taseca_app no lee la vista directamente.
    IF has_table_privilege('taseca_app', 'rest.empresas', 'SELECT')
       OR has_column_privilege('taseca_app', 'rest.empresas', 'razon_social', 'SELECT') THEN
        RAISE EXCEPTION 'taseca_app todavía puede leer rest.empresas directamente.';
    END IF;

    RAISE NOTICE 'OK · anon ve sólo las 11 columnas de marca; taseca_app ya no lee la ficha de otras empresas.';
END $$;

NOTIFY pgrst, 'reload schema';
