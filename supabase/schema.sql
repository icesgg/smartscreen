-- SmartScreen Enterprise Edition - Supabase Schema
-- 조직(org) 기반 콘텐츠 관리 스키마

--
-- 적용: Supabase 대시보드 > SQL Editor 에 붙여넣고 실행 (새 프로젝트에 한 번).
--
-- 2026-09-30 에 라이브의 정책을 직접 읽어 (inspect_live.sql) 이 파일을 거기에
-- 맞췄다. 그 전까지 이 파일에는 contents.active 열, anon 읽기 정책, 'content'
-- 버킷의 정책이 하나도 없었다 - 전부 대시보드에서 손으로 넣은 것이었고, 이 파일로
-- 새 프로젝트를 세우면 클라이언트의 `active=eq.true` 가 400 을 받았다.
-- 이미 돌고 있는 프로젝트는 content_lockdown.sql ('content' 버킷의 쓰기 정책) 과
-- hardening.sql (행의 모양 제약, 버킷 상한, org_exists) 을 적용해야 이 파일과
-- 같아진다.
--
-- ============================================================
-- 이 표들은 device_tokens / clip_items 와 방침이 다르다
-- ============================================================
-- contents 와 'content' 버킷은 **로그인 없이 읽힌다.** 기업 PC 는 로그인이 없고
-- (config.ini 에 서버 주소 + anon key + 조직 id 만 있다) 그 PC 가 잠금 화면
-- 콘텐츠를 받아야 하기 때문이다. 대가는 anon key 를 가진 누구나 모든 조직의
-- 행과 파일을 읽는다는 것이다 - 조직이 하나뿐인 지금은 드러나지 않는다.
-- 조이려면 기업 PC 에 로그인이나 그에 준하는 것이 필요해지고, 그건 아직 정하지
-- 않았다. 쓰기는 조직의 멤버만 한다.

