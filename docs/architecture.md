# Axonic Assistant MVP v1.0 – Arquitectura Técnica y Funcional

## 1. Visión General
Axonic Assistant es un agente conversacional proactivo diseñado para operar en WhatsApp y centralizar la gestión del negocio y la comunicación con pacientes de una clínica estética. El objetivo del MVP es demostrar la arquitectura "Modo DUAL", que diferencia el comportamiento del bot según el rol del usuario identificado por su número telefónico y permite automatizar la gestión de reservas, inventario, reporting y servicio al cliente.

## 2. Componentes Principales
| Capa | Tecnología | Rol en el MVP |
| --- | --- | --- |
| Canal Conversacional | WhatsApp Business API (Cloud API de Meta) | Recepción y envío de mensajes (texto, audio, botones, plantillas). |
| Orquestador | n8n (self-hosted en VPS) | Coordina flujos, integra APIs y enruta la conversación entre servicios. |
| Base de Datos | Supabase (PostgreSQL + auth + storage) | Persistencia de usuarios, inventario, agenda interna, knowledge base, listas de espera y auditoría. |
| Motor LLM | Google Gemini 1.5 Pro (API) | Comprensión de lenguaje natural, generación de respuestas y planes de acción. |
| Agenda | Google Calendar API | Fuente de disponibilidad y confirmación de citas. |
| Almacenamiento de Prompts y Config | Git + Supabase (table `prompts`) | Versionado y ajustes de personalidad.

## 3. Arquitectura Lógica "Modo DUAL"
1. **Identificación:** Cada mensaje entrante llega a n8n via webhook de WhatsApp. n8n registra el número telefónico y consulta en Supabase (`profiles` table) para determinar el rol (`owner`, `lead`). Si no existe registro, crea uno con rol `lead`.
2. **Contexto Conversacional:** n8n construye un payload con el historial relevante, estados de conversación y metadatos (última intención, cita en progreso, etc.) almacenados en Supabase (`conversations` table) o Redis opcional para baja latencia.
3. **Router de Flujos:** En función del rol, n8n ejecuta dos pipelines distintos:
   - **Modo Comandante (owner):** Permite acceso a flujos de gestión y comandos administrativos.
   - **Modo Asistente (lead/cliente):** Desencadena flujos guiados de reserva, atención y venta consultiva.
4. **Motor IA:** n8n invoca Gemini con prompts específicos por rol. La respuesta se post-procesa para mapear intenciones, entidades y acciones.
5. **Ejecución de Acciones:** Dependiendo de la intención detectada, se activan módulos (Calendario, Inventario, Knowledge Base, Reporting). Tras ejecutar acciones, el resultado se formatea para WhatsApp y se envía.

## 4. Modelo de Datos en Supabase
### 4.1. Tablas Core
- `profiles`
  - `id` (uuid)
  - `phone_number` (text, unique)
  - `role` (enum: `owner`, `lead`)
  - `name`, `email`, `metadata`
  - `created_at`, `updated_at`
- `conversations`
  - `id`
  - `profile_id`
  - `state` (jsonb, contexto actual)
  - `last_intent`, `last_message`
  - `updated_at`
- `appointments`
  - `id`
  - `profile_id`
  - `service_id`
  - `calendar_event_id`
  - `status` (enum: `pending`, `confirmed`, `cancelled`)
  - `start_time`, `end_time`
  - `notes`
  - `created_at`
- `services`
  - `id`
  - `name`
  - `description`
  - `base_price`
  - `duration_minutes`
  - `metadata`
- `knowledge_base`
  - `id`
  - `category`
  - `question`
  - `answer`
  - `last_modified_by`
  - `updated_at`
- `inventory`
  - `id`
  - `sku`
  - `name`
  - `quantity`
  - `reorder_threshold`
  - `price`
- `cross_sell_rules`
  - `id`
  - `trigger_service_id`
  - `recommended_service_id`
  - `message_template`
  - `priority`
- `waitlists`
  - `id`
  - `service_id`
  - `desired_date`
  - `profile_id`
  - `status` (enum: `active`, `notified`, `converted`)
- `audit_logs`
  - `id`
  - `profile_id`
  - `action`
  - `payload`
  - `timestamp`

