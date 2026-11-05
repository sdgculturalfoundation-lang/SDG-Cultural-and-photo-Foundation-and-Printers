# SDG Cultural and Photo Foundation: website

Starter files for the website. The site itself is built by Claude Code from PROMPT.md.

## What is in this repo
| Path | Purpose |
|---|---|
| `PROMPT.md` | The prompt to paste into Claude Code |
| `CLAUDE.md` | Project rules Claude Code reads automatically |
| `supabase/migrations/0001_init.sql` | Database tables, access rules, storage buckets |
| `docs/home-layout.html` | Home page design reference (open in a browser) |
| `.env.example` | Names of the environment variables you need |

## Setup
1. Supabase: create a project, open the SQL editor, paste `supabase/migrations/0001_init.sql`, run it.
   Then enable Google under Authentication > Providers.
2. Copy `.env.example` to `.env.local` and fill in the Supabase URL and anon key.
3. Start Claude Code in this repo and paste the prompt from `PROMPT.md`.
4. Vercel: import this repo, add the same environment variables, deploy.
5. After signing up on the live site, make yourself admin by running this in the Supabase SQL editor
   (replace the email):
   `update profiles set role = 'admin' where id = (select id from auth.users where email = 'you@example.com');`

## Later: online book sales
The shop tables already exist. Paystack files are provided separately (paystack-addon.zip).
Add them only when you are ready to sell books online.