-- 조직 테이블
create table orgs (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

alter table orgs enable row level security;

-- 콘텐츠 테이블 (이미지/동영상)
create table contents (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references orgs(id) on delete cascade,
  filename         text not null,
  storage_path     text not null,        -- Supabase Storage 경로
  file_hash        text not null,        -- SHA-256
  file_size        bigint not null,
  content_type     text not null check (content_type in ('image', 'video')),
  display_position text not null default 'center' check (display_position in ('center', 'banner')),
  version          int not null default 1,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- 송출 중인가. PC 는 active 인 행만 받는다 (FetchManifest 의 active=eq.true).
  -- 위치(center/banner)마다 하나만 켤 수 있다 (아래 contents_one_active_per_position).
  active           boolean not null default false,

  -- 행의 모양을 스키마가 지킨다 (hardening.sql). storage_path 는
  -- '<org_id>/<file_hash>.<ext>' 여야 한다 - 대시보드가 만드는 그대로다.
  -- 36(uuid) + 1 + 64(hash) + 1 = 102 글자까지가 고정이고 그 뒤가 확장자다.
  --
  -- 이게 없던 동안, 조직의 멤버는 여기에 아무 문자열이나 넣을 수 있었고 기업 PC 는
  -- 마지막 '/' 뒤를 로컬 파일 이름으로 썼다. 역슬래시는 거르지 않아서 '..\..\' 가
  -- 든 경로로 enterprise_content 폴더 밖에 파일을 쓸 수 있었다 (1.1.4 까지).
  -- 클라이언트도 같은 모양을 따로 확인한다 - 둘 중 하나가 틀려도 다른 하나가 남는다.
  --
  -- 확장자는 PC 가 띄울 수 있는 것만 (영상: client/video/player.cpp 의 IsVideoFile,
  -- 그림: GDI+), content_type 에 묶어서. 1.1.4 까지의 PC 는 content_type 을 안 보고
  -- 확장자만으로 영상/그림을 갈랐다. 대시보드의 CONTENT_EXT 와 같아야 한다 - 다르면
  -- 파일은 올라가고 행만 거절된다.
  constraint contents_storage_path_shape check (
    file_hash ~ '^[0-9a-f]{64}$'
    and left(storage_path, 102) = org_id::text || '/' || file_hash || '.'
    and (
         (content_type = 'image' and substr(storage_path, 103) in ('png', 'jpg', 'jpeg', 'bmp', 'gif'))
      or (content_type = 'video' and substr(storage_path, 103) in ('mp4', 'avi', 'wmv', 'mkv', 'mov', 'webm'))
    )
  ),
  constraint contents_filename_sane check (
    char_length(filename) between 1 and 255
    and filename !~ '[[:cntrl:]]'
  ),
  -- 새 클라이언트가 받기를 거절하는 크기와 같다 (200 MB). 1.1.4 에는 상한이 없었다.
  constraint contents_file_size_range check (file_size between 1 and 209715200)
);

-- 위치(center/banner)마다 송출 중인 행은 하나. 대시보드가 지키던 규칙을 스키마로
-- 옮겼다 (hardening.sql): 1.1.4 까지의 PC 는 켜진 행을 개수 제한 없이 전부, 시작할
-- 때 UI 스레드에서 내려받았다.
create unique index contents_one_active_per_position
  on contents (org_id, display_position) where active;

alter table contents enable row level security;

-- 조직 멤버 테이블
create table org_members (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  user_id    uuid not null references auth.users(id),
  role       text not null default 'member' check (role in ('admin', 'member')),
  created_at timestamptz not null default now(),
  unique (org_id, user_id)
);

alter table org_members enable row level security;

-- 표 권한. 예전 프로젝트는 public 의 새 표를 anon/authenticated 에 자동으로 열어
-- 주지만 (라이브가 그렇다), 그 자동 부여가 없는 프로젝트에서는 아래가 없으면 모든
-- 요청이 "permission denied for table" 로 끝난다. 이미 있는 곳에서는 아무 일도
-- 하지 않는다. 실제로 무엇이 되는지는 아래 정책이 정한다 - 권한은 문을 달 뿐이다.
grant usage on schema public to anon, authenticated;
grant select on contents to anon;
grant select, insert, update, delete on contents to authenticated;
grant select, insert on orgs to authenticated;
grant select, insert, update, delete on org_members to authenticated;

-- ============================================================
-- Row Level Security Policies
-- ============================================================

-- orgs: 소속 멤버만 조회 가능
create policy "org_members_can_read_org"
  on orgs for select
  to authenticated
  using (
    id in (
      select org_id from org_members where user_id = auth.uid()
    )
  );

-- orgs: 인증된 사용자는 조직 생성 가능
create policy "authenticated_can_create_org"
  on orgs for insert
  to authenticated
  with check (created_by = auth.uid());

-- contents: 로그인 없이 읽는다 (기업 PC). 맨 위 설명 참고.
-- anon 에게는 이것 하나뿐이다 - insert/update/delete 정책이 없어 쓰지 못한다.
create policy "anon_can_read_contents"
  on contents for select
  to anon
  using (true);

-- contents: 소속 멤버 조회
create policy "org_members_can_read_contents"
  on contents for select
  to authenticated
  using (
    org_id in (
      select org_id from org_members where user_id = auth.uid()
    )
  );

-- contents: 소속 멤버 업로드
create policy "org_members_can_insert_contents"
  on contents for insert
  to authenticated
  with check (
    org_id in (
      select org_id from org_members where user_id = auth.uid()
    )
  );

-- contents: 소속 멤버 수정
create policy "org_members_can_update_contents"
  on contents for update
  to authenticated
  using (
    org_id in (
      select org_id from org_members where user_id = auth.uid()
    )
  );

-- contents: 소속 멤버 삭제
create policy "org_members_can_delete_contents"
  on contents for delete
  to authenticated
  using (
    org_id in (
      select org_id from org_members where user_id = auth.uid()
    )
  );

-- org_members: 자기 멤버십만 보인다.
-- "같은 조직의 멤버 전체" 로 쓰면 (org_id in (select org_id from org_members ...))
-- 정책이 자기 표를 다시 읽어 무한 재귀 오류가 난다. 이 파일의 첫 판이 그랬고
-- 라이브에서는 이 꼴로 고쳐져 있었다. 다른 표의 정책이 org_members 를 서브쿼리로
-- 읽을 때도 이 정책이 걸리므로, 거기서 보이는 것도 자기 멤버십뿐이다. 대시보드가
-- 쓰는 흐름에는 그것으로 충분하다. 단, 아래 admin 의 update/delete 정책은 이
-- select 정책 때문에 자기 행에만 닿는다 (고치거나 지울 행이 먼저 보여야 한다) -
-- 다른 멤버를 고치거나 빼는 것은 지금 SQL Editor 에서만 된다.
create policy "members_can_read_org_members"
  on org_members for select
  to authenticated
  using (user_id = auth.uid());

-- org_members: admin만 멤버 추가 가능
create policy "admins_can_insert_members"
  on org_members for insert
  to authenticated
  with check (
    org_id in (
      select org_id from org_members
      where user_id = auth.uid() and role = 'admin'
    )
  );

-- org_members: admin만 멤버 수정 가능
create policy "admins_can_update_members"
  on org_members for update
  to authenticated
  using (
    org_id in (
      select org_id from org_members
      where user_id = auth.uid() and role = 'admin'
    )
  );

-- org_members: admin만 멤버 삭제 가능
create policy "admins_can_delete_members"
  on org_members for delete
  to authenticated
  using (
    org_id in (
      select org_id from org_members
      where user_id = auth.uid() and role = 'admin'
    )
  );

-- ============================================================
-- updated_at 자동 갱신 트리거
-- ============================================================
create or replace function update_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger contents_updated_at
  before update on contents
  for each row execute function update_updated_at();

-- ============================================================
-- 편의 함수: 조직 생성 시 생성자를 admin으로 자동 등록
-- ============================================================
-- security definer 인 이유: org_members 의 insert 정책은 "그 조직의 admin" 만
-- 받는데, 조직을 막 만든 사람은 아직 admin 이 아니다. search_path 를 못박아 둔다 -
-- RLS 를 건너뛰는 함수는 이것과 아래 org_exists 둘뿐이다.
create or replace function public.handle_new_org()
returns trigger as $$
begin
  insert into public.org_members (org_id, user_id, role)
  values (new.id, new.created_by, 'admin');
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger on_org_created
  after insert on orgs
  for each row execute function handle_new_org();

-- ============================================================
-- org_members.created_at 은 서버가 적는다
-- ============================================================
-- 조직의 admin 은 아무 user_id 나 자기 조직의 멤버로 넣을 수 있고 (받는 쪽의 동의가
-- 없다 - 초대 흐름은 아직 없다), created_at 도 적어 보낼 수 있었다. 대시보드는
-- 멤버십이 여럿이면 가장 오래된 것을 여는데, 날짜를 옛날로 적은 행을 심으면 남의
-- 대시보드가 심은 사람의 조직으로 열린다. 넣는 시각을 서버가 적으면 심은 행은 언제나
-- 진짜 행보다 새것이다 (hardening.sql).
create or replace function public.org_members_stamp_created_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.created_at := now();
  return new;
end;
$$;

create trigger org_members_stamp_created_at
  before insert on org_members
  for each row execute function public.org_members_stamp_created_at();

-- ============================================================
-- org_exists - 기업 등록 때 조직 id 가 실제로 있는지 묻는다
-- ============================================================
-- orgs 는 anon 에게 안 보인다 (그래야 한다). 그래서 PC 는 오타 난 id 와 "콘텐츠가
-- 아직 없는 조직" 을 구분하지 못했고, 없는 조직에 등록된 채로 남았다. 이 함수는
-- id 를 이미 아는 사람에게 있다/없다 한 비트만 돌려준다 - orgs 의 select 정책을 여는
-- 대신이다. id 는 gen_random_uuid() 라 훑어서 찾을 수 없다. 본문이 스키마를 전부
-- 적었으므로 search_path 는 비운다.
create or replace function public.org_exists(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.orgs where id = p_org);
$$;

revoke all on function public.org_exists(uuid) from public;
grant execute on function public.org_exists(uuid) to anon, authenticated, service_role;

-- ============================================================
-- Storage - 'content' 버킷
-- ============================================================
-- 비공개 버킷이고 읽기를 정책으로 연다. public 으로 만들면 읽기만 RLS 를 거치지
-- 않게 되고 (/object/public/...), 나중에 읽기를 조일 자리가 없어진다. 쓰기는
-- public 이든 아니든 아래 정책을 거친다.
--
-- 그림과 영상이라고 **밝힌** 업로드만, 200 MB 까지. allowed_mime_types 는 올리는 쪽이
-- 적어 보낸 Content-Type 만 본다 - 내용 검사가 아니고, 실수로 다른 파일을 올리는 것을
-- 막는 정도다. 실제 상한은 프로젝트 전체 상한과 이 값 중 작은 쪽이다.
-- 버킷을 대시보드에서 먼저 만들어 둔 프로젝트에서도 상한이 들어가도록 do update 다.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('content', 'content', false, 209715200, array['image/*', 'video/*'])
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 읽기: 로그인 없이 (기업 PC), 그리고 로그인한 사람 (대시보드의 미리보기).
create policy "anon_can_read_storage"
  on storage.objects for select
  to anon
  using (bucket_id = 'content');

create policy "authenticated_can_read"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'content');

-- 쓰기: 경로의 첫 폴더가 조직 id 다 (dashboard.html: `${org.id}/${hash}.${ext}`).
-- 그 조직의 멤버만 올리고, 덮어쓰고, 지운다.
--
-- 조건을 bucket_id 하나로 두면 안 된다. 라이브가 그랬다: "authenticated" 는
-- 조직의 멤버가 아니라 구글 계정으로 로그인한 아무나라서, 누구든 남의 조직의
-- 파일을 지우고 같은 경로에 다른 파일을 올릴 수 있었다 - 기업 PC 는 그걸 받아
-- 잠금 화면에 띄운다 (content_lockdown.sql).
create policy "org_members_upload_content"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'content'
    and (storage.foldername(name))[1] in (
      select m.org_id::text from public.org_members m where m.user_id = auth.uid()
    )
  );

-- x-upsert 로 같은 경로에 다시 올리는 것은 update 다 (clipboard.sql 의 같은 함정).
-- 대시보드가 upsert 로 올리므로 없으면 같은 파일의 두 번째 업로드가 거절된다.
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
