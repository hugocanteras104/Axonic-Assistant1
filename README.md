# Axonic Assistant Knowledge Base

Este repositorio incluye el esquema de Supabase y los scripts necesarios para mantener la tabla `public.knowledge_base` libre de duplicados gracias a una columna generada que normaliza las preguntas.

## ¿Por dónde empezar?

1. **Revisar el esquema.** Abre [`supabase/schema.sql`](supabase/schema.sql) y confirma que la columna generada `question_normalized` y la `UNIQUE constraint` `knowledge_base_question_key` están presentes. Si estás creando el proyecto desde cero, ejecuta el archivo completo contra tu base de datos de Supabase/Postgres:
   ```bash
   sudo -u postgres psql -d axonic -f supabase/schema.sql
   ```

2. **Aplicar la migración en un proyecto existente.** Si el proyecto ya está creado, vuelve a ejecutar solo la sección de `ALTER TABLE` para garantizar que la columna y la constraint existan sin tocar los datos existentes:
   ```sql
   alter table public.knowledge_base
       add column if not exists question_normalized text
           generated always as (trim(lower(question))) stored;

   alter table public.knowledge_base
       add constraint knowledge_base_question_key
           unique (question_normalized);
   ```

3. **Configurar tus integraciones.** Cuando hagas `upsert` contra el endpoint REST de Supabase, asegúrate de indicar `Prefer: resolution=merge-duplicates` y el conflicto sobre `knowledge_base_question_key`. El helper [`scripts/upsertKnowledgeBase.js`](scripts/upsertKnowledgeBase.js) ya lo hace por ti:
   ```js
   import { upsertKnowledgeBase } from './scripts/upsertKnowledgeBase.js';

   await upsertKnowledgeBase({
     supabaseUrl: process.env.SUPABASE_URL,
     serviceKey: process.env.SUPABASE_SERVICE_KEY,
     entry: {
       question: 'How are you?',
       answer: 'Great!',
       metadata: {},
     },
   });
   ```

4. **Compartir la normalización.** Si necesitas normalizar preguntas desde n8n u otros scripts, reutiliza `normalizeQuestion` exportado por el mismo helper para mantener el mismo criterio que la base de datos.

5. **Verificar con tests.** Ejecuta la suite de Node.js para comprobar que el helper sigue apuntando a la constraint correcta:
   ```bash
   npm test
   ```

Con estos pasos podrás reproducir el flujo completo: preparar el esquema, configurar tus integraciones y asegurarte de que los upserts no fallen por constraints ausentes.
