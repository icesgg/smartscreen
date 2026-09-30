-- SmartScreen - 2026-09-30 검토에서 나온 서버 쪽 조임 (content_lockdown.sql 다음)
--
-- 적용: Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 실행.
--       ("destructive operation" 경고가 뜬다 - drop constraint / drop policy 때문이다. 진행.)
--       이미 돌고 있는 프로젝트를 고치는 파일이다. 새 프로젝트는 schema.sql /
--       clipboard.sql / releases.sql 에 같은 내용이 들어 있어 이 파일이 필요 없다.
--       여러 번 실행해도 된다. 중간에 실패하면 전부 되돌아가고 아무것도 안 바뀐다.
--       (지금 있는 행이 새 제약에 안 맞으면 그 자리에서 멈춘다 - 그 행을 먼저 본다.
--        contents 의 두 행은 2026-09-30 에 맞는 것을 확인했다. clip_items 는 config.ini 의
--        clipMaxKB 를 8192 넘게 올렸거나 0 으로 둔 PC 가 큰 것을 올려 둔 경우에만 걸린다.)
--
-- 순서: **고친 dashboard.html 이 GitHub Pages 에 올라간 뒤에** 실행할 것. 확인하는 법:
--   1) docs/dashboard.html 을 커밋하고 push 한다 (작업 트리에만 있으면 Pages 는 예전 것이다).
--   2) https://icesgg.github.io/smartscreen/dashboard.html 의 소스 보기에
--      "CONTENT_EXT" 가 보여야 한다. Pages 는 10분쯤 캐시한다.
--   3) 열어 둔 대시보드 탭은 Ctrl+F5. 열려 있는 탭은 새로 받기 전까지 예전 스크립트다.
-- 예전 대시보드는 확장자를 파일 이름 그대로 붙여서 ('사진.PNG' -> '.PNG', 아이폰의
-- 'IMG_1234.MOV', 점이 없는 이름은 이름 전체) 아래 1번 제약에 걸린다 - 파일은 올라가고
-- 행만 거절되어 버킷에 고아 파일이 남는다. 새 대시보드는 소문자로 바꾸고, 모양이 안
-- 맞는 파일은 올리기 전에 거절한다.
--
-- 여섯을 한다. 돌고 있는 PC(1.1.4)가 읽는 길은 하나도 안 바뀐다.
--
-- 1. contents 행의 모양을 스키마가 지킨다
--    storage_path / filename / file_hash 는 글자 그대로의 text 였고, 조직의 멤버는
--    거기에 아무 문자열이나 넣을 수 있었다. 기업 PC 는 storage_path 의 마지막 '/' 뒤를
--    **로컬 파일 이름으로** 썼는데 역슬래시는 거르지 않아서, '..\..\' 가 든 경로로
--    enterprise_content 폴더 밖에 파일을 쓸 수 있었다 (client/enterprise/supabase.cpp,
--    1.1.4 까지). 클라이언트도 같이 고쳤지만, 이미 깔린 PC 는 새 exe 를 받을 때까지
--    예전 코드다 - 그 사이를 지키는 것이 이 제약이다.
--    모양: storage_path = '<org_id>/<file_hash>.<ext>' (대시보드가 만드는 그대로),
--    ext 는 PC 가 실제로 띄울 수 있는 형식만. 예전 PC 는 content_type 을 안 보고
--    확장자만으로 영상/그림을 가르므로, 확장자를 content_type 에 묶어 둔다.
--
-- 2. 위치마다 송출 중인 행은 하나
--    대시보드가 지키던 규칙을 스키마로 옮긴다. 예전 PC 는 켜진 행을 개수 제한 없이
--    전부, 시작할 때 UI 스레드에서 내려받는다 - 켜진 행이 N 개면 N 개를 다 받는다.
--
-- 3. clip_items 와 'clip' / 'content' 버킷에 크기 상한
--    4 MB 상한은 클라이언트에만 있었다. 서버는 프로젝트 전체 상한까지 받았다.
--    버킷의 allowed_mime_types 는 올리는 쪽이 **적어 보낸** Content-Type 만 본다 -
--    내용 검사가 아니다. 실수로 다른 파일을 올리는 것을 막는 정도이고, 파일의 실제
--    내용은 새 클라이언트가 file_hash 로 확인한다. 실제 업로드 상한은 프로젝트 전체
--    상한 (Storage > Settings) 과 버킷 상한 중 작은 쪽이다.
--    남는 것: 계정 하나가 만들 수 있는 clip_items 행의 개수와 'clip' 버킷의 파일 개수는
--    여전히 제한이 없다 (지우는 것은 클라이언트가 부르는 prune_clip_items 다).
--
-- 4. org_release_approvals.approved_by 는 본인이어야 한다
--    기본값이 auth.uid() 지만 보내는 쪽이 다른 값을 적을 수 있었다.
--
-- 5. org_exists(uuid) - 기업 등록 때 조직 id 가 실제로 있는지 묻는 함수
--    orgs 는 anon 에게 안 보인다 (그래야 한다). 그래서 PC 는 오타 난 id 와 "콘텐츠가
--    아직 없는 조직" 을 구분하지 못했고, 없는 조직에 등록된 채로 남았다. 이 함수는
--    id 를 이미 아는 사람에게 있다/없다 한 비트만 돌려준다. id 는 gen_random_uuid()
--    라 훑어서 찾을 수 없다.
--
-- 6. org_members.created_at 은 서버가 적는다
--    조직의 admin 은 아무 user_id 나 자기 조직의 멤버로 넣을 수 있고 (초대를 받는
--    쪽의 동의가 없다 - 그건 따로 정할 일이다), created_at 도 적어 보낼 수 있었다.
--    대시보드는 멤버십이 여럿이면 가장 오래된 것을 여는데, 날짜를 옛날로 적은 행을
--    심으면 남의 대시보드가 심은 사람의 조직으로 열린다. 넣는 시각을 서버가 적으면
--    심은 행은 언제나 진짜 행보다 새것이다.

