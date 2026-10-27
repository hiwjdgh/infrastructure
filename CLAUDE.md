# CLAUDE.md

Docker Compose + 컨테이너 Nginx로 서비스별 blue/green 배포를 하는 infra 저장소. 앱 코드/Dockerfile은 각 앱 저장소에 있고, 여기에는 없다. 사용법 전체는 `README.md` 참고.

## 구조 요약

- `compose.yaml` — 공용 Nginx (`platform-nginx`), 외부 네트워크 `platform-network`
- `services/compose.yaml` — 모든 서비스가 공유하는 blue/green 슬롯 템플릿 (`platform-<service>-<blue|green>`)
- `services/<service>.conf` — Bash로 `source`되는 서비스 설정: `IMAGE_REPO`, `SERVER_NAME`, `CONTAINER_PORT`, `HEALTH_PATH`
- `scripts/deploy-service.sh <service> <tag|image>` → `switch-traffic.sh`가 `nginx/routes/<service>.conf`를 생성하고 reload
- `nginx/routes/`, `runtime/` — 배포 시 생성되는 호스트 로컬 상태. 직접 수정·커밋 금지
- `environments/<APP_ENV>/<service>.env` — 앱 런타임 환경변수 (Git 제외). `APP_ENV`는 루트 `.env`, `deploy-service.sh`가 `APP_ENV_FILE`로 compose에 전달. 커밋되는 것은 `environments/<service>.env.example`만
- `examples/common/` — 모든 앱 저장소에 똑같이 복사하는 파일 (서비스명 없음)
  - `release-notes.sh`: base..head 사이 **개별 커밋 메시지**(Conventional Commits, `--no-merges`)로 다음 버전 + changelog 계산. 머지 커밋(dev 당겨오기, PR 머지)은 제외. pr-changelog / release 둘 다 이 스크립트를 쓴다 — PR에 보인 버전과 실제 릴리스 버전이 같아야 하므로 로직을 워크플로에 따로 복제하지 않는다
  - `pr-changelog`: dev·main 대상 PR 열림/커밋 추가 → 본문 마커(`<!-- changelog:start/end -->`) 사이에 changelog 갱신. dev→main이면 제목 `Release vX.Y.Z`
  - `release`: main push → `vX.Y.Z` 태그 + GitHub Release(changelog). main에 커밋하지 않는다 (CHANGELOG.md 커밋 금지 — dev/main 어긋남)
  - `branch-guard`: main 대상 PR은 `dev`, `hotfix/*`에서만 허용
  - `commit-lint.sh`: 커밋 메시지 규칙(Conventional Commits)의 단일 기준 + 한글 안내. `commit-check`(PR 단계, 필수)와 `commit-msg`(로컬 훅, 선택)가 둘 다 이 스크립트를 호출한다. 허용 타입을 바꾸면 `release-notes.sh`의 분류와 README 표도 함께 맞춘다
  - `commit-check`: dev→main을 제외한 모든 PR에서 **PR 안의 모든 비머지 커밋**을 검사 (`fixup!`/`squash!`도 차단). 위반 시 마커(`<!-- commit-convention -->`) 댓글 하나를 생성/갱신하고 수정 방법(툴별 reword + 강제 push) 안내
  - `commit-msg`: 로컬 훅, **필수**. package.json `prepare` / composer `post-install-cmd`로 자동 활성화 권장
- `examples/common/` 셸 스크립트는 GitHub Actions(`bash -eo pipefail`)와 Windows Git Bash 양쪽에서 돈다. `| head -1` 대신 `| sed -n 1p`(SIGPIPE 방지), CR 제거(`tr -d '\r'`)를 유지한다
- `examples/{php,nextjs,nestjs}/` — 스택별 파일. 세 스택의 워크플로는 서비스명과 상단 안내 주석만 다르므로 하나를 고치면 나머지도 같이 고친다
  - `ghcr`: dev/main push → `sha-<7자리>` 이미지
  - `deploy`: 수동 실행 전용. 실행 브랜치로 대상 결정 (dev → test 서버, main → prod 서버, prod는 릴리스 태그만). **AWS SSM**(GitHub OIDC → IAM 역할 → `ssm send-command`)으로 서버 스크립트 실행. SSH / self-hosted runner / 저장된 AWS 키를 쓰지 않는다. AWS 설정은 `docs/aws-ssm-deploy.md`. IAM 역할은 test/prod 분리(신뢰 정책 `repo:hiwjdgh/*:environment:<env>`, 권한은 해당 인스턴스 한 대)

## 브랜치 / 서버

- 이름 브랜치(`kim`, `lee` …) = 개발자별 **장기 유지** 작업 브랜치, 로컬 실행 (`APP_ENV=local`) → dev로 PR
- `dev` = 개발 통합 브랜치 → AWS Ubuntu 26.04 **TEST** 서버 (`APP_ENV=test`)
- `main` = 운영 브랜치, `dev` → `main` PR로만 반영 → AWS Ubuntu 26.04 **PROD** 서버 (`APP_ENV=prod`)
- **모든 PR은 merge commit으로만 머지 (squash 금지).** 이름 브랜치가 장기 유지되므로 squash하면 이력이 갈라져 다음 PR에 이전 커밋이 다시 올라오고 충돌이 나며, changelog의 재료인 개별 커밋이 하나로 합쳐진다
- **changelog의 단위는 개발자의 커밋 메시지다** (PR 제목 아님). 개발자는 수정 + 규칙에 맞는 커밋 메시지만 작성하고, PR 본문·버전·Release는 자동
- 배포는 항상 사람이 Deploy 워크플로를 수동 실행한다. 자동 배포 트리거를 추가하지 않는다.

