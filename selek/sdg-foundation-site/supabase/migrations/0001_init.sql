-- SDG Cultural and Photo Foundation: initial schema, RLS and storage
-- Run in the Supabase SQL editor, or save as supabase/migrations/0001_init.sql.
-- All money is stored in kobo (NGN x 100). Orders are created and settled by the
-- server using the service-role key; browsers can never write orders or downloads.

-- ============ ENUMS ============
create type user_role      as enum ('customer', 'admin');
create type order_status   as enum ('pending', 'paid', 'failed');
create type book_format    as enum ('hardcopy', 'pdf', 'epub');
create type gallery_cat    as enum ('tourism_books', 'traditional_attires', 'indoor', 'outdoor');
create type facility_kind  as enum ('indoor', 'outdoor');
create type booking_status as enum ('new', 'confirmed', 'declined');
create type post_status    as enum ('draft', 'published');

-- ============ PROFILES ============
create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  phone      text,
  role       user_role not null default 'customer',
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin')
$$;

create or replace function public.my_role() returns user_role
language sql security definer stable set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'));
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- ============ BOOKS ============
create table books (
  id           uuid primary key default gen_random_uuid(),
  slug         text unique not null,
  title        text not null,
  author       text not null default 'Selek Domshak Amos',
  description  text,
  cover_path   text,                         -- path in book-covers bucket
  is_published boolean not null default false,
  is_featured  boolean not null default false,
  created_at   timestamptz not null default now()
);

create table book_formats (
  id         uuid primary key default gen_random_uuid(),
  book_id    uuid not null references books(id) on delete cascade,
  format     book_format not null,
  price_kobo integer not null check (price_kobo >= 0),
  stock      integer check (stock >= 0),     -- hardcopy only; null for digital
  is_active  boolean not null default true,
  unique (book_id, format)
);

-- File paths live in their own admin-only table so they can never leak through
-- a public read of book_formats.
create table book_files (
  book_format_id uuid primary key references book_formats(id) on delete cascade,
  file_path      text not null,              -- path in PRIVATE book-files bucket
  file_size      bigint,
  uploaded_at    timestamptz not null default now()
);

-- ============ ORDERS ============
create table orders (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references profiles(id),
  paystack_reference text unique,
  amount_kobo        integer not null check (amount_kobo >= 0),
  currency           text not null default 'NGN',
  status             order_status not null default 'pending',
  payment_method     text not null default 'paystack',   -- 'paystack' | 'bank_transfer'
  payment_channel    text,
  paid_at            timestamptz,
  created_at         timestamptz not null default now()
);

create table order_items (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references orders(id) on delete cascade,
  book_format_id   uuid not null references book_formats(id),
  quantity         integer not null default 1 check (quantity > 0),
  unit_price_kobo  integer not null check (unit_price_kobo >= 0)
);

-- Download limit (5 per purchase) is enforced server-side by counting rows here.
create table downloads (
  id            uuid primary key default gen_random_uuid(),
  order_item_id uuid not null references order_items(id) on delete cascade,
  user_id       uuid not null references profiles(id),
  downloaded_at timestamptz not null default now(),
  ip_address    inet
);

-- ============ CONTENT ============
create table gallery_items (
  id           uuid primary key default gen_random_uuid(),
  category     gallery_cat not null,
  title        text,
  alt_text     text not null,
  image_path   text not null,                -- path in gallery bucket
  sort_order   integer not null default 0,
  is_published boolean not null default true,
  created_at   timestamptz not null default now()
);

create table facilities (
  id           uuid primary key default gen_random_uuid(),
  slug         text unique not null,
  name         text not null,
  kind         facility_kind not null,
  description  text,
  capacity     integer,
  rate_kobo    integer check (rate_kobo >= 0),
  image_paths  text[] not null default '{}',
  is_published boolean not null default true
);

create table testimonials (
  id           uuid primary key default gen_random_uuid(),
  author       text not null,
  role         text,
  quote        text not null,
  is_published boolean not null default false,
  created_at   timestamptz not null default now()
);

create table posts (
  id           uuid primary key default gen_random_uuid(),
  slug         text unique not null,
  title        text not null,
  excerpt      text,
  body         text,
  category     text not null default 'Culture',   -- Tourism, Culture, Photography, Education, Company Updates
  cover_path   text,
  status       post_status not null default 'draft',
  published_at timestamptz,
  created_at   timestamptz not null default now()
);

create table sales_points (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  address      text not null,
  phone        text,
  map_url      text,
  is_published boolean not null default true
);

-- ============ INBOUND FORMS ============
create table enquiries (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 120),
  phone      text not null check (char_length(phone) between 5 and 30),
  email      text check (email is null or char_length(email) <= 200),
  interests  text[] not null default '{}',
  message    text not null check (char_length(message) between 1 and 4000),
  handled    boolean not null default false,
  created_at timestamptz not null default now()
);

create table facility_bookings (
  id          uuid primary key default gen_random_uuid(),
  facility_id uuid not null references facilities(id),
  name        text not null check (char_length(name) between 1 and 120),
  phone       text not null check (char_length(phone) between 5 and 30),
  email       text check (email is null or char_length(email) <= 200),
  event_date  date not null,
  event_type  text,
  message     text check (message is null or char_length(message) <= 4000),
  status      booking_status not null default 'new',
  created_at  timestamptz not null default now()
);

create table newsletter_subscribers (
  id         uuid primary key default gen_random_uuid(),
  email      text unique not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  created_at timestamptz not null default now()
);

-- Never put secrets here: rows with is_public = true are readable by everyone.
create table site_settings (
  key       text primary key,
  value     jsonb not null,
  is_public boolean not null default true
);

