-- SmartScreen - 폰 신원 토큰을 계정에 묶는 테이블
--
-- 목적: 폰 등록을 BLE 핸드셰이크 대신 계정으로 한다. 폰과 PC가 같은 계정으로
-- 로그인하면 양쪽이 같은 토큰을 내려받고, 그걸로 서로를 알아본다.
-- 설계 배경은 docs/IDENTIFICATION.md 와 docs/PROXIMITY.md 를 참고.
--
-- 적용: Supabase 대시보드 > SQL Editor 에 붙여넣고 실행.

-- ============================================================
-- device_tokens
-- ============================================================
-- 계정당 폰 하나. user_id 를 기본키로 둬서 그 제약을 스키마가 지킨다.
-- 폰을 바꾸면 같은 줄을 덮어쓴다 (upsert).
create table device_tokens (
  user_id    uuid primary key references auth.users(id) on delete cascade,

  -- 폰이 GATT 특성 7A1C0021 로 내주는 16바이트 값을 대문자 hex 32자리로.
  -- 이 값이 곧 폰의 신원이다. 아는 사람은 자기 기기로 같은 값을 흘려
  -- 남의 PC 화면을 계속 열어둘 수 있으므로, 아래 RLS 를 반드시 켠 채로 쓴다.
  token      text not null check (token ~ '^[0-9A-F]{32}$'),

  -- 사용자가 알아보기 위한 이름. "내 아이폰" 같은 것. 판정에는 안 쓴다.
  label      text,
  platform   text not null default 'ios' check (platform in ('ios', 'android')),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table device_tokens enable row level security;

-- ============================================================
-- RLS - 자기 줄만
-- ============================================================
-- 이 테이블에는 "조직 멤버면 볼 수 있다" 류의 정책을 절대 넣지 말 것.
-- 같은 조직 사람이 내 토큰을 읽으면 내 화면을 열어둘 수 있다.
-- contents 테이블과 성격이 다르다: 저건 공유하라고 있는 것이고 이건 비밀이다.

create policy "own_device_token_select"
  on device_tokens for select
  to authenticated
  using (user_id = auth.uid());

create policy "own_device_token_insert"
  on device_tokens for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "own_device_token_update"
  on device_tokens for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "own_device_token_delete"
  on device_tokens for delete
  to authenticated
  using (user_id = auth.uid());

-- PC 는 select 만 쓴다. 쓰기는 폰만 한다.
-- anon 역할에는 아무 정책도 주지 않는다 = 로그인 없이는 한 줄도 못 읽는다.

-- ============================================================
-- updated_at 자동 갱신 (schema.sql 의 함수를 재사용)
-- ============================================================
create trigger device_tokens_updated_at
  before update on device_tokens
  for each row execute function update_updated_at();

-- ============================================================
-- 폰 앱이 로그인 직후 한 번 부르는 함수
-- ============================================================
-- 이미 줄이 있으면 그 토큰을 돌려주고, 없으면 넘겨받은 값으로 만든다.
--
-- 이게 있어야 앱을 지웠다 다시 깔아도 등록이 유지된다. 지금은 토큰이
-- UserDefaults 에만 있어서 재설치하면 새 값이 생기고, 그 폰을 등록해 둔
-- 모든 PC 가 한꺼번에 못 알아보게 된다. 서버가 원본을 들고 있으면
-- 재설치한 앱이 옛 토큰을 도로 받아 간다.
create or replace function claim_device_token(p_token text, p_platform text default 'ios')
returns text
language plpgsql
security invoker          -- 호출자 권한으로 돈다 = 위 RLS 가 그대로 적용된다
as $$
declare
  v_existing text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select token into v_existing from device_tokens where user_id = auth.uid();
  if v_existing is not null then
    return v_existing;     -- 재설치: 서버에 있던 것을 그대로 쓴다
  end if;

  insert into device_tokens (user_id, token, platform)
  values (auth.uid(), upper(p_token), p_platform);
  return upper(p_token);
end;
$$;
