alter table public.receipt_lines
  drop constraint if exists receipt_lines_item_id_fkey;

alter table public.receipt_lines
  add constraint receipt_lines_item_id_fkey
  foreign key (item_id)
  references public.inventory_items(id)
  on delete cascade;
