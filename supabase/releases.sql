-- SmartScreen - 프로그램 자동 업데이트를 위한 표 다섯 개와 버킷 하나
--
-- 목적: 새 버전을 서버에 올리면 모든 PC 가 스스로 알아채서 받아 간다.
-- 개인 PC 는 사용자가 [업데이트] 를 눌러야 바뀌고, 기업 PC 는 그 조직의
-- 관리자가 대시보드에서 버전을 승인하면 묻지 않고 바뀐다.
-- 설계 배경은 docs/UPDATE.md, 클라이언트는 client/update.cpp, 올리는 도구는
-- tools/publish.cpp (publish.bat).
--
-- Windows 판은 releases / org_release_approvals, Mac 판은 mac_releases /
-- org_mac_release_approvals 를 쓴다 (아래 "Mac 판"). 버킷과 release_admins 는 같이 쓴다.
--
-- 적용: Supabase 대시보드 > SQL Editor 에 붙여넣고 실행.
--       맨 아래 "관리자 지정" 의 이메일을 확인하고 실행할 것.
--       이 파일은 새 프로젝트용이다. 이미 돌고 있는 프로젝트에 Mac 표를 더하는 것은
--       mac_releases.sql 이다 (이 파일의 Mac 부분과 releases_storage_path_windows 가 그것과 같다).
--
-- ============================================================
-- 이 표들은 device_tokens / clip_items 와 방침이 다르다
-- ============================================================
-- 저 둘은 anon 정책이 하나도 없다 - 비밀이라서. 여기는 반대로 releases 와
-- org_release_approvals 를 **로그인 없이 읽게 한다.** 개인 PC 는 로그인이 없고
-- 그 PC 도 업데이트를 받아야 한다. 읽히는 것은 버전 번호, 파일 경로, 해시,
-- 배포 메모, "어느 조직이 어느 버전을 승인했나" 다. 비밀이 아니다 - exe 는
-- 어차피 나눠 주는 물건이다.
--
-- 지켜야 하는 것은 읽기가 아니라 **쓰기**다. 이 표에 행을 넣을 수 있는 사람은
-- 모든 PC 에 실행 파일을 밀어 넣을 수 있다. 그래서 쓰기는 release_admins 에
-- 든 계정만 하고, 클라이언트는 행에 적힌 SHA-256 과 다른 파일은 실행하지
-- 않는다. 버킷의 파일만 바꿔 놓아도 소용이 없다.

-- ============================================================
-- release_admins - 버전을 올릴 수 있는 계정
-- ============================================================
create table release_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table release_admins enable row level security;

-- 자기 줄만 보인다. Publish.exe 가 "내가 자격이 있나" 를 먼저 묻는 데 쓴다 -
-- 없으면 아래 insert 가 RLS 오류로 거절되는데, 그 오류 문구는 무엇을 해야
-- 하는지 말해 주지 않는다.
create policy "own_release_admin_select"
  on release_admins for select
  to authenticated
  using (user_id = auth.uid());

-- insert/update/delete 정책은 없다 = 이 표는 SQL Editor 에서만 고친다.
-- 관리자가 관리자를 추가하는 길을 열면, 계정 하나가 새면 전부 샌다.

-- ============================================================
-- releases - 올라간 버전들
-- ============================================================
create table releases (
  -- "1.2.3" 꼴만. 클라이언트가 세 숫자로 비교하므로 (client/relver.h) 다른 꼴은
  -- 조용히 건너뛰어진다. 스키마가 먼저 거른다.
  version      text primary key check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),

  -- stable 이 기본. beta 는 내 PC 에서 먼저 돌려 보는 용도다 (config.ini 의
  -- updateChannel=beta). 기업 PC 도 채널을 따르므로 관리자가 beta 를 승인하면
  -- 그 조직의 beta 채널 PC 만 받는다.
  channel      text not null default 'stable' check (channel in ('stable', 'beta')),

  -- 'releases' 버킷 안의 경로. '<version>/SmartScreen.exe' 모양만 받는다 - 이 표는 Windows
  -- exe 전용이다. 깔린 Windows PC 는 이 표의 켜진 행을 플랫폼을 묻지 않고 전부 받으므로,
  -- Mac zip 이 여기 들어가면 Windows PC 들이 그걸 자기 exe 자리에 놓는다 (mac_releases.sql).
  storage_path text not null
               constraint releases_storage_path_windows
               check (storage_path ~ '^[0-9]+\.[0-9]+\.[0-9]+/SmartScreen\.exe$'),

  -- 이 행의 전부다. 클라이언트는 받은 파일의 해시가 이 값과 다르면 버린다.
  -- 파일 옆에 .sha256 파일로 두면 파일을 바꿀 수 있는 사람이 해시도 바꾼다.
  sha256       text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size         bigint not null check (size > 0),

  notes        text,                 -- 배포 메모. 첫 줄이 PC 화면에 보인다

  -- 끄면 PC 들이 이 버전을 못 본다. 잘못 올린 것을 지우지 않고 끈다 - 지우면
  -- org_release_approvals 의 승인도 같이 사라져 무슨 일이 있었는지 알 수 없다.
  active       boolean not null default true,

  published_by uuid references auth.users(id) default auth.uid(),
  published_at timestamptz not null default now()
);

