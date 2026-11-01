DO $patch$ DECLARE def text; BEGIN
SELECT pg_get_functiondef(oid) INTO def FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='glur_set_prebatch_standard_yield';
def:=replace(def,'sum(i.quantity*s.cost_per_unit)','sum(i.quantity*coalesce((SELECT h.cost_per_unit FROM public.glur_cost_history h WHERE h.shop_id=s.shop_id AND h.stock_id=s.id AND h.effective_on<=(now() AT TIME ZONE ''Asia/Bangkok'')::date ORDER BY h.effective_on DESC,h.created_at DESC LIMIT 1),s.cost_per_unit))');
EXECUTE def;
END $patch$;
CREATE OR REPLACE FUNCTION glur_private.refresh_prebatch_estimate_from_price()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r record;
BEGIN
IF NEW.effective_on>(now() AT TIME ZONE 'Asia/Bangkok')::date THEN RETURN NEW; END IF;
IF TG_OP='UPDATE' AND NEW.cost_per_unit IS NOT DISTINCT FROM OLD.cost_per_unit AND NEW.effective_on IS NOT DISTINCT FROM OLD.effective_on THEN RETURN NEW; END IF;
IF pg_trigger_depth()>12 THEN RAISE EXCEPTION 'Pre-batch cost dependency cycle'; END IF;
IF auth.uid() IS NULL OR NOT public.glur_stock_allowed(NEW.shop_id,'recipes_edit') THEN RETURN NEW; END IF;
FOR r IN SELECT p.id,p.standard_yield FROM public.glur_prebatch_recipes p
JOIN public.glur_prebatch_ingredients i ON i.recipe_id=p.id AND i.shop_id=p.shop_id
WHERE p.shop_id=NEW.shop_id AND i.stock_id=NEW.stock_id AND p.standard_yield>0
AND NOT EXISTS(SELECT 1 FROM public.glur_prebatch_batches b WHERE b.recipe_id=p.id)
ORDER BY p.id LOOP
PERFORM public.glur_set_prebatch_standard_yield(r.id,r.standard_yield);
END LOOP;
RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION glur_private.refresh_prebatch_estimate_from_price() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER glur_refresh_prebatch_estimates AFTER INSERT OR UPDATE ON public.glur_cost_history FOR EACH ROW EXECUTE FUNCTION glur_private.refresh_prebatch_estimate_from_price();