### 4.2. Vistas y Funciones
- **View `owner_dashboard_metrics`:** Agrega citas por día, ingresos estimados, tratamiento más reservado.
- **RPC `decrement_inventory(sku, qty)`:** Garantiza consistencia con triggers.
- **RPC `get_available_slots(service_id, date_range)`:** Cacheable para respuestas rápidas.
- **Trigger `on_appointment_cancelled`:** Inserta evento en `notifications_queue` para el optimizador "Tetris".

## 5. Flujos n8n Propuestos
### 5.1. Webhook Entrante WhatsApp
1. Webhook → Nodo Function: normaliza payload.
2. Consulta Supabase (`profiles`): determina rol.
3. Switch: `owner` vs `lead`.
4. Enrutamiento hacia sub-workflows.

### 5.2. Sub-workflow Modo Comandante
- **NLU Owner Prompt:** Envia a Gemini prompt con contexto y base de conocimiento relevante.
- **Parser de Intenciones:** Nodo Function parsea JSON estructurado (ej. `{intent:"list_calendar", parameters:{date:"2024-06-12"}}`).
- **Switch Intenciones:**
  - `list_calendar` → Google Calendar (List events).
  - `create_event` → Validación + Inserción Google Calendar + Supabase `appointments` (status `confirmed`).
  - `cancel_event` → Cancel Google Event + Update `appointments`.
  - `update_kb` → Upsert en `knowledge_base`.
  - `inventory_update` → RPC Supabase.
  - `reporting_query` → Query a view `owner_dashboard_metrics`.
- **Respuesta:** Formatear output y enviar por WhatsApp.

### 5.3. Sub-workflow Modo Asistente
- **NLU Cliente Prompt:** Gemini retorna intención en JSON (ej. `book_service`, `faq`, `recommendation`).
- **Book Service:**
  1. Obtener servicio y preferencias (fecha, hora, profesional).
  2. Consultar `get_available_slots` + Google Calendar.
  3. Confirmar con el cliente (botones o quick replies).
  4. Crear evento en Google Calendar + registro en `appointments` (status `pending/confirmed`).
  5. Enviar recordatorio automático (sub-workflow programado).
- **FAQ:**
  - Consultar `knowledge_base` (Busqueda semántica opcional con pgvector).
  - Responder con tono profesional.
- **Sales Assist:**
  1. Identificar servicio gatillador.
  2. Consultar `cross_sell_rules` + verificar inventario.
  3. Generar mensaje consultivo (Gemini) y enviar.

### 5.4. Workflow Optimizador "Tetris"
- Trigger: `on_appointment_cancelled` (Supabase Realtime) o n8n cron que revisa `notifications_queue`.
- Pasos:
  1. Leer lista de espera ordenada por prioridad (`waitlists`).
  2. Verificar disponibilidad del hueco (Google Calendar).
  3. Enviar mensaje proactivo al primer cliente (WhatsApp template message).
  4. Si acepta → crear/actualizar cita. Si rechaza → notificar siguiente en la lista.

## 6. Prompting y Personalidad
- Mantener prompts versionados en Supabase `prompts` con campos `role`, `language`, `persona`.
- Prompt base (owner): enfatizar eficiencia, reportes claros, confirmación de acciones.
- Prompt base (cliente): tono cálido, experto en estética, enfocado en cerrar la cita y upsell.
- Utilizar formato JSON estructurado en salidas para facilidad de parsing.

## 7. Seguridad y Cumplimiento
- Almacenar tokens de APIs en Supabase Vault o variables seguras en n8n.
- Limitar accesos con RLS (Row Level Security) en Supabase según rol.
- Auditar todos los comandos críticos en `audit_logs`.
- Cumplir con la política de opt-in de WhatsApp Business y GDPR (consentimiento y derecho al olvido).

## 8. Despliegue y Observabilidad
- n8n en VPS con SSL (Traefik/Nginx) y backups automáticos.
- Supabase gestionado (backups automáticos, monitoreo).
- Logging centralizado (n8n log streaming a Loki/CloudWatch).
- Alertas para fallos de flujos críticos (citas, inventario).
- Métricas de WhatsApp (tiempo de respuesta, tasa de conversión) y Supabase dashboards.

## 9. Roadmap Futuro
1. Integrar pagos y depósitos (Stripe/ Mercado Pago).
2. Soporte multicanal (Instagram DM, Webchat) reutilizando la misma capa de orquestación.
3. Aprendizaje continuo del bot (feedback loop de conversaciones con etiquetas).
4. Expansión a otros verticales con esquema multi-tenant (añadir `business_id` en tablas).

