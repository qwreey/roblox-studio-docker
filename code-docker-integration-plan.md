# code-docker 연결 계획 (2026-08-13, 설계안 — 아직 code-docker 쪽엔 미적용)

이 문서는 이 repo(`roblox-studio-docker`)를 별도 프로젝트인 `~/Projects/code-docker`
안에 서비스로 편입시키는 **구체적인 방법**을 다룬다. "왜" 편입하려는지(MCP 브리지,
HTTPService 라우팅, VNC 격리)는 이미 `CLAUDE.md`의 "Future code-docker integration"
절에 정리돼 있으므로 여기서 반복하지 않는다 — 이 문서는 순전히 "어떻게"에 대한 것.

**범위 안내**: 이 repo가 "standalone" 이어야 한다는 원칙(`CLAUDE.md` 최상단)은 변하지
않는다 — 아래 계획은 이 repo의 기존 `docker-compose.yml`을 단 한 줄도 건드리지 않고,
그 위에 얹는 *선택적* 오버레이 파일(`roblox-studio-code-docker.yml`, 이미 이 커밋에
추가됨)로만 이루어진다. `docker-compose.yml` 단독 실행은 지금까지와 완전히 동일하게
계속 동작한다.

code-docker 쪽 변경(아래 "code-docker 쪽에서 할 일" 절)은 **아직 실제로 적용되지
않았다** — 이 문서와 이 repo의 `roblox-studio-code-docker.yml`까지만 이번 세션에서
준비됐고, code-docker 자신의 파일을 고치는 건 별도 세션에서 code-docker repo를 직접
열어 진행해야 한다 (이 repo가 code-docker를 건드리지 않는다는 원칙과, 실제로 이
docker-compose.yml을 옆에 두고 작업하려면 code-docker 쪽 컨텍스트가 필요하다는 두
가지 이유 모두에서).

## 핵심 메커니즘: Compose `include:` 체인

사용자(오너)가 제안한 방식 그대로다 — Docker Compose의 `include:` 최상위 키를 체인으로
엮어서, **code-docker의 `docker-compose.yml` 자체는 업스트림 그대로 두면서도**
런타임에 이 repo의 서비스 정의를 끌어와 병합한다. `git pull`로 code-docker를
업데이트해도 로컬 커스터마이징과 절대 충돌하지 않는다는 게 핵심 장점 — 파일을
직접 고치는 게 아니라 "무엇을 추가로 include할지"만 지역 설정(`.env`)으로 가리키기
때문.

실제로 동작하는지 직접 검증했다 (Docker Compose 5.4.0, 3단계 include 체인 +
env var 기본값 + cross-repo 상대경로까지 전부 실제 `docker compose config`로 확인,
아래 "검증 방법" 절 참고). 확인된 동작:

1. **`include: - path: ${EXTRA_INCLUDE:-empty-extra-include.yml}`** — 최상위
   `include:`의 `path:`도 다른 필드와 똑같이 env var 보간이 적용된다. `EXTRA_INCLUDE`가
   `.env`에 없으면 `empty-extra-include.yml`(0바이트 빈 파일)을 include하는데, **빈
   파일을 include해도 에러 없이 그냥 아무것도 안 가져온다** — 이게 "아무것도 안 켠"
   기본 상태를 만드는 방법이다.
2. **체인이 여러 단계(code-docker → extra-include.yml → roblox-studio-code-docker.yml
   → roblox-studio-docker/docker-compose.yml)를 거쳐도 문제없이 전부 하나의 프로젝트로
   병합된다.** 오너가 "순환"이라 부른 부분 — `roblox-studio-code-docker.yml`이
   `docker-compose.yml`을 다시 include하는 것 — 은 실제로는 순환 참조가 아니다.
   서로 다른 경로에 있는, 우연히 같은 파일 이름(`docker-compose.yml`)을 가진 두
   개의 별개 파일일 뿐이라 Compose가 경로로 구분해서 문제없이 처리한다(직접 확인함).
