-- Read-only visibility for TEST movement history, restricted to shop owner.
-- No LIVE policy changes; no modifications to stock or historical movements.
CREATE POLICY glur_test_owner_read_stock_movements
ON public.glur_stock_movements FOR SELECT TO authenticated
USING (
 shop_id='e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af'::uuid
 AND EXISTS (
   SELECT 1 FROM public.glur_members m
   WHERE m.shop_id=glur_stock_movements.shop_id
     AND m.user_id=(SELECT auth.uid())
     AND m.role='owner'
 )
);
