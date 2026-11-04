delete from public.closure_requests where client_id in (select id from auth.users where email like '%@test.local');
delete from public.payments where loan_id in (select l.id from public.loans l join public.applications a on a.id=l.application_id where a.email like '%test.local' or a.email='x@x.io');
delete from public.loans where application_id in (select id from public.applications where email like '%test.local' or email='x@x.io');
delete from public.applications where email like '%test.local' or email='x@x.io';
delete from public.profiles where email like '%@test.local';
delete from auth.users where email like '%@test.local';
