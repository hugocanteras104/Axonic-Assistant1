-- Ensure required extensions are available for UUID generation.
create extension if not exists pgcrypto;

-- Base knowledge base table definition. The unique constraint is declared
-- separately so that the migration can be reapplied safely.
create table if not exists public.knowledge_base (
    id uuid primary key default gen_random_uuid(),
    question text not null,
    answer text not null,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- Normalize questions to avoid duplicates caused by casing/whitespace
-- differences and enforce uniqueness on the normalized value.
alter table public.knowledge_base
    add column if not exists question_normalized text
        generated always as (trim(lower(question))) stored;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.knowledge_base'::regclass
          and conname = 'knowledge_base_question_key'
    ) then
        alter table public.knowledge_base
            add constraint knowledge_base_question_key
                unique (question_normalized);
    end if;
end;
$$;
