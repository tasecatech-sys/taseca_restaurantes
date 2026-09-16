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

En Supabase: **Connect → Session pooler**. Copia la cadena y reemplaza el
usuario y la contraseña por los del paso 1. Queda algo así:

```
postgresql://taseca_rest:TU-CONTRASEÑA@aws-0-us-east-1.pooler.supabase.com:5432/postgres
```

Usa el **pooler**, no la conexión directa: la directa sólo responde por IPv6.

### 3. Publicar

Instala `flyctl` ([fly.io/docs/flyctl/install](https://fly.io/docs/flyctl/install/)) y,
desde esta carpeta:

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
