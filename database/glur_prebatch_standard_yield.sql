ALTER TABLE public.glur_prebatch_recipes ADD COLUMN IF NOT EXISTS standard_yield numeric CHECK(standard_yield>0);
ALTER TABLE public.glur_stock ADD COLUMN IF NOT EXISTS estimated_cost boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION public.glur_set_prebatch_standard_yield(p_recipe_id uuid,p_standard_yield numeric)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.glur_prebatch_recipes%ROWTYPE; total numeric; unit_cost numeric;
BEGIN
SELECT * INTO r FROM public.glur_prebatch_recipes WHERE id=p_recipe_id FOR UPDATE;
IF NOT FOUND OR auth.uid() IS NULL OR NOT public.glur_stock_allowed(r.shop_id,'recipes_edit') THEN RAISE EXCEPTION 'Permission denied'; END IF;
IF p_standard_yield IS NULL OR p_standard_yield<=0 OR p_standard_yield::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'Standard yield must be positive'; END IF;
SELECT coalesce(sum(i.quantity*s.cost_per_unit),0) INTO total FROM public.glur_prebatch_ingredients i JOIN public.glur_stock s ON s.id=i.stock_id AND s.shop_id=i.shop_id WHERE i.recipe_id=r.id AND i.shop_id=r.shop_id;
SELECT total+coalesce(sum(n.quantity*CASE WHEN n.package_size>0 THEN n.purchase_price/n.package_size ELSE 0 END),0) INTO total FROM public.glur_prebatch_nonstock_ingredients n WHERE n.recipe_id=r.id AND n.shop_id=r.shop_id;
unit_cost:=total/p_standard_yield;
UPDATE public.glur_prebatch_recipes SET standard_yield=p_standard_yield WHERE id=r.id;
PERFORM 1 FROM public.glur_stock WHERE id=r.output_stock_id AND shop_id=r.shop_id FOR UPDATE;
IF NOT EXISTS(SELECT 1 FROM public.glur_prebatch_batches WHERE recipe_id=r.id) THEN
UPDATE public.glur_stock SET cost_per_unit=unit_cost,estimated_cost=true WHERE id=r.output_stock_id AND shop_id=r.shop_id;
INSERT INTO public.glur_cost_history(shop_id,stock_id,effective_on,cost_per_unit,note) VALUES(r.shop_id,r.output_stock_id,(now() AT TIME ZONE 'Asia/Bangkok')::date,unit_cost,'ต้นทุนประมาณจากผลผลิตมาตรฐาน Pre-batch') ON CONFLICT(shop_id,stock_id,effective_on) DO UPDATE SET cost_per_unit=excluded.cost_per_unit,note=excluded.note;
END IF;
RETURN unit_cost;
END $$;
REVOKE ALL ON FUNCTION public.glur_set_prebatch_standard_yield(uuid,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.glur_set_prebatch_standard_yield(uuid,numeric) TO authenticated;
DO $patch$ DECLARE def text; BEGIN
SELECT pg_get_functiondef(oid) INTO def FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='glur_produce_prebatch';
IF position('GLUR_PRODUCTION_COST_HISTORY' IN def)=0 THEN
def:=replace(def,'RETURN v_batch;', '/* GLUR_PRODUCTION_COST_HISTORY */ UPDATE public.glur_stock SET estimated_cost=false WHERE id=v_out.id AND shop_id=v_r.shop_id;
INSERT INTO public.glur_cost_history(shop_id,stock_id,effective_on,cost_per_unit,note)
SELECT v_r.shop_id,v_out.id,(now() AT TIME ZONE ''Asia/Bangkok'')::date,s.cost_per_unit,''ต้นทุนหลังผลิต Pre-batch''
FROM public.glur_stock s WHERE s.id=v_out.id AND s.shop_id=v_r.shop_id
ON CONFLICT(shop_id,stock_id,effective_on) DO UPDATE SET cost_per_unit=excluded.cost_per_unit,note=excluded.note;
RETURN v_batch;');
EXECUTE def;
END IF;END $patch$;
NOTIFY pgrst,'reload schema';