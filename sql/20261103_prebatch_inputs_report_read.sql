-- Read-only input history for daily closing reports. No write grants.
create policy pb_inputs_report_read on public.glur_prebatch_batch_inputs
for select to authenticated using (
 (select auth.uid()) is not null and exists (
  select 1 from public.glur_prebatch_batches b
  where b.id = glur_prebatch_batch_inputs.batch_id
  and (public.glur_has_permission(b.shop_id,'reports_view') or public.glur_is_developer(b.shop_id))
  and (b.shop_id <> 'e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af'::uuid or public.glur_is_developer(b.shop_id))
 )
);
grant select on public.glur_prebatch_batch_inputs to authenticated;