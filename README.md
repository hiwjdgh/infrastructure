# Platform Infrastructure — PHP / Next.js / Nest.js Blue/Green 배포

이 저장소는 공용 Docker 네트워크, 컨테이너 Nginx, 서비스별 blue/green 전환을 관리합니다. 애플리케이션 코드와 Dockerfile은 **포함하지 않으며**, 각 서비스는 별도 저장소에서 GHCR 이미지를 빌드·푸시합니다.

> **처음 구성한다면 [docs/initial-setup.md](docs/initial-setup.md)의 순서를 따라 진행하세요.** (GitHub → AWS → 서버 → ALB → 앱 저장소 → 첫 배포 → 개발자 온보딩)

| 서비스 | 설정 파일 | 이미지 (현재: 개인 계정) | 포트 | 로컬 호스트명 |
|---|---|---|---|---|
| php-frontend | `services/php-frontend.conf` | `ghcr.io/hiwjdgh/php-frontend` | 80 | `frontend.localhost` |
| php-backend | `services/php-backend.conf` | `ghcr.io/hiwjdgh/php-backend` | 80 | `backend.localhost` |
| next-frontend | `services/next-frontend.conf` | `ghcr.io/hiwjdgh/next-frontend` | 3000 | `next.localhost` |
| nest-backend | `services/nest-backend.conf` | `ghcr.io/hiwjdgh/nest-backend` | 3000 | `nest.localhost` |

## 0. GHCR 계정: 개인 → Organization 전환

현재 GHCR은 **개인 계정(`hiwjdgh`)** 기준으로 설정되어 있습니다. organization으로 옮길 때 바꿔야 하는 줄에는 모두 같은 줄에 `# [ORG]` 주석이 붙어 있습니다. 아래 명령으로 전부 찾을 수 있습니다.

```bash
grep -rn "\[ORG\]" .
```

전환 시 체크리스트:

1. `services/*.conf`의 `IMAGE_REPO`를 `ghcr.io/<org>/<서비스명>`으로 변경
2. 각 앱 저장소의 `ghcr.yml`, `deploy.yml`에서 `IMAGE`를 `ghcr.io/<org>/<서비스명>`으로 변경
3. org **Settings → Packages**에서 Actions의 패키지 생성/쓰기를 허용하고, 각 패키지의 **Manage Actions access**에 해당 저장소를 Write 권한으로 추가
4. org **Settings → Actions → General → Workflow permissions**가 read-only로 제한되어 있으면 release.yml이 태그를 만들지 못합니다. org 정책을 확인하세요.
5. (선택) 공통 배포 variables는 org 레벨로, main 브랜치 보호 규칙은 org Rulesets로 옮겨 모든 저장소에 일괄 적용
5-1. **AWS IAM 배포 역할 2개(`github-deploy-test`, `github-deploy-prod`)의 신뢰 정책**에서 `repo:hiwjdgh/*`를 `repo:<org>/*`로 변경 ([docs/aws-ssm-deploy.md](docs/aws-ssm-deploy.md) 참고)
6. 서버의 `.env`에 있는 `GHCR_USERNAME`은 **org 이름이 아니라 사람(또는 머신 유저) 계정**을 유지합니다. 그 계정이 org 패키지 read 권한을 가져야 하고, org에 SAML SSO가 켜져 있다면 PAT를 org에 대해 SSO Authorize 해야 합니다.
7. **주의:** 저장소를 org로 transfer 해도 개인 네임스페이스의 GHCR 패키지는 **자동으로 옮겨지지 않습니다.** 전환 후 org 네임스페이스로 이미지를 다시 빌드·푸시한 다음 배포하세요. (`deploy-service.sh`에 태그만 넘기면 `IMAGE_REPO`가 사용되므로 1번을 먼저 바꿔야 합니다.)

## 1. 요구사항

- Ubuntu / WSL2, Docker Engine, Docker Compose 플러그인, Git, `flock` (`util-linux`), Bash
- 비공개 GHCR 이미지 pull용 PAT classic (`read:packages`)
- 각 이미지는 컨테이너 안에서 **HTTP를 서빙**해야 합니다.
  - PHP: 80 포트, **`php:8.3.36-fpm-alpine` + 컨테이너 내부 nginx** (CVE 대응으로 8.3.36 고정). 아래 "PHP 이미지 구조" 참고
  - Next.js / Nest.js: 3000 포트, `0.0.0.0` 바인딩, **`node:24.22.1-alpine`** (운영 서버 버전과 동일하게 고정)
- 헬스 체크 경로(`HEALTH_PATH`, 기본 `/`)가 HTTP 2xx를 반환해야 합니다. 실제 앱에서는 `/health` 같은 전용 경로를 만들고 `.conf`에서 바꾸는 것을 권장합니다.

## 2. 체크아웃과 초기화

```bash
mkdir -p ~/platform
cd ~/platform
git clone git@github.com:hiwjdgh/infrastructure.git   # [ORG] git@github.com:<org>/infrastructure.git
cd infrastructure
cp .env.example .env        # APP_ENV(local|test|prod), GHCR_USERNAME / GHCR_TOKEN 입력
./scripts/ghcr-login.sh     # 서버를 GHCR에 로그인
./scripts/init.sh
```

