-- GLUR BAR: shared TEST/LIVE stock audit. REVIEW BEFORE APPLYING.
-- This migration intentionally remains in the development branch.
-- Both modes use the same trigger; shop_id partitions history.
-- Do not backfill inferred historical changes.
CREATE OR REPLACE FUNCTION public.glur_capture_stock_movement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_kind text;
BEGIN
  IF NEW.shop_id IS DISTINCT FROM OLD.shop_id OR NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Stock identity/shop cannot be changed';
  END IF;
  IF NEW.quantity IS NOT DISTINCT FROM OLD.quantity THEN
    RETURN NEW;
  END IF;
  v_kind := CASE
    WHEN NEW.quantity > OLD.quantity THEN 'increase'
    ELSE 'decrease'
  END;
  INSERT INTO public.glur_stock_movements
    (shop_id,stock_id,movement_type,quantity_before,quantity_change,
     quantity_after,cost_per_unit_snapshot,reason,created_by)
  VALUES
    (NEW.shop_id,NEW.id,v_kind,OLD.quantity,NEW.quantity-OLD.quantity,
     NEW.quantity,NEW.cost_per_unit,'Automatic stock quantity change',auth.uid());
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.glur_capture_stock_movement() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS glur_stock_quantity_history ON public.glur_stock;
CREATE TRIGGER glur_stock_quantity_history
AFTER UPDATE OF quantity ON public.glur_stock
FOR EACH ROW
WHEN (OLD.quantity IS DISTINCT FROM NEW.quantity)
EXECUTE FUNCTION public.glur_capture_stock_movement();

-- Read-only history: members with stock view permission.
-- Check existing RLS policies before deploying; avoid duplicate policies.
ALTER TABLE public.glur_stock_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS glur_stock_movement_member_read ON public.glur_stock_movements;
CREATE POLICY glur_stock_movement_member_read ON public.glur_stock_movements
FOR SELECT TO authenticated
USING (public.glur_stock_allowed(shop_id,'stock_view'));

GRANT SELECT ON public.glur_stock_movements TO authenticated;

-- Verification after deployment (run as an authenticated TEST user):
-- 1. Record one TEST sale, verify exactly one movement per changed stock row.
-- 2. Receive TEST stock, verify positive quantity_change.
-- 3. Verify quantity_before + quantity_change = quantity_after.
-- 4. Verify LIVE and TEST readers cannot see the other shop's rows.
-- 5. Verify direct client INSERT/UPDATE/DELETE of history is rejected.
