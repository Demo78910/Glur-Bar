DO $fix$ DECLARE def text; BEGIN
SELECT pg_get_functiondef(oid) INTO def FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='glur_produce_prebatch';
def:=replace(def,'s.quantity AS available,s.cost_per_unit FROM','s.quantity AS available,coalesce((SELECT h.cost_per_unit FROM public.glur_cost_history h WHERE h.shop_id=s.shop_id AND h.stock_id=s.id AND h.effective_on<=(now() AT TIME ZONE ''Asia/Bangkok'')::date ORDER BY h.effective_on DESC,h.created_at DESC LIMIT 1),s.cost_per_unit) AS cost_per_unit FROM');
EXECUTE def;
SELECT pg_get_functiondef(oid) INTO def FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='glur_set_prebatch_standard_yield';
def:=replace(def,'SELECT total+coalesce(sum(n.quantity*CASE WHEN n.package_size>0 THEN n.purchase_price/n.package_size ELSE 0 END),0) INTO total FROM public.glur_prebatch_nonstock_ingredients n WHERE n.recipe_id=r.id AND n.shop_id=r.shop_id;',
'SELECT total+coalesce(sum(n.quantity*CASE
WHEN cv.id IS NOT NULL THEN CASE WHEN cv.package_size>0 THEN coalesce(cv.purchase_price,0)/cv.package_size ELSE 0 END
WHEN c.id IS NOT NULL AND EXISTS(SELECT 1 FROM public.glur_cost_catalog_history hx WHERE hx.shop_id=r.shop_id AND hx.catalog_id=c.id) THEN 0
WHEN c.id IS NOT NULL AND c.package_size>0 THEN c.purchase_price/c.package_size
WHEN n.package_size>0 THEN n.purchase_price/n.package_size ELSE 0 END),0) INTO total
FROM public.glur_prebatch_nonstock_ingredients n
LEFT JOIN LATERAL(SELECT cc.* FROM public.glur_cost_catalog cc WHERE cc.shop_id=r.shop_id AND lower(btrim(cc.name))=lower(btrim(n.name)) AND lower(btrim(cc.unit))=lower(btrim(n.unit)) ORDER BY cc.updated_at DESC LIMIT 1)c ON true
LEFT JOIN LATERAL(SELECT h.* FROM public.glur_cost_catalog_history h WHERE h.shop_id=r.shop_id AND h.catalog_id=c.id AND h.effective_date<=(now() AT TIME ZONE ''Asia/Bangkok'')::date ORDER BY h.effective_date DESC,h.created_at DESC LIMIT 1)cv ON true
WHERE n.recipe_id=r.id AND n.shop_id=r.shop_id;');
EXECUTE def;
END $fix$;
CREATE OR REPLACE FUNCTION glur_private.refresh_prebatch_catalog_estimate()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r record;
BEGIN
IF NEW.effective_date>(now() AT TIME ZONE 'Asia/Bangkok')::date OR auth.uid() IS NULL OR NOT public.glur_stock_allowed(NEW.shop_id,'recipes_edit') THEN RETURN NEW; END IF;
FOR r IN SELECT DISTINCT p.id,p.standard_yield FROM public.glur_prebatch_recipes p JOIN public.glur_prebatch_nonstock_ingredients n ON n.recipe_id=p.id AND n.shop_id=p.shop_id JOIN public.glur_cost_catalog c ON c.shop_id=n.shop_id AND lower(btrim(c.name))=lower(btrim(n.name)) AND lower(btrim(c.unit))=lower(btrim(n.unit)) WHERE p.shop_id=NEW.shop_id AND c.id=NEW.catalog_id AND p.standard_yield>0 AND NOT EXISTS(SELECT 1 FROM public.glur_prebatch_batches b WHERE b.recipe_id=p.id) ORDER BY p.id LOOP
PERFORM public.glur_set_prebatch_standard_yield(r.id,r.standard_yield);
END LOOP; RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION glur_private.refresh_prebatch_catalog_estimate() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER glur_refresh_catalog_prebatch_cost AFTER INSERT OR UPDATE ON public.glur_cost_catalog_history FOR EACH ROW EXECUTE FUNCTION glur_private.refresh_prebatch_catalog_estimate();