ALTER TABLE public.glur_daily_closings
 ADD COLUMN IF NOT EXISTS original_cogs numeric,
 ADD COLUMN IF NOT EXISTS cost_revised_at timestamptz,
 ADD COLUMN IF NOT EXISTS cost_revision_note text;
CREATE TABLE public.glur_closing_cost_revisions(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),shop_id uuid NOT NULL,
 closing_id uuid NOT NULL REFERENCES public.glur_daily_closings(id),
 sale_id uuid NOT NULL,version_id uuid NOT NULL,
 cogs_before numeric NOT NULL,cogs_after numeric NOT NULL,
 profit_before numeric NOT NULL,profit_after numeric NOT NULL,
 reason text NOT NULL,actor_id uuid,created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.glur_closing_cost_revisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.glur_closing_cost_revisions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.glur_closing_cost_revisions TO authenticated;
CREATE POLICY closing_cost_revision_read ON public.glur_closing_cost_revisions FOR SELECT TO authenticated USING(public.glur_is_developer(shop_id));
CREATE OR REPLACE FUNCTION glur_private.revise_closing_cost()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.glur_daily_closings%ROWTYPE; delta numeric; reason text; matched integer;
BEGIN
IF NEW.cost_version_id IS NULL OR NEW.total_cost IS NOT DISTINCT FROM OLD.total_cost THEN RETURN NEW; END IF;
IF NOT glur_private.is_developer(NEW.shop_id) THEN RAISE EXCEPTION 'Developer only: closing cost correction'; END IF;
delta:=NEW.total_cost-OLD.total_cost;
SELECT v.note INTO reason FROM public.glur_recipe_cost_versions v WHERE v.id=NEW.cost_version_id AND v.shop_id=NEW.shop_id;
IF reason IS NULL THEN RAISE EXCEPTION 'Correction reason missing'; END IF;
PERFORM pg_advisory_xact_lock(hashtextextended('glur:closing:'||NEW.shop_id::text,0));
SELECT count(*) INTO matched FROM public.glur_daily_closings x WHERE x.shop_id=NEW.shop_id AND NEW.created_at<=x.closed_at AND (
(x.period_start IS NOT NULL AND x.period_end IS NOT NULL AND NEW.sold_at>=x.period_start AND NEW.sold_at<x.period_end)
OR (x.period_start IS NULL AND x.period_end IS NULL AND x.business_date=((NEW.sold_at AT TIME ZONE 'Asia/Bangkok')-interval '3 hours')::date));
IF matched>1 THEN RAISE EXCEPTION 'Overlapping closing periods: review before cost correction'; END IF;
FOR c IN SELECT * FROM public.glur_daily_closings x WHERE x.shop_id=NEW.shop_id AND NEW.created_at<=x.closed_at AND (
(x.period_start IS NOT NULL AND x.period_end IS NOT NULL AND NEW.sold_at>=x.period_start AND NEW.sold_at<x.period_end)
OR (x.period_start IS NULL AND x.period_end IS NULL AND x.business_date=((NEW.sold_at AT TIME ZONE 'Asia/Bangkok')-interval '3 hours')::date)) FOR UPDATE LOOP
INSERT INTO public.glur_closing_cost_revisions(shop_id,closing_id,sale_id,version_id,cogs_before,cogs_after,profit_before,profit_after,reason,actor_id)
VALUES(NEW.shop_id,c.id,NEW.id,NEW.cost_version_id,c.cogs,c.cogs+delta,c.profit_after_expenses,c.profit_after_expenses-delta,reason,auth.uid());
UPDATE public.glur_daily_closings SET original_cogs=coalesce(original_cogs,cogs),cogs=cogs+delta,
gross_profit=gross_profit-delta,profit_after_expenses=profit_after_expenses-delta,
cost_revised_at=clock_timestamp(),cost_revision_note=reason WHERE id=c.id;
END LOOP;
RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION glur_private.revise_closing_cost() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER glur_revise_closing_after_cost AFTER UPDATE OF total_cost ON public.glur_sales FOR EACH ROW EXECUTE FUNCTION glur_private.revise_closing_cost();
NOTIFY pgrst,'reload schema';