-- SmartScreen - Mac 판 프로그램 업데이트를 위한 표 둘 (mac_releases, org_mac_release_approvals)
--
-- 적용: Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 실행.
--       ("destructive operation" 경고가 뜬다 - drop policy / drop constraint 때문이다. 진행.)
--       이미 돌고 있는 프로젝트(releases.sql + hardening.sql 이 적용된 곳)에 Mac 표를 더하는
--       파일이다. 새 프로젝트는 releases.sql 에 같은 내용이 들어 있어 이 파일이 필요 없다.
--       여러 번 실행해도 된다. 중간에 실패하면 전부 되돌아가고 아무것도 안 바뀐다.
--
-- 순서: 이 파일을 먼저 돌리고, 그 뒤에 Mac 판을 올린다 (release.bat 의 Mac 단계,
--       release-mac.bat, 또는 Publish.exe --platform mac). 표가 없으면 Publish.exe 가
--       "mac_releases 표가 없다" 로 멈추고, 대시보드는 "Mac 업데이트 표가 아직 없습니다" 만
--       보여 준다 (Windows 목록은 그대로). 돌고 있는 Windows PC 가 읽는 길은 하나도 안 바뀐다.
--
-- ============================================================
-- 왜 releases 에 Mac 행을 넣지 않나
-- ============================================================
-- 이미 깔린 Windows 1.1.0 ~ 1.1.7 은 고정된 조회를 한다:
--   releases?select=version,storage_path,sha256,size,notes&active=eq.true&channel=eq.<채널>
-- 플랫폼 조건이 없고, 깔린 exe 안에 박혀 있어 앞으로도 없다. 그 표에 켜진 Mac 행이 들어가면
-- Windows PC 들이 SmartScreen-mac.zip 을 받는다. 해시는 행에 적힌 zip 의 해시라 **맞는다.**
-- 개인 PC 는 [업데이트] 를 누르는 순간, 기업 PC 는 그 번호가 승인되는 순간 묻지 않고, zip 을
-- SmartScreen.exe 자리에 놓고 (실패 기록까지 지운 뒤) 실행에 실패한다. 화면을 지키는 프로그램이
-- 없어지고, 무엇이 잘못됐는지도 남지 않는다. 열(platform)을 더해도 소용없다 - 예전 조회는 그
-- 열을 모르고, 모르는 열이 있는 행도 그대로 돌려받는다.
--
-- 번호도 겹친다. Mac 판은 Windows 판과 같은 client/version.h 로 빌드된다 (mac/build_app.sh).
-- releases 의 기본키가 version 이라 Windows 1.1.8 과 Mac 1.1.8 이 한 표에 같이 못 들어가고,
-- 승인(org_release_approvals)도 버전마다라서 "Windows 1.1.8 은 승인, Mac 1.1.8 은 아직" 을
-- 적을 수 없다.
--
-- 그래서 Mac 은 표가 따로다. 열·제약·정책·권한은 releases / org_release_approvals 와 같다
-- (hardening.sql 의 "승인한 사람은 본인" 까지). 다른 것:
--   * storage_path 는 모양까지 못박는다: 'mac/<그 행의 버전>/SmartScreen-mac.zip'.
--   * sha256 / size 는 SmartScreen.app 이 아니라 SmartScreen-mac.zip 의 것이다. Mac 은 zip 을
--     받아 해시를 행과 대조한 뒤에야 푼다 (믿는 것은 행의 해시 하나 - releases 와 같다).
--   * min_macos 열이 하나 더 있다. 기본값 '13.0' 은 앱의 배포 대상(Package.swift, Info.plist 의
--     LSMinimumSystemVersion)과 같고, Publish.exe 는 보내지 않는다. 나중에 배포 대상을 올리면
--     낮은 macOS 의 Mac 이 그 행을 "새 버전" 으로 보지 않게 하는 자리다. 클라이언트가 이 열을
--     select 해도, 안 해도 된다.
--   * 권한은 필요한 것만 남긴다 (아래 "권한").
--
-- 버킷은 새로 만들지 않는다. 같은 'releases' 버킷의 mac/ 아래에 둔다. 버킷 정책
-- (releases.sql 의 anyone_downloads_releases / admins_upload_releases / admins_replace_releases /
-- admins_remove_releases) 은 bucket_id 와 release_admins 만 보고 경로는 안 본다 - 이미 맞다.
-- 버킷에 크기·형식 상한도 없다 (hardening.sql 은 clip / content 버킷만 바꿨다).
--
-- ============================================================
-- 덤: releases 에는 Windows exe 만
-- ============================================================
-- releases.storage_path 에 '<버전>/SmartScreen.exe' 모양의 제약을 건다. Publish.exe 는 언제나
-- 그 경로로 올렸으므로 (1.1.0 ~ 1.1.7) 지금 행은 다 맞아야 한다. SQL Editor 에서 Mac 행을
-- releases 에 잘못 넣는 길을 서버가 막는다 (위의 사고는 행 하나로 난다). 지금 행 중 하나라도
-- 안 맞으면 여기서 멈추고 전부 되돌아간다 - 그때는 이것으로 그 행을 먼저 본다:
--   select version, storage_path, active from public.releases
--    where storage_path !~ '^[0-9]+\.[0-9]+\.[0-9]+/SmartScreen\.exe$';