기본 포트는 다른 로컬 웹 서버와 충돌하지 않도록 **8080**입니다.

```bash
curl -I http://localhost:8080
```

서비스를 배포하기 전에는 `404`가 정상입니다.

## 3. 브랜치 전략과 앱 저장소 GitHub Actions 템플릿

### 브랜치 / 서버

| 브랜치 | 역할 | 실행 / 배포 대상 | 배포 단위 |
|---|---|---|---|
| 이름 브랜치 (`kim`, `lee` …) | 개발자별 **계속 사용하는** 작업 브랜치. 로컬에서 개발·커밋·push 후 dev로 PR | 개발자 **로컬** (`APP_ENV=local`) | — |
| `dev` | 통합 브랜치. 이름 브랜치 PR이 모이는 곳 | **TEST** 서버 (AWS Ubuntu 26.04, `APP_ENV=test`) | 커밋 (`sha-xxxxxxx`) |
| `main` | 운영 브랜치. TEST에서 확인 후 **`dev` → `main` PR로만** 반영 | **PROD** 서버 (AWS Ubuntu 26.04, `APP_ENV=prod`) | 릴리스 태그 (`vX.Y.Z`) |
| `hotfix/*` | 운영 긴급 수정. `main`에서 분기 → `main`으로 PR → 머지 후 `main` → `dev` 역머지 PR | — | — |

```
이름 브랜치 ──PR──▶ dev          [pr-changelog] PR 본문에 "이 PR 의 변경 내용" 자동 작성 (커밋 메시지 기준)
(로컬 개발,          │  └─push──▶ [ghcr] sha 이미지 빌드
 커밋 메시지 규칙)   │                └─▶ (버튼) Deploy @dev  ──▶ TEST 서버에서 확인
                     │
                     └──PR──▶ main     [pr-changelog] PR 제목 "Release vX.Y.Z" + 본문에 dev 에 쌓인 전체 changelog
                              └─머지─▶ main ──push──▶ [ghcr] sha 이미지 빌드
                                               └──▶ [release] vX.Y.Z 태그 + GitHub Release(changelog)
                                                        └─▶ (버튼) Deploy @main ──▶ PROD 서버
```

**모든 PR은 "Create a merge commit"으로만 머지합니다 (squash 금지).** 이유는 두 가지입니다.
- 이름 브랜치를 계속 쓰기 때문입니다. squash로 머지하면 이름 브랜치의 커밋이 dev에 반영되지 않은 것으로 남아서, 다음 PR에 이미 머지한 커밋이 다시 올라오고 dev를 당겨올 때 충돌이 납니다.
- changelog가 개별 커밋 메시지로 만들어지기 때문입니다. squash하면 커밋이 하나로 합쳐져 changelog가 사라집니다.

개발자는 이름 브랜치에서 작업을 시작하기 전에 dev를 당겨오세요 (`git pull origin dev` 또는 툴의 "dev 병합").

배포는 **자동으로 실행되지 않습니다.** Actions → Deploy → **Run workflow**에서 "Use workflow from"으로 고른 브랜치에 따라 대상 서버가 정해집니다.

### Changelog / 버전 자동화

**개발자가 할 일은 코드 수정과 규칙에 맞는 커밋 메시지 작성뿐입니다.** 나머지는 자동입니다.

1. 개발자는 이름 브랜치에 커밋합니다. **커밋 메시지 = changelog 한 줄**입니다: `feat(auth): 소셜 로그인 UI`, `fix: 로그인 버튼 정렬`
2. 이름 브랜치 → dev PR을 열면 `pr-changelog.yml`이 **PR 본문에 그 PR의 변경 내용을 자동으로 작성**합니다. 커밋을 추가로 push하면 갱신됩니다.
3. dev에는 머지된 커밋이 계속 쌓입니다.
4. dev → main PR을 열면 **PR 제목이 `Release vX.Y.Z`로, 본문에 dev에 쌓인 전체 changelog가 자동으로 작성**됩니다.
5. 머지하면 `release.yml`이 같은 내용으로 **`vX.Y.Z` 태그와 GitHub Release**를 만듭니다. 저장소의 **Releases 페이지가 누적 changelog**가 됩니다.

PR 본문 예시:

```markdown
# 이름 브랜치(kim) → dev
## 📝 이 PR 의 변경 내용
> 커밋 3개 · 버전 영향: minor
### ✨ 기능 추가
- **auth:** 소셜 로그인 UI (a01d59a · 김정호)
- **auth:** 카카오 로그인 연동 (a2ded6c · 김정호)
### 🐛 버그 수정
- 로그인 버튼 정렬 (b882cfb · 김정호)

# dev → main
## 🚀 v1.1.0 릴리스 예정
> v1.0.0 → **v1.1.0** (minor) · 커밋 5개 · 머지하면 `v1.1.0` 태그와 GitHub Release 가 자동 생성됩니다.
### ✨ 기능 추가
- **auth:** 소셜 로그인 UI (a01d59a · 김정호)
- **auth:** 카카오 로그인 연동 (a2ded6c · 김정호)
- 알림 기능 (775c774 · 이영희)
### 🐛 버그 수정
- 로그인 버튼 정렬 (b882cfb · 김정호)
### 🔧 기타
- 알림 API 문서 (9588408 · 이영희)
```