-- ============ ROW LEVEL SECURITY ============
alter table profiles               enable row level security;
alter table books                  enable row level security;
alter table book_formats           enable row level security;
alter table book_files             enable row level security;
alter table orders                 enable row level security;
alter table order_items            enable row level security;
alter table downloads              enable row level security;
alter table gallery_items          enable row level security;
alter table facilities             enable row level security;
alter table testimonials           enable row level security;
alter table posts                  enable row level security;
alter table sales_points           enable row level security;
alter table enquiries              enable row level security;
alter table facility_bookings      enable row level security;
alter table newsletter_subscribers enable row level security;
alter table site_settings          enable row level security;

-- profiles: see/edit your own row; you can never change your own role
create policy "profiles read own or admin" on profiles for select using (id = auth.uid() or is_admin());
create policy "profiles update own"        on profiles for update
  using (id = auth.uid() or is_admin())
  with check ((id = auth.uid() and role = my_role()) or is_admin());

-- public catalogue: everyone reads published rows, admins do everything
create policy "books public read"        on books        for select using (is_published or is_admin());
create policy "books admin write"        on books        for all using (is_admin()) with check (is_admin());
create policy "formats public read"      on book_formats for select using (
  (is_active and exists (select 1 from books b where b.id = book_id and b.is_published)) or is_admin());
create policy "formats admin write"      on book_formats for all using (is_admin()) with check (is_admin());
create policy "book_files admin only"    on book_files   for all using (is_admin()) with check (is_admin());

create policy "gallery public read"      on gallery_items for select using (is_published or is_admin());
create policy "gallery admin write"      on gallery_items for all using (is_admin()) with check (is_admin());
create policy "facilities public read"   on facilities    for select using (is_published or is_admin());
create policy "facilities admin write"   on facilities    for all using (is_admin()) with check (is_admin());
create policy "testimonials public read" on testimonials  for select using (is_published or is_admin());
create policy "testimonials admin write" on testimonials  for all using (is_admin()) with check (is_admin());
create policy "posts public read"        on posts         for select using (status = 'published' or is_admin());
create policy "posts admin write"        on posts         for all using (is_admin()) with check (is_admin());
create policy "sales_points public read" on sales_points  for select using (is_published or is_admin());
create policy "sales_points admin write" on sales_points  for all using (is_admin()) with check (is_admin());
create policy "settings public read"     on site_settings for select using (is_public or is_admin());
create policy "settings admin write"     on site_settings for all using (is_admin()) with check (is_admin());

-- orders: customers read their own; only the server (service role) inserts; admins can update
create policy "orders read own or admin"  on orders for select using (user_id = auth.uid() or is_admin());
create policy "orders admin update"       on orders for update using (is_admin()) with check (is_admin());
create policy "items read own or admin"   on order_items for select using (
  is_admin() or exists (select 1 from orders o where o.id = order_id and o.user_id = auth.uid()));
create policy "downloads read own or admin" on downloads for select using (user_id = auth.uid() or is_admin());

-- inbound forms: anyone may submit, only admins read or manage
create policy "enquiries anyone insert"   on enquiries for insert with check (true);
create policy "enquiries admin read"      on enquiries for select using (is_admin());
create policy "enquiries admin update"    on enquiries for update using (is_admin()) with check (is_admin());
create policy "bookings anyone insert"    on facility_bookings for insert with check (status = 'new');
create policy "bookings admin read"       on facility_bookings for select using (is_admin());
create policy "bookings admin update"     on facility_bookings for update using (is_admin()) with check (is_admin());
create policy "newsletter anyone insert"  on newsletter_subscribers for insert with check (true);
create policy "newsletter admin read"     on newsletter_subscribers for select using (is_admin());

-- ============ STORAGE ============
insert into storage.buckets (id, name, public) values
  ('book-covers', 'book-covers', true),
  ('gallery',     'gallery',     true),
  ('blog-media',  'blog-media',  true),
  ('book-files',  'book-files',  false)
on conflict (id) do nothing;

create policy "public read public buckets" on storage.objects for select
  using (bucket_id in ('book-covers', 'gallery', 'blog-media'));

-- book-files has NO public read policy. Downloads use 60-second signed URLs
-- created server-side with the service-role key after ownership is checked.
create policy "admin manage buckets" on storage.objects for all to authenticated
  using (is_admin() and bucket_id in ('book-covers', 'gallery', 'blog-media', 'book-files'))
  with check (is_admin() and bucket_id in ('book-covers', 'gallery', 'blog-media', 'book-files'));

-- ============ SEED ============
insert into site_settings (key, value, is_public) values
  ('contact',  '{"email":"info@yourdomain.org","phone":"+234 000 000 0000","whatsapp":"2340000000000"}', true),
  ('address',  '{"line":"Kwata-Zawan, adjacent COCIN Church, along Vom Road, Jos-South LGA, Plateau State, Nigeria"}', true),
  ('stats',    '{"years":0,"books":0,"events":0,"communities":0}', true),
  ('bank_transfer', '{"bank":"","account_name":"SDG Cultural and Photo Foundation","account_number":""}', true)
on conflict (key) do nothing;

insert into facilities (slug, name, kind, description, capacity) values
  ('indoor-hall',    'Indoor hall',    'indoor',  'Placeholder: describe the hall, seating and equipment.', null),
  ('outdoor-grounds','Outdoor grounds','outdoor', 'Placeholder: describe the grounds and what they suit.',  null)
on conflict (slug) do nothing;

-- After you sign up on the live site, make yourself admin (replace the email):
-- update profiles set role = 'admin'
--   where id = (select id from auth.users where email = 'you@example.com');
