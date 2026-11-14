-- FormFix AI: Supabase setup. Paste into Supabase > SQL Editor > Run (once).

create extension if not exists pgcrypto;

-- 1. Admin allow-list. RLS on, no policies: the API can never read this table.
create table if not exists public.admins (email text primary key);
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.admins
                 where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;
grant execute on function public.is_admin() to anon, authenticated;

-- 2. Approved exercises (shown in every user's workout selector)
create table if not exists public.exercises (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  muscles text[] not null default '{}',
  camera_angle text,
  notes text,
  source_submission uuid unique,
  created_at timestamptz not null default now()
);
create unique index if not exists exercises_name_key on public.exercises (lower(name));

-- 3. User submissions (bug reports and exercise requests)
create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('bug', 'exercise')),
  title text not null check (char_length(title) between 1 and 120),
  body text check (char_length(body) <= 4000),
  severity text,
  context text check (char_length(context) <= 500),
  muscles text[],
  camera_angle text,
  notes text check (char_length(notes) <= 2000),
  status text not null default 'new' check (status in ('new', 'approved', 'resolved', 'declined')),
  created_at timestamptz not null default now()
);

-- 4. Row Level Security
alter table public.exercises   enable row level security;
alter table public.submissions enable row level security;

-- Everyone can read the exercise list; only admins can change it.
create policy "anyone reads exercises" on public.exercises
  for select to anon, authenticated using (true);
create policy "admin writes exercises" on public.exercises
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Everyone can submit (always as status 'new'); only admins can read or change submissions.
create policy "anyone submits" on public.submissions
  for insert to anon, authenticated with check (status = 'new');
create policy "admin reads submissions" on public.submissions
  for select to authenticated using (public.is_admin());
create policy "admin updates submissions" on public.submissions
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin deletes submissions" on public.submissions
  for delete to authenticated using (public.is_admin());

-- 5. Let a user see the status of their OWN submissions (they hold the unguessable ids).
create or replace function public.get_my_submissions(ids uuid[])
returns table (id uuid, type text, title text, status text, created_at timestamptz)
language sql security definer set search_path = public stable as $$
  select s.id, s.type, s.title, s.status, s.created_at
  from public.submissions s where s.id = any(ids) limit 100;
$$;
grant execute on function public.get_my_submissions(uuid[]) to anon, authenticated;

-- 6. Realtime
alter publication supabase_realtime add table public.exercises, public.submissions;

-- 7. Make yourself an admin AFTER creating your user in Authentication > Users:
-- insert into public.admins (email) values ('you@example.com');
-- Also: Authentication > Providers > Email > turn OFF "Allow new users to sign up".
