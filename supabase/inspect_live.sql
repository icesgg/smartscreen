-- SmartScreen - 라이브 서버의 실제 상태를 한 번에 뽑는다 (읽기 전용)
--
-- 목적: supabase/schema.sql 이 라이브와 어긋나 있다 (contents.active 열, anon 정책,
-- 'content' 버킷 정책이 저장소의 어느 .sql 에도 없다). anon key 로 밖에서 찔러 보면
-- "읽힌다 / insert 는 막힌다" 까지만 알 수 있고, update / delete / Storage 쓰기는
-- 실제로 써 보지 않고는 알 수 없다. 정책을 직접 읽으면 아무것도 쓰지 않고 전부 안다.
--
-- 쓰는 법: Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 실행 -> 결과 한 칸을 복사.
-- 이 파일은 아무것도 바꾸지 않는다 (select 하나뿐).
--
-- SQL Editor 는 여러 문장을 돌리면 마지막 결과만 보여 주므로 한 문장으로 묶었다.

select jsonb_pretty(jsonb_build_object(

  -- 표와 Storage 의 모든 정책. cmd 가 ALL/SELECT/INSERT/UPDATE/DELETE,
  -- roles 에 anon 이 들어 있는 줄이 "로그인 없이 되는 일" 이다.
  'policies', (
    select jsonb_agg(jsonb_build_object(
             'table', schemaname || '.' || tablename,
             'name',  policyname,
             'cmd',   cmd,
             'roles', roles,
             'using', qual,
             'check', with_check)
           order by schemaname, tablename, cmd, policyname)
      from pg_policies
     where schemaname = 'public'
        or (schemaname = 'storage' and tablename = 'objects')
  ),

  -- RLS 가 꺼진 표가 있으면 정책과 무관하게 전부 열려 있다.
  'rls', (
    select jsonb_agg(jsonb_build_object(
             'table', c.relname,
             'rls_enabled', c.relrowsecurity,
             'rls_forced',  c.relforcerowsecurity)
           order by c.relname)
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
  ),

  -- contents 의 실제 열 (schema.sql 을 라이브에 맞추는 데 필요하다).
  'contents_columns', (
    select jsonb_agg(jsonb_build_object(
             'column',   column_name,
             'type',     data_type,
             'nullable', is_nullable,
             'default',  column_default)
           order by ordinal_position)
      from information_schema.columns
     where table_schema = 'public' and table_name = 'contents'
  ),

  -- contents 의 제약 (check / fk / unique).
  'contents_constraints', (
    select jsonb_agg(jsonb_build_object(
             'name', conname,
             'def',  pg_get_constraintdef(oid))
           order by conname)
      from pg_constraint
     where conrelid = 'public.contents'::regclass
  ),

  -- 버킷. public = true 면 RLS 를 거치지 않고 읽힌다.
  'buckets', (
    select jsonb_agg(jsonb_build_object(
             'id', id, 'public', public,
             'file_size_limit', file_size_limit,
             'allowed_mime_types', allowed_mime_types)
           order by id)
      from storage.buckets
  ),

  -- public 스키마의 함수. security_definer 인데 search_path 가 없는 것을 본다.
  'functions', (
    select jsonb_agg(jsonb_build_object(
             'name', p.proname,
             'args', pg_get_function_identity_arguments(p.oid),
             'security_definer', p.prosecdef,
             'config', p.proconfig,
             'anon_can_execute', has_function_privilege('anon', p.oid, 'execute'))
           order by p.proname)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
  ),

  -- 트리거 (updated_at, handle_new_org 등).
  'triggers', (
    select jsonb_agg(jsonb_build_object(
             'table', event_object_table,
             'name',  trigger_name,
             'when',  action_timing || ' ' || event_manipulation,
             'does',  action_statement)
           order by event_object_table, trigger_name)
      from information_schema.triggers
     where trigger_schema = 'public'
  )

)) as live_state;
