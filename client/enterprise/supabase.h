// supabase.h - Enterprise: Supabase REST API client (WinHTTP)
#pragma once
#include "../common.h"
#include <string>
#include <vector>

// contents 표의 행 하나. 여기 담기는 것은 **검증을 통과한 행뿐이다**:
// storage_path 가 글자 그대로 org_id + "/" + file_hash + "." + ext 이고, org_id 가
// 이 PC 의 조직이고, 나머지 값도 아래 적힌 범위 안이다. 서버의
// contents_storage_path_shape 제약과 같은 모양이고 (supabase/hardening.sql), 서버가
// 지키고 있어도 여기서 따로 본다 - 제약이 적용되기 전의 서버에도 붙기 때문이다.
//
// 서버에는 쓰는 열만 달라고 한다 (FetchManifest 의 select=). filename 은 사람이
// 읽는 이름일 뿐 PC 가 쓸 데가 없고, 아무 글자나 들어오는 유일한 열이라 파서 앞에
// 가져올 이유가 없다. version 은 읽기만 하고 아무도 쓰지 않던 값이라 같이 뺐다.
struct ContentItem {
    std::wstring id;
    std::wstring storagePath;   // "<org uuid>/<file_hash>.<ext>"
    std::wstring fileHash;      // sha256, 소문자 hex 64자
    int64_t      fileSize;      // 1 .. 200 MB
    std::wstring contentType;   // "image" or "video"
    std::wstring displayPos;    // "center" or "banner"
    // 로컬 파일 이름 "<file_hash>.<ext>". 검증된 조각으로 만든다. 예전에는
    // storage_path 의 마지막 '/' 뒤를 그대로 썼는데 역슬래시는 거르지 않아서,
    // "..\..\" 가 든 경로로 enterprise_content 폴더 밖에 파일을 쓸 수 있었다.
    std::wstring localName;
};

struct ContentManifest {
    std::wstring orgId;               // 다듬은 조직 id (소문자)
    std::vector<ContentItem> items;   // 새 것부터 (created_at desc)
};

// 조직 id 를 다듬는다: 앞뒤 공백을 떼고, 8-4-4-4-12 모양의 uuid 인지 보고, 소문자로.
// 아니면 false. 이 값은 URL 에 그대로 들어가므로 (...?org_id=eq.<여기>) 이걸
// 통과한 것만 쓴다.
bool NormalizeOrgId(const std::wstring& in, std::wstring& out);

// 서버에 그 조직이 있는가 (public.org_exists, supabase/hardening.sql).
//   1 = 있다,  0 = 없다,  -1 = 알 수 없다
// -1 은 서버에 닿지 못했을 때와 **함수가 아직 서버에 없을 때** (HTTP 404, PGRST202)
// 둘 다다. 뒤쪽을 "없다" 로 읽으면 SQL 을 돌리기 전의 서버에서는 어떤 조직도
// 등록할 수 없게 된다.
int CheckOrgExists(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                   const std::wstring& orgId);

// Fetch content manifest from Supabase (active 인 행만, 검증을 통과한 것만).
// false = 요청이 실패했다. true 이고 items 가 비었으면 "송출 중인 것이 없다" 이다.
bool FetchManifest(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                   const std::wstring& orgId, ContentManifest& outManifest);

// Download a file from Supabase Storage.
// storagePath 는 "<org uuid>/<sha256>.<ext>" 모양이어야 하고, 받은 파일의 SHA-256 이
// 그 이름과 같을 때만 localPath 에 놓인다.
bool DownloadContent(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                     const std::wstring& storagePath, const std::wstring& localPath);

// Get enterprise content directory
std::wstring GetEnterpriseContentDir();

// 그 경로가 enterprise_content 폴더 안의 파일인가 (대소문자 무시, 접두어 비교).
// 화면 이미지 경로의 주인을 가르는 기준이다: 이 안을 가리키면 동기화가 넣은
// 것이고, 밖이면 사용자가 고른 것이다.
bool IsEnterpriseContentPath(const std::wstring& path);

// 동기화 한 번의 결과. bool 하나로는 "서버에 못 닿았다" 와 "닿았는데 송출 중인
// 것이 없다" 가 같은 false 였고, 그래서 관리자가 송출을 멈춰도 PC 는 실패로 알고
// 옛 그림을 계속 띄웠다.
enum class EnterpriseSync {
    RequestFailed,   // 서버에 묻지 못했다 (오프라인, HTTP 오류, 내려받기 도중 끊김). 아무것도 바꾸지 말 것
    NoContent,       // 물어봤고, 쓸 수 있는 active 콘텐츠가 없다
    Ready,           // 적어도 한 자리의 파일이 검증까지 끝나 있다
};

// 서버의 active 콘텐츠를 받아 둔다. 자리마다 받은 파일의 경로를 돌려주고,
// 그 자리에 쓸 것이 없으면 빈 문자열이다. RequestFailed 면 둘 다 빈 값이고
// 그건 "없다" 가 아니라 "모른다" 다.
// 네트워크를 타고 파일 해시를 재므로 오래 걸릴 수 있다. 여러 스레드에서 불러도
// 되지만 한 번에 하나씩 돈다.
EnterpriseSync SyncEnterpriseContentEx(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                                       const std::wstring& orgId,
                                       std::wstring& outCenter, std::wstring& outBanner);

// Check and download new content if available (true = EnterpriseSync::Ready)
bool SyncEnterpriseContent(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                           const std::wstring& orgId);

// After sync, get paths for center/banner content (마지막으로 끝난 동기화의 결과)
std::wstring GetEnterpriseCenterPath();
std::wstring GetEnterpriseBannerPath();
