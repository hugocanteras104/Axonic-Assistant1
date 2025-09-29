-- Axonic Assistant Supabase Schema
-- This script provisions the database objects required by the MVP described in docs/architecture.md.

-- Enable extensions used for UUID generation and advanced features.
create extension if not exists "pgcrypto";
create extension if not exists "uuid-ossp";

-- Enumerated types ---------------------------------------------------------
create type public.user_role as enum ('owner', 'lead');
create type public.appointment_status as enum ('pending', 'confirmed', 'cancelled');
create type public.waitlist_status as enum ('active', 'notified', 'converted');

-- Helper function to automatically manage updated_at columns ---------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := timezone('utc', now());
  return new;
end;
$$;

-- Core tables ---------------------------------------------------------------
create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  phone_number text not null unique,
  role public.user_role not null default 'lead',
  name text,
  email text,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create trigger set_updated_at_profiles
before update on public.profiles
for each row execute function public.set_updated_at();

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  last_intent text,
  last_message text,
  channel text default 'whatsapp',
  updated_at timestamptz not null default timezone('utc', now())
);

create trigger set_updated_at_conversations
before update on public.conversations
for each row execute function public.set_updated_at();

create table public.services (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  base_price numeric(10,2) not null,
  duration_minutes integer not null check (duration_minutes > 0),
  metadata jsonb default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create trigger set_updated_at_services
before update on public.services
for each row execute function public.set_updated_at();

create table public.appointments (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  calendar_event_id text,
  status public.appointment_status not null default 'pending',
  start_time timestamptz not null,
  end_time timestamptz not null,
  notes text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint appointments_time_check check (end_time > start_time)
);

create index appointments_profile_idx on public.appointments(profile_id);
create index appointments_service_idx on public.appointments(service_id);
create index appointments_time_range_idx on public.appointments using gist (tstzrange(start_time, end_time));

create trigger set_updated_at_appointments
before update on public.appointments
for each row execute function public.set_updated_at();

create table public.knowledge_base (
  id uuid primary key default gen_random_uuid(),
  category text,
  question text not null,
  answer text not null,
  last_modified_by uuid references public.profiles(id) on delete set null,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create trigger set_updated_at_knowledge_base
before update on public.knowledge_base
for each row execute function public.set_updated_at();

create table public.inventory (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  name text not null,
  quantity integer not null default 0,
  reorder_threshold integer not null default 0,
  price numeric(10,2),
  metadata jsonb default '{}'::jsonb,
  updated_at timestamptz not null default timezone('utc', now())
);

create trigger set_updated_at_inventory
before update on public.inventory
for each row execute function public.set_updated_at();

create table public.cross_sell_rules (
  id uuid primary key default gen_random_uuid(),
  trigger_service_id uuid not null references public.services(id) on delete cascade,
  recommended_service_id uuid references public.services(id) on delete set null,
  message_template text not null,
  priority integer not null default 100,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now())
);

create index cross_sell_trigger_idx on public.cross_sell_rules(trigger_service_id, priority);

create table public.waitlists (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  desired_date date not null,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  status public.waitlist_status not null default 'active',
  notes text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create unique index waitlists_unique_idx on public.waitlists(service_id, desired_date, profile_id);

create trigger set_updated_at_waitlists
before update on public.waitlists
for each row execute function public.set_updated_at();

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete set null,
  action text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now())
);

create table public.prompts (
  id uuid primary key default gen_random_uuid(),
  role public.user_role not null,
  language text not null default 'es',
  persona text not null,
  content text not null,
  version integer not null default 1,
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now())
);

create table public.notifications_queue (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  profile_id uuid references public.profiles(id) on delete set null,
  event text not null,
  payload jsonb not null default '{}'::jsonb,
  processed_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);

-- Inventory management RPC --------------------------------------------------
create or replace function public.decrement_inventory(p_sku text, p_quantity integer)
returns public.inventory
language plpgsql
as $$
declare
  v_row public.inventory;
begin
  if p_quantity <= 0 then
    raise exception 'Quantity must be positive';
  end if;

  update public.inventory
     set quantity = quantity - p_quantity,
         updated_at = timezone('utc', now())
   where sku = p_sku
     and quantity >= p_quantity
  returning * into v_row;

  if not found then
    raise exception 'Insufficient stock for SKU %', p_sku;
  end if;

  return v_row;
end;
$$;