alter table releases enable row level security;

-- 누구나 켜진 행을 읽는다. 관리자는 꺼진 행도 본다 (Publish.exe --list).
create policy "anyone_reads_active_releases"
  on releases for select
  to anon, authenticated
  using (
    active
    or exists (select 1 from release_admins where user_id = auth.uid())
  );

create policy "admins_insert_releases"
  on releases for insert
  to authenticated
  with check (exists (select 1 from release_admins where user_id = auth.uid()));

create policy "admins_update_releases"
  on releases for update
  to authenticated
  using (exists (select 1 from release_admins where user_id = auth.uid()))
  with check (exists (select 1 from release_admins where user_id = auth.uid()));

create policy "admins_delete_releases"
  on releases for delete
  to authenticated
  using (exists (select 1 from release_admins where user_id = auth.uid()));

-- ============================================================
-- org_release_approvals - 조직 관리자가 승인한 버전
-- ============================================================
-- 기업 PC 는 여기 있는 버전 중 가장 높은 것만 받는다. 새 버전이 올라와도 이
-- 표에 없으면 "관리자 승인을 기다려요" 로 보이기만 한다. 배포 시점을 정하는
-- 사람은 프로그램을 만든 사람이 아니라 그 조직의 관리자다.
create table org_release_approvals (
  org_id      uuid not null references orgs(id) on delete cascade,
  version     text not null references releases(version) on delete cascade,
  approved_by uuid not null references auth.users(id) default auth.uid(),
  approved_at timestamptz not null default now(),
  primary key (org_id, version)
);

alter table org_release_approvals enable row level security;

-- 표 권한 (schema.sql 의 같은 자리 참고). 새 표를 자동으로 열어 주지 않는 프로젝트
-- 에서는 이게 없으면 정책이 있어도 "permission denied" 다. 무엇이 되는지는 정책이 정한다.
-- release_admins 를 anon 에도 준다: releases 의 select 정책이 release_admins 를 하위
-- 질의로 읽고, 그 권한 검사는 부르는 역할(anon)로 한다 - 없으면 로그인 없는 PC 의
-- 업데이트 확인이 "permission denied for table release_admins" 로 끝난다. anon 에게
-- 보이는 줄은 없다 (release_admins 의 정책이 authenticated 뿐이다).
grant select on release_admins to anon, authenticated;
grant select on releases, org_release_approvals to anon, authenticated;
grant insert, update, delete on releases to authenticated;
grant insert, delete on org_release_approvals to authenticated;

-- 로그인 없이 읽는다. 기업 PC 는 (지금 구조에서는) 로그인이 없다 - 콘텐츠도
-- anon 키로 받는다. 행에 든 것은 조직 id 와 버전 번호뿐이다.
create policy "anyone_reads_approvals"
  on org_release_approvals for select
  to anon, authenticated
  using (true);

-- 쓰기는 그 조직의 admin 만. member 는 대시보드에서 목록만 본다.
-- approved_by 는 본인이어야 한다 - 기본값이 auth.uid() 지만 보내는 쪽이 다른 값을
-- 적을 수 있었다 (hardening.sql).
create policy "org_admins_approve"
  on org_release_approvals for insert
  to authenticated
  with check (
    approved_by = auth.uid()
    and exists (
      select 1 from public.org_members m
       where m.org_id = org_release_approvals.org_id
         and m.user_id = auth.uid()
         and m.role = 'admin'
    )
  );

create policy "org_admins_revoke"
  on org_release_approvals for delete
  to authenticated
  using (
    exists (
      select 1 from org_members m
       where m.org_id = org_release_approvals.org_id
         and m.user_id = auth.uid()
         and m.role = 'admin'
    )
  );

-- update 정책은 없다. 승인은 넣거나 빼는 것이다.

-- ============================================================
-- Storage - 'releases' 버킷
-- ============================================================
-- 비공개 버킷이지만 anon 에 select 를 준다. public 버킷으로 만들지 않은 이유는
-- 그러면 RLS 를 거치지 않아 아래 정책이 아무 말도 못 하기 때문이다 - 쓰기를
-- 막는 것이 이 정책의 일이다.
insert into storage.buckets (id, name, public)
values ('releases', 'releases', false)
on conflict (id) do nothing;

create policy "anyone_downloads_releases"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'releases');

create policy "admins_upload_releases"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'releases'
              and exists (select 1 from release_admins where user_id = auth.uid()));

-- x-upsert 로 같은 경로에 다시 올리는 것은 update 다 (clipboard.sql 의 같은 함정).
create policy "admins_replace_releases"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'releases'
         and exists (select 1 from release_admins where user_id = auth.uid()))
  with check (bucket_id = 'releases'
              and exists (select 1 from release_admins where user_id = auth.uid()));

