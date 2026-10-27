# 초기 세팅 순서

처음 한 번 전체 환경을 구성하는 순서입니다. **위에서부터 순서대로** 진행하세요. 뒤 단계가 앞 단계에서 만든 값을 사용합니다.

| 단계 | 내용 | 담당 | 결과물 (다음 단계에서 사용) |
|---|---|---|---|
| 0 | 값 정하기 | 리드 | 도메인, 서비스 목록 |
| 1 | GitHub 준비 | 리드 | GHCR 토큰, infrastructure 저장소 |
| 2 | AWS 계정 설정 | AWS 담당 | 배포 IAM 역할 ARN 2개 |
| 3 | 서버 2대 구성 (TEST, PROD) | AWS 담당 / 리드 | 인스턴스 ID, `/healthz` 응답 |
| 4 | ALB · 도메인 | AWS 담당 | 도메인 접속 가능 |
| 5 | 앱 저장소 설정 (저장소마다) | 리드 | 첫 이미지, 워크플로 동작 |
| 6 | 첫 배포 · 첫 릴리스 | 리드 | TEST / PROD 서비스 |
| 7 | 개발자 온보딩 | 각 개발자 | — |

---

## 0. 값 정하기

아래 표를 채워두면 이후 단계에서 그대로 사용합니다.

| 항목 | 값 (예시) |
|---|---|
| GitHub 계정 | `hiwjdgh` (**[ORG]** 전환 시 org 이름) |
| AWS 리전 | `ap-northeast-2` |
| 앱 저장소 / 서비스명 | `php-frontend`, `php-backend`, `next-frontend`, `nest-backend` |
| TEST 도메인 | `php-frontend` → `test-admin.example.com`, `next-frontend` → `test-www.example.com`, … |
| PROD 도메인 | `php-frontend` → `admin.example.com`, `next-frontend` → `www.example.com example.com`, … |
| 메모리 상한 (PROD) | PHP 1g, Node 2g (TEST는 기본 512m) |

---

## 1. GitHub 준비

### 1-1. GHCR pull용 토큰 (classic)

GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)** → Generate new token

- 권한(scope): **`read:packages` 하나만**
- 만료일: 정하고 **만료 전에 갱신할 수 있도록 캘린더에 알림** 등록. 만료되면 서버의 `docker pull`이 실패하고 배포도 실패합니다.
- 이 토큰은 3단계에서 **서버의 `.env`에만** 넣습니다. GitHub secret에는 넣지 않습니다.

### 1-2. infrastructure 저장소 올리기

이 폴더를 GitHub **Private** 저장소로 올립니다.

```bash
cd infrastructure
git init -b main
git add .
git commit -m "chore: 초기 인프라 구성"
git remote add origin git@github.com:hiwjdgh/infrastructure.git   # [ORG] git@github.com:<org>/infrastructure.git
git push -u origin main
```

---

## 2. AWS 계정 설정 (계정당 한 번)

**[aws-ssm-deploy.md](aws-ssm-deploy.md)** 의 아래 단계를 진행합니다.

- **2단계:** GitHub OIDC 공급자 등록
- **1-1:** EC2용 인스턴스 역할 `ec2-ssm-managed` 생성 (`AmazonSSMManagedInstanceCore`)
- **3단계:** 배포 역할 `github-deploy-test`, `github-deploy-prod` 생성
  - 권한 정책에는 인스턴스 ID가 필요합니다. 3단계에서 EC2를 만든 뒤에 마무리해도 됩니다.

**결과물:** 역할 ARN 2개 → 5단계에서 사용

---

## 3. 서버 구성 (TEST, PROD 각각)

### 3-1. EC2 생성

| 항목 | TEST | PROD |
|---|---|---|
| AMI | Ubuntu Server 26.04 LTS | 동일 |
| 메모리 | 8GB | 32GB |
| IAM 인스턴스 프로파일 | `ec2-ssm-managed` | 동일 |
| 보안 그룹 인바운드 | **없음** (4단계에서 ALB 보안 그룹 → 8080만 추가) | 동일 |
| 아웃바운드 | 443 허용 (SSM, GHCR, Docker Hub) | 동일 |

**인스턴스 ID**를 기록합니다. 그다음 2단계 권한 정책의 `<TEST_INSTANCE_ID>` / `<PROD_INSTANCE_ID>`를 채웁니다.

서버 접속은 SSH 대신 **Session Manager**로 합니다. EC2 → 연결 → Session Manager에서 접속한 뒤 `sudo -iu ubuntu`를 실행하세요. 접속이 안 되면 [aws-ssm-deploy.md](aws-ssm-deploy.md) 1-2 ~ 1-4를 확인하세요.

### 3-2. Docker 설치

```bash
# Docker 공식 apt 저장소
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

sudo usermod -aG docker ubuntu     # 배포 사용자를 docker 그룹에 추가 → 세션 재접속
docker compose version             # 2.24 이상이어야 함
```

Docker 공식 저장소가 아직 26.04를 지원하지 않으면 Ubuntu 기본 패키지를 쓰세요: `sudo apt-get install -y docker.io docker-compose-v2`. 이 경우에도 `docker compose version`이 2.24 이상인지 확인합니다.