-- Availability RPC ----------------------------------------------------------
create or replace function public.get_available_slots(
  p_service_id uuid,
  p_start timestamptz,
  p_end timestamptz,
  p_interval_minutes integer default 15
)
returns table(slot_start timestamptz, slot_end timestamptz)
language plpgsql
as $$
declare
  v_duration integer;
  v_step interval;
begin
  select duration_minutes into v_duration
  from public.services
  where id = p_service_id and is_active
  limit 1;

  if not found then
    raise exception 'Service % does not exist or is inactive', p_service_id;
  end if;

  if p_start >= p_end then
    raise exception 'Start time must be before end time';
  end if;

  if p_interval_minutes <= 0 then
    raise exception 'Interval minutes must be positive';
  end if;

  v_step := make_interval(mins => p_interval_minutes);

  return query
  with candidate_slots as (
    select gs as slot_start,
           gs + make_interval(mins => v_duration) as slot_end
      from generate_series(
             date_trunc('minute', p_start),
             date_trunc('minute', p_end - make_interval(mins => v_duration)),
             v_step
           ) as gs
  )
  select c.slot_start, c.slot_end
    from candidate_slots c
   where not exists (
          select 1
            from public.appointments a
           where a.status in ('pending', 'confirmed')
             and tstzrange(a.start_time, a.end_time, '[)') &&
                 tstzrange(c.slot_start, c.slot_end, '[)')
        );
end;
$$;

-- Trigger to enqueue waitlist notifications ---------------------------------
create or replace function public.enqueue_waitlist_on_cancel()
returns trigger
language plpgsql
as $$
begin
  if (old.status in ('pending', 'confirmed')) and new.status = 'cancelled' then
    insert into public.notifications_queue (appointment_id, service_id, profile_id, event, payload)
    values (new.id, new.service_id, new.profile_id, 'appointment_cancelled', jsonb_build_object('start_time', new.start_time, 'end_time', new.end_time));
  end if;
  return new;
end;
$$;

create trigger on_appointment_cancelled
after update on public.appointments
for each row execute function public.enqueue_waitlist_on_cancel();

-- Owner dashboard view ------------------------------------------------------
create or replace view public.owner_dashboard_metrics as
with daily AS (
  select date_trunc('day', a.start_time) as day,
         count(*) filter (where a.status = 'confirmed') as confirmed_appointments,
         count(*) filter (where a.status = 'pending') as pending_appointments,
         sum(case when a.status in ('confirmed', 'pending') then coalesce(s.base_price, 0) else 0 end) as estimated_revenue
    from public.appointments a
    join public.services s on s.id = a.service_id
   group by 1
),
ranked_services as (
  select date_trunc('day', a.start_time) as day,
         s.name,
         count(*) as service_count,
         row_number() over (partition by date_trunc('day', a.start_time) order by count(*) desc, s.name asc) as rn
    from public.appointments a
    join public.services s on s.id = a.service_id
   where a.status in ('confirmed', 'pending')
   group by 1, s.name
)
select d.day,
       d.confirmed_appointments,
       d.pending_appointments,
       coalesce(d.estimated_revenue, 0) as estimated_revenue,
       rs.name as top_service,
       rs.service_count as top_service_bookings
  from daily d
  left join ranked_services rs on rs.day = d.day and rs.rn = 1
 order by d.day desc;

-- Useful indexes ------------------------------------------------------------
create index appointments_status_idx on public.appointments(status);
create index inventory_sku_quantity_idx on public.inventory(sku, quantity);
create index knowledge_base_question_idx on public.knowledge_base using gin (to_tsvector('spanish', coalesce(question, '')));
create index knowledge_base_answer_idx on public.knowledge_base using gin (to_tsvector('spanish', coalesce(answer, '')));

-- Initial seeds -------------------------------------------------------------
insert into public.profiles (phone_number, role, name)
values ('+34123456789', 'owner', 'Dueña Clínica')
on conflict (phone_number) do nothing;

insert into public.services (name, description, base_price, duration_minutes)
values
  ('Diagnóstico facial', 'Evaluación inicial con especialista.', 40.00, 30),
  ('Tratamiento vitamina C', 'Sesión revitalizante con vitamina C.', 70.00, 60),
  ('Masaje relajante', 'Masaje corporal completo.', 55.00, 50)
on conflict (name) do nothing;

insert into public.prompts (role, language, persona, content)
values
  ('owner', 'es', 'comandante', 'Eres Axonic Assistant para la dueña. Responde con precisión administrativa y confirma acciones.'),
  ('lead', 'es', 'asistente', 'Eres Axonic Assistant para clientes. Sé amable, experto en estética y guía a reservar una cita.')
on conflict do nothing;
