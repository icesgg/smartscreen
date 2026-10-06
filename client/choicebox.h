// choicebox.h - 단추를 정해 쓰는 MessageBox
//
// MessageBoxW 는 정해진 단추 묶음(예/아니요/취소 ...)만 띄워서 넷째 단추를 둘 수 없다.
// TaskDialog 는 comctl32 v6 매니페스트가 있어야 하는데 이 exe 에는 매니페스트가 없다 -
// 가져다 쓰기만 해도 시작할 때 진입점을 못 찾아 프로그램이 아예 뜨지 않는다.
// 그래서 같은 모양을 직접 만든다: 왼쪽 위 아이콘, 흰 글 칸, 회색 띠에 오른쪽으로 붙은 단추.
//
// 단추가 정해진 묶음으로 충분한 곳은 그대로 MessageBoxW 를 쓴다. 이건 그걸로 안 되는 곳만.
#pragma once
#include <windows.h>

enum class ChoiceIcon { None, Question, Warning, Information, Error };

struct ChoiceButton {
    int            id;     // 눌렀을 때 돌려줄 값. IDYES 같은 표준 값도, 따로 정한 값도 된다 (0 은 안 된다)
    const wchar_t* label;  // "예(&Y)" - & 뒤 글자가 단축키 (Alt+Y, 단추에 초점이 있으면 Y 만)
    bool           apart;  // true: 단추 줄 왼쪽 끝에 따로 둔다. 되돌릴 수 없는 일을 손이 가는 자리에서 떼어 놓는다
};

// 고른 단추의 id 를 돌려준다. 띄우지 못했으면 0 - 부르는 쪽이 MessageBoxW 로 대신할 수 있다.
//  - Enter 는 defaultId (Tab 으로 초점을 옮겼으면 그 단추), Esc 와 제목 줄의 X 는 cancelId.
//    cancelId 가 0 이면 Esc 와 X 가 막힌다 (MB_YESNO 처럼). IDCANCEL 단추를 두면 cancelId 도 IDCANCEL 로.
//  - Tab 순서는 화면의 왼쪽에서 오른쪽이다 (apart 단추가 먼저).
//  - 창은 MessageBoxW 처럼 owner 가 있는 모니터의 작업 영역 가운데에 뜨고, 닫힐 때까지 owner 가 막힌다.
int ChoiceBox(HWND owner, const wchar_t* text, const wchar_t* title, ChoiceIcon icon,
              const ChoiceButton* buttons, int count, int defaultId, int cancelId);
