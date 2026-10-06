# CRM Bamvolea Sportcity Valencia

CRM interno de gestión para el club (clases, alumnos, entrenadores, calendario
de eventos/alquileres y KPIs). Stack: Supabase (Postgres + Auth + Storage +
Edge Functions) y un único `index.html` en JavaScript vanilla, sin build
step, pensado para hospedar en Vercel o cualquier hosting estático.

**Modo solo eventos (activo):** ahora mismo la app muestra únicamente
Eventos (Presupuestos y Calendario) y Configuración (Plantillas de email),
con la imagen corporativa de Bamvolea. El resto de módulos sigue en el
código pero oculto; para recuperarlos, pon `EVENTS_ONLY = false` en
`index.html`.

Alcance de esta primera versión: Alumnos, Parrilla, Lista de espera, Tareas,
Grupos, Planificación, KPIs, Entrenadores/Vista entrenador, Eventos y
Gestión (plantillas de email + Playtomic Manager). No incluye Casales
(campamento de verano) ni Ligas internas — el club no las ofrece por ahora;
se pueden añadir más adelante siguiendo el mismo patrón de módulos.

## 1. Crear el proyecto en Supabase

1. Crea un proyecto nuevo en [supabase.com](https://supabase.com).
2. En **SQL Editor**, ejecuta en orden los archivos de `supabase/migrations/`:
   - `0001_init.sql` — esquema, RLS y bucket de adjuntos.
   - `0002_rpc_and_seed.sql` — tipos de clase, plantillas base y las
     funciones RPC de la Vista entrenador (acceso por PIN).
   - `0003` a `0005` — Playtomic (IDs de profesor, sincronización de clases)
     y alta de entrenadores.
   - `0006_event_quotes.sql` — Presupuestos de eventos: tarifas
     (`quote_catalog`), presupuestos (`event_quotes`), plantilla de email
     `presupuesto_evento` y los tres últimos presupuestos enviados
     (GRUPPE, Power Electronics, CECOTEC) como historial.
3. En **Authentication > Users**, crea una cuenta para cada persona del
   equipo (email + contraseña).
4. En **Table Editor > profiles**, da de alta una fila por cada usuario:
   `id` (el UUID del usuario en Auth), `full_name`, `email`, `role`
   (`admin`, `front_desk`, `administracion`, `coordinacion`, `entrenador`,
   `direccion`) y `club_ids` (array con el UUID del club — hay uno solo,
   "Bamvolea Sportcity Valencia", visible en la tabla `clubs`).
   Si das de alta a alguien con `role='entrenador'` y quieres que entre con
   usuario/contraseña normal en vez del PIN, rellena también `trainer_id`
   con el UUID de su fila en `trainers` — verá un menú reducido con "Mi
   vista" (el mismo contenido que la Vista entrenador por PIN). La mayoría
   de entrenadores no necesita esto: les basta con el PIN.
5. En **Table Editor > trainers**, da de alta al equipo técnico con su PIN
   personal (para la Vista entrenador) y, si tenéis Playtomic, su
   `external_system_name` exacto tal como aparece allí (para casar los
   KPIs reales por nombre).

## 2. Desplegar las Edge Functions

Desde el dashboard de Supabase (**Edge Functions**), crea dos funciones y
pega el contenido de:

- `supabase/functions/send-email/index.ts` → nómbrala `send-email`.
- `supabase/functions/playtomic-proxy/index.ts` → nómbrala `playtomic-proxy`.

(También puedes usar `supabase functions deploy send-email` /
`playtomic-proxy` con la CLI si la tienes instalada — no es obligatorio.)

Configura los **secrets** de cada función (Edge Functions > Settings):

| Función | Secrets |
|---|---|
| `send-email` | `RESEND_API_KEY`, `RESEND_FROM` (ej. `Bamvolea Sportcity Valencia <no-reply@tudominio.com>`) |
| `playtomic-proxy` | `PLAYTOMIC_CLIENT_ID`, `PLAYTOMIC_CLIENT_SECRET`, `PLAYTOMIC_TENANT_ID` |

`SUPABASE_URL` y `SUPABASE_ANON_KEY` ya están disponibles automáticamente
dentro de las Edge Functions, no hace falta configurarlos.

**Importante sobre Playtomic**: `playtomic-proxy/index.ts` usa la
["Third Party API" pública de Playtomic para clubs](https://third-party.playtomic.io/)
(`https://thirdparty.playtomic.io/api/v1/oauth/token` para login,
`.../api/v1/bookings` para reservas — nótese que el host de la API no lleva
guion, a diferencia del sitio de documentación). Las credenciales se
generan en Playtomic Manager → Settings → Developer tools. Aun así,
comprobad con una llamada real (Postman o el propio Playtomic Manager)
antes de confiar del todo en los datos, porque:
- El campo `coach_ids` de cada reserva son IDs de Playtomic, no nombres —
  si vuestra cuenta no expone el nombre del profesor en ese mismo payload,
  el casado por nombre (`trainers.external_system_name`) en KPIs y
  Playtomic Manager no encontrará coincidencias hasta resolver esos IDs
  contra el endpoint de profesores/empleados de Playtomic (no implementado
  aquí).
- La API solo conserva reservas de los últimos ~3 meses.
Nunca pongáis `PLAYTOMIC_CLIENT_ID`/`SECRET` en el frontend.

> Si ya tenías `send-email` desplegada, vuelve a pegar su `index.ts`
> actualizado: antes fallaba con adjuntos de más de ~100 KB (como el PDF de
> un presupuesto) y ahora los codifica por trozos.

## 3. Configurar el frontend

Edita las primeras líneas de `index.html` (o defínelas antes de cargar el
archivo, como variables `window.SUPABASE_URL` / `window.SUPABASE_ANON_KEY`):

```html
<script>
  window.SUPABASE_URL = 'https://tu-proyecto.supabase.co';
  window.SUPABASE_ANON_KEY = 'tu-anon-key-publica';
  window.EVENTOS_PROVEEDOR_EMAIL = 'proveedor@ejemplo.com'; // opcional
</script>
```

La `anon key` es pública por diseño (queda visible en el código fuente);
toda la seguridad real vive en las políticas de Row Level Security de cada
tabla, no en ocultar esta clave.

## 4. Desplegar en Vercel

No hay build step: en Vercel, crea un proyecto "Other"/estático apuntando
a este repositorio, sin comando de build, sirviendo `index.html` como raíz.
También puedes abrir el archivo directamente en un hosting estático
cualquiera (Netlify, GitHub Pages, S3, etc.).

## 5. Vista entrenador (PIN)

En la pantalla de acceso, "Soy entrenador/a → Vista entrenador (PIN)" entra
sin usuario/contraseña: solo hace falta el PIN dado de alta en `trainers`.
Es un acceso deliberadamente simple para consultar entre clase y clase
desde el móvil — el resto del equipo entra siempre con su cuenta real.

## Checklist de arranque

- [ ] Migraciones ejecutadas y RLS activo (revisa en Supabase que las
      tablas muestren el candado de RLS habilitado).
- [ ] Al menos un usuario `admin` en `profiles` para poder gestionar el
      resto desde la propia app si añades una pantalla de administración
      de usuarios más adelante (por ahora se gestionan desde el Table
      Editor de Supabase).
- [ ] Entrenadores dados de alta con su PIN.
- [ ] Plantillas de email en Gestión → Plantillas revisadas con vuestro
      tono y datos de contacto reales.
- [ ] Secrets de `send-email` configurados y probados (manda un email de
      prueba desde Gestión → Plantillas o Tareas).
- [ ] Si vais a usar Playtomic: credenciales configuradas y endpoint
      verificado contra una respuesta real antes de confiar en los KPIs
      "reales".

## Presupuestos de eventos (Eventos > Presupuestos)

Sustituye al Excel "DESGLOSE EVENTO" y al Word del presupuesto:

1. **Nuevo presupuesto** → empresa, fecha y nº de participantes (el título
   "EVENTO DEPORTIVO EMPRESA" y el texto de la fecha se rellenan solos).
2. **Plantilla rápida** (torneo, alquiler, clinic, pádel + fútbol 7, evento
   familiar) y ajustar el desglose: pistas × horas × €/h, bolas, gestión del
   torneo, monitores, ludoteca… Escribiendo el horario ("de 9:30 a 14:30")
   se calculan las horas; los botes de bolas siguen al nº de pistas.
3. Las viñetas del PDF se generan solas desde el desglose (se pueden
   retocar a mano) y la vista previa se actualiza al momento.
4. **Descargar PDF**, **Imprimir** (PDF vectorial vía "Guardar como PDF") o
   **Enviar por email** con el PDF adjunto (marca el presupuesto como
   enviado). **Aceptado → calendario** crea el evento en el calendario.
5. **Duplicar** reutiliza cualquier presupuesto anterior; **Tarifas**
   (admin, coordinación, dirección) cambia precios por defecto y textos.

El diseño del PDF usa las imágenes de `assets/presupuestos/` (cabecera,
logo e icono de calendario) y la dirección del club definida en
`QUOTE_CLUB_ADDRESS` dentro de `index.html`.

## Qué añadir después

Casales (campamento de verano) y Ligas internas no están construidos en
esta versión porque el club no los ofrece todavía. Si en el futuro hacen
falta, se pueden añadir como nuevos módulos siguiendo el mismo patrón:
tabla(s) en una nueva migración SQL + entrada en `NAV` + `MODULES.<clave>`
en `index.html`.
