# Divine Aiders Cashloan CC – loan management (static site + Supabase)

Supabase project: `divine-aiders`, ref `qqgzoajzhysnjformphz`, https://qqgzoajzhysnjformphz.supabase.co (Free plan, eu-west-1)
Pages: index.html (info), apply.html (public application), client.html (client area), staff.html (staff).
Only the publishable key is in `config.js`. Never add the service_role/secret key.
SQL: `sql/01_schema.sql`, `sql/02_advisor_fixes.sql` (both applied), `sql/test_rls.sql` (role tests), `sql/test_cleanup.sql`.

## REQUIRED one-time dashboard setting
Supabase Dashboard → Authentication → Sign In / Providers → Email → turn **OFF "Confirm email"**.
Free-tier built-in email only delivers to project team members and is rate-limited, so client confirmation emails would not arrive.
Security doesn't depend on email confirmation: a signed-up account gets **no access** until it redeems a staff-issued
access code that is tied to the email address the client applied with.
Also recommended: Authentication → Attack Protection → enable leaked-password protection, and (Site URL) set to your GitHub Pages URL.

## Access-code flow
1. Staff approve an application (staff.html) → `approve_application()` creates the loan (principal, total = amount × 1.3,
   balance = total) and a 10-character code like `K7QPM-3ZRXA` (≈50 bits random). Only a bcrypt hash is stored, in the
   private `app.access_codes` table. The code is shown ONCE, with a "Copy message"/"Open WhatsApp" button.
2. Staff send the code privately (WhatsApp/SMS/in person). Valid 14 days. Need a new one? "New access code" button.
3. Client opens client.html → "Activate account" → enters the SAME email used on the application, a new password and the code.
   The page signs up with email+password, then calls `redeem_access_code()`, which checks email + code, creates the client
   profile and links the loan. Code is single-use; 5 wrong attempts lock that code (staff issue a new one).
4. After that the client just signs in with email + password.
Walk-in clients: staff "Add client" creates an approved application + loan + code in one step.

## Make the owner (or any employee) a staff user
1. Dashboard → Authentication → Users → **Add user** → "Create new user", enter the email + a strong password,
   tick "Auto Confirm User". (Or sign up on client.html "Activate" tab — it will say no client account; that's fine.)
2. Dashboard → SQL Editor, run (replace the email):
```sql
insert into public.profiles (id, role, full_name, email, status)
select id, 'staff', 'Cole Kastoor', email, 'active' from auth.users where email = 'OWNER@EXAMPLE.COM'
on conflict (id) do update set role = 'staff', status = 'active', deleted_at = null;
```
3. Sign in on staff.html. To revoke staff: `update public.profiles set status='blocked' where email='...';`

## Security model (RLS on every table)
- anon: INSERT only (column-limited) into applications and documents, and upload to the private `applicant-docs`
  bucket only into a folder named after a pending application created < 2 h ago. No read on anything. 5 MB, PDF/JPG/PNG only (enforced by the bucket).
- clients (role client, status active): read own profile, loans, payments, closure requests; create closure requests for own loans.
- blocked/closed clients: read nothing.
- staff (role staff, status active): full access; documents via 2-minute signed URLs.
- DB triggers: payments reduce balance, overpayment rejected, loan auto-"paid" at 0; deleting a payment restores the balance;
  closure approval raises an error unless balance = 0 and then closes the loan; one pending closure request per loan.
- Privileged functions live in the unexposed `app` schema; `public` only has SECURITY INVOKER wrappers.
