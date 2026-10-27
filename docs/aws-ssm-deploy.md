# AWS SSM 배포 설정 가이드

앱 저장소의 **Deploy 버튼(GitHub Actions)** 이 TEST / PROD EC2에서 `deploy-service.sh`를 실행할 수 있도록 AWS를 설정하는 방법입니다. **처음 한 번만** 설정하면 됩니다.

## 왜 SSM인가

| 방식 | EC2 인바운드 포트 | GitHub에 저장하는 비밀 | 저장소별 등록 |
|---|---|---|---|
| SSH | 22번을 넓게 열어야 함 (GitHub IP가 계속 바뀜) | SSH 개인키 | 없음 |
| self-hosted runner | 없음 | 없음 | 개인 계정은 **저장소마다** 등록 필요 |
| **SSM (사용)** | **없음** | **없음** (실행할 때마다 임시 자격 증명) | **없음** |

## 동작 흐름

```
Deploy 버튼 (dev → test / main → prod)
  │
  ├─ ① GitHub Actions 가 GitHub OIDC 토큰을 발급받음
  │      "hiwjdgh/next-frontend 저장소의 prod environment 에서 실행 중" 이라는 증명서
  │
  ├─ ② AWS STS 에 토큰 제시 → IAM 역할(github-deploy-prod)의 임시 자격 증명 발급
  │      역할의 신뢰 정책이 "repo:hiwjdgh/*:environment:prod" 인 경우만 허용
  │
  ├─ ③ aws ssm send-command → PROD EC2 에 명령 전달
  │      sudo -H -u ubuntu bash -lc 'cd ~/platform/infrastructure && ./scripts/deploy-service.sh next-frontend sha-abc1234'
  │
  └─ ④ EC2 의 SSM 에이전트가 실행 → 결과 로그를 GitHub Actions 화면에 표시
         (SSM 에이전트는 EC2 → AWS 방향으로 연결하므로 EC2 인바운드 포트가 필요 없음)
```

**보안 포인트:** TEST 역할과 PROD 역할을 분리합니다.
- PROD 역할은 **prod environment**에서만 쓸 수 있습니다.
- prod environment는 **main 브랜치**에서만 실행되도록 GitHub에서 제한합니다.
- 따라서 dev 브랜치나 개인 브랜치에서는 PROD 서버에 명령을 보낼 수 없습니다.

## 준비할 값

아래 표를 먼저 채워두면 이후 단계에서 그대로 붙여넣을 수 있습니다.

| 이름 | 예시 | 확인 위치 |
|---|---|---|
| `ACCOUNT_ID` | `123456789012` | AWS 콘솔 우측 상단 계정 메뉴 |
| `REGION` | `ap-northeast-2` (서울) | EC2가 있는 리전 |
| `TEST_INSTANCE_ID` | `i-0aaaaaaaaaaaaaaaa` | EC2 → 인스턴스 → TEST 서버 |
| `PROD_INSTANCE_ID` | `i-0bbbbbbbbbbbbbbbb` | EC2 → 인스턴스 → PROD 서버 |
| `GITHUB_OWNER` | `hiwjdgh` | 앱 저장소 소유자 (**[ORG] organization 전환 시 org 이름으로 변경**) |

---

## 1단계. EC2 준비 (TEST, PROD 각각)

### 1-1. 인스턴스 역할 연결

EC2가 SSM과 통신하려면 인스턴스에 IAM 역할이 있어야 합니다.

1. IAM → 역할 → **역할 생성**
   - 신뢰할 엔터티: **AWS 서비스 → EC2**
   - 권한 정책: **`AmazonSSMManagedInstanceCore`**
   - 이름: `ec2-ssm-managed` (TEST, PROD 공용으로 써도 됩니다)
2. EC2 → 인스턴스 선택 → 작업 → 보안 → **IAM 역할 수정** → `ec2-ssm-managed` 선택

이미 다른 인스턴스 역할이 붙어 있다면, 그 역할에 `AmazonSSMManagedInstanceCore` 정책만 추가하세요.

### 1-2. SSM 에이전트 확인

Ubuntu 공식 AMI에는 SSM 에이전트가 snap으로 기본 설치되어 있습니다. 서버에서 확인합니다.

```bash
sudo snap list amazon-ssm-agent
sudo snap services amazon-ssm-agent          # Current 가 active 인지 확인
```

없거나 멈춰 있다면:

```bash
sudo snap install amazon-ssm-agent --classic
sudo snap start --enable amazon-ssm-agent
```

### 1-3. 네트워크

SSM 에이전트는 **EC2에서 밖으로 나가는 HTTPS(443)** 만 사용합니다.
- **퍼블릭 서브넷 / NAT 게이트웨이가 있는 경우:** 추가 설정이 없습니다.
- **인터넷이 안 되는 프라이빗 서브넷인 경우:** VPC 엔드포인트(Interface) 3개를 만드세요. `com.amazonaws.<REGION>.ssm`, `ssmmessages`, `ec2messages`입니다.

### 1-4. 연결 확인

1~3분 뒤 AWS 콘솔 **Systems Manager → Fleet Manager**(또는 노드 관리)에 인스턴스가 **Online**으로 보이면 성공입니다.

