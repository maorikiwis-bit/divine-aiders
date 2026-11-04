-- Move SECURITY DEFINER logic out of the exposed schema; expose thin SECURITY INVOKER wrappers.
alter function public.approve_application(uuid,text) set schema app;
alter function public.decline_application(uuid,text) set schema app;
alter function public.staff_add_client(text,text,text,text,numeric,int,text) set schema app;
alter function public.redeem_access_code(text) set schema app;
grant execute on function app.approve_application(uuid,text), app.decline_application(uuid,text),
  app.staff_add_client(text,text,text,text,numeric,int,text), app.redeem_access_code(text) to authenticated;

create function public.approve_application(p_application_id uuid, p_notes text default null) returns text
language sql security invoker set search_path = '' as $$ select app.approve_application(p_application_id, p_notes) $$;
create function public.decline_application(p_application_id uuid, p_notes text default null) returns void
language sql security invoker set search_path = '' as $$ select app.decline_application(p_application_id, p_notes) $$;
create function public.staff_add_client(p_name text, p_id_number text, p_email text, p_phone text,
  p_amount numeric, p_months int, p_employer text default null) returns text
language sql security invoker set search_path = '' as $$ select app.staff_add_client(p_name,p_id_number,p_email,p_phone,p_amount,p_months,p_employer) $$;
create function public.redeem_access_code(p_code text) returns uuid
language sql security invoker set search_path = '' as $$ select app.redeem_access_code(p_code) $$;
revoke all on function public.approve_application(uuid,text), public.decline_application(uuid,text),
  public.staff_add_client(text,text,text,text,numeric,int,text), public.redeem_access_code(text) from public, anon;
grant execute on function public.approve_application(uuid,text), public.decline_application(uuid,text),
  public.staff_add_client(text,text,text,text,numeric,int,text), public.redeem_access_code(text) to authenticated;

-- explicit deny-all policy: access codes are only touched by definer functions
create policy no_direct_access on app.access_codes for all to authenticated, anon using (false) with check (false);