| 커밋 메시지 | changelog 섹션 | 버전 |
|---|---|---|
| `feat!: ...` (타입 뒤 `!`) 또는 본문에 `BREAKING CHANGE: ...` | ⚠️ 호환성 깨짐 | **major** (1.2.3 → 2.0.0) |
| `feat: ...` | ✨ 기능 추가 | **minor** (1.2.3 → 1.3.0) |
| `fix: ...` | 🐛 버그 수정 | patch (1.2.3 → 1.2.4) |
| `perf: ...` | ⚡ 성능 개선 | patch |
| 그 외 (`chore:`, `refactor:`, `docs:`, 형식 없음 등) | 🔧 기타 | patch |

- 첫 릴리스는 `v0.0.1` 또는 `v0.1.0`부터 시작합니다. 1.0.0부터 시작하려면 main에 `v1.0.0` 태그를 직접 하나 만들어 두세요.
- PR 본문에서 `<!-- changelog:start -->` ~ `<!-- changelog:end -->` 사이만 자동으로 덮어씁니다. 그 밖에 적은 QA 메모 등은 유지됩니다.
- PR 제목은 자유입니다. 단 dev → main PR의 제목은 `Release vX.Y.Z`로 자동 설정됩니다.
- dev를 당겨올 때 생기는 머지 커밋이나 PR 머지 커밋은 changelog에서 제외됩니다.
- 핫픽스는 머지 즉시 patch 릴리스(예: v1.1.1)가 되고, 다음 정기 릴리스 changelog에 중복으로 나오지 않습니다.
- changelog는 main에 파일(CHANGELOG.md)로 커밋하지 않습니다. 커밋하면 dev와 main이 매번 어긋나서 역머지가 필요해지기 때문입니다.

### 커밋 메시지 규칙 강제

커밋 메시지가 그대로 changelog가 되므로 **모든 커밋**이 규칙을 지켜야 합니다. 개발자마다 쓰는 Git 툴(SourceTree, VS Code, IntelliJ, GitHub Desktop, CLI 등)과 상관없이 두 단계로 검사하며, 규칙은 `commit-lint.sh` 한 곳에서만 관리합니다.

| 단계 | 방식 | 강제력 | 위반 시 |
|---|---|---|---|
| **① 커밋할 때 (필수)** | `.githooks/commit-msg` 로컬 훅 | 훅이 켜져 있어야 동작 (설치 시 자동 활성화 권장) | **커밋 자체가 거부**되고 툴 화면에 규칙 안내 출력 → 메시지만 고쳐서 다시 커밋 |
| **② PR (최종 관문)** | `commit-check.yml`이 PR 안의 모든 커밋 검사 | **우회 불가** (툴 무관) | 위반 커밋 목록 + 수정 방법 안내 댓글, 머지 차단. 고쳐서 강제 push하면 자동 재검사, 댓글이 ✅로 바뀜 |

①에서 막으면 메시지만 다시 쓰면 되지만, ②에서 걸리면 **이미 push한 커밋의 메시지를 수정하고 강제 push**해야 해서 번거롭습니다. 그래서 로컬 훅을 반드시 켜두세요.

| PR | ② 검사 대상 |
|---|---|
| 이름 브랜치 → `dev` | PR 안의 모든 커밋 (머지 커밋 제외) |
| `hotfix/*` → `main` | PR 안의 모든 커밋 |
| `main` → `dev` (역머지) | PR 안의 모든 커밋 (보통 이미 검사된 핫픽스 커밋) |
| `dev` → `main` | 검사 안 함 (dev에 들어올 때 이미 검사됨) |

로컬 훅 활성화 — 앱 저장소에 아래를 추가해두면 **의존성 설치(`npm install` / `composer install`) 때 자동으로 켜집니다.** 개발자가 따로 할 일이 없습니다.

```jsonc
// package.json (Next.js / Nest.js)
"scripts": { "prepare": "git config core.hooksPath .githooks || true" }

// composer.json (PHP)
"scripts": { "post-install-cmd": ["git config core.hooksPath .githooks || true"] }
```

수동으로 켜려면 clone 후 한 번: `git config core.hooksPath .githooks`

- 대부분의 GUI 툴(SourceTree, VS Code, IntelliJ, GitHub Desktop, GitKraken)은 git 훅을 실행합니다. Windows에서는 Git for Windows의 bash로 실행됩니다.
- `Merge ...`, `Revert "..."`처럼 Git/GitHub가 자동으로 만드는 메시지는 허용됩니다. `fixup!` / `squash!` 커밋은 로컬에서는 허용되지만, PR에 올리기 전에 정리해야 합니다 (②에서 차단).
- 규칙 안내만 보려면: `bash .github/scripts/commit-lint.sh --guide`

