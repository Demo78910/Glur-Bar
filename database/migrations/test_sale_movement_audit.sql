-- GLUR BAR: TEST-only sale ingredient movement audit.
-- Safe for existing data: no historical backfill, no stock quantity changes.
-- Applies only to TEST shop; LIVE sale flow remains untouched.
CREATE OR REPLACE FUNCTION public.glur_test_sale_ingredient_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_shop uuid;
  v_before numeric;
  v_cost numeric;
BEGIN
  SELECT shop_id INTO v_shop FROM public.glur_sales WHERE id=NEW.sale_id;
  IF v_shop IS DISTINCT FROM 'e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af'::uuid THEN
    RETURN NEW;
  END IF;
  IF NEW.quantity_used IS NULL OR NEW.quantity_used <= 0 THEN
    RAISE EXCEPTION 'Invalid sale ingredient quantity';
  END IF;
  SELECT quantity,cost_per_unit INTO v_before,v_cost
    FROM public.glur_stock WHERE id=NEW.stock_id AND shop_id=v_shop FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stock missing for sale ingredient'; END IF;
  IF v_before < NEW.quantity_used THEN
    RAISE EXCEPTION 'Insufficient stock for sale';
  END IF;
  INSERT INTO public.glur_stock_movements
    (shop_id,stock_id,movement_type,quantity_before,quantity_change,quantity_after,
     cost_per_unit_snapshot,reason,reference_id,created_by)
  VALUES
    (v_shop,NEW.stock_id,'sale',v_before,-NEW.quantity_used,v_before-NEW.quantity_used,
     NEW.cost_per_unit,'ตัดใช้จากการขาย',NEW.sale_id,auth.uid());
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS glur_test_sale_movement_on_ingredient ON public.glur_sale_ingredients;
CREATE TRIGGER glur_test_sale_movement_on_ingredient
AFTER INSERT ON public.glur_sale_ingredients
FOR EACH ROW EXECUTE FUNCTION public.glur_test_sale_ingredient_movement();
REVOKE ALL ON FUNCTION public.glur_test_sale_ingredient_movement() FROM PUBLIC,anon,authenticated;