### 3-3. infrastructure 설치

배포 사용자(`ubuntu`)로 진행합니다.

**infrastructure 저장소 clone**

Private 저장소이므로 GitHub 인증이 필요합니다. 서버용 **Deploy key(읽기 전용)** 를 권장합니다.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/infra_deploy -N ""
cat ~/.ssh/infra_deploy.pub
```

출력된 공개키를 infrastructure 저장소 → Settings → **Deploy keys** → Add (Allow write access 체크 해제)에 등록합니다. 그다음 clone합니다.

```bash
mkdir -p ~/platform && cd ~/platform
GIT_SSH_COMMAND="ssh -i ~/.ssh/infra_deploy" git clone git@github.com:hiwjdgh/infrastructure.git   # [ORG] <org>/infrastructure
cd infrastructure
git config core.sshCommand "ssh -i ~/.ssh/infra_deploy"
```

**서버 설정 (`.env`)**

```bash
cp .env.example .env
chmod 600 .env
vi .env
```

| 키 | TEST | PROD |
|---|---|---|
| `HTTP_PORT` | `8080` | `8080` |
| `APP_ENV` | `test` | `prod` |
| `GHCR_USERNAME` / `GHCR_TOKEN` | `hiwjdgh` / 1-1의 토큰 | 동일 |
| `SERVER_NAME_<SERVICE>` | 0단계의 TEST 도메인 | 0단계의 PROD 도메인 |
| `MEMORY_LIMIT_<SERVICE>` | (비움 → 512m) | 0단계의 PROD 값 |

**앱 환경변수 (서비스마다)**

```bash
cp environments/next-frontend.env.example environments/test/next-frontend.env   # PROD 서버는 environments/prod/
vi environments/test/next-frontend.env
chmod 600 environments/*/*.env
```

**GHCR 로그인, 공용 Nginx 기동**

```bash
./scripts/ghcr-login.sh     # Login Succeeded
./scripts/init.sh           # 공용 Nginx 기동
curl -s http://localhost:8080/healthz    # ok
```

---

## 4. ALB · 도메인

자세한 설명은 README 10장을 참고하세요.

1. **ACM 인증서** 발급: TEST / PROD 도메인 전부 포함 (와일드카드 `*.example.com` 권장), DNS 검증
2. **대상 그룹** (TEST, PROD 각각)
   - 프로토콜 HTTP, 포트 `8080`, 대상 = 해당 EC2
   - 헬스 체크 경로 **`/healthz`**, 성공 코드 `200`
3. **ALB 보안 그룹**: 인터넷에서 80, 443 허용
4. **EC2 보안 그룹**: 인바운드 `8080`을 **ALB 보안 그룹에서만** 허용
5. **리스너**
   - `:80` → HTTPS(443)로 리다이렉트
   - `:443` → ACM 인증서. TEST와 PROD가 ALB 하나를 같이 쓰면 **Host 헤더 규칙**으로 TEST 도메인은 TEST 대상 그룹, PROD 도메인은 PROD 대상 그룹으로 전달
6. **Route 53**: 각 도메인 → ALB (A 레코드, 별칭)

**확인:** 대상 그룹에서 EC2가 **healthy**인지 확인합니다. TEST 도메인으로 접속하면 아직 배포 전이므로 `404`가 나오는 게 정상입니다.

---

## 5. 앱 저장소 설정 (저장소마다)

### 5-1. 파일 복사

| infrastructure의 파일 | 앱 저장소 위치 |
|---|---|
| `examples/common/release-notes.sh` | `.github/scripts/release-notes.sh` |
| `examples/common/commit-lint.sh` | `.github/scripts/commit-lint.sh` |
| `examples/common/pr-changelog.yml.example` | `.github/workflows/pr-changelog.yml` |
| `examples/common/release.yml.example` | `.github/workflows/release.yml` |
| `examples/common/commit-check.yml.example` | `.github/workflows/commit-check.yml` |
| `examples/common/branch-guard.yml.example` | `.github/workflows/branch-guard.yml` |
| `examples/common/commit-msg` | `.githooks/commit-msg` |
| `examples/<스택>/ghcr.yml.example` | `.github/workflows/ghcr.yml` |
| `examples/<스택>/deploy.yml.example` | `.github/workflows/deploy.yml` |
| `examples/<스택>/Dockerfile.example` | `Dockerfile` |
| `examples/php/docker/*` (PHP만) | `docker/` |

### 5-2. 저장소별 수정

- **php-backend:** `ghcr.yml`, `deploy.yml`의 `php-frontend`를 모두 `php-backend`로 바꿉니다.
- **로컬 훅 자동 활성화** (필수)
  - Node: `package.json`의 `"scripts"`에 `"prepare": "git config core.hooksPath .githooks || true"`
  - PHP: `composer.json`의 `"scripts"`에 `"post-install-cmd": ["git config core.hooksPath .githooks || true"]`
- **Next.js:** `next.config`에 `output: 'standalone'`
- **Nest.js:** `main.ts`가 `process.env.PORT`(3000)로 listen하고, `app.set('trust proxy', true)` 설정
- **PHP:** 필요한 확장을 Dockerfile의 `docker-php-ext-install`에 추가합니다. 웹 루트가 `public/`이면 `DOCUMENT_ROOT` build-arg를 지정합니다.
- **실행 권한** (Windows에서 추가한 경우)
  ```bash
  git update-index --chmod=+x .githooks/commit-msg .github/scripts/*.sh
  ```

커밋 메시지 규칙에 맞춰 main에 커밋하고(`chore: 배포 워크플로 추가`), **main에서 `dev` 브랜치를 만들어** 둘 다 push합니다.

### 5-3. 저장소 Settings

1. **General → Pull Requests**
   - "Allow merge commits"만 켜고, Default message 유지
   - "Allow squash merging", "Allow rebase merging"은 끄기
2. **Environments**
   - `test`: Deployment branches = `dev`
   - `prod`: Deployment branches = `main`, Required reviewers 지정
   - 각각 variables: `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN` (2단계의 test/prod ARN), `DEPLOY_INSTANCE_ID` (3단계의 TEST/PROD ID)
3. **Actions → General → Workflow permissions**: 기본값(Read)이어도 됩니다. 각 워크플로에 필요한 권한이 명시되어 있습니다.

### 5-4. 첫 이미지 확인

dev에 push한 시점에 `ghcr.yml`이 실행됩니다.
- Actions 탭에서 **Publish GHCR image**가 성공했는지 확인합니다.
- GitHub 프로필 → **Packages**에 `<서비스명>` 패키지가 **Private**으로 생겼는지 확인합니다.

### 5-5. 브랜치 보호 규칙 (워크플로가 한 번 실행된 뒤)

필수 체크(`convention`, `source-branch`)는 **워크플로가 한 번 실행되어야 선택 목록에 나타납니다.** 그래서 먼저 아무 브랜치에서 dev로 테스트 PR을 하나 열었다가 닫은 뒤 설정하세요.

Settings → **Rules → Rulesets** → New branch ruleset

| 대상 | 규칙 |
|---|---|
| `dev` | Require a pull request, Block force pushes, Allowed merge methods = **Merge**, Required status checks = `convention` |
| `main` | Require a pull request, Block force pushes, Allowed merge methods = **Merge**, Required status checks = `convention`, `source-branch` |

---

## 6. 첫 배포 · 첫 릴리스

### 6-1. TEST 배포
1. 앱 저장소 → Actions → **Deploy** → Run workflow → 브랜치 **dev** → Run
2. `deploy` job 로그 마지막에 `Deployed <service>: none -> blue`가 나오면 성공입니다.
3. TEST 도메인으로 접속해서 확인합니다.

실패하면 [aws-ssm-deploy.md](aws-ssm-deploy.md)의 "문제 해결" 표를 보세요.

### 6-2. 첫 릴리스 → PROD 배포
1. dev → main PR을 엽니다. 제목이 `Release v0.x.y`로 바뀌고 본문에 changelog가 채워지는지 확인합니다.
   - `v1.0.0`부터 시작하려면 PR을 열기 전에 main에 태그를 하나 만들어 두세요: `git tag v1.0.0 main && git push origin v1.0.0`
2. 머지하면 Actions의 **Release**가 성공하고 Releases 페이지에 버전이 생깁니다.
3. Deploy → 브랜치 **main** → Run → prod 승인(Required reviewers) → PROD 도메인에서 확인합니다.

### 6-3. 마무리
- **EC2 보안 그룹에 22번 규칙이 남아 있다면 삭제합니다.**
- 1-1 토큰의 만료 알림을 다시 확인합니다.

---

## 7. 개발자 온보딩 (개발자마다)

1. 앱 저장소를 clone하고, dev에서 **이름 브랜치**를 만듭니다 (예: `kim`).
2. `npm install` 또는 `composer install`을 실행합니다. 이때 커밋 메시지 훅이 자동으로 켜집니다.
   - 확인: `git config core.hooksPath` 결과가 `.githooks`
3. 규칙을 한 번 읽어봅니다: `bash .github/scripts/commit-lint.sh --guide`
4. 작업 흐름
   1. 작업 전에 dev를 당겨옵니다.
   2. 규칙에 맞게 커밋합니다 (`feat: …`, `fix: …`).
   3. push하고 dev로 PR을 엽니다. PR 본문은 자동으로 작성됩니다.
   4. 머지되면 Deploy(dev)로 TEST에서 확인합니다.

자세한 내용은 README 3장과 상황별 대응을 참고하세요.

---

## 정기 점검

| 주기 | 항목 |
|---|---|
| 토큰 만료 전 | 1-1 토큰을 재발급하고, 서버 2대의 `.env`를 바꾼 뒤 `./scripts/ghcr-login.sh` 실행 |
| PHP / Node 보안 패치 | `Dockerfile`의 `PHP_VERSION` / `NODE_VERSION`을 올리고 dev → TEST → main 순으로 배포 |
| 서버 디스크 | 오래된 이미지 정리: `docker image prune -a --filter "until=720h"` (현재 실행 중인 blue/green 이미지는 삭제되지 않음) |