이미 push한 커밋 메시지를 고치는 방법 (②에서 걸렸을 때, PR 댓글에도 안내됨):
- IntelliJ / WebStorm / PhpStorm: Git 로그에서 커밋 우클릭 → *Edit Commit Message* → *Force Push*
- SourceTree: 수정할 커밋의 부모 우클릭 → *Rebase children … interactively* → *Edit message* → 강제 push
- CLI: `git rebase -i origin/dev` → 해당 줄을 `reword`로 변경 → `git push --force-with-lease`

이름 브랜치는 각자 쓰는 브랜치라 강제 push해도 다른 사람에게 영향이 없습니다. dev와 main은 보호 규칙으로 강제 push가 막혀 있습니다.

### 템플릿 파일

각 앱 저장소에 복사하세요. `common/`은 모든 저장소에 똑같이, 스택 폴더는 해당 저장소에만 복사합니다.

| 파일 | 복사 위치 | 트리거 | 하는 일 |
|---|---|---|---|
| `common/release-notes.sh` | `.github/scripts/release-notes.sh` | — | 커밋 메시지로 다음 버전과 changelog 계산 (아래 두 워크플로가 사용) |
| `common/pr-changelog.yml.example` | `.github/workflows/pr-changelog.yml` | dev·main 대상 PR 열림/커밋 추가 | PR 본문에 changelog 작성. dev → main은 제목 `Release vX.Y.Z` + 다음 버전 |
| `common/release.yml.example` | `.github/workflows/release.yml` | main push (PR 머지) | `vX.Y.Z` 태그 + GitHub Release 생성 (main에 커밋하지 않음) |
| `common/branch-guard.yml.example` | `.github/workflows/branch-guard.yml` | main 대상 PR | `dev`, `hotfix/*` 외 브랜치에서 main으로의 PR 차단 |
| `common/commit-lint.sh` | `.github/scripts/commit-lint.sh` | — | 커밋 메시지 규칙 검사 + 안내 (아래 두 파일이 사용) |
| `common/commit-check.yml.example` | `.github/workflows/commit-check.yml` | dev·main 대상 PR | PR 안의 모든 커밋 검사, 위반 시 안내 댓글 + 머지 차단 |
| `common/commit-msg` | `.githooks/commit-msg` (실행 권한 필요) | 로컬 커밋 (**필수**) | 규칙 위반 커밋 거부 |
| `<스택>/ghcr.yml.example` | `.github/workflows/ghcr.yml` | dev, main push | 이미지를 `sha-<커밋 7자리>` 태그로 빌드·푸시 |
| `<스택>/deploy.yml.example` | `.github/workflows/deploy.yml` | **수동 실행** | dev→TEST / main→PROD. AWS SSM으로 서버의 `deploy-service.sh` / `rollback-service.sh` 실행 |
| `<스택>/Dockerfile.example` | `./Dockerfile` | — | PHP: `php:8.3.36-fpm-alpine` + nginx, 80 포트 / Next.js·Nest.js: `node:24.22.1-alpine`, 3000 포트 |
| `php/docker/*` | `./docker/` (PHP 저장소만) | — | 컨테이너 내부 nginx 설정, php-fpm 풀 설정, 두 프로세스를 함께 실행하는 entrypoint |

| 스택 | 템플릿 폴더 | 서비스명 |
|---|---|---|
| PHP | `examples/php/` | `php-frontend` / `php-backend` |
| Next.js | `examples/nextjs/` | `next-frontend` |
| Nest.js | `examples/nestjs/` | `nest-backend` |

### Deploy 실행 규칙

| 실행 브랜치 | 대상 | `ref` 비움 | `ref` 지정 |
|---|---|---|---|
| `dev` | TEST | dev 최신 커밋 | dev에 포함된 커밋 SHA만 |
| `main` | PROD | 최신 릴리스 태그 | 릴리스 태그(`vX.Y.Z`)만 |
| 그 외 | — | 실패 | 실패 |

- Deploy는 대상을 커밋 SHA로 바꾸고 `sha-xxxxxxx` 이미지가 GHCR에 있는지 확인한 다음 배포합니다. 이미지를 다시 빌드하지 않습니다. 방금 push했다면 ghcr.yml이 끝난 뒤 실행하세요.
- `action=rollback`은 해당 서버에서 실행 중인 이전 슬롯으로 트래픽을 되돌립니다.

### 저장소 설정 체크리스트

1. **Settings → Rules(또는 Branches)**
   - `main`: PR 필수, 직접 push 금지, 허용 머지 방식 **merge commit만**, Required status checks: `source-branch`(branch-guard), `convention`(commit-check)
   - `dev`: PR 필수, 직접 push 금지, 허용 머지 방식 **merge commit만**, Required status checks: `convention`(commit-check)
2. **Settings → General → Pull Requests**
   - **"Allow merge commits"만 켜고** "Allow squash merging", "Allow rebase merging"은 끄기
   - merge commit의 Default commit message는 **Default message** 유지