begin;

set local lock_timeout = '5s';

-- ------------------------------------------------------------
-- 1. contents 행의 모양
-- ------------------------------------------------------------
alter table public.contents drop constraint if exists contents_storage_path_shape;
alter table public.contents drop constraint if exists contents_filename_sane;
alter table public.contents drop constraint if exists contents_file_size_range;

-- 36(uuid) + 1('/') + 64(hash) + 1('.') = 102. 그 뒤가 확장자다.
-- 비교가 전부 "같다" 라서 '..', 역슬래시, '?', 공백이 들어갈 자리가 없다.
-- 확장자 목록은 PC 가 띄울 수 있는 것과 같다 (영상: client/video/player.cpp 의
-- IsVideoFile, 그림: GDI+). 대시보드의 CONTENT_EXT 와 같아야 한다 - 다르면 파일은
-- 올라가고 행만 거절된다.
alter table public.contents add constraint contents_storage_path_shape check (
  file_hash ~ '^[0-9a-f]{64}$'
  and left(storage_path, 102) = org_id::text || '/' || file_hash || '.'
  and (
       (content_type = 'image' and substr(storage_path, 103) in ('png', 'jpg', 'jpeg', 'bmp', 'gif'))
    or (content_type = 'video' and substr(storage_path, 103) in ('mp4', 'avi', 'wmv', 'mkv', 'mov', 'webm'))
  )
);

-- 사람이 읽는 이름. PC 는 이걸 경로로 쓰지 않는다 (쓰던 적도 없다). 제어 문자만 막는다.
alter table public.contents add constraint contents_filename_sane check (
  char_length(filename) between 1 and 255
  and filename !~ '[[:cntrl:]]'
);

-- 새 클라이언트가 받기를 거절하는 크기와 같다 (200 MB). 1.1.4 에는 상한이 없었다.
alter table public.contents add constraint contents_file_size_range check (
  file_size between 1 and 209715200
);

-- ------------------------------------------------------------
-- 2. 위치마다 송출 중인 행은 하나
-- ------------------------------------------------------------
-- 이미 둘이 켜져 있으면 여기서 멈춘다. 그때는 대시보드에서 하나를 끄고 다시 실행.
create unique index if not exists contents_one_active_per_position
  on public.contents (org_id, display_position) where active;

-- ------------------------------------------------------------
-- 3. 크기 상한
-- ------------------------------------------------------------
alter table public.clip_items drop constraint if exists clip_items_limits;

-- 클라이언트 기본 상한은 4 MB (clipMaxKB). 설정으로 올릴 수 있으므로 여유를 둔다.
-- device 는 컴퓨터 이름(15자 이하)이다.
alter table public.clip_items add constraint clip_items_limits check (
  octet_length(coalesce(body, '')) <= 8388608
  and char_length(device) between 1 and 64
  and char_length(coalesce(storage_path, '')) <= 200
  and bytes between 0 and 16777216
);

-- 클라이언트는 'Content-Type: image/png' 로만 올린다 (client/clipsync.cpp).
update storage.buckets
   set file_size_limit = 16777216,
       allowed_mime_types = array['image/png']
 where id = 'clip';

-- 대시보드는 파일의 MIME 형식 그대로 올린다 (image/png, video/mp4 ...).
update storage.buckets
   set file_size_limit = 209715200,
       allowed_mime_types = array['image/*', 'video/*']
 where id = 'content';