```bash
# 로컬 PC 의 AWS CLI 로 확인할 때
aws ssm describe-instance-information --region <REGION> \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName]' --output table
```

### 1-5. 배포 사용자 확인

SSM 명령은 root로 실행되지만, 배포 스크립트는 **infrastructure를 clone한 사용자**(기본 `ubuntu`)로 바꿔서 실행합니다.

```bash
# 서버에서, 배포 사용자로
ls ~/platform/infrastructure/scripts/deploy-service.sh   # README 2장대로 clone 되어 있어야 함
groups | grep -w docker || sudo usermod -aG docker $USER  # docker 그룹 (추가 후 재로그인)
cat ~/platform/infrastructure/.env                        # APP_ENV, SERVER_NAME_*, GHCR_* 설정
~/platform/infrastructure/scripts/ghcr-login.sh           # GHCR 로그인 (한 번)
```

사용자나 경로가 다르면 4단계의 `DEPLOY_USER`, `DEPLOY_PATH` 변수로 지정합니다.

---

## 2단계. GitHub OIDC 공급자 등록 (계정당 한 번)

GitHub Actions가 발급하는 토큰을 AWS가 신뢰하도록 등록합니다.

**콘솔:** IAM → 자격 증명 공급자 → **공급자 추가**
- 공급자 유형: **OpenID Connect**
- 공급자 URL: `https://token.actions.githubusercontent.com`
- 대상(Audience): `sts.amazonaws.com`

**CLI:**

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

이미 등록되어 있다면(다른 프로젝트에서 사용 중) 건너뜁니다.

---

## 3단계. 배포용 IAM 역할 2개 만들기

`github-deploy-test`와 `github-deploy-prod`를 만듭니다. 두 역할은 **신뢰 정책의 environment 이름**과 **권한 정책의 인스턴스 ID**만 다릅니다.

### 3-1. 신뢰 정책 (누가 이 역할을 쓸 수 있나)