3. `.githooks/commit-msg` 실행 권한: `git update-index --chmod=+x .githooks/commit-msg` 후 커밋 (Windows에서 추가한 경우)
4. **Settings → Environments**에서 `test`, `prod` 생성
   - Deployment branches: `test` → `dev`만, `prod` → `main`만
   - `prod`에 Required reviewers 권장
   - 각 environment에 아래 **variables** 등록 (TEST 서버와 PROD 서버 값이 각각 다름. 비밀값 없음)

| 이름 | 값 |
|---|---|
| `AWS_REGION` | 예) `ap-northeast-2` |
| `AWS_DEPLOY_ROLE_ARN` | `test` → `github-deploy-test` 역할 ARN / `prod` → `github-deploy-prod` 역할 ARN |
| `DEPLOY_INSTANCE_ID` | 해당 서버의 EC2 인스턴스 ID (`i-…`) |
| `DEPLOY_USER` | 선택, 기본 `ubuntu` (infrastructure를 clone한 사용자) |
| `DEPLOY_PATH` | 선택, 홈 기준 경로. 기본 `platform/infrastructure` |

### 배포 명령 전달 방식: AWS SSM

Deploy 워크플로는 서버에 **AWS SSM**으로 명령을 보냅니다. AWS 쪽 설정(OIDC 공급자, IAM 역할, EC2 인스턴스 역할)은 **[docs/aws-ssm-deploy.md](docs/aws-ssm-deploy.md)** 를 따라 한 번만 하면 됩니다.

```
Deploy 버튼 → GitHub OIDC 토큰 → AWS IAM 역할(임시 자격 증명) → SSM send-command → EC2 에서 deploy-service.sh 실행
```

- **EC2 인바운드 포트가 필요 없습니다.** SSH 22번은 닫고, 서버 접속은 Session Manager로 합니다.
- **GitHub에 AWS 키나 SSH 키를 저장하지 않습니다.** 배포할 때마다 임시 자격 증명을 발급받습니다.
- **self-hosted runner가 필요 없습니다.** 개인 계정에서도 저장소별 등록이 없습니다.
- TEST 역할과 PROD 역할이 분리되어 있어서, PROD 서버에는 main 브랜치의 prod environment에서만 명령을 보낼 수 있습니다.
- 서버에는 미리 `./scripts/ghcr-login.sh`로 GHCR 로그인이 되어 있어야 합니다.

스택별 참고:

- PHP 템플릿은 `php-frontend` 기준입니다. backend 저장소에서는 `ghcr.yml`, `deploy.yml`의 `php-frontend`를 모두 `php-backend`로 바꾸세요.
- **PHP 이미지 구조:** `php:8.3.36-fpm-alpine`에 nginx를 함께 넣어 컨테이너 하나가 80 포트로 HTTP를 받습니다.
  - 공용 Nginx → (HTTP) → 컨테이너 내부 nginx → (FastCGI, `127.0.0.1:9000`) → php-fpm 순서로 요청이 전달됩니다. php-fpm은 컨테이너 밖에서 접근할 수 없습니다.
  - `Dockerfile.example`과 `docker/` 폴더(nginx.conf, php-fpm.conf, entrypoint.sh)를 함께 복사하세요. 확장 모듈은 Dockerfile의 `docker-php-ext-install` 줄에 추가합니다.
  - Laravel처럼 `public/`이 웹 루트면 빌드 시 `--build-arg DOCUMENT_ROOT=/var/www/html/public` (ghcr.yml의 build-push-action에 `build-args`로 추가)
  - 실제 클라이언트 IP(`REMOTE_ADDR`)와 HTTPS 여부(`$_SERVER['HTTPS']`)는 공용 Nginx의 헤더로 복원됩니다.
  - php-fpm 워커 수는 `PHP_FPM_MAX_CHILDREN`(기본 10, 512m 기준)으로 조절합니다. 메모리 상한을 올렸다면 env 파일에 함께 올리세요 (워커 1개당 대략 30~60MB).
- Next.js는 `next.config`에 `output: 'standalone'`이 필요합니다.
- Next.js의 `NEXT_PUBLIC_*` 값은 **빌드 시점에 이미지에 박힙니다.** dev 빌드(TEST)와 main 빌드(PROD)에서 값이 달라야 한다면 ghcr.yml에서 브랜치별 build-arg로 넘기세요.
- Nest.js의 `main.ts`는 `process.env.PORT`(기본 3000)로 listen 해야 합니다.
- 태그는 `sha-<짧은 커밋 해시>` 형식으로 푸시됩니다.

## 4. 서비스별 독립 배포

이미지 전체 경로를 넘기거나, **태그만** 넘기면 `services/<서비스>.conf`의 `IMAGE_REPO`가 앞에 붙습니다.

```bash
cd ~/platform/infrastructure

# 태그만 사용 (권장 — org 전환 시 .conf만 바꾸면 됨)
./scripts/deploy-service.sh php-frontend  sha-1234567
./scripts/deploy-service.sh php-backend   sha-1234567
./scripts/deploy-service.sh next-frontend sha-1234567
./scripts/deploy-service.sh nest-backend  sha-1234567

# 전체 이미지 경로 사용
./scripts/deploy-service.sh next-frontend ghcr.io/hiwjdgh/next-frontend:sha-1234567   # [ORG] ghcr.io/<org>/next-frontend:sha-1234567
```