-- update 는 0 행에 닿아도 오류가 아니다. 버킷이 없거나 값이 안 들어갔으면 여기서
-- 멈춰 전부 되돌린다 - "중간에 실패하면 아무것도 안 바뀐다" 가 이 부분에도 맞도록.
do $$
begin
  if (select count(*) from storage.buckets
       where (id = 'clip'    and file_size_limit = 16777216  and allowed_mime_types = array['image/png'])
          or (id = 'content' and file_size_limit = 209715200 and allowed_mime_types = array['image/*', 'video/*'])) <> 2 then
    raise exception 'hardening: bucket limits were not applied (bucket missing or update matched no row)';
  end if;
end $$;

-- ------------------------------------------------------------
-- 4. 승인한 사람은 본인
-- ------------------------------------------------------------
drop policy if exists "org_admins_approve" on public.org_release_approvals;

create policy "org_admins_approve"
  on public.org_release_approvals for insert
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

-- ------------------------------------------------------------
-- 5. org_exists
-- ------------------------------------------------------------
-- security definer: orgs 의 select 정책은 "내가 멤버인 조직" 이라 anon 에게는 아무것도
-- 안 보인다. 그 정책을 여는 대신, 있다/없다만 답하는 함수를 둔다. handle_new_org 와
-- 함께 RLS 를 건너뛰는 함수는 이 둘뿐이다. 본문이 스키마를 전부 적었으므로
-- search_path 는 비운다.
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

-- ------------------------------------------------------------
-- 6. org_members.created_at 은 서버가 적는다
-- ------------------------------------------------------------
-- 호출자 권한으로 돈다 (security definer 가 아니다) - 새 행의 칸 하나를 고칠 뿐이다.
-- handle_new_org 가 넣는 첫 admin 행에도 걸리고, 그래도 값은 같다 (now()).
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

drop trigger if exists org_members_stamp_created_at on public.org_members;
create trigger org_members_stamp_created_at
  before insert on public.org_members
  for each row execute function public.org_members_stamp_created_at();

commit;

-- 새 함수가 /rest/v1/rpc/org_exists 로 바로 보이도록. 보통은 저절로 되지만, 안 되면
-- PC 는 404 를 받고 "알 수 없음" 으로 넘어간다 (안전하지만 기능이 조용히 안 켜진다).
notify pgrst, 'reload schema';

-- ============================================================
-- 확인 (읽기 전용). 결과 한 칸을 복사해 두면 된다.
-- ============================================================
-- constraints : contents 에 새로 셋 (contents_storage_path_shape / _filename_sane /
--               _file_size_range), clip_items 에 새로 하나 (clip_items_limits).
--               원래 있던 check (content_type, display_position, kind, payload) 도 같이 나온다
-- one_active  : contents_one_active_per_position 한 줄
-- buckets     : clip = 16777216 + ["image/png"], content = 209715200 + ["image/*", "video/*"],
--               releases 는 둘 다 null 그대로
-- approve     : check 에 approved_by = auth.uid() 가 보여야 한다
-- org_exists  : security_definer = true, anon_can_execute = true, config 에 search_path=""
-- stamp       : org_members 에 org_members_stamp_created_at (BEFORE INSERT) 한 줄
select jsonb_pretty(jsonb_build_object(

  'stamp', (
    select jsonb_agg(jsonb_build_object(
             'table', event_object_table,
             'name',  trigger_name,
             'when',  action_timing || ' ' || event_manipulation))
      from information_schema.triggers
     where trigger_schema = 'public' and trigger_name = 'org_members_stamp_created_at'
  ),


  'constraints', (
    select jsonb_agg(jsonb_build_object(
             'table', conrelid::regclass::text,
             'name',  conname,
             'def',   pg_get_constraintdef(oid))
           order by conrelid::regclass::text, conname)
      from pg_constraint
     where contype = 'c'
       and conrelid in ('public.contents'::regclass, 'public.clip_items'::regclass)
  ),

  'one_active', (
    select jsonb_agg(jsonb_build_object('name', indexname, 'def', indexdef))
      from pg_indexes
     where schemaname = 'public' and indexname = 'contents_one_active_per_position'
  ),

  'buckets', (
    select jsonb_agg(jsonb_build_object(
             'id', id, 'public', public,
             'file_size_limit', file_size_limit,
             'allowed_mime_types', allowed_mime_types)
           order by id)
      from storage.buckets
  ),

  'approve', (
    select jsonb_agg(jsonb_build_object('name', policyname, 'cmd', cmd, 'check', with_check))
      from pg_policies
     where schemaname = 'public' and tablename = 'org_release_approvals' and cmd = 'INSERT'
  ),

  'org_exists', (
    select jsonb_agg(jsonb_build_object(
             'args', pg_get_function_identity_arguments(p.oid),
             'security_definer', p.prosecdef,
             'config', to_jsonb(p.proconfig),
             'anon_can_execute', has_function_privilege('anon', p.oid, 'execute')))
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'org_exists'
  )

)) as after_hardening;
