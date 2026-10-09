# 🚀 API de Taseca en la nube (PostgREST propio)

Aquí vive la configuración para publicar **nuestro** PostgREST contra la base
de Supabase. Es el mismo programa que corre en el computador del negocio
(`iniciar-postgrest.bat`), sólo que alojado en internet.

## Por qué

El Data API que trae Supabase es también PostgREST, pero valida los tokens con
las claves **del proyecto**, no con el secreto que guarda nuestra base. En los
proyectos nuevos esas claves son asimétricas (ES256) y PostgreSQL no puede
firmar así, de modo que nadie podría iniciar sesión.

Con PostgREST propio nada de eso cambia: la base firma su token como siempre y
el servidor lo valida con el secreto que le pide a la base al arrancar
(`core.fn_postgrest_pre_config`). Cero cambios en la aplicación y cero
dependencia de cómo Supabase maneje sus llaves.

## Pasos (una sola vez)

### 1. Contraseña para el usuario de conexión

En el editor SQL de Supabase. El rol ya existe (lo crea `09_postgrest.sql`):

```sql
ALTER ROLE taseca_rest LOGIN PASSWORD 'una-contraseña-larga-y-aleatoria';
GRANT taseca_app, taseca_anon TO taseca_rest;
```

Guarda esa contraseña en tu gestor. **No la compartas con nadie**, tampoco por chat.

### 2. La cadena de conexión

En Supabase: **Connect → Session pooler**. Copia la cadena tal cual y cámbiale
dos cosas: el usuario y la contraseña.

Ojo con el usuario: el pooler exige que lleve pegada la referencia del
proyecto, así que donde dice `postgres.wnbslnjdoupdoshipxbc` va
`taseca_rest.wnbslnjdoupdoshipxbc`. Queda algo así:

```
postgresql://taseca_rest.wnbslnjdoupdoshipxbc:TU-CONTRASEÑA@aws-1-us-east-2.pooler.supabase.com:5432/postgres
```

La región y el número del host los copias de tu panel; cambian según el
proyecto. Usa el **pooler**, no la conexión directa: esa sólo responde por IPv6.

### 2b. Probarlo en tu computador antes de publicar nada

Con Docker instalado, una sola línea levanta el mismo servidor en el puerto
3001 y se ve si conecta:

```bash
docker run --rm -p 3001:3000 -e PGRST_DB_URI="LA-CADENA-DEL-PASO-2" -e PGRST_DB_SCHEMAS=rest -e PGRST_DB_ANON_ROLE=taseca_anon -e PGRST_DB_PRE_CONFIG=core.fn_postgrest_pre_config -e PGRST_DB_PREPARED_STATEMENTS=false postgrest/postgrest:v12.2.12
```

Y en otra ventana:

```bash
curl http://localhost:3001/empresas?select=codigo
```

Si responde la lista de empresas, la conexión y los permisos están bien y sólo
falta publicarlo. Si no, el propio contenedor dice por qué en su salida.

### 3. Publicar

Instala `flyctl` (en Windows, PowerShell):

```powershell
iwr https://fly.io/install.ps1 -useb | iex
```

Y desde esta carpeta:

```bash
fly auth signup
fly launch --copy-config --no-deploy
fly secrets set PGRST_DB_URI="postgresql://taseca_rest:TU-CONTRASEÑA@..."
fly deploy
```

`fly launch` puede pedir un nombre libre si `taseca-api` ya está tomado; el que
elijas queda como `https://EL-NOMBRE.fly.dev`.

### 4. Apuntar la aplicación

En `js/backend.js`, dentro de `NUBE`:

```js
url: 'https://taseca-api.fly.dev',
apikey: '',      // el nuestro no pide clave de portería
esquema: '',     // sólo publica rest, no hace falta decirlo
```

Sube el cambio y listo: el sitio publicado entra con usuario y PIN, como en el
local.

## Comprobar que quedó bien

```bash
curl https://taseca-api.fly.dev/empresas?select=codigo
```

Debe responder la lista de empresas. Si responde `permission denied`, falta el
`GRANT` del paso 1; si no responde nada, mira `fly logs`.

## Costo

Una máquina compartida de 256 MB, que se suspende sola cuando no hay tráfico y
despierta en menos de un segundo con la primera petición. Es el escalón más
barato de Fly; con el uso de un restaurante no debería pasar de unos pocos
dólares al mes.

## Alternativas

La misma imagen y las mismas variables sirven en Railway, Koyeb o cualquier
servidor con Docker. Lo único que cambia es dónde se pega `PGRST_DB_URI`.