첫 배포는 **blue**, 같은 서비스의 다음 배포는 **green** 슬롯으로 올라갑니다. 이전 슬롯은 롤백용으로 계속 실행됩니다. 스크립트는 Nginx 컨테이너에서 새 슬롯의 HTTP 헬스 체크를 하고, 해당 서비스의 라우트만 바꾼 뒤 Nginx 설정 검사 → reload → 활성 색상 기록 순으로 진행합니다.

DNS 설정 없이 Host 헤더로 테스트:

```bash
curl -i -H 'Host: frontend.localhost' http://localhost:8080/
curl -i -H 'Host: backend.localhost'  http://localhost:8080/
curl -i -H 'Host: next.localhost'     http://localhost:8080/
curl -i -H 'Host: nest.localhost'     http://localhost:8080/
```

### 앱 환경변수 (env 파일)

컨테이너 런타임 환경변수는 `environments/<APP_ENV>/<서비스>.env`에서 읽습니다. `APP_ENV`는 서버의 `.env`에 지정하며 기본값은 `local`입니다.

```bash
# 예: TEST 서버 (.env 에 APP_ENV=test)
cp environments/nest-backend.env.example environments/test/nest-backend.env
vi environments/test/nest-backend.env
```

- `environments/*/*.env`는 Git에서 제외됩니다. 시크릿은 각 호스트에만 보관하세요. 커밋되는 것은 `environments/*.env.example`뿐입니다.
- 파일이 없으면 경고만 출력하고 환경변수 없이 기동합니다.
- env 파일은 **컨테이너가 생성될 때** 적용됩니다. 값을 바꾼 뒤에는 같은 태그로 다시 배포하세요(`deploy-service.sh <서비스> <현재 태그>`). 새 슬롯이 새 값으로 뜨고, 이전 슬롯은 이전 값을 유지하므로 롤백도 됩니다.
- Next.js의 `NEXT_PUBLIC_*`는 빌드 시점 값이라 env 파일로 바꿀 수 없습니다.
- Docker Compose 2.24 이상이 필요합니다(`env_file`의 `required: false`).

### 컨테이너 메모리 상한

컨테이너 하나가 메모리를 과도하게 쓰더라도 서버 전체(공용 Nginx, 다른 서비스)가 멈추지 않도록 컨테이너마다 상한을 둡니다. 상한을 넘으면 해당 컨테이너만 재시작됩니다.

| 우선순위 | 위치 | 예 |
|---|---|---|
| 1 | 서버의 `.env` — `MEMORY_LIMIT_<서비스명 대문자, -는 _>` | `MEMORY_LIMIT_NEXT_FRONTEND=2g` |
| 2 | `services/<서비스>.conf` — `MEMORY_LIMIT` | `512m` (모든 서비스 기본값) |

- **blue/green 두 슬롯이 동시에 떠 있으므로** 서버에 필요한 메모리는 (상한 합계 × 2)입니다.
  - TEST (8GB): 기본값 512m 그대로 → 4서비스 × 2슬롯 × 512m = 최대 4GB
  - PROD (32GB): `.env.example`의 예시(PHP 1g, Node 2g) → 최대 12GB
- **Node 서비스:** `NODE_OPTIONS=--max-old-space-size`가 상한의 75%로 자동 설정됩니다 (`.conf`의 `NODE_HEAP_PERCENT`). env 파일에 `NODE_OPTIONS`를 쓰면 무시됩니다.
- **PHP 서비스:** 상한을 올리면 env 파일의 `PHP_FPM_MAX_CHILDREN`도 함께 올리세요. (예: 2g → 30)
- 상한 변경은 다음 배포부터 적용됩니다. 현재 태그로 다시 배포하면 바로 적용됩니다.

## 5. 롤백

```bash
./scripts/rollback-service.sh next-frontend
```

롤백은 실행 중인 이전 슬롯으로 트래픽만 되돌립니다. 이미지를 다시 빌드하거나 pull 하지 않습니다. 이전 슬롯이 없으면 안전하게 실패합니다.

## 6. 새 서비스 추가

1. `services/<서비스명>.conf` 생성 (`IMAGE_REPO`, `SERVER_NAME`, `CONTAINER_PORT`, `HEALTH_PATH`)
2. `environments/<서비스명>.env.example` 생성, 각 호스트에 `environments/<APP_ENV>/<서비스명>.env` 작성
3. 앱 저장소에 `examples/`의 워크플로/Dockerfile 복사 후 서비스명·이미지명 변경
4. `./scripts/deploy-service.sh <서비스명> sha-xxxxxxx`

서비스명은 소문자, 숫자, `-`만 사용할 수 있습니다.

## 7. 파일 구성