IAM → 역할 → 역할 생성 → **사용자 지정 신뢰 정책**에 아래를 붙여넣습니다. `<ACCOUNT_ID>`를 바꾸고, PROD 역할은 `environment:test`를 `environment:prod`로 바꿉니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:hiwjdgh/*:environment:test"
        }
      }
    }
  ]
}
```

- **[ORG]** organization으로 옮기면 `repo:hiwjdgh/*`를 `repo:<org>/*`로 바꿉니다. 이 줄만 바꾸면 됩니다.
- `hiwjdgh/*`는 이 계정의 **모든 저장소**를 뜻합니다. 앱 저장소로만 제한하려면 `StringLike`의 값을 배열로 나열하세요.
  ```json
  "token.actions.githubusercontent.com:sub": [
    "repo:hiwjdgh/php-frontend:environment:test",
    "repo:hiwjdgh/php-backend:environment:test",
    "repo:hiwjdgh/next-frontend:environment:test",
    "repo:hiwjdgh/nest-backend:environment:test"
  ]
  ```

### 3-2. 권한 정책 (이 역할로 무엇을 할 수 있나)

역할 생성 화면에서 **인라인 정책**으로 추가합니다. 이름은 `ssm-deploy`로 합니다. TEST 역할은 `<TEST_INSTANCE_ID>`, PROD 역할은 `<PROD_INSTANCE_ID>`를 넣으세요.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RunDeployCommandOnThisServerOnly",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ec2:<REGION>:<ACCOUNT_ID>:instance/<TEST_INSTANCE_ID>",
        "arn:aws:ssm:<REGION>::document/AWS-RunShellScript"
      ]
    },
    {
      "Sid": "ReadCommandResult",
      "Effect": "Allow",
      "Action": "ssm:GetCommandInvocation",
      "Resource": "*"
    }
  ]
}
```

이 역할은 **지정한 서버 한 대에서 명령을 실행하는 것**만 할 수 있습니다. 다른 서버나 다른 AWS 리소스에는 접근할 수 없습니다.

### 3-3. 역할 이름과 ARN

| 역할 | 신뢰 정책 environment | 권한 정책 인스턴스 | ARN (4단계에서 사용) |
|---|---|---|---|
| `github-deploy-test` | `environment:test` | TEST EC2 | `arn:aws:iam::<ACCOUNT_ID>:role/github-deploy-test` |
| `github-deploy-prod` | `environment:prod` | PROD EC2 | `arn:aws:iam::<ACCOUNT_ID>:role/github-deploy-prod` |

---

## 4단계. GitHub 저장소 설정 (앱 저장소마다)

각 앱 저장소 → **Settings → Environments**에서 `test`, `prod`를 만들고 아래처럼 설정합니다.

### Deployment branches

| environment | 허용 브랜치 | 그 밖에 |
|---|---|---|
| `test` | `dev`만 | — |
| `prod` | `main`만 | **Required reviewers** 지정 권장 (배포 전 승인) |

### Environment variables (secrets 아님)

| 이름 | `test` 값 | `prod` 값 |
|---|---|---|
| `AWS_REGION` | `ap-northeast-2` | `ap-northeast-2` |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/github-deploy-test` | `arn:aws:iam::<ACCOUNT_ID>:role/github-deploy-prod` |
| `DEPLOY_INSTANCE_ID` | `<TEST_INSTANCE_ID>` | `<PROD_INSTANCE_ID>` |
| `DEPLOY_USER` | (선택) 기본 `ubuntu` | (선택) |
| `DEPLOY_PATH` | (선택) 기본 `platform/infrastructure` | (선택) |

모두 비밀값이 아니므로 **variables**에 넣습니다. AWS 키나 SSH 키는 어디에도 저장하지 않습니다.

**[ORG]** organization으로 옮기면 이 값들을 **org variables**로 한 번만 등록할 수 있습니다. 대상 저장소를 지정하면 되므로, 저장소마다 반복할 필요가 없어집니다.

---

## 5단계. SSH 포트 닫기 (권장)

배포는 SSM으로 하므로, EC2 보안 그룹의 **22번 인바운드 규칙을 삭제**합니다. 서버에 접속할 때는 Session Manager를 씁니다.

- **콘솔:** EC2 → 인스턴스 선택 → **연결** → **Session Manager** 탭 → 연결
- **CLI:** `aws ssm start-session --target <INSTANCE_ID>` (로컬에 [Session Manager 플러그인](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) 필요)

Session Manager로 접속하면 기본 사용자가 `ssm-user`입니다. 배포 사용자로 바꾸려면 `sudo -iu ubuntu`를 실행하세요.

이렇게 하면 EC2 인바운드에는 **ALB에서 오는 `HTTP_PORT`(8080)만** 남습니다.

---

## 6단계. 동작 확인

### 6-1. 로컬에서 SSM 명령 직접 보내보기 (AWS 관리자 권한으로)

```bash
CMD_ID=$(aws ssm send-command --region <REGION> \
  --instance-ids <TEST_INSTANCE_ID> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo -H -u ubuntu bash -lc \"cd ~/platform/infrastructure && docker ps --format {{.Names}}\""]' \
  --query Command.CommandId --output text)
sleep 5
aws ssm get-command-invocation --region <REGION> --command-id "$CMD_ID" --instance-id <TEST_INSTANCE_ID> \
  --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
```

`Success`와 함께 `platform-nginx` 등의 컨테이너 이름이 나오면 EC2 쪽 설정은 끝난 것입니다.

### 6-2. GitHub에서 배포

앱 저장소 → Actions → **Deploy** → Run workflow → 브랜치 `dev` → Run

`deploy` job 로그에 서버의 `deploy-service.sh` 출력이 그대로 보이고, 마지막 줄이 `Deployed <service>: … -> …`이면 성공입니다.

---

## 문제 해결

| 증상 (Actions 로그) | 원인 | 해결 |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | 신뢰 정책 조건 불일치 | `sub` 값의 소유자(`hiwjdgh`), 저장소 이름, environment 이름(`test`/`prod`)이 정확한지 확인. 2단계 OIDC 공급자가 있는지 확인 |
| `Could not load credentials` / `id-token` 관련 오류 | 워크플로 권한 누락 | deploy.yml의 `permissions`에 `id-token: write`가 있는지 확인 |
| `AccessDeniedException ... ssm:SendCommand` | 권한 정책의 리소스 ARN 불일치 | 리전, 계정 ID, 인스턴스 ID 확인 (TEST 역할에 PROD 인스턴스를 넣지 않았는지) |
| `InvalidInstanceId` | 인스턴스가 SSM에 연결되지 않음 | 1-1 인스턴스 역할, 1-2 에이전트 실행, 1-3 아웃바운드 443 확인. Fleet Manager에서 Online인지 확인 |
| `DEPLOY_INSTANCE_ID 변수를 확인하세요` | environment 변수 누락 | 4단계의 environment variables 확인 (repository variables가 아니라 **environment** variables) |
| 결과 `Failed` + `permission denied ... docker.sock` | 배포 사용자가 docker 그룹이 아님 | 1-5의 `sudo usermod -aG docker <배포 사용자>` 실행 (SSM 명령은 매번 `sudo -u`로 새로 로그인하므로 바로 적용됨) |
| 결과 `Failed` + `unauthorized` (docker pull) | 서버의 GHCR 로그인 안 됨 / 토큰 만료 | 서버에서 `scripts/ghcr-login.sh` 재실행 |
| 결과 `Failed` + `Health check failed` | 새 버전이 기동에 실패 | 이전 버전이 그대로 서비스 중. 앱 로그 확인: `docker logs platform-<service>-<blue\|green>` |
| 결과 `TimedOut` | 15분 초과 (이미지 pull이 매우 느린 경우 등) | 서버에서 직접 `deploy-service.sh` 실행해 원인 확인 |

## organization 전환 시 [ORG]

1. 3-1 신뢰 정책 두 개에서 `repo:hiwjdgh/*`를 `repo:<org>/*`로 변경
2. 4단계 variables를 org variables로 옮기기 (선택)
3. 그 밖의 AWS 설정(OIDC 공급자, 인스턴스 역할, 권한 정책)은 **변경 없음**
