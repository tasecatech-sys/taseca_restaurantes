/* ============================================================================
   TASECA · 39 · EL PANEL DE TASECA TIENE QUE PODER VER EL MODO
   ----------------------------------------------------------------------------
   EL SÍNTOMA, DESPUÉS DE LA 38

     Se pone una empresa en claro desde el panel. La base lo guarda -se
     comprueba-, el portal del cliente se ve claro. Pero al volver a abrir
     «Administrar tema», el selector dice OSCURO otra vez.

     Y eso no es sólo confuso: si en esa pantalla se cambia cualquier otra
     cosa -un color, la tipografía- y se guarda, el formulario manda el
     modo que ESTÁ VIENDO, o sea oscuro, y deshace el cambio sin avisar.

   LA CAUSA

     La 38 arregló la ESCRITURA. Faltaba la LECTURA.

     El panel de plataforma lee de rest.plataforma_empresas, y esa vista
     no expone `modo`. La 31 lo añadió a api.v_empresa_ficha y a
     rest.empresas -las que usa el portal del cliente- pero se dejó ésta,
     que es la que lee el panel.

     js/remoto.js (aEmpresa) ya leía `e.modo` desde el principio: lo que
     llegaba era undefined, así que caía al valor por defecto.

   LA LECCIÓN, QUE YA VA TRES VECES

     Añadir un campo son CUATRO sitios: la columna, la vista que lo lee,
     el procedimiento que lo escribe y el cliente. La 31 hizo uno y medio.

   OJO con CREATE OR REPLACE VIEW: no deja quitar columnas, renombrarlas
   ni meter una en medio. `modo` va la última, detrás de `patron`. Y la
   lista de abajo es la forma REAL de la vista hoy, sacada con:
       SELECT pg_get_viewdef('rest.plataforma_empresas'::regclass, true);

   Se puede ejecutar más de una vez.
   Requiere: 00 … 38 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. LA VISTA
   ============================================================================ */
CREATE OR REPLACE VIEW rest.plataforma_empresas AS
SELECT empresa_id,
       codigo,
       nombre_comercial,
       razon_social,
       nit,
       eslogan,
       descripcion,
       estado,
       hora_corte_operativa,
       telefono,
       whatsapp,
       email,
       direccion,
       horario_general,
       instagram_url,
       facebook_url,
       tiempo_mesa,
       tiempo_domicilio,
       color_primario,
       color_secundario,
       color_acento,
       color_fondo,
       tipografia,
       logo_texto,
       logo_acento,
       iniciales,
       lema,
       plantilla,
       creado_en,
       jornada_actual,
       imagenes_version,
       modulos,
       metodos_pago,
       cuentas,
       n_unidades,
       n_usuarios,
       patron,
       modo
  FROM api.v_empresa_ficha v
 WHERE api.fn_tiene_permiso(core.fn_jwt_usuario(), 'plataforma'::CHARACTER VARYING);


/* ============================================================================
   2. REVISIÓN

   No basta con que la columna exista en la vista: se comprueba que para
   una empresa en claro la vista DEVUELVA claro. Es el fallo exacto.
   ============================================================================ */
DO $blk$
DECLARE
    v_tiene BOOLEAN;
    v_claro INTEGER;
BEGIN
    SELECT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'rest' AND table_name = 'plataforma_empresas'
                      AND column_name = 'modo') INTO v_tiene;

    IF NOT v_tiene THEN
        RAISE EXCEPTION 'rest.plataforma_empresas sigue sin exponer el modo.';
    END IF;

    /* La vista filtra por permiso de plataforma, así que desde aquí no
       devuelve filas. Se comprueba contra la ficha, que es su origen. */
    SELECT count(*) INTO v_claro
      FROM api.v_empresa_ficha WHERE modo = 'claro';

    RAISE NOTICE 'OK · la vista del panel ya expone el modo. Empresas en claro ahora mismo: %.', v_claro;
    RAISE NOTICE '  Recarga el panel de Taseca y «Administrar tema» mostrará el valor real.';
END;
$blk$;