- `compose.yaml`: 공용 Nginx 컨테이너와 외부 네트워크
- `nginx/nginx.conf`: Nginx 메인 설정 (WebSocket upgrade 매핑 포함)
- `nginx/routes/`: **배포 시 자동 생성**. 직접 수정하거나 커밋하지 마세요.
- `services/compose.yaml`: 공용 blue/green 슬롯 정의
- `services/*.conf`: 서비스별 이미지 경로, 호스트명, 포트, 헬스 체크 경로
- `scripts/ghcr-login.sh`: `.env`의 계정 정보로 GHCR 로그인
- `scripts/init.sh`: 공용 인프라 기동
- `docs/initial-setup.md`: 처음 한 번 전체 환경을 구성하는 순서 (체크리스트)
- `docs/aws-ssm-deploy.md`: Deploy 워크플로용 AWS 설정 가이드 (OIDC, IAM 역할, SSM)
- `scripts/load-service-config.sh`: 서비스 설정 + 서버 `.env` 덮어쓰기(도메인, 메모리) 로드. 배포·전환 스크립트가 공통으로 사용
- `scripts/deploy-service.sh`: 이미지 pull → 비활성 슬롯 기동 → 헬스 체크 → 라우트 전환
- `scripts/switch-traffic.sh`: 직렬화된 Nginx 설정 전환 (실패 시 복구)
- `scripts/rollback-service.sh`: 실행 중인 이전 슬롯으로 되돌리기
- `environments/*.env.example`: 서비스별 앱 환경변수 예시. 실제 값은 `environments/<local|test|prod>/<서비스>.env` (Git 제외)
- `examples/`: 앱 저장소에 복사할 워크플로(ghcr / release / deploy)와 Dockerfile 예시
- `runtime/`: 호스트 로컬 상태. Git에서 제외됨

## 8. 배포 원칙

- 배포는 앱 저장소의 Deploy 워크플로(3장)가 AWS SSM으로 서버의 `deploy-service.sh`를 실행하는 방식입니다. infrastructure 저장소에서 `git pull`을 하는 것으로 배포를 대신하지 마세요.
- 배포 스크립트는 **Ubuntu 호스트에서** 실행되어야 합니다.
- `latest` 대신 불변 SHA 태그를 사용합니다. 릴리스 태그(`vX.Y.Z`)는 Deploy 워크플로가 SHA 태그로 바꿔서 사용합니다.
- PROD에 올라가는 이미지는 dev에서 검증한 이미지를 그대로 옮기는 것이 아니라, **main의 머지 커밋으로 다시 빌드한 이미지**입니다. 소스는 같지만 빌드는 별개입니다.

## 9. Local / TEST / PROD

| 환경 | 서버 | `.env`의 `APP_ENV` | 배포 출처 |
|---|---|---|---|
| Local | 개발자 PC (WSL2) | `local` | 이름 브랜치를 로컬에서 실행 (필요하면 `deploy-service.sh`로 수동) |
| TEST | AWS Ubuntu 26.04 | `test` | Deploy 워크플로 @dev |
| PROD | AWS Ubuntu 26.04 | `prod` | Deploy 워크플로 @main |

각 Ubuntu 머신에 이 저장소를 `~/platform/infrastructure`로 따로 클론하세요. 호스트별 시크릿, 상태, 자격 증명은 그 호스트에만 둡니다. `services/*.conf`의 `*.localhost` 도메인은 **로컬용 기본값**이고, TEST/PROD는 서버의 `.env`에서 실제 도메인으로 덮어씁니다 (10장).

## 10. AWS ALB 뒤 요청 흐름 (TEST / PROD)

```
사용자 브라우저  https://test-www.example.com/login
   │  DNS(Route 53): test-www.example.com → ALB
   ▼
① ALB  :443  ── ACM 인증서로 HTTPS 종료 (:80 은 443 으로 리다이렉트)
   │  헤더 추가: X-Forwarded-For: <사용자 IP>,  X-Forwarded-Proto: https,  Host: test-www.example.com (그대로)
   │  리스너 규칙: 해당 서버(TEST/PROD)의 대상 그룹으로 전달
   ▼  HTTP
② EC2 :HTTP_PORT(8080)  ── 보안 그룹: ALB 보안 그룹에서 오는 것만 허용
   ▼  Docker 포트포워딩 8080 → 80
③ 공용 Nginx (platform-nginx)
   │  - 사용자 실제 IP 복원 (ALB가 보낸 X-Forwarded-For)
   │  - Host 헤더로 서비스 선택 (서버 .env 의 SERVER_NAME_<SERVICE>)
   │      test-www.example.com → next-frontend
   │      test-api.example.com → nest-backend …
   │  - 현재 활성 슬롯(blue 또는 green) 컨테이너로 전달
   │    X-Real-IP / X-Forwarded-For / X-Forwarded-Proto(https) 그대로 전달
   ▼  HTTP (Docker 내부 네트워크, 외부 포트 없음)
④ 앱 컨테이너  platform-next-frontend-blue:3000
             platform-php-frontend-green:80 (내부 nginx → php-fpm)
```

