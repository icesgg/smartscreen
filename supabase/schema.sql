-- SmartScreen Enterprise Edition - Supabase Schema
-- 조직(org) 기반 콘텐츠 관리 스키마

-- ============================================================
-- NOTE: Supabase Storage bucket 'content' 는 대시보드에서 수동 생성 필요
--   Settings > Storage > New bucket > name: "content", Public: OFF
-- ============================================================

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
  updated_at       timestamptz not null default now()
);

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

-- org_members: 소속 멤버는 멤버 목록 조회 가능
create policy "members_can_read_org_members"
  on org_members for select
  to authenticated
  using (
    org_id in (
      select org_id from org_members where user_id = auth.uid()
    )
  );

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
create or replace function handle_new_org()
returns trigger as $$
begin
  insert into org_members (org_id, user_id, role)
  values (new.id, new.created_by, 'admin');
  return new;
end;
$$ language plpgsql security definer;

create trigger on_org_created
  after insert on orgs
  for each row execute function handle_new_org();