begin;

-- releases 에 제약을 거는 동안 그 표가 잠긴다 (PC 들의 업데이트 확인이 그 뒤에 줄을 선다).
-- 행이 열 개 남짓이라 몇 ms 지만, 다른 세션이 붙잡고 있으면 5초 안에 물러난다 - 다시 실행.
set local lock_timeout = '5s';

-- ------------------------------------------------------------
-- 1. mac_releases - 올라간 Mac 버전들
-- ------------------------------------------------------------
create table if not exists public.mac_releases (
  -- "1.2.3" 꼴만. Windows 와 같은 규칙으로 비교한다 (client/relver.h, mac/.../RelVer.swift).
  version      text primary key check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),

  -- stable 이 기본. beta 는 내 Mac 에서 먼저 돌려 보는 용도다 (config.ini 의 updateChannel=beta).
  channel      text not null default 'stable' check (channel in ('stable', 'beta')),

  -- 'releases' 버킷 안의 경로. 아래 mac_releases_storage_path_shape 가 모양을 못박는다.
  storage_path text not null,

  -- 이 행의 전부다. Mac 은 받은 zip 의 해시가 이 값과 다르면 버린다.
  sha256       text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size         bigint not null check (size > 0),

  -- 이 버전이 도는 가장 낮은 macOS ("13.0" 꼴).
  min_macos    text not null default '13.0' check (min_macos ~ '^[0-9]+\.[0-9]+$'),

  notes        text,                 -- 배포 메모. 첫 줄이 Mac 화면에 보인다

  -- 끄면 Mac 들이 이 버전을 못 본다. 지우지 않고 끈다 - 지우면 승인도 같이 사라진다.
  active       boolean not null default true,

  published_by uuid references auth.users(id) default auth.uid(),
  published_at timestamptz not null default now(),

  -- 경로에 그 행의 버전이 들어 있어야 한다. 1.1.9 행이 1.1.8 의 zip 을 가리키면 Mac 들이
  -- 받아서 풀고, 적용기가 "버전이 다르다" 로 거절하고, Mac 마다 실패 기록이 남는다.
  constraint mac_releases_storage_path_shape check (
    storage_path ~ '^mac/[0-9]+\.[0-9]+\.[0-9]+/SmartScreen-mac\.zip$'
    and storage_path = 'mac/' || version || '/SmartScreen-mac.zip'
  )
);

alter table public.mac_releases enable row level security;

-- 누구나 켜진 행을 읽는다 (개인 Mac 은 로그인이 없다). 관리자는 꺼진 행도 본다 (--list).
drop policy if exists "anyone_reads_active_mac_releases" on public.mac_releases;
create policy "anyone_reads_active_mac_releases"
  on public.mac_releases for select
  to anon, authenticated
  using (
    active
    or exists (select 1 from public.release_admins where user_id = auth.uid())
  );

drop policy if exists "admins_insert_mac_releases" on public.mac_releases;
create policy "admins_insert_mac_releases"
  on public.mac_releases for insert
  to authenticated
  with check (exists (select 1 from public.release_admins where user_id = auth.uid()));

-- Publish.exe 의 upsert(merge-duplicates)는 insert ... on conflict do update 다 - 같은 번호를
-- 다시 올리면(같은 zip) update 정책이 걸린다.
drop policy if exists "admins_update_mac_releases" on public.mac_releases;
create policy "admins_update_mac_releases"
  on public.mac_releases for update
  to authenticated
  using (exists (select 1 from public.release_admins where user_id = auth.uid()))
  with check (exists (select 1 from public.release_admins where user_id = auth.uid()));

drop policy if exists "admins_delete_mac_releases" on public.mac_releases;
create policy "admins_delete_mac_releases"
  on public.mac_releases for delete
  to authenticated
  using (exists (select 1 from public.release_admins where user_id = auth.uid()));

