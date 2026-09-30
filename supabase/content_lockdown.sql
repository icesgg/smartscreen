-- SmartScreen - 'content' 버킷의 쓰기를 그 조직의 멤버로 좁힌다
--
-- 적용: Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 실행.
--       ("destructive operation" 경고가 뜬다 - drop policy 때문이다. 진행.)
--       이미 돌고 있는 프로젝트를 고치는 파일이다. 새 프로젝트는 schema.sql 만
--       적용하면 되고 (같은 정책이 거기 들어 있다) 이 파일은 필요 없다.
--       여러 번 실행해도 된다. 중간에 실패하면 전부 되돌아가고 아무것도 안 바뀐다.
--
-- ============================================================
-- 무엇이 열려 있었나 (2026-09-30, inspect_live.sql 로 정책을 직접 읽어서 확인)
-- ============================================================
--   authenticated_can_upload   insert  with check (bucket_id = 'content')
--   authenticated_can_delete   delete  using      (bucket_id = 'content')
--
-- 조건이 버킷 이름뿐이다. "authenticated" 는 조직의 멤버가 아니라 **구글 계정으로
-- 로그인한 아무나**다 - 가입이 열려 있고(대시보드가 누구에게나 조직을 만들게
-- 한다), 로그인에 필요한 anon key 는 exe 와 dashboard.html 에 박혀 있다.
--
-- 그래서 아무 구글 계정이나
--   1) contents 표를 anon 으로 읽어 남의 조직의 storage_path 를 알아내고
--   2) 그 파일을 지우고 (delete 정책)
--   3) 같은 경로에 다른 파일을 올릴 수 있었다 (insert 정책)
-- 기업 PC 는 그 경로의 파일을 받아 **잠금 화면에 띄운다.** contents 행은 못
-- 고쳐도 상관없다 - 행이 가리키는 파일이 바뀐 것이니까. (1.1.4 까지의 클라이언트는
-- file_hash 를 대조하지 않고 크기만 본다: client/enterprise/supabase.cpp.)
-- 지우기만 해도 그 조직의 화면에서 콘텐츠가 빠진다.
--
-- update 정책은 아예 없었다. 그래서 대시보드의 upload(..., { upsert: true }) 는
-- 같은 파일을 두 번째 올릴 때 거절됐다 - 같은 이름에 다시 올리는 것은 Storage
-- 에서 update 다 (clipboard.sql 의 같은 함정).
--
-- ============================================================
-- 무엇으로 바꾸나
-- ============================================================
-- 경로의 첫 폴더가 조직 id 다 (dashboard.html: `${org.id}/${hash}.${ext}`).
-- 그 폴더의 주인인 조직에 속한 사람만 올리고, 덮어쓰고, 지운다.
-- clip 버킷이 (storage.foldername(name))[1] = auth.uid() 로 하는 것과 같은 꼴이다.
--
-- **읽기는 건드리지 않는다.** 이 파일을 적용한 뒤에도 anon key 를 가진 누구나
-- 모든 조직의 contents 행과 'content' 버킷의 파일을 읽는다
-- (anon_can_read_contents / anon_can_read_storage). 기업 PC 가 로그인 없이
-- 콘텐츠를 받기 위한 것이고, 그걸 조일지는 따로 정할 일이다 - 조이면 기업 PC 마다
-- 로그인이나 그에 준하는 것이 필요해진다. 이 파일이 고치는 것은 "남이 바꿀 수
-- 있다" 이지 "남이 볼 수 있다" 가 아니다.

begin;

-- 정책을 바꾸는 동안 storage.objects 가 잠긴다. 보통 몇 ms 지만, 다른 세션이
-- 그 표를 붙잡고 있으면 이 문장이 줄을 서고 그 뒤로 모든 내려받기가 줄을 선다.
-- 5초 안에 못 잡으면 통째로 물러난다 - 그때는 다시 실행하면 된다.
set local lock_timeout = '5s';

drop policy if exists "authenticated_can_upload"    on storage.objects;
drop policy if exists "authenticated_can_delete"    on storage.objects;
drop policy if exists "org_members_upload_content"  on storage.objects;
drop policy if exists "org_members_replace_content" on storage.objects;
drop policy if exists "org_members_delete_content"  on storage.objects;

-- org_members 의 select 정책이 (user_id = auth.uid()) 라서 아래 서브쿼리는
-- 자기 멤버십만 본다. 폴더 이름이 없는 경로('file.png')는 [1] 이 null 이라
-- 거절된다. uuid::text 는 소문자+하이픈이고 비교는 글자 그대로라, 대문자로 쓴
-- 폴더는 다른 폴더다.
create policy "org_members_upload_content"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'content'
    and (storage.foldername(name))[1] in (
      select m.org_id::text from public.org_members m where m.user_id = auth.uid()
    )
  );

