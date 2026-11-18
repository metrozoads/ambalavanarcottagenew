-- =====================================================================
-- Sri Ambalavanar Cottage · booking database (Supabase / Postgres)
-- Run once: Supabase > SQL Editor > New query > paste all > Run.
-- The Admin web app uses the same tables later (vacancy, walk-ins).
-- =====================================================================

-- Rooms and rates (rates include GST; change here AND in booking-config.js)
create table if not exists room_rates (
  type text primary key,            -- D = Double, T = Triple, S = Single
  ac numeric not null,
  nonac numeric not null,
  max_adults int not null
);
insert into room_rates values ('D',2100,1600,2),('T',3150,2650,3),('S',1600,1050,1)
on conflict (type) do update set ac = excluded.ac, nonac = excluded.nonac, max_adults = excluded.max_adults;

create table if not exists rooms (
  room text primary key,
  type text not null references room_rates(type),
  active boolean not null default true     -- set false to close a room (repair etc.)
);
insert into rooms (room, type)
select r, case when r in ('G1','F1') then 'T' when r = 'F13' then 'S' else 'D' end
from unnest(array['G1','G2','G3','G4','G5','G6','G7','G8','G9','G10',
                  'F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12','F13']) as r
on conflict (room) do nothing;

-- Every booking: website holds, website payments, and walk-ins from the Admin app
create table if not exists bookings (
  id bigserial primary key,
  code text unique not null,
  token uuid unique not null default gen_random_uuid(),
  room text not null references rooms(room),
  check_in date not null,
  check_out date not null check (check_out > check_in),
  status text not null default 'hold',     -- hold | paid | confirmed | cancelled
  hold_until timestamptz,
  source text not null default 'website',  -- website | walk-in | phone
  guest_name text, phone text, email text, gstin text, id_proof text, arrival text,
  ac boolean, adults int, children int, extra_beds int default 0,
  amount numeric, utr text, utr_verified boolean not null default false,
  invoice_no text unique, receipt_no text unique, paid_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists bookings_room_dates on bookings (room, check_in, check_out);

create sequence if not exists booking_code_seq;
create sequence if not exists invoice_seq;

-- Nobody reads tables directly from the website: only the functions below.
alter table room_rates enable row level security;
alter table rooms enable row level security;
alter table bookings enable row level security;
-- Logged-in staff (MD / Admin web app) can see and edit everything.
drop policy if exists staff_all_bookings on bookings;
create policy staff_all_bookings on bookings for all to authenticated using (true) with check (true);
drop policy if exists staff_all_rooms on rooms;
create policy staff_all_rooms on rooms for all to authenticated using (true) with check (true);
drop policy if exists staff_all_rates on room_rates;
create policy staff_all_rates on room_rates for all to authenticated using (true) with check (true);

-- A booking blocks a room if it is paid/confirmed, or an unexpired hold
create or replace function _blocking(b bookings) returns boolean language sql stable as $$
  select b.status in ('paid','confirmed') or (b.status = 'hold' and b.hold_until > now())
$$;

-- 1) Website: which rooms are busy for these dates (no guest data is shown)
create or replace function room_status(p_in date, p_out date)
returns table(room text, state text) language sql security definer set search_path = public as $$
  select r.room, 'booked' from rooms r where not r.active
  union all
  select b.room, case when bool_or(b.status in ('paid','confirmed')) then 'booked' else 'hold' end
  from bookings b
  where b.check_in < p_out and p_in < b.check_out and _blocking(b)
  group by b.room
$$;

-- 2) Website: lock a room for 10 minutes
create or replace function hold_room(p_room text, p_in date, p_out date)
returns json language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if p_in < (now() at time zone 'Asia/Kolkata')::date or p_out <= p_in or p_out - p_in > 30 then
    raise exception 'BAD_DATES';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_room));
  if not exists (select 1 from rooms where room = p_room and active) then raise exception 'ROOM_TAKEN'; end if;
  if exists (select 1 from bookings x where x.room = p_room and x.check_in < p_out and p_in < x.check_out and _blocking(x)) then
    raise exception 'ROOM_TAKEN';
  end if;
  insert into bookings (code, room, check_in, check_out, status, hold_until)
  values ('SAC-' || lpad(nextval('booking_code_seq')::text, 4, '0'), p_room, p_in, p_out, 'hold', now() + interval '10 minutes')
  returning * into b;
  return json_build_object('token', b.token, 'code', b.code, 'hold_until', b.hold_until);
end $$;

-- 3) Website: guest goes back / changes room
create or replace function release_hold(p_token uuid)
returns void language sql security definer set search_path = public as $$
  update bookings set status = 'cancelled' where token = p_token and status = 'hold'
$$;

-- 4) Website: guest paid and typed the UTR → booking + invoice number
create or replace function confirm_payment(p_token uuid, p_details jsonb, p_utr text)
returns json language plpgsql security definer set search_path = public as $$
declare b bookings; rate room_rates; nights int; beds int; amt numeric; fy text; d date;
begin
  select * into b from bookings where token = p_token for update;
  if not found or b.status not in ('hold') then raise exception 'NOT_FOUND'; end if;
  perform pg_advisory_xact_lock(hashtext(b.room));
  if exists (select 1 from bookings x where x.id <> b.id and x.room = b.room and x.check_in < b.check_out and b.check_in < x.check_out and _blocking(x)) then
    raise exception 'ROOM_TAKEN';
  end if;
  if p_utr !~ '^[A-Za-z0-9]{12,22}$' then raise exception 'BAD_UTR'; end if;
  select rr.* into rate from rooms r join room_rates rr on rr.type = r.type where r.room = b.room;
  nights := b.check_out - b.check_in;
  beds := least(greatest(coalesce((p_details->>'extra_beds')::int, 0), 0), 1);
  amt := ((case when coalesce((p_details->>'ac')::boolean, true) then rate.ac else rate.nonac end) + beds * 500) * nights;
  d := (now() at time zone 'Asia/Kolkata')::date;
  fy := case when extract(month from d) >= 4 then to_char(d, 'YY') || '-' || to_char(d + interval '1 year', 'YY')
             else to_char(d - interval '1 year', 'YY') || '-' || to_char(d, 'YY') end;
  update bookings set
    status = 'paid', hold_until = null, utr = p_utr, amount = amt, paid_at = now(),
    guest_name = left(p_details->>'name', 120), phone = left(p_details->>'phone', 15), email = left(p_details->>'email', 160),
    gstin = nullif(left(p_details->>'gstin', 15), ''), id_proof = left(p_details->>'id_proof', 40), arrival = left(p_details->>'arrival', 60),
    ac = coalesce((p_details->>'ac')::boolean, true), adults = (p_details->>'adults')::int, children = (p_details->>'children')::int, extra_beds = beds,
    invoice_no = 'SAC/' || fy || '/' || lpad(nextval('invoice_seq')::text, 4, '0')
  where id = b.id returning * into b;
  update bookings set receipt_no = replace(b.invoice_no, 'SAC/', 'RCP/') where id = b.id;
  return json_build_object('code', b.code, 'invoice_no', b.invoice_no, 'receipt_no', replace(b.invoice_no, 'SAC/', 'RCP/'), 'amount', b.amount, 'paid_at', b.paid_at);
end $$;

-- Only these four functions are open to the public website
revoke all on function room_status(date,date), hold_room(text,date,date), release_hold(uuid), confirm_payment(uuid,jsonb,text) from public;
grant execute on function room_status(date,date), hold_room(text,date,date), release_hold(uuid), confirm_payment(uuid,jsonb,text) to anon, authenticated;