create policy "admins_remove_releases"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'releases'
         and exists (select 1 from release_admins where user_id = auth.uid()));

-- ============================================================
-- Mac 판 - mac_releases / org_mac_release_approvals
-- ============================================================
-- 돌고 있는 프로젝트에는 mac_releases.sql 로 더한다. 이 부분은 그 파일과 같아야 한다 -
-- 까닭도 그 파일 머리말에 있다. 줄이면: 깔린 Windows PC 는 releases 의 켜진 행을 플랫폼을
-- 묻지 않고 전부 SmartScreen.exe 로 받으므로 Mac zip 을 같은 표에 넣을 수 없고, 두 판의 버전
-- 번호가 같아서(client/version.h 하나) 기본키도 겹친다. 그래서 표와 승인이 플랫폼마다 따로다.
-- 버킷은 같은 'releases' 의 mac/ 아래이고, 위의 버킷 정책이 경로를 안 보므로 그대로 맞다.
create table mac_releases (
  version      text primary key check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  channel      text not null default 'stable' check (channel in ('stable', 'beta')),
  storage_path text not null,
  sha256       text not null check (sha256 ~ '^[0-9a-f]{64}$'),   -- SmartScreen-mac.zip 의 해시
  size         bigint not null check (size > 0),
  -- 이 버전이 도는 가장 낮은 macOS. 기본값은 앱의 배포 대상과 같고 Publish.exe 는 보내지 않는다.
  min_macos    text not null default '13.0' check (min_macos ~ '^[0-9]+\.[0-9]+$'),
  notes        text,
  active       boolean not null default true,
  published_by uuid references auth.users(id) default auth.uid(),
  published_at timestamptz not null default now(),
  -- 경로에 그 행의 버전이 들어 있어야 한다 (다른 번호의 zip 을 가리키면 Mac 마다 적용이 실패한다).
  constraint mac_releases_storage_path_shape check (
    storage_path ~ '^mac/[0-9]+\.[0-9]+\.[0-9]+/SmartScreen-mac\.zip$'
    and storage_path = 'mac/' || version || '/SmartScreen-mac.zip'
  )
);

alter table mac_releases enable row level security;

create policy "anyone_reads_active_mac_releases"
  on mac_releases for select
  to anon, authenticated
  using (
    active
    or exists (select 1 from release_admins where user_id = auth.uid())
  );

create policy "admins_insert_mac_releases"
  on mac_releases for insert
  to authenticated
  with check (exists (select 1 from release_admins where user_id = auth.uid()));

create policy "admins_update_mac_releases"
  on mac_releases for update
  to authenticated
  using (exists (select 1 from release_admins where user_id = auth.uid()))
  with check (exists (select 1 from release_admins where user_id = auth.uid()));

create policy "admins_delete_mac_releases"
  on mac_releases for delete
  to authenticated
  using (exists (select 1 from release_admins where user_id = auth.uid()));

-- 기업 Mac 은 여기 있는 버전 중 가장 높은 것만 받는다. Windows 승인과 따로다.
create table org_mac_release_approvals (
  org_id      uuid not null references orgs(id) on delete cascade,
  version     text not null references mac_releases(version) on delete cascade,
  approved_by uuid not null references auth.users(id) default auth.uid(),
  approved_at timestamptz not null default now(),
  primary key (org_id, version)
);

alter table org_mac_release_approvals enable row level security;

create policy "anyone_reads_mac_approvals"
  on org_mac_release_approvals for select
  to anon, authenticated
  using (true);

create policy "org_admins_approve_mac"
  on org_mac_release_approvals for insert
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

create policy "org_admins_revoke_mac"
  on org_mac_release_approvals for delete
  to authenticated
  using (
    exists (
      select 1 from public.org_members m
       where m.org_id = org_mac_release_approvals.org_id
         and m.user_id = auth.uid()
         and m.role = 'admin'
    )
  );

-- 권한: 먼저 걷고 쓰는 것만 다시 준다 (기본으로 다 주는 프로젝트에서도 정책 하나가 잘못되면
-- anon 이 쓰는 일이 없게). 다시 주는 것은 releases / org_release_approvals 와 같다.
revoke all on mac_releases, org_mac_release_approvals from anon, authenticated;
grant select on mac_releases, org_mac_release_approvals to anon, authenticated;
grant insert, update, delete on mac_releases to authenticated;
grant insert, delete on org_mac_release_approvals to authenticated;

-- ============================================================
-- 관리자 지정
-- ============================================================
-- 이메일을 확인하고 실행할 것. 이 계정으로 Publish.exe 가 로그인한다.
-- 다른 사람을 더하려면 같은 문장을 그 이메일로 한 번 더.
insert into release_admins (user_id)
select id from auth.users where email = 'icesgg@gmail.com'
on conflict (user_id) do nothing;

-- 확인: 한 줄이 나와야 한다. 안 나오면 그 이메일로 로그인한 적이 없는 것이다.
select u.email, a.created_at
  from release_admins a join auth.users u on u.id = a.user_id;