-- x-upsert 로 같은 경로에 다시 올리는 것. with check 가 있어야 남의 폴더로
-- 옮기지 못한다 (move 는 name 을 바꾸는 update 다).
create policy "org_members_replace_content"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'content'
    and (storage.foldername(name))[1] in (
      select m.org_id::text from public.org_members m where m.user_id = auth.uid()
    )
  )
  with check (
    bucket_id = 'content'
    and (storage.foldername(name))[1] in (
      select m.org_id::text from public.org_members m where m.user_id = auth.uid()
    )
  );

create policy "org_members_delete_content"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'content'
    and (storage.foldername(name))[1] in (
      select m.org_id::text from public.org_members m where m.user_id = auth.uid()
    )
  );

-- security definer 함수는 search_path 를 못박아 둔다. 안 그러면 부르는 쪽의
-- search_path 로 org_members 를 찾는다. 지금 그걸 악용할 길은 없지만(클라이언트는
-- 스키마를 만들 수 없다) 이 함수는 RLS 를 건너뛰는 유일한 함수다.
create or replace function public.handle_new_org()
returns trigger as $$
begin
  insert into public.org_members (org_id, user_id, role)
  values (new.id, new.created_by, 'admin');
  return new;
end;
$$ language plpgsql security definer set search_path = public;

commit;

-- ============================================================
-- 확인 (읽기 전용). 결과 한 칸을 복사해 두면 된다.
-- ============================================================
-- content_policies : 다섯 줄이어야 한다.
--     anon_can_read_storage / authenticated_can_read           (select, 그대로)
--     org_members_upload_content / _replace_content / _delete_content
--   authenticated_can_upload 나 authenticated_can_delete 가 보이면 적용이 안 된 것이다.
-- handle_new_org   : config 에 search_path=public 이 있어야 한다.
-- objects / rows   : 구멍이 **이미 쓰였는지** 보는 자리다. 정책을 고쳐도 그 전에
--   바뀐 파일은 그대로 남아 PC 로 내려간다. 의심할 것:
--     owner_is_member = false   올린 계정이 그 조직의 멤버가 아니다
--     org_exists = false        조직 폴더 밖에 있다 (이제 대시보드로는 못 지운다)
--     size 가 rows 의 file_size 와 다르다, 또는 객체의 created_at 이 행보다 한참 뒤다
--   rows 의 object_exists = false 는 행만 남고 파일이 없는 것이다.
select jsonb_pretty(jsonb_build_object(

  'content_policies', (
    select jsonb_agg(jsonb_build_object('name', policyname, 'cmd', cmd, 'roles', roles)
                     order by cmd, policyname)
      from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and (coalesce(qual, '') like '%''content''%'
            or coalesce(with_check, '') like '%''content''%')
  ),

  'handle_new_org', (
    select jsonb_agg(jsonb_build_object('security_definer', p.prosecdef,
                                        'config', to_jsonb(p.proconfig)))
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'handle_new_org'
  ),

  -- owner_id 열이 없는 예전 Storage 스키마에서도 실패하지 않도록 to_jsonb 로 읽는다.
  'objects', (
    select jsonb_agg(jsonb_build_object(
             'name',       o.name,
             'size',       o.metadata->>'size',
             'created_at', o.created_at,
             'updated_at', o.updated_at,
             'owner',      to_jsonb(o)->>'owner_id',
             'org_exists', exists (
                 select 1 from public.orgs g
                  where g.id::text = (storage.foldername(o.name))[1]),
             'owner_is_member', exists (
                 select 1 from public.org_members m
                  where m.org_id::text = (storage.foldername(o.name))[1]
                    and m.user_id::text = to_jsonb(o)->>'owner_id'),
             'rows', (
                 select jsonb_agg(jsonb_build_object(
                          'file_size', c.file_size, 'active', c.active,
                          'created_at', c.created_at))
                   from public.contents c
                  where c.storage_path = o.name))
           order by o.created_at)
      from (select * from storage.objects
             where bucket_id = 'content'
             order by created_at desc limit 200) o
  ),

  'rows', (
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'active', c.active, 'storage_path', c.storage_path,
             'path_in_org_folder',
                 coalesce((storage.foldername(c.storage_path))[1] = c.org_id::text, false),
             'object_exists', exists (
                 select 1 from storage.objects o
                  where o.bucket_id = 'content' and o.name = c.storage_path))
           order by c.created_at)
      from public.contents c
  )

)) as after_lockdown;