현재 서비스: `php-frontend`, `php-backend` (포트 80), `next-frontend`, `nest-backend` (포트 3000).

## GHCR 계정 규칙 (중요)

- 현재는 **개인 계정 `hiwjdgh`** 의 GHCR(`ghcr.io/hiwjdgh/...`)을 사용하고, 추후 organization으로 이전한다.
- 계정/네임스페이스에 의존하는 값을 추가·수정할 때는 **개인 계정 값을 넣고, 같은 줄에 `# [ORG] ...` 주석으로 org 전환 시 바꿀 값을 적는다.**
  예: `IMAGE_REPO=ghcr.io/hiwjdgh/next-frontend  # [ORG] ghcr.io/<org>/next-frontend 로 변경`
- org 이름은 아직 미정이므로 `<org>` 플레이스홀더를 쓴다.
- `grep -rn "\[ORG\]" .` 로 전환 대상이 모두 잡혀야 한다. 새 파일에서도 이 표시를 빠뜨리지 않는다.
- `GHCR_USERNAME`(pull용 로그인 계정)은 org 전환 후에도 사람/머신유저 계정이다. org 이름으로 바꾸라고 쓰지 않는다.

## ALB / 도메인

- TEST, PROD 모두 AWS ALB 뒤에 있다. ALB가 HTTPS(ACM)를 종료하고 EC2 `HTTP_PORT`(기본 8080)로 HTTP 전달 → 공용 Nginx가 Host 헤더로 서비스 선택
- 도메인은 서버마다, 시스템마다 다르다. `services/<service>.conf`의 `SERVER_NAME`은 로컬용(`*.localhost`), 서버별 실제 도메인은 서버 `.env`의 `SERVER_NAME_<SERVICE>` (공백으로 여러 개). 덮어쓰기 해석은 `scripts/load-service-config.sh` 한 곳에서 한다
- 공용 Nginx: VPC 사설 대역에서 온 `X-Forwarded-For`로 실제 IP 복원(`real_ip_recursive on`), ALB의 `X-Forwarded-Proto`를 앱까지 그대로 전달, default server의 `/healthz`는 ALB 헬스 체크용
- 앱이 신뢰할 클라이언트 IP는 `X-Real-IP`. `X-Forwarded-For` 첫 값은 위조 가능

## 메모리 상한

- 우선순위: 서버 `.env`의 `MEMORY_LIMIT_<SERVICE>` (예: `MEMORY_LIMIT_NEXT_FRONTEND`) > `services/<service>.conf`의 `MEMORY_LIMIT` > `512m`. `deploy-service.sh`가 계산해 compose의 `mem_limit`/`memswap_limit`로 전달
- Node 서비스는 `.conf`의 `NODE_HEAP_PERCENT`(75)로 `NODE_OPTIONS=--max-old-space-size`를 자동 설정. 그 외 서비스는 `NODE_OPTIONS`를 unset
- blue/green 두 슬롯이 동시에 떠 있으므로 서버 메모리는 (상한 합계 × 2)로 계산한다. TEST 8GB / PROD 32GB, DB는 서버에 없음

## 런타임 버전 (고정)

- PHP **8.3.36** (`php:8.3.36-fpm-alpine`) — 운영 서버 8.3, CVE 대응으로 8.3.36 패치 버전 고정. Apache 아님
  - 이미지 하나에 php-fpm + nginx (`examples/php/docker/`). 공용 Nginx는 HTTP(80)로만 프록시한다 — 공용 Nginx에서 `fastcgi_pass`로 FPM에 직접 붙이지 않는다 (정적 파일 공유가 필요해져 blue/green 이미지 불변성이 깨짐)
  - php-fpm은 `127.0.0.1:9000`에서만 listen (다른 컨테이너에서 FastCGI 접근 차단). 워커 수 `PHP_FPM_MAX_CHILDREN`은 메모리 상한에 맞춘다
- Node **24.22.1** (`node:24.22.1-alpine`) — 운영 서버 버전과 일치해야 함
- Dockerfile 예시는 `ARG PHP_VERSION` / `ARG NODE_VERSION`으로 관리한다. `8.3`, `24`, `lts` 같은 떠다니는 태그를 쓰지 않는다. 버전을 바꾸면 Dockerfile 예시, README, 이 파일을 함께 고친다.

## 작성 규칙

- 셸 스크립트: `#!/usr/bin/env bash` + `set -euo pipefail`, 서비스명은 `^[a-z][a-z0-9-]*$` 로 검증, 동시 실행은 `flock`으로 직렬화. 기존 스크립트의 간결한 스타일을 따른다.
- `.conf` 파일은 Bash가 source 하므로 `=` 양옆에 공백 금지. 인라인 주석은 값 뒤에 공백을 두고 `#`.
- 모든 스크립트/설정은 **LF 줄바꿈**을 유지한다 (Ubuntu 호스트에서 실행됨).
- 새 서비스 추가 = `services/<name>.conf` 하나 추가 + 필요 시 `examples/`와 README 표 갱신. `services/compose.yaml`은 서비스별로 복제하지 않는다.
- README와 사용자 대상 문서는 한글로 작성한다.

## 검증

로컬 개발 환경은 Windows이므로 Bash 도구(Git Bash)로 확인한다. (`python`은 Windows 스토어 스텁이라 사용 불가)

```bash
for f in scripts/*.sh; do bash -n "$f"; done
docker run --rm -v "$(pwd -W)/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:1.27-alpine nginx -t
```

실제 배포 흐름(`init.sh` → `deploy-service.sh`)은 Ubuntu/WSL2에서 `flock`이 있어야 동작한다.
