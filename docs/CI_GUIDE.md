# 3거점 하이브리드 플랫폼 공통 CI/CD 가이드

본 문서는 **hybrid-5th** 모노레포에서 팀원들이 자신의 파트 코드를 안전하게 검증하고, 독립적으로 CI 테스트를 추가할 수 있도록 돕는 실무 가이드입니다.

---

## 1. CI 기본 철학 및 구조

우리 프로젝트는 **Monorepo** 구조이므로 다음 3가지 핵심 원칙을 기반으로 CI를 운영합니다.

1. **선택적 실행 (Path Filtering)**: 내가 수정한 파트의 검증만 실행되어 CI 대기 시간과 리소스를 절약합니다. (예: Terraform 코드만 수정 시 Terraform 검증만 실행)
2. **단일 품질 게이트 (CI Quality Gate)**: GitHub Actions의 `ci-gate` Job이 모든 실행 Job의 상태를 종합 판단하여 PR 머지 여부를 결정합니다. 수정하지 않은 파트의 Job이 건너뛰어져도(skipped) PR이 블로킹되지 않습니다.
3. **안전한 배포 분리**: PR 단계에서는 **오직 무결성 검증과 테스트, Docker 빌드 가능 여부만 확인**합니다. AWS Apply나 실제 배포, 패키지 실서버 배포는 별도 승인 절차 또는 main 브랜치 머지 후에만 일어납니다.

---

## 2. 현재 자동 검증 파이프라인 현황

| 파트 | 감지 경로 | 수행 검증 | 도구 |
|---|---|---|---|
| **AWS Terraform** | `infra/aws/**` | 서식 검사, 문법 검증 | `terraform fmt`, `terraform validate` |
| **Shell Scripts** | `scripts/**`, `infra/aws/userdata/**`, `**/*.sh` | 셸 스크립트 정적 분석 | `shellcheck` |
| **품질 게이트** | 전체 | 하위 Job 성공/스킵 종합 판정 | `ci-gate` |

> 백엔드·모니터링 CI는 각 repo([jammy-collector](https://github.com/cloud4-final/jammy-collector), [jammy-observability](https://github.com/cloud4-final/jammy-observability))에서 관리합니다.

---

## 3. 팀원 각자 파트 CI 추가하는 방법 (3단계)

본인의 파트(예: K8s 매니페스트, AI 모델 서빙, OS 프로비저닝 스크립트 등)에 대한 CI를 추가하고 싶을 때는 `.github/workflows/ci.yml` 파일에서 다음 3곳만 수정하면 됩니다.

### [1단계] 경로 필터 및 출력 등록 (`detect-changes` Job)
`detect-changes` Job의 `outputs`와 `with.filters` 항목 아래에 본인 파트의 식별자와 감시할 디렉토리 경로를 추가합니다.

```yaml
# .github/workflows/ci.yml
jobs:
  detect-changes:
    name: Detect Changed Paths
    runs-on: ubuntu-latest
    outputs:
      terraform: ${{ steps.filter.outputs.terraform }}
      scripts: ${{ steps.filter.outputs.scripts }}
      k8s: ${{ steps.filter.outputs.k8s }}               # <--- 1) 출력 등록
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            terraform:
              - 'infra/aws/**'
            scripts:
              - 'scripts/**'
              - 'infra/aws/userdata/**'
              - '**/*.sh'
            k8s:                                         # <--- 2) 경로 필터 추가
              - 'k8s/**'
```

### [2단계] 파트 검증 Job 작성
`detect-changes` 출력을 조건(`if`)으로 받는 신규 Job을 작성합니다.

```yaml
  validate-k8s:
    name: Validate Kubernetes Manifests
    needs: detect-changes
    if: needs.detect-changes.outputs.k8s == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate with kubeconform
        run: |
          # 본인 파트에서 수행할 테스트/린트 명령 작성
          echo "Validating k8s manifests..."
```

### [3단계] `ci-gate`의 의존성(`needs`)에 등록
PR 필수 체크가 정상 통과되도록 `ci-gate`의 `needs` 목록에 작성한 Job 이름을 추가합니다.
`ci-gate`는 `toJSON(needs)` 기반으로 모든 의존 Job의 상태를 자동 요약 및 평가하므로, 스크립트 수정 없이 `needs` 목록에만 추가하면 자동으로 품질 게이트에 반영됩니다.

```yaml
  ci-gate:
    name: CI Quality Gate
    needs: [detect-changes, lint-scripts, lint-terraform, validate-k8s] # <--- needs에만 추가하면 자동 반영
    if: always()
    ...
```

---

## 4. 로컬 사전 검증 가이드 (PR 올리기 전 권장)

PR을 올리기 전에 로컬 터미널에서 다음 명령어로 사전 검증하면 CI 실패를 미리 방지할 수 있습니다.

### 4-1. Terraform (AWS 파트)
```bash
cd infra/aws
terraform fmt -check -diff
terraform init -backend=false
terraform validate
```

### 4-2. Shell 스크립트 (네트워크 / 온프레미스 파트)
> ※ `infra/aws/userdata/edge.sh.tftpl`은 Terraform 템플릿 파일이므로 직접 정적 분석 대상이 아닙니다. `scripts/*.sh` 등 실제 존재하는 셸 스크립트를 대상으로 검증합니다.

```bash
# 기본 문법 체크
bash -n scripts/*.sh

# shellcheck이 설치된 경우
shellcheck scripts/*.sh
```

---

## 5. 보안 및 안전 수칙 (필수 준수)

1. **비밀 정보 Git 커밋 절대 금지**:
   - AWS Access Key / Secret Key
   - Tailscale Auth Key
   - SSH Private Key (`id_rsa`, `*.pem`)
   - `terraform.tfstate`, `*.tfvars`
   - Kubeconfig 파일
2. **main 브랜치 직접 푸시 금지**:
   - 반드시 `feat/<기능명>`, `fix/<이슈명>`, `chore/<작업명>` 브랜치로 분기 후 PR을 생성하세요.
   - PR 머지 조건: `ci-gate` 통과 + 팀원 1인 이상 승인(Approve).
3. **위험 작업 자동화 차단**:
   - `terraform apply`, KVM 인스턴스 강제 재기동, DB 마이그레이션 등 상태를 변경하는 작업은 PR CI에서 자동 실행하지 않습니다.