-- ------------------------------------------------------------
-- 2. org_mac_release_approvals - 조직 관리자가 승인한 Mac 버전
-- ------------------------------------------------------------
-- 기업 Mac 은 여기 있는 버전 중 가장 높은 것만 받는다. Windows 승인과 따로다 - 같은 번호라도
-- 플랫폼마다 승인한다 (대시보드의 Windows / Mac 목록).
create table if not exists public.org_mac_release_approvals (
  org_id      uuid not null references public.orgs(id) on delete cascade,
  version     text not null references public.mac_releases(version) on delete cascade,
  approved_by uuid not null references auth.users(id) default auth.uid(),
  approved_at timestamptz not null default now(),
  primary key (org_id, version)
);

alter table public.org_mac_release_approvals enable row level security;

-- 로그인 없이 읽는다. 기업 Mac 도 (지금 구조에서는) 로그인이 없다. 행에 든 것은 조직 id 와
-- 버전 번호뿐이다.
drop policy if exists "anyone_reads_mac_approvals" on public.org_mac_release_approvals;
create policy "anyone_reads_mac_approvals"
  on public.org_mac_release_approvals for select
  to anon, authenticated
  using (true);

-- 쓰기는 그 조직의 admin 만. approved_by 는 본인이어야 한다 - 기본값이 auth.uid() 지만
-- 보내는 쪽이 다른 값을 적을 수 있다 (hardening.sql 4번과 같다).
drop policy if exists "org_admins_approve_mac" on public.org_mac_release_approvals;
create policy "org_admins_approve_mac"
  on public.org_mac_release_approvals for insert
  to authenticated
  with check (
    approved_by = auth.uid()
    and exists (
      select 1 from public.org_members m
       where m.org_id = org_mac_release_approvals.org_id
         and m.user_id = auth.uid()
         and m.role = 'admin'
    )
  );

drop policy if exists "org_admins_revoke_mac" on public.org_mac_release_approvals;
create policy "org_admins_revoke_mac"
  on public.org_mac_release_approvals for delete
  to authenticated
  using (
    exists (
      select 1 from public.org_members m
       where m.org_id = org_mac_release_approvals.org_id
         and m.user_id = auth.uid()
         and m.role = 'admin'
    )
  );

-- update 정책은 없다. 승인은 넣거나 빼는 것이다.

-- ------------------------------------------------------------
-- 3. 권한
-- ------------------------------------------------------------
-- 무엇이 되는지는 정책이 정하고, 권한은 그 위의 울타리다. Supabase 는 새 표에 anon /
-- authenticated 의 모든 권한을 기본으로 주는 경우가 있어서 (프로젝트 설정에 따라 다르다)
-- 먼저 걷고, 쓰는 것만 다시 준다 - 그러면 정책 하나가 잘못돼도 anon 은 못 쓴다.
-- 다시 주는 것은 releases / org_release_approvals 와 같다.
-- release_admins 의 select 는 releases.sql 이 이미 anon 에 줬다: 위의 select 정책이
-- release_admins 를 하위 질의로 읽고, 그 권한 검사는 부르는 역할(anon)로 한다 - 없으면 로그인
-- 없는 Mac 의 확인이 "permission denied for table release_admins" 로 끝난다. 한 번 더 준다 (해가 없다).
revoke all on public.mac_releases, public.org_mac_release_approvals from anon, authenticated;
grant select on public.release_admins to anon, authenticated;
grant select on public.mac_releases, public.org_mac_release_approvals to anon, authenticated;
grant insert, update, delete on public.mac_releases to authenticated;
grant insert, delete on public.org_mac_release_approvals to authenticated;

-- ------------------------------------------------------------
-- 4. releases 에는 Windows exe 경로만 (머리말의 "덤")
-- ------------------------------------------------------------
-- not valid 로 걸고 validate 로 지금 행을 따로 검사한다. 안 맞는 행이 있으면 validate 에서
-- 멈추고 위의 begin 부터 전부 되돌아간다.
alter table public.releases drop constraint if exists releases_storage_path_windows;
alter table public.releases add constraint releases_storage_path_windows
  check (storage_path ~ '^[0-9]+\.[0-9]+\.[0-9]+/SmartScreen\.exe$') not valid;
alter table public.releases validate constraint releases_storage_path_windows;

commit;

-- 새 표가 /rest/v1/mac_releases 로 바로 보이도록. 보통은 저절로 되지만, 안 되면 한동안
-- PGRST205 ("schema cache 에 없다") 가 나고 Mac 의 업데이트 확인이 "표가 없다" 로 끝난다.
notify pgrst, 'reload schema';

