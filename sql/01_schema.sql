-- Divine Aiders Cashloan CC - schema, RLS, storage, access-code flow
create extension if not exists pgcrypto with schema extensions;
create schema if not exists app;            -- private (NOT exposed via Data API)
revoke all on schema app from public, anon;
grant usage on schema app to authenticated, anon;

-- ---------- tables ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'client' check (role in ('staff','client')),
  full_name text not null default '',
  phone text,
  email text,
  status text not null default 'active' check (status in ('active','blocked','closed')),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.applications (
  id uuid primary key default gen_random_uuid(),
  applicant_name text not null check (length(applicant_name) between 2 and 120),
  id_number text not null check (length(id_number) between 5 and 30),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text not null check (length(phone) between 6 and 20),
  employer text check (length(employer) <= 120),
  amount_requested numeric(12,2) not null check (amount_requested between 100 and 100000),
  term_months int not null check (term_months between 1 and 24),
  interest_rate numeric(5,4) not null default 0.30 check (interest_rate = 0.30),
  total_repayable numeric(12,2) generated always as (round(amount_requested * 1.30, 2)) stored,
  monthly_installment numeric(12,2) generated always as (round(amount_requested * 1.30 / term_months, 2)) stored,
  consent boolean not null check (consent),
  status text not null default 'pending' check (status in ('pending','approved','declined')),
  staff_notes text,
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  doc_type text not null check (doc_type in ('id_copy','payslip','bank_statement_1','bank_statement_2','bank_statement_3')),
  storage_path text not null,
  uploaded_at timestamptz not null default now(),
  unique (application_id, doc_type),
  check (storage_path like application_id::text || '/%')
);

create table public.loans (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.profiles(id),
  application_id uuid unique references public.applications(id),
  principal numeric(12,2) not null check (principal > 0),
  total numeric(12,2) not null check (total >= principal),
  balance numeric(12,2) not null check (balance >= 0),
  term_months int,
  monthly_installment numeric(12,2),
  status text not null default 'active' check (status in ('active','paid','closed')),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null references public.loans(id),
  amount numeric(12,2) not null check (amount > 0),
  paid_on date not null default current_date,
  method text not null default 'cash' check (method in ('cash','bank_transfer','debit_order','mobile','online','other')),
  reference text,
  recorded_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.closure_requests (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id),
  loan_id uuid not null references public.loans(id),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  note text,
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  created_at timestamptz not null default now()
);

create table app.access_codes (
  application_id uuid primary key references public.applications(id) on delete cascade,
  email text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  failed_attempts int not null default 0,
  used_at timestamptz,
  used_by uuid references auth.users(id)
);
revoke all on app.access_codes from public, anon, authenticated;

create index on public.documents(application_id);
create index on public.loans(client_id);
create index on public.payments(loan_id);
create index on public.payments(recorded_by);
create index on public.closure_requests(loan_id);
create index on public.closure_requests(client_id);
create index on public.applications(decided_by);
create index on public.closure_requests(decided_by);
create index on app.access_codes(used_by);