3. **`networks:` 병합 규칙이 이 설계에 유리하게 동작한다**: 이 repo의
   `docker-compose.yml`은 `studio` 서비스에 `networks:`를 아예 선언하지 않는다(암시적
   기본 네트워크에 의존). 오버레이 파일(`roblox-studio-code-docker.yml`)이 명시적으로
   `networks: [code-docker-internal]`을 주면, **암시적 기본 네트워크는 조용히
   사라지고 `code-docker-internal`만 남는다** — 원치 않는 `_default` 브리지 네트워크가
   같이 붙는 부작용이 없다(직접 확인함). 반대로 두 파일 모두 명시적 `networks:`
   목록을 가지고 있으면 합집합으로 병합된다 — 나중에 이 repo의 `docker-compose.yml`이
   자기 네트워크를 명시적으로 갖게 되더라도 이 메커니즘 자체는 계속 성립한다.
4. **`ports:`는 (network와 달리) 파일 간에 합집합으로 병합되고, 오버레이에서
   "빼는" 건 기본적으로 안 된다** — 이 repo의 `docker-compose.yml`이 이미
   `5900:5900`/`8787:8787`을 직접 게시하고 있으므로, 오버레이가 아무 것도 안 하면
   code-docker와 병행 실행해도 두 포트는 계속 호스트에 직접 열린다. 이건 Compose
   Spec의 `!reset` YAML 태그로 명시적으로 초기화할 수 있다 (`ports: !reset []`) —
   직접 검증 완료. 지금 오버레이 파일에서는 **의도적으로 이걸 안 쓴다** (아래 "Phase
   1 vs Phase 2" 참고) — 나중에 VNC를 router 경유로만 열고 싶어지면 이 한 줄을
   추가하면 된다.

## Phase 1 — 지금 준비됨, code-docker 쪽 코드 변경 없이 동작

**목표**: `studio` 컨테이너를 `code-docker-internal` 네트워크에 붙여서, code-docker
쪽 에이전트 컨테이너가 나중에 Studio MCP 브리지나 HTTPService를 호출할 수 있는
"네트워크 경로"만 미리 열어둔다. **그 경로를 실제로 쓰는 배선(에이전트가 실제로
브리지를 호출하도록 MCP 설정을 넣는 것 등)은 여전히 별도 작업으로 남는다** —
`CLAUDE.md`에 이미 "명시적으로 미룬 것"으로 기록돼 있는 항목이고, 이 문서도 그 범위를
넘지 않는다.

이 repo에 이미 추가됨: **`roblox-studio-code-docker.yml`** (repo 루트, 커밋에 포함).
내용 요약:
```yaml
include:
  - path: docker-compose.yml
services:
  studio:
    networks:
      - code-docker-internal
```
VNC/MCP 포트는 손대지 않는다 — 지금 이 repo를 단독으로 띄울 때와 완전히 동일하게
호스트에 직접 게시된다. 즉 code-docker와 나란히 띄워도 지금 당장은 **VNC 격리
효과가 없다** (round-trip으로 host에 그대로 노출) — 이건 의도적으로 남겨둔 제약이지
빠뜨린 게 아니다. 아래 Phase 2 참고.

## Phase 2 — 구현 완료 (2026-08-13/14)

`roblox-studio-code-docker.yml`에 실제로 반영됨. 원래 그리던 최종 그림(VNC를
`code-docker-internal`이 아니라 **별도의 전용 `internal: true` 네트워크** -
에이전트 컨테이너는 못 붙고 `code-docker-router`만 같이 붙는 - 위에 놓고, 사람은
router를 거쳐서만 VNC에 닿게 하는 것) 그대로 구현됨.

**당초 예상과 달랐던 점**: code-docker 쪽에서 실제로 실측 검증해보니(코드
읽기가 아니라 진짜 컨테이너 띄워서 확인 - code-docker 쪽
`.claude/backlog/roblox-studio-vnc-isolation-plan.md`의 "실측 검증 결과" 절
참고), 아래 두 가정이 둘 다 틀렸었다:
1. ~~"`forwards:`의 `target_host`가 `code-docker-internal`에서만 resolve
   가능해야 한다"~~ - 코드(`firewall.default.sh`)는 애초에 그런 제약이 없었다.
   주석 문구는 "지금까지 router가 다른 네트워크에 붙어본 적이 없어서 사실상
   그랬다"는 배포 현실 서술이었을 뿐. router가 새 네트워크에 붙기만 하면
   `getent hosts`가 Docker 임베디드 DNS로 알아서 resolve한다 - **code-docker
   쪽 코드 수정이 전혀 필요 없었다.**
2. ~~"`DOCKER-INTERNAL`이 이 forward 트래픽을 막는다"~~ - 오히려 반대로,
   router가 studio와 같은 브리지에 직접 붙어 있는 이 트래픽 패턴은
   호스트 레벨 `DOCKER-INTERNAL`/`FORWARD` 체인을 아예 안 거친다(실측: `nft`
   카운터가 계속 0으로 유지됨). `code-docker-netfilter-fix`의 다중 네트워크
   지원은 (harmless한 일반화라 코드는 남아있지만) 이 시나리오엔 불필요했다.
3. **진짜 막혔던 원인은 따로 있었다**: `roblox-studio-vnc`가 `internal: true`라
   Docker가 studio 쪽에 기본 게이트웨이 라우트를 아예 안 준다 - SYN은 router의
   DNAT을 타고 studio까지 도달하지만, studio가 응답을 돌려보낼 라우트가 없어서
   그냥 hang한다. 이건 이 repo 쪽에서 풀어야 하는 문제였다 - 아래 참고.

**해결책 (오너 결정, 2026-08-13)**: `studio`를 code-docker/dind와 동일한 신뢰
등급의 개발용 컨테이너로 취급한다 - Roblox Studio 자체에 HTTPService/plugin
권한이 있어 임의 아웃바운드가 가능한 컨테이너이므로, `/dev/dri` 격리 때문에
별도 컨테이너로 나눴을 뿐 네트워크 처우는 code-docker와 같게 간다. 그래서
code-docker/dind가 쓰는 것과 정확히 같은 **netinit 사이드카 패턴**(부팅 시
자기 기본 라우트를 router 쪽으로 계속 재조정하는 경량 `network_mode:
service:studio` + `NET_ADMIN` 컨테이너)을 그대로 가져다 썼다 - SNAT 방식(router가
forward 트래픽에 SNAT을 걸어 studio가 항상 router만 보게 하는 대안)은 기존
`forwards:`가 code-docker/dind에 원본 클라이언트 IP를 그대로 보여주는 동작을
바꾸는 트레이드오프라 채택 안 함.

실제로 반영된 것 (모두 이 repo 안, code-docker 쪽 변경 없음):
- `netinit/` (신규) - code-docker의 `netinit/` 서브트리를 그대로 복사한 것
  (own Dockerfile + `apply_default_route` 루프). `ROUTER_HOSTNAME`은 기본값
  `router`를 그대로 씀 - studio가 Phase 1부터 이미 `code-docker-internal`에도
  붙어 있어서, 그 네트워크에 code-docker 쪽이 이미 걸어둔 `router` 별칭이
  그대로 resolve된다 (router가 어느 인터페이스로 studio의 다음 홉을 받든 자기
  라우팅 테이블로 알아서 올바르게 처리하므로, `roblox-studio-vnc` 쪽에 별도
  별칭을 추가할 필요가 전혀 없었다 - code-docker 쪽에서 실측 확인됨).
- `roblox-studio-code-docker.yml` - `studio`에 `roblox-studio-vnc` 네트워크
  (`vnc-only` alias) 추가, `VNC_BIND_ALIAS=vnc-only`, `ports:`를
  `!override`로 MCP_PORT(8787)만 남기고 VNC_PORT(5900) 직접 게시 제거,
  `studio-netinit` 서비스 신규 추가, `code-docker-router`에 필드 병합으로
  `roblox-studio-vnc` 추가, `roblox-studio-vnc` 네트워크(`internal: true`)
  신규 정의.
- code-docker 쪽 실제 merge 결과를 `docker compose config`로 재검증함(이
  repo와 code-docker를 나란히 두고) - `studio`가 `ports: [8787]`만 갖고
  `roblox-studio-vnc`엔 `vnc-only` alias로 붙는 것, `code-docker-router`가
  `roblox-studio-vnc`를 필드 병합으로 얻는 것, `studio-netinit`이
  `network_mode: service:studio`로 올바르게 빌드/구성되는 것 전부 확인.

**2026-08-18 업데이트 — end-to-end 검증 완료, 아래는 더 이상 미해결 아님.** 실제
`docker compose up`으로 두 repo를 나란히 띄워서 끝까지 확인했다 - 자세한 내용은
바로 아래 "## 2026-08-18 — 실제 end-to-end 테스트 결과" 절 참고.

`forwards:` 항목(host_port -> `vnc-only`:5900) 추가는 컴포즈 파일이 아니라
`docker compose up` 이후 router-manager의 Net 관리 탭/API에서 런타임에 하는
것 - code-docker 쪽 `docs/router.md` 참고. 실제로 `curl -X POST
/router/api/netgate/forwards -d '{"hostPort":5900,"targetHost":"vnc-only",
"targetPort":5900}'`로 해봤고 정상 동작했다.

## 2026-08-18 — 실제 end-to-end 테스트 결과

`code-docker/extra-include.yml` (`path: ../roblox-studio-docker/roblox-studio-code-docker.yml`,
버전관리 대상 아님) → `EXTRA_INCLUDE=extra-include.yml
CODE_DOCKER_EXTRA_INTERNAL_NETWORKS=roblox-studio-vnc docker compose up -d`로
6개 컨테이너(code-docker, dind, netinit, netfilter-fix, router, studio,
studio-netinit) 전부 실제로 띄워서 확인함:

- **격리**: code-docker 컨테이너에서 `studio:5900` 연결 시도 → `Connection
  refused` (라우팅이 막힌 게 아니라 wayvnc 자체가 `vnc-only` alias IP에만
  바인딩해서 나는 fail-closed 거부 - 설계대로).
- **경로**: router의 `code-docker-external` IP:5900으로 접속 → 실제 `RFB
  003.008` 배너 수신. `studio-netinit`의 반환 라우트 수정이 실제로 동작함을
  증명.
- **netfilter-fix**: `CODE_DOCKER_EXTRA_INTERNAL_NETWORKS=roblox-studio-vnc`
  설정 시 두 네트워크 모두 watching하고 DOCKER-USER 룰 2개 정상 설치.

**테스트 중 실제로 발견해서 고친 버그**: `roblox-studio-vnc` 네트워크에
`name:`이 없어서 Compose가 `code-docker_roblox-studio-vnc`로 자동 접두사를
붙였는데, `CODE_DOCKER_EXTRA_INTERNAL_NETWORKS`는 접두사 없는 순수 이름을
기대하는 계약이라 실측 전까진 이게 조용히 안 먹혔다 - 명시적 `name:
roblox-studio-vnc` 추가로 수정 (커밋 d6d6ea4).

**MCP_PORT 관련 정정 (중요)**: 이 문서와 `CLAUDE.md`가 이전에 "MCP_PORT는
host에 그대로 게시된 채 유지된다"고 썼던 건 틀렸다 - code-docker와 통합된
상태에서 `studio`는 `code-docker-internal`/`roblox-studio-vnc` 둘 다
`internal: true`라 non-internal 네트워크가 하나도 없고, Docker는 그런
컨테이너의 host publish DNAT를 에러 없이 그냥 건너뛴다(실측: 컨테이너 IP로
직접 붙으면 8787 정상 응답, `127.0.0.1:8787`은 응답 없음). **오너 결정
(2026-08-18): 이건 고칠 필요 없음 - MCP_PORT는 애초에 host에 공개될 필요가
없고, 실제 소비 경로는 code-docker 자신의 에이전트 컨테이너가
`code-docker-internal` 위에서 `studio:8787`로 직접 붙는 것(실측 확인:
`code-docker -> studio:8787` reachable)이 맞다.** code-docker 바깥에서 MCP에
접근할 필요가 생기면 host publish를 되살리는 대신 `code-docker-router`의
netgate `forwards:`(VNC와 동일한 방식)나 Dev Proxy/App Routes로 노출하는 쪽이
"국경은 router만" 원칙과 일관됨 - `roblox-studio-code-docker.yml`의 `ports:`도
이제 `!reset []`로 아예 비워서 이 사실을 코드로도 반영했다(예전
`!override - MCP_PORT`는 어차피 아무것도 게시 못 하고 있었으므로).

## code-docker 쪽에서 할 일 — 전부 완료 (2026-08-13/14)

1~4는 code-docker 쪽 별도 세션에서 적용 완료 (`include:`/`EXTRA_INCLUDE`/
`empty-extra-include.yml`/`docs/index.md` 안내, 전부 그대로 커밋됨). 5번("Phase 2
진행 시 netgate `forwards:` 로직 확장 필요")은 **실측 결과 불필요한 것으로
판명나서 하지 않음** - 위 "Phase 2 — 구현 완료" 절 참고. code-docker 쪽에
더 이상 남은 작업 없음 - 이 문서의 나머지 미해결 항목(end-to-end 검증)은 전부
이 repo 쪽 몫.

## 검증 방법 (재현 가능한 기록)

`docker compose config`로 3단계 include 체인, env var 경로 보간, cross-repo 상대경로
(`builds/roblox-studio-docker/` 아래에서 `docker-compose.yml`을 include했을 때
build context/volume 경로가 그 위치 기준으로 올바르게 잡히는지), `networks:` 병합
규칙(암시적 기본 네트워크 대체 vs 명시적 목록끼리 합집합), `ports: !reset []`까지
전부 임시 디렉토리에서 실제로 재현해서 확인했다 (이 세션에서, `/tmp` 스크래치 아래 —
실제 repo는 전혀 건드리지 않음). 마지막으로 이 repo의 실제 `docker-compose.yml` +
`roblox-studio-code-docker.yml`을 code-docker 쪽 구조를 흉내낸 최소 mock
(`code-docker-internal` 네트워크 + `include: ${EXTRA_INCLUDE:-...}` 최상위 키만
가진 가짜 `docker-compose.yml`) 옆에 두고 풀 체인으로 `docker compose config`를
돌려서, 최종적으로 `studio` 서비스가 build context/volume 경로/환경변수를 전부
올바르게 유지한 채 `code-docker-internal` 네트워크 하나에만 붙는 걸 확인했다.

## 대안 비교: sed + 주석 마커 기반 마이그레이터

오너가 언급한 대안 — `docker-compose.yml` 안에 주석으로 "여기서부터 여기까지는
사용자가 편집 가능" 영역을 표시해두고, 업데이트 시 `sed`/셸 스크립트로 그 영역만
보존하며 나머지를 새 버전으로 갈아끼우는 마이그레이터 — 도 원리적으로는 가능하지만,
`include:` 방식과 비교하면 다음 이유로 권장하지 않는다:

- **텍스트 매칭은 YAML 파서가 아니다.** 마커 사이 들여쓰기가 어긋나거나, 사용자가
  마커 자체를 실수로 지우거나 복사하면 조용히 깨진다 — `include:`는 Compose 자체가
  파싱/검증하므로 깨지면 `docker compose config`가 바로 에러를 낸다.
- **버전 관리와 충돌한다.** 마커 방식은 결국 업스트림 파일 자체를 로컬에서 변형해
  보관하는 것이라 `git pull`/`git merge` 충돌 가능성이 남는다. `include:` 방식은
  업스트림 파일을 로컬에서 단 1바이트도 안 건드리므로 이 문제가 구조적으로 발생하지
  않는다 (이게 오너가 원래 든 이유이기도 하고, 이번 검증으로 실제로 성립하는 것도
  확인됨).
- **`include:`는 이미 Docker Compose가 공식 지원하는 기능**이라 마이그레이터
  스크립트 자체를 만들고 유지보수할 필요가 없다 — 새로 작성/디버깅해야 할 코드가
  이쪽이 훨씬 적다.

마커+마이그레이터 방식이 나은 경우가 있다면, Compose의 `include:`/병합 규칙으로
표현 불가능한 아주 세밀한 부분 편집(예: 한 서비스 정의 안의 특정 줄만 조건부로
바꾸기)이 필요할 때 정도인데, 지금 이 통합에 필요한 건 전부(네트워크 부착, 환경변수
추가, 포트 초기화) `include:`의 병합 규칙만으로 커버된다는 걸 위에서 확인했으므로,
**이 프로젝트에는 `include:` 방식을 추천한다.**
