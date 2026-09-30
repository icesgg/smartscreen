-- SmartScreen - 같은 계정의 PC 사이에서 클립보드를 넘기는 테이블
--
-- 목적: A 에서 스크린캡처하거나 무언가를 복사하면 B 에서 Ctrl+V 로 붙는다.
-- 둘 다 같은 구글 계정으로 로그인해 있다는 것이 유일한 연결고리다.
-- 설계 배경은 docs/CLIPBOARD.md 를 참고.
--
-- 적용: Supabase 대시보드 > SQL Editor 에 붙여넣고 실행.
--
-- device_tokens.sql 과 같은 방침을 따른다: anon 역할에는 정책을 하나도 주지
-- 않는다. 클립보드는 contents 와 성격이 정반대다 - contents 는 공유하라고
-- 있는 것이고, 이것은 사람이 방금 복사한 것이라 무엇이 들어올지 아무도 모른다.
-- 화면 사진, 코드, 붙여넣으려던 비밀번호가 다 같은 통로로 지나간다.

-- ============================================================
-- clip_items
-- ============================================================
create table clip_items (
  id          bigserial primary key,

  -- 기본값이 auth.uid() 라서 클라이언트가 이 칸을 보내지 않는다. 보내게 두면
  -- 남의 id 를 적어 보낼 수 있고, 그걸 막는 것은 아래 insert 정책이지만 -
  -- 애초에 보낼 값이 없는 편이 낫다. 틀릴 수 있는 자리를 하나 없앤다.
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,

  -- 어느 PC 가 올렸는지. 판정에 쓴다 - 올린 PC 는 자기가 올린 것을 다시
  -- 자기 클립보드에 붙이지 않아야 한다(그러면 되울림이 된다). 사람이 읽는
  -- 이름이기도 해서 호스트 이름을 그대로 쓴다.
  device      text not null,

  kind        text not null check (kind in ('text', 'image')),

  -- kind='text' 면 본문이 여기 그대로 들어온다. 텍스트를 Storage 에 넣으면
  -- 왕복이 두 번이 되고, 클립보드 텍스트는 대개 몇 백 바이트다.
  body        text,

  -- kind='image' 면 Storage('clip' 버킷) 안의 경로. 경로는 계정/기기마다
  -- 하나로 고정하고 덮어쓴다 (아래 주석 참고) - 그래서 여기 같은 값이
  -- 여러 행에 반복된다.
  storage_path text,

  bytes       bigint not null default 0,
  created_at  timestamptz not null default now(),

  -- 둘 중 맞는 칸이 채워져 있는지 스키마가 지킨다. 한쪽이 비어 있으면
  -- 받는 쪽은 "새 항목이 왔는데 내용이 없다"는 상태가 되고, 그건 로그로
  -- 원인을 가릴 수 없는 종류의 고장이다.
  constraint clip_items_payload check (
    (kind = 'text'  and body is not null) or
    (kind = 'image' and storage_path is not null)
  )
);

-- 받는 쪽은 언제나 "내 것 중 가장 새 것 하나"만 읽는다.
create index clip_items_user_newest on clip_items (user_id, id desc);

alter table clip_items enable row level security;

-- ============================================================
-- RLS - 자기 줄만
-- ============================================================
-- 조직·팀 단위 정책을 절대 넣지 말 것. 같은 조직 사람이 내 클립보드를 읽는 것은
-- 내 화면을 들여다보는 것과 같다.

create policy "own_clip_select"
  on clip_items for select
  to authenticated
  using (user_id = auth.uid());

create policy "own_clip_insert"
  on clip_items for insert
  to authenticated
  with check (user_id = auth.uid());

-- 올린 쪽이 지난 것을 지운다 (아래 prune_clip_items).
create policy "own_clip_delete"
  on clip_items for delete
  to authenticated
  using (user_id = auth.uid());

-- update 정책은 없다. 클립보드 항목은 고쳐 쓰는 물건이 아니다.

-- ============================================================
-- 지난 항목 지우기
-- ============================================================
-- 클립보드는 "가장 새 것"만 의미가 있는데, 행을 안 지우면 영원히 쌓인다.
-- 새로 올린 것보다 오래된 자기 행을 지우고 지운 개수를 돌려준다.
-- 클라이언트가 DELETE 필터를 직접 쓰지 않고 이걸 부르는 이유는, 필터를
-- 틀리게 쓰면(예: user_id 를 빼먹으면) PostgREST 가 통째 삭제로 보고
-- 거절하거나 - 더 나쁘게는 - 의도보다 많이 지우기 때문이다.
create or replace function prune_clip_items(p_keep_id bigint)
returns integer
language plpgsql
security invoker          -- 호출자 권한 = 위 RLS 가 그대로 적용된다
as $$
declare
  v_deleted integer;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  delete from clip_items
   where user_id = auth.uid()
     and id < p_keep_id;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- ============================================================
-- Storage - 'clip' 버킷
-- ============================================================
-- 비공개 버킷. 읽기도 사용자 JWT 로만 된다.
insert into storage.buckets (id, name, public)
values ('clip', 'clip', false)
on conflict (id) do nothing;

-- 경로는 반드시 '<user_id>/...' 로 시작한다. 아래 정책이 그 첫 칸을
-- auth.uid() 와 맞춰 보는 것으로 남의 파일을 막는다.
--
-- 기기마다 파일 하나('<user_id>/<device>.png')를 덮어쓴다. 올릴 때마다 새
-- 이름을 만들면 행을 지워도 파일은 남아 버킷이 끝없이 커지고, 그 고아 파일을
-- 지우려면 지우기 전에 경로를 먼저 읽어 와야 한다. 덮어쓰면 파일 수가
-- 기기 수로 묶여서 청소할 것이 아예 생기지 않는다.
--
-- 덮어쓰기의 대가: A 가 연달아 두 장을 올리면 B 가 첫 장을 내려받는 중에
-- 내용이 두 번째 장으로 바뀔 수 있다. B 는 늘 "가장 새 행"만 보고 그 행이
-- 가리키는 파일을 받으므로, 이 경우 B 가 얻는 것은 더 새 그림이다. 틀린
-- 그림이 아니라 앞선 그림을 건너뛴 것이고, 다음 폴링에서 맞춰진다.

create policy "own_clip_object_select"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'clip' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "own_clip_object_insert"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'clip' and (storage.foldername(name))[1] = auth.uid()::text);

-- x-upsert 로 덮어쓰려면 update 도 필요하다 (같은 이름에 다시 올리는 것이
-- Storage 에서는 update 다). 이게 없으면 두 번째 캡처부터 403 이 되고,
-- 첫 장만 되는 증상으로 나타난다.
create policy "own_clip_object_update"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'clip' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'clip' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "own_clip_object_delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'clip' and (storage.foldername(name))[1] = auth.uid()::text);
