
begin;
select set_config('request.jwt.claim.sub','7309615b-5500-4c7b-a646-8b25e8d9ca07',true);
set local role authenticated;
do $$
declare
 src uuid:='e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af'; dst uuid:='bdd83213-8d38-42d7-bd35-835506dc25ac';
 sid uuid; did uuid; rid uuid; pid uuid; result jsonb; stocks_before jsonb; stocks_after jsonb; test_name text:='__IMPORT_QA_'||gen_random_uuid(); blocked boolean;
begin
 select jsonb_agg(to_jsonb(s) order by id) into stocks_before from public.glur_stock s where shop_id in(src,dst);
 select id into sid from public.glur_stock where shop_id=src and name='Mekhong 70cl' and unit='ml' limit 1;
 select id into did from public.glur_stock where shop_id=dst and name='Mekhong 70cl' and unit='ml' limit 1;
 insert into public.glur_recipes(shop_id,name,selling_price) values(src,test_name,300) returning id into rid;
 insert into public.glur_recipe_ingredients(shop_id,recipe_id,stock_id,quantity) values(src,rid,sid,45);
 result:=public.glur_import_test_recipe('cocktail',rid,false,false);
 if not (result->>'ready')::boolean then raise exception 'preview failed %',result; end if;
 result:=public.glur_import_test_recipe('cocktail',rid,true,false);
 if not exists(select 1 from public.glur_recipe_ingredients where recipe_id=(result->>'id')::uuid and stock_id=did and shop_id=dst and quantity=45) then raise exception 'wrong live mapping'; end if;
 blocked:=false;
 begin perform public.glur_import_test_recipe('cocktail',rid,true,false); exception when others then blocked:=true; end;
 if not blocked then raise exception 'duplicate not blocked'; end if;
 update public.glur_recipe_ingredients set quantity=30 where recipe_id=rid and shop_id=src;
 result:=public.glur_import_test_recipe('cocktail',rid,true,true);
 if not exists(select 1 from public.glur_recipe_ingredients where recipe_id=(result->>'id')::uuid and stock_id=did and quantity=30) then raise exception 'replacement failed'; end if;
 -- Validate actual prebatch replacement path including nonstock LIVE price mapping.
 select id into pid from public.glur_prebatch_recipes where shop_id=src and name='Mekong Ume' limit 1;
 result:=public.glur_import_test_recipe('prebatch',pid,true,true);
 if not exists(select 1 from public.glur_prebatch_nonstock_ingredients n join public.glur_cost_catalog c on c.shop_id=n.shop_id and c.name=n.name and c.unit=n.unit where n.recipe_id=(result->>'id')::uuid and n.shop_id=dst and n.purchase_price=c.purchase_price) then raise exception 'nonstock live mapping failed'; end if;
 select jsonb_agg(to_jsonb(s) order by id) into stocks_after from public.glur_stock s where shop_id in(src,dst);
 if stocks_before is distinct from stocks_after then raise exception 'import changed stock'; end if;
 -- Name mismatch blocks preview AND apply, atomically.
 insert into public.glur_stock(shop_id,name,unit,quantity,cost_per_unit,min_quantity) values(src,test_name,'ml',0,0,0) returning id into sid;
 update public.glur_recipe_ingredients set stock_id=sid where recipe_id=rid and shop_id=src;
 result:=public.glur_import_test_recipe('cocktail',rid,false,false);
 if (result->>'ready')::boolean then raise exception 'name mismatch allowed'; end if;
 blocked:=false;
 begin perform public.glur_import_test_recipe('cocktail',rid,true,true); exception when others then blocked:=true; end;
 if not blocked then raise exception 'name mismatch mutation allowed'; end if;
 perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
 blocked:=false;
 begin perform public.glur_import_test_recipe('cocktail',rid,false,false); exception when others then if sqlerrm='GLUR_DEVELOPER_ONLY' then blocked:=true; else raise; end if; end;
 if not blocked then raise exception 'nondeveloper allowed'; end if;
end $$;
rollback;