-- ============================================================
-- 확인 (읽기 전용). 결과 한 칸을 복사해 두면 된다.
-- ============================================================
-- columns     : mac_releases 10열 (version ~ published_at, min_macos 포함),
--               org_mac_release_approvals 4열 (org_id, version, approved_by, approved_at)
-- constraints : mac_releases 의 check 들 (version / channel / sha256 / size / min_macos /
--               mac_releases_storage_path_shape) + pkey + published_by fkey,
--               org_mac_release_approvals 의 pkey + fkey 셋 (orgs, mac_releases, auth.users),
--               그리고 releases_storage_path_windows 한 줄 (convalidated = true)
-- policies    : mac_releases 넷 (select anon+authenticated / insert / update / delete),
--               org_mac_release_approvals 셋 (select anon+authenticated / insert 의 check 에
--               approved_by = auth.uid() / delete)
-- rls         : 두 표 다 rls_enabled = true
-- grants      : anon 은 select 만 (mac_releases, org_mac_release_approvals, release_admins).
--               authenticated 는 mac_releases 에 select/insert/update/delete,
--               org_mac_release_approvals 에 select/insert/delete (update 없음)
-- releases_bucket_policies : 넷. 조건에 bucket_id = 'releases' 와 release_admins 만 있고
--               경로(name)는 없어야 한다 - 그래야 mac/ 아래도 같은 규칙이다
-- releases_paths : 지금 Windows 행들. 전부 '<버전>/SmartScreen.exe'
-- mac_rows    : 처음에는 0
select jsonb_pretty(jsonb_build_object(

  'columns', (
    select jsonb_agg(jsonb_build_object(
             'table',    table_name,
             'column',   column_name,
             'type',     data_type,
             'nullable', is_nullable,
             'default',  column_default)
           order by table_name, ordinal_position)
      from information_schema.columns
     where table_schema = 'public'
       and table_name in ('mac_releases', 'org_mac_release_approvals')
  ),

  'constraints', (
    select jsonb_agg(jsonb_build_object(
             'table',       conrelid::regclass::text,
             'name',        conname,
             'validated',   convalidated,
             'def',         pg_get_constraintdef(oid))
           order by conrelid::regclass::text, conname)
      from pg_constraint
     where conrelid in ('public.mac_releases'::regclass, 'public.org_mac_release_approvals'::regclass)
        or (conrelid = 'public.releases'::regclass and conname = 'releases_storage_path_windows')
  ),

  'policies', (
    select jsonb_agg(jsonb_build_object(
             'table', tablename,
             'name',  policyname,
             'cmd',   cmd,
             'roles', roles,
             'using', qual,
             'check', with_check)
           order by tablename, cmd, policyname)
      from pg_policies
     where schemaname = 'public'
       and tablename in ('mac_releases', 'org_mac_release_approvals')
  ),

  'rls', (
    select jsonb_agg(jsonb_build_object(
             'table',       c.relname,
             'rls_enabled', c.relrowsecurity)
           order by c.relname)
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname in ('mac_releases', 'org_mac_release_approvals')
  ),

  'grants', (
    select jsonb_agg(jsonb_build_object(
             'table',  tt.t,
             'role',   rr.r,
             'select', has_table_privilege(rr.r::name, tt.t, 'select'),
             'insert', has_table_privilege(rr.r::name, tt.t, 'insert'),
             'update', has_table_privilege(rr.r::name, tt.t, 'update'),
             'delete', has_table_privilege(rr.r::name, tt.t, 'delete'))
           order by tt.t, rr.r)
      from unnest(array['public.mac_releases', 'public.org_mac_release_approvals',
                        'public.release_admins']) as tt(t)
     cross join unnest(array['anon', 'authenticated']) as rr(r)
  ),

  'releases_bucket_policies', (
    select jsonb_agg(jsonb_build_object(
             'name',  policyname,
             'cmd',   cmd,
             'roles', roles,
             'using', qual,
             'check', with_check)
           order by cmd, policyname)
      from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and (coalesce(qual, '') like '%''releases''%'
            or coalesce(with_check, '') like '%''releases''%')
  ),

  'releases_paths', (
    select jsonb_agg(jsonb_build_object(
             'version',      version,
             'storage_path', storage_path,
             'active',       active)
           order by published_at)
      from public.releases
  ),

  'mac_rows', (select count(*) from public.mac_releases)

)) as after_mac_releases;
