-- More than one scannable code per item.
--
-- items.barcode stays the item's MAIN code (the one a sticker prints). item_barcodes holds any
-- further codes for the same item -- typically the maker's barcode printed on the product, next
-- to the clinic's own generated barcode / QR. Scanning any of them opens the same item.
--
-- Also fixes link_barcode(): it used to overwrite items.barcode, so linking a product barcode
-- to an item that already had a printed clinic code would have stopped that printed code
-- scanning. It now ADDS the scanned code instead. (The page was also passing the item's code
-- text where the item's id belongs, so no link has saved since the move to Supabase; that half
-- is fixed in index.html.)
--
-- Sterilisation (tracker = 'instruments') keeps a single code: that workflow is keyed on the
-- tray code throughout (dispatch_log), so a second code there would not be honoured.

create table item_barcodes (
  id       uuid primary key default gen_random_uuid(),
  item_id  uuid not null references items(id) on delete cascade,
  barcode  text not null check (barcode <> '' and barcode = btrim(barcode)),
  added_by uuid references profiles(id),
  added_at timestamptz not null default clock_timestamp()
);
-- one code -> one item, whichever tracker it is in: a scan can only ever open one item
create unique index item_barcodes_barcode_uq on item_barcodes (barcode);
create index item_barcodes_item_idx on item_barcodes (item_id);

-- No policies on purpose: the table is read and written only through the SECURITY DEFINER
-- functions below, each of which checks app_role_rank() itself.
alter table item_barcodes enable row level security;
revoke all on table item_barcodes from anon, authenticated;

-- Name of ANOTHER item that already answers to this code (as its barcode, its item code, or one
-- of its extra codes); null when the code is free. Internal helper.
create or replace function item_code_clash(p_code text, p_item_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select x.name from (
    select i.name from items i
     where i.id <> p_item_id and (i.barcode = p_code or i.code = p_code)
    union all
    select i.name from item_barcodes b join items i on i.id = b.item_id
     where b.barcode = p_code and b.item_id <> p_item_id
  ) x limit 1
$$;

-- ============================================================================
-- link: a scanned code -> an existing item (any active user, as before)
--   item has no barcode yet      -> becomes its main barcode        (kind 'primary')
--   already one of its codes     -> nothing to do                   (kind 'same')
--   otherwise                    -> added as an extra code          (kind 'extra')
-- ============================================================================
create or replace function link_barcode(p_item_id uuid, p_barcode text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_item  items%rowtype;
  v_code  text := btrim(coalesce(p_barcode, ''));
  v_clash text;
  v_kind  text;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if v_code = '' then
    raise exception 'No code to link';
  end if;
  if length(v_code) > 200 then
    raise exception 'That code is too long';
  end if;
  select * into v_item from items where id = p_item_id for update;
  if not found then
    raise exception 'Item not found';
  end if;

  if v_item.barcode = v_code or v_item.code = v_code
     or exists(select 1 from item_barcodes where item_id = p_item_id and barcode = v_code) then
    return jsonb_build_object('ok', true, 'kind', 'same', 'name', v_item.name);
  end if;

  v_clash := item_code_clash(v_code, p_item_id);
  if v_clash is not null then
    raise exception 'That code already belongs to "%"', v_clash;
  end if;

  if btrim(coalesce(v_item.barcode, '')) = '' then
    update items set barcode = v_code where id = p_item_id;
    v_kind := 'primary';
  elsif v_item.tracker = 'instruments' then
    raise exception 'Sterilisation items keep a single code. Edit the item to change it.';
  else
    if (select count(*) from item_barcodes where item_id = p_item_id) >= 10 then
      raise exception 'This item already has 10 extra codes';
    end if;
    insert into item_barcodes (item_id, barcode, added_by) values (p_item_id, v_code, auth.uid());
    v_kind := 'extra';
  end if;

  insert into barcode_link_events (barcode, tracker, item_id, code, linked_by)
  values (v_code, v_item.tracker, p_item_id, v_item.code, auth.uid());

  return jsonb_build_object('ok', true, 'kind', v_kind, 'name', v_item.name);
end;
$$;

-- remove one extra code from an item (admin+, the same floor as editing an item)
create or replace function item_barcode_remove(p_item_id uuid, p_barcode text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_n int;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  delete from item_barcodes where item_id = p_item_id and barcode = btrim(coalesce(p_barcode, ''));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'removed', v_n);
end;
$$;

-- every extra code, for the page's scan lookup (one jsonb value, so PostgREST's row cap can't
-- silently truncate it)
create or replace function get_item_barcodes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('item_id', b.item_id, 'barcode', b.barcode)
                                    order by b.added_at), '[]'::jsonb)
            from item_barcodes b);
end;
$$;

-- ============================================================================
-- Sticker printer -> "No barcode yet": give every listed item that has no barcode a new one
-- (superadmin+). Unlike item_bulk_generate_barcodes this NEVER replaces an existing barcode:
-- an item that already has one (e.g. someone else just gave it one) is skipped.
-- ============================================================================
create or replace function item_assign_missing_barcodes(p_item_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id      uuid;
  v_item    items%rowtype;
  v_new     text;
  v_result  jsonb := '{}'::jsonb;
  v_skipped int := 0;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if coalesce(array_length(p_item_ids, 1), 0) > 2000 then
    raise exception 'Too many items in one go';
  end if;
  foreach v_id in array coalesce(p_item_ids, '{}'::uuid[]) loop
    select * into v_item from items where id = v_id for update;
    if not found or btrim(coalesce(v_item.barcode, '')) <> '' then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    loop
      v_new := to_char(floor(random()*9000000000000+1000000000000), 'FM9999999999999');
      exit when not exists(select 1 from items where barcode = v_new or code = v_new)
            and not exists(select 1 from item_barcodes where barcode = v_new);
    end loop;
    update items set barcode = v_new where id = v_id;
    v_result := v_result || jsonb_build_object(v_id::text, v_new);
  end loop;
  return jsonb_build_object('ok', true, 'barcodes', v_result, 'skipped', v_skipped);
end;
$$;

-- ============================================================================
-- Keep the two places consistent whichever function writes items:
--   * an item's barcode / code may not be another item's extra code;
--   * if an item's own extra code becomes its barcode / code, the now-redundant extra goes.
-- ============================================================================
create or replace function items_extra_code_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_other text;
begin
  if tg_op = 'INSERT' or new.barcode is distinct from old.barcode or new.code is distinct from old.code then
    select i.name into v_other
      from item_barcodes b join items i on i.id = b.item_id
     where b.item_id <> new.id
       and b.barcode in (nullif(btrim(coalesce(new.barcode, '')), ''), nullif(btrim(coalesce(new.code, '')), ''))
     limit 1;
    if v_other is not null then
      raise exception 'That code is already a second code on "%"', v_other;
    end if;
    if tg_op = 'UPDATE' then
      delete from item_barcodes where item_id = new.id and barcode in (new.barcode, new.code);
    end if;
  end if;
  return new;
end;
$$;
create trigger items_extra_code_guard_trg
  before insert or update of barcode, code on items
  for each row execute function items_extra_code_guard();

revoke execute on function item_code_clash(text,uuid) from public, anon, authenticated;
revoke execute on function items_extra_code_guard() from public, anon, authenticated;
do $$
declare fn text;
begin
  foreach fn in array array[
    'link_barcode(uuid,text)',
    'item_barcode_remove(uuid,text)',
    'get_item_barcodes()',
    'item_assign_missing_barcodes(uuid[])'
  ]
  loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;