-- ---------- helper functions (private schema) ----------
create or replace function app.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role='staff' and p.status='active');
$$;
create or replace function app.is_active_client() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role='client' and p.status='active');
$$;
-- an application can receive document uploads only while pending and within 2 hours of creation
create or replace function app.application_open(app_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.applications a where a.id = app_id and a.status='pending' and a.created_at > now() - interval '2 hours');
$$;
create or replace function app.safe_uuid(t text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin return t::uuid; exception when others then return null; end $$;
revoke all on all functions in schema app from public;
grant execute on function app.is_staff(), app.is_active_client() to authenticated;
grant execute on function app.application_open(uuid), app.safe_uuid(text) to anon, authenticated;

-- ---------- triggers ----------
create or replace function app.touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
create trigger applications_touch before update on public.applications for each row execute function app.touch_updated_at();

-- payments reduce balance; balance can't go negative (check constraint); auto mark paid
create or replace function app.apply_payment() returns trigger language plpgsql security definer set search_path = '' as $$
declare l public.loans;
begin
  select * into l from public.loans where id = new.loan_id for update;
  if l.status <> 'active' then raise exception 'Loan is not active (status %)', l.status; end if;
  if new.amount > l.balance then raise exception 'Payment N$% exceeds outstanding balance N$%', new.amount, l.balance; end if;
  update public.loans set balance = balance - new.amount,
         status = case when balance - new.amount = 0 then 'paid' else status end
   where id = new.loan_id;
  return new;
end $$;
create trigger payments_apply after insert on public.payments for each row execute function app.apply_payment();

-- payments are append-only (corrections = staff deletes & re-records, which restores balance)
create or replace function app.revert_payment() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.loans set balance = balance + old.amount,
         status = case when status='paid' then 'active' else status end
   where id = old.loan_id;
  return old;
end $$;
create trigger payments_revert after delete on public.payments for each row execute function app.revert_payment();

-- closure: approve only when balance = 0 (enforced in DB)
create or replace function app.check_closure() returns trigger language plpgsql security definer set search_path = '' as $$
declare bal numeric;
begin
  select balance into bal from public.loans where id = new.loan_id;
  if tg_op = 'INSERT' then
    if exists (select 1 from public.closure_requests where loan_id=new.loan_id and status='pending') then
      raise exception 'A closure request for this loan is already pending';
    end if;
    new.status := 'pending'; new.decided_by := null; new.decided_at := null;
    return new;
  end if;
  if new.status = 'approved' and old.status <> 'approved' then
    if bal is null or bal > 0 then
      raise exception 'Cannot approve closure: loan balance is N$% (must be 0)', coalesce(bal,0);
    end if;
    update public.loans set status='closed', closed_at=now() where id=new.loan_id;
  end if;
  if new.status <> old.status then new.decided_by := auth.uid(); new.decided_at := now(); end if;
  return new;
end $$;
create trigger closure_check before insert or update on public.closure_requests for each row execute function app.check_closure();
alter table public.closure_requests add constraint closure_one_pending exclude using btree (loan_id with =) where (status='pending');

-- ---------- RLS ----------
alter table public.profiles enable row level security;
alter table public.applications enable row level security;
alter table public.documents enable row level security;
alter table public.loans enable row level security;
alter table public.payments enable row level security;
alter table public.closure_requests enable row level security;
alter table app.access_codes enable row level security;  -- no policies: only definer functions touch it

-- table privileges: anon gets only column-limited INSERT
revoke all on public.profiles, public.applications, public.documents, public.loans, public.payments, public.closure_requests from anon;
grant insert (id, applicant_name, id_number, email, phone, employer, amount_requested, term_months, consent) on public.applications to anon;
grant insert (application_id, doc_type, storage_path) on public.documents to anon;

-- staff: full access
create policy staff_all on public.profiles for all to authenticated using ((select app.is_staff())) with check ((select app.is_staff()));
create policy staff_all on public.applications for all to authenticated using ((select app.is_staff())) with check ((select app.is_staff()));
create policy staff_all on public.documents for all to authenticated using ((select app.is_staff())) with check ((select app.is_staff()));
create policy staff_all on public.loans for all to authenticated using ((select app.is_staff())) with check ((select app.is_staff()));
create policy staff_all on public.payments for all to authenticated using ((select app.is_staff())) with check ((select app.is_staff()));
create policy staff_all on public.closure_requests for all to authenticated using ((select app.is_staff())) with check ((select app.is_staff()));

-- public applicants: insert only, forced pending/no staff fields
create policy public_apply on public.applications for insert to anon, authenticated
  with check (status='pending' and staff_notes is null and decided_by is null and consent);
create policy public_docs on public.documents for insert to anon, authenticated
  with check ((select app.application_open(application_id)));

-- clients: own rows only, and only while active
create policy client_own_profile on public.profiles for select to authenticated
  using (id = (select auth.uid()) and status = 'active');
create policy client_own_loans on public.loans for select to authenticated
  using (client_id = (select auth.uid()) and (select app.is_active_client()));
create policy client_own_payments on public.payments for select to authenticated
  using ((select app.is_active_client()) and exists (select 1 from public.loans l where l.id = loan_id and l.client_id = (select auth.uid())));
create policy client_own_closures on public.closure_requests for select to authenticated
  using (client_id = (select auth.uid()) and (select app.is_active_client()));
create policy client_request_closure on public.closure_requests for insert to authenticated
  with check (client_id = (select auth.uid()) and status='pending' and (select app.is_active_client())
              and exists (select 1 from public.loans l where l.id = loan_id and l.client_id = (select auth.uid())));

-- ---------- storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('applicant-docs','applicant-docs', false, 5242880, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

create policy "applicant upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id='applicant-docs' and (select app.application_open(app.safe_uuid((storage.foldername(name))[1]))));
create policy "staff read docs" on storage.objects for select to authenticated
  using (bucket_id='applicant-docs' and (select app.is_staff()));
create policy "staff delete docs" on storage.objects for delete to authenticated
  using (bucket_id='applicant-docs' and (select app.is_staff()));

-- ---------- access-code flow (RPCs) ----------
create or replace function app.new_code() returns text language plpgsql volatile set search_path = '' as $$
declare alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea := extensions.gen_random_bytes(10); r text := ''; i int;
begin
  for i in 0..9 loop r := r || substr(alphabet, (get_byte(b,i) % 32) + 1, 1); end loop;
  return substr(r,1,5) || '-' || substr(r,6,5);
end $$;

create or replace function public.approve_application(p_application_id uuid, p_notes text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare a public.applications; code text;
begin
  if not app.is_staff() then raise exception 'Staff only' using errcode='42501'; end if;
  select * into a from public.applications where id = p_application_id for update;
  if not found then raise exception 'Application not found'; end if;
  if a.status = 'declined' then raise exception 'Application was declined'; end if;
  update public.applications set status='approved', decided_by=auth.uid(), decided_at=now(),
         staff_notes = coalesce(p_notes, staff_notes) where id = a.id;
  insert into public.loans (application_id, principal, total, balance, term_months, monthly_installment)
  values (a.id, a.amount_requested, a.total_repayable, a.total_repayable, a.term_months, a.monthly_installment)
  on conflict (application_id) do nothing;
  code := app.new_code();
  insert into app.access_codes (application_id, email, code_hash, expires_at)
  values (a.id, lower(a.email), extensions.crypt(code, extensions.gen_salt('bf')), now() + interval '14 days')
  on conflict (application_id) do update set code_hash=excluded.code_hash, expires_at=excluded.expires_at,
     failed_attempts=0, email=excluded.email
     where app.access_codes.used_at is null;
  if exists (select 1 from app.access_codes where application_id=a.id and used_at is not null) then
    raise exception 'Client account already activated for this application';
  end if;
  return code;  -- shown ONCE to staff; only the bcrypt hash is stored
end $$;

create or replace function public.decline_application(p_application_id uuid, p_notes text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app.is_staff() then raise exception 'Staff only' using errcode='42501'; end if;
  update public.applications set status='declined', decided_by=auth.uid(), decided_at=now(),
         staff_notes=coalesce(p_notes, staff_notes) where id=p_application_id and status='pending';
  if not found then raise exception 'Only pending applications can be declined'; end if;
end $$;

-- staff adds a client directly (walk-in): creates an approved application + loan + access code
create or replace function public.staff_add_client(p_name text, p_id_number text, p_email text, p_phone text,
  p_amount numeric, p_months int, p_employer text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare new_id uuid;
begin
  if not app.is_staff() then raise exception 'Staff only' using errcode='42501'; end if;
  insert into public.applications (applicant_name,id_number,email,phone,employer,amount_requested,term_months,consent,staff_notes)
  values (p_name,p_id_number,p_email,p_phone,p_employer,p_amount,p_months,true,'Added by staff (walk-in)') returning id into new_id;
  return public.approve_application(new_id);
end $$;

-- client redeems the access code after signing up with the SAME email
create or replace function public.redeem_access_code(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); uemail text; c app.access_codes; a public.applications; ok boolean := false; loan uuid;
begin
  if uid is null then raise exception 'Sign in first' using errcode='42501'; end if;
  select lower(email) into uemail from auth.users where id = uid;
  for c in select * from app.access_codes where email = uemail and used_at is null and expires_at > now() and failed_attempts < 5 for update loop
    if c.code_hash = extensions.crypt(upper(trim(p_code)), c.code_hash) then ok := true; exit; end if;
  end loop;
  if not ok then
    update app.access_codes set failed_attempts = failed_attempts + 1 where email = uemail and used_at is null;
    raise exception 'Invalid or expired access code' using errcode='42501';
  end if;
  select * into a from public.applications where id = c.application_id;
  insert into public.profiles (id, role, full_name, phone, email, status)
  values (uid, 'client', a.applicant_name, a.phone, uemail, 'active')
  on conflict (id) do nothing;
  if exists (select 1 from public.profiles where id=uid and role='staff') then raise exception 'Staff accounts cannot redeem client codes'; end if;
  update public.loans set client_id = uid where application_id = a.id returning id into loan;
  update app.access_codes set used_at = now(), used_by = uid where application_id = a.id;
  return loan;
end $$;

revoke all on function public.approve_application(uuid,text), public.decline_application(uuid,text),
  public.staff_add_client(text,text,text,text,numeric,int,text), public.redeem_access_code(text) from public, anon;
grant execute on function public.approve_application(uuid,text), public.decline_application(uuid,text),
  public.staff_add_client(text,text,text,text,numeric,int,text), public.redeem_access_code(text) to authenticated;
revoke all on function app.new_code() from public;
