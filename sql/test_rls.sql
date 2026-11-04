create temp table t(n serial, test text, result text);
grant all on t to anon, authenticated; grant usage on sequence t_n_seq to anon, authenticated;
do $$
declare staff uuid := '00000000-0000-0000-0000-0000000000a1'; cli uuid := '00000000-0000-0000-0000-0000000000c1';
        other uuid := '00000000-0000-0000-0000-0000000000c2'; app1 uuid := gen_random_uuid(); code text; loan uuid; cnt int; r text;
begin
  insert into auth.users(id, email, aud, role) values (staff,'staff@test.local','authenticated','authenticated'),
    (cli,'client@test.local','authenticated','authenticated'),(other,'other@test.local','authenticated','authenticated');
  insert into public.profiles(id, role, full_name, email) values (staff,'staff','Test Staff','staff@test.local');

  -- ANON
  perform set_config('role','anon',true); perform set_config('request.jwt.claims','{"role":"anon"}',true);
  insert into public.applications(id,applicant_name,id_number,email,phone,amount_requested,term_months,consent)
    values (app1,'Test Client','90010100123','client@test.local','0811234567',1000,4,true);
  insert into t(test,result) values ('anon insert application','OK');
  insert into public.documents(application_id,doc_type,storage_path) values (app1,'id_copy',app1||'/id_copy.pdf');
  insert into t(test,result) values ('anon insert document row','OK');
  begin select count(*) into cnt from public.applications; insert into t(test,result) values ('anon select applications','rows='||cnt);
  exception when others then insert into t(test,result) values ('anon select applications','DENIED: '||sqlerrm); end;
  begin select count(*) into cnt from public.documents; insert into t(test,result) values ('anon select documents','rows='||cnt);
  exception when others then insert into t(test,result) values ('anon select documents','DENIED: '||sqlerrm); end;
  begin select count(*) into cnt from public.loans; insert into t(test,result) values ('anon select loans','rows='||cnt);
  exception when others then insert into t(test,result) values ('anon select loans','DENIED: '||sqlerrm); end;
  begin select count(*) into cnt from storage.objects where bucket_id='applicant-docs'; insert into t(test,result) values ('anon select storage objects','rows='||cnt);
  exception when others then insert into t(test,result) values ('anon select storage objects','DENIED: '||sqlerrm); end;
  begin insert into public.applications(applicant_name,id_number,email,phone,amount_requested,term_months,consent,status)
    values ('X','1234567','x@x.io','0811111111',500,2,true,'approved'); insert into t(test,result) values ('anon insert approved app','ALLOWED (bad)');
  exception when others then insert into t(test,result) values ('anon insert pre-approved app','DENIED: '||sqlerrm); end;
  begin perform public.approve_application(app1); insert into t(test,result) values ('anon approve','ALLOWED (bad)');
  exception when others then insert into t(test,result) values ('anon call approve_application','DENIED: '||sqlerrm); end;

  -- OTHER authenticated user with no profile tries to approve
  perform set_config('role','authenticated',true); perform set_config('request.jwt.claims',json_build_object('sub',other,'role','authenticated')::text,true);
  begin perform public.approve_application(app1); insert into t(test,result) values ('non-staff approve','ALLOWED (bad)');
  exception when others then insert into t(test,result) values ('non-staff approve','DENIED: '||sqlerrm); end;
  select count(*) into cnt from public.applications; insert into t(test,result) values ('no-profile user select applications','rows='||cnt);

  -- STAFF
  perform set_config('request.jwt.claims',json_build_object('sub',staff,'role','authenticated')::text,true);
  select count(*) into cnt from public.applications; insert into t(test,result) values ('staff select applications','rows='||cnt);
  select total_repayable||' / '||monthly_installment into r from public.applications where id=app1; insert into t(test,result) values ('calc 1000 x 4m (total/monthly)',r);
  code := public.approve_application(app1, 'ok'); insert into t(test,result) values ('staff approve -> access code', 'format '||(code ~ '^[A-Z2-9]{5}-[A-Z2-9]{5}$'));
  select id into loan from public.loans where application_id=app1;
  insert into public.payments(loan_id,amount,method) values (loan,300,'cash');
  select balance::text into r from public.loans where id=loan; insert into t(test,result) values ('balance after N$300 payment',r);
  begin insert into public.payments(loan_id,amount) values (loan,5000); insert into t(test,result) values ('overpayment','ALLOWED (bad)');
  exception when others then insert into t(test,result) values ('overpayment','DENIED: '||sqlerrm); end;

  -- CLIENT redeem
  perform set_config('request.jwt.claims',json_build_object('sub',other,'role','authenticated')::text,true);
  begin perform public.redeem_access_code(code); insert into t(test,result) values ('wrong-email redeem','ALLOWED (bad)');
  exception when others then insert into t(test,result) values ('redeem with different email','DENIED: '||sqlerrm); end;
  perform set_config('request.jwt.claims',json_build_object('sub',cli,'role','authenticated')::text,true);
  begin perform public.redeem_access_code('AAAAA-AAAAA'); exception when others then insert into t(test,result) values ('redeem wrong code','DENIED: '||sqlerrm); end;
  perform public.redeem_access_code(code); insert into t(test,result) values ('client redeem correct code','OK');
  select count(*) into cnt from public.loans; insert into t(test,result) values ('client sees loans','rows='||cnt);
  select count(*) into cnt from public.payments; insert into t(test,result) values ('client sees payments','rows='||cnt);
  select count(*) into cnt from public.applications; insert into t(test,result) values ('client select applications','rows='||cnt);
  select count(*) into cnt from public.profiles; insert into t(test,result) values ('client sees profiles','rows='||cnt);
  begin update public.loans set balance=0 where id=loan; get diagnostics cnt = row_count; insert into t(test,result) values ('client update own balance','rows changed='||cnt);
  exception when others then insert into t(test,result) values ('client update own balance','DENIED: '||sqlerrm); end;
  insert into public.closure_requests(client_id,loan_id) values (cli,loan); insert into t(test,result) values ('client create closure request','OK');
  begin perform public.redeem_access_code(code); exception when others then insert into t(test,result) values ('reuse code','DENIED: '||sqlerrm); end;

  -- STAFF closure approval with balance > 0
  perform set_config('request.jwt.claims',json_build_object('sub',staff,'role','authenticated')::text,true);
  begin update public.closure_requests set status='approved' where loan_id=loan; insert into t(test,result) values ('approve closure bal>0','ALLOWED (bad)');
  exception when others then insert into t(test,result) values ('staff approve closure, balance>0','DENIED: '||sqlerrm); end;
  insert into public.payments(loan_id,amount,method) values (loan,1000,'bank_transfer');
  select status||' bal='||balance into r from public.loans where id=loan; insert into t(test,result) values ('after full payment',r);
  update public.closure_requests set status='approved' where loan_id=loan;
  select status into r from public.loans where id=loan; insert into t(test,result) values ('staff approve closure, balance=0 -> loan', r);
  update public.profiles set status='blocked' where id=cli;

  -- BLOCKED client
  perform set_config('request.jwt.claims',json_build_object('sub',cli,'role','authenticated')::text,true);
  select (select count(*) from public.loans)||'/'||(select count(*) from public.payments)||'/'||(select count(*) from public.profiles)||'/'||(select count(*) from public.closure_requests) into r;
  insert into t(test,result) values ('blocked client loans/payments/profiles/closures', r);
  perform set_config('role','postgres',true);
end $$;
select test, result from t order by n;