**서버별 / 시스템별 도메인:** 시스템(서비스)마다 도메인이 다르고, 같은 시스템도 TEST와 PROD의 도메인이 다릅니다. 각 서버의 `.env`에 그 서버의 도메인을 적습니다.

```bash
# TEST 서버 .env
SERVER_NAME_NEXT_FRONTEND=test-www.example.com
SERVER_NAME_NEST_BACKEND=test-api.example.com
# PROD 서버 .env  (여러 개는 공백으로 구분, 따옴표 필요)
SERVER_NAME_NEXT_FRONTEND="www.example.com example.com"
SERVER_NAME_NEST_BACKEND=api.example.com
```

도메인을 바꾼 뒤에는 해당 서비스를 다시 배포하면(같은 태그 가능) 라우트에 반영됩니다. 등록되지 않은 도메인으로 들어온 요청은 `404`를 반환합니다.

**ALB 설정 체크리스트 (TEST, PROD 각각):**

| 항목 | 설정 |
|---|---|
| 대상 그룹 | 프로토콜 HTTP, 포트 = 서버 `.env`의 `HTTP_PORT`(기본 8080), 대상 = 해당 EC2 |
| 헬스 체크 | 경로 **`/healthz`**, 성공 코드 200 (공용 Nginx가 응답. 도메인이 없는 요청이라 앱 대신 Nginx가 답함) |
| 리스너 :443 | ACM 인증서 (도메인이 여러 개면 와일드카드 `*.example.com` 또는 인증서 여러 개 추가), 기본 동작: 대상 그룹으로 전달 |
| 리스너 :80 | HTTPS(443)로 리다이렉트 |
| 보안 그룹 | ALB: 인터넷에서 80/443 허용 / EC2: `HTTP_PORT`는 **ALB 보안 그룹에서만** 허용 |
| Route 53 | 각 도메인 → ALB (A 레코드, 별칭) |

TEST와 PROD가 ALB 하나를 같이 쓴다면, 리스너 규칙에서 **Host 헤더 조건**으로 TEST 도메인은 TEST 대상 그룹, PROD 도메인은 PROD 대상 그룹으로 나눕니다.

**앱에서 알아둘 것:**
- 사용자 실제 IP는 `X-Real-IP` 헤더(또는 PHP의 `$_SERVER['REMOTE_ADDR']`)를 쓰세요. `X-Forwarded-For`의 첫 번째 값은 사용자가 위조할 수 있습니다.
- HTTPS 여부는 `X-Forwarded-Proto: https`로 전달됩니다. PHP는 `$_SERVER['HTTPS']`가 `on`으로 설정되고, Nest.js/Express는 `app.set('trust proxy', true)`를 설정해야 `req.protocol`이 `https`가 됩니다.
- ALB 유휴 타임아웃(기본 60초)보다 오래 걸리는 요청은 ALB에서 끊깁니다. 긴 작업은 비동기로 처리하거나 ALB 유휴 타임아웃을 늘리세요.

## 제한 사항 / 운영 환경 보강 필요

1. **운영 수준의 배포 시스템이 아닙니다.** 단일 Ubuntu 호스트, 단일 Nginx, HTTP를 서빙하는 단순 컨테이너를 전제로 합니다.
2. 전환할 때마다 Nginx가 reload 됩니다. 진행 중인 요청과 장시간 연결(WebSocket 등)은 앱 차원의 draining과 타임아웃이 필요합니다. 헬스 체크가 2xx여도 무중단을 보장하지는 않습니다.
3. 컨테이너 안에 저장되는 세션, 업로드 파일 등은 blue/green 간에 공유되지 않습니다. Redis / DB / 오브젝트 스토리지 / 공유 볼륨을 사용하세요. 롤아웃 중에는 DB 스키마 변경이 하위 호환되어야 합니다.
4. TLS, 인증서, 시크릿 암호화/중앙 관리, 로그 로테이션, 리소스 제한, 보안, 메트릭은 **구성되어 있지 않습니다.** 앱 환경변수는 호스트의 평문 env 파일로 관리되므로 파일 권한(`chmod 600`)을 제한하세요.
5. `runtime/`과 `nginx/routes/`는 호스트 로컬 상태입니다. 필요하면 백업하세요. 스크립트는 이전 슬롯이 계속 살아 있다고 가정합니다.
6. PHP 컨테이너는 nginx와 php-fpm 두 프로세스를 간단한 entrypoint로 함께 실행합니다. 둘 중 하나가 죽으면 컨테이너가 종료되고 Docker가 재시작합니다(`restart: unless-stopped`). 그동안 해당 슬롯은 응답하지 않습니다.
7. routes 디렉터리는 쓰기 가능한 bind mount입니다. 호스트 파일시스템 접근을 제한하고, 생성된 상태 파일이나 토큰은 절대 커밋하지 마세요.
8. HTTPS는 ALB에서만 처리합니다. EC2의 `HTTP_PORT`가 ALB 외의 곳에 열려 있으면 HTTPS를 거치지 않는 접근과 `X-Forwarded-For` 위조가 가능해지므로, 보안 그룹을 반드시 ALB 보안 그룹으로 제한하세요.
