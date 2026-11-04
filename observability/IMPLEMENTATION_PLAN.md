# 3-site Observability Master Plan — DRAFT (Agy review pending)

> 상태: **계획 초안 / 현장 접근·설치·Gemini 리뷰 미실행**. 절대 완료 표시 금지.
> 대상: `jammy-a`, `jammy-b`, `jammy-c` 및 `jammy-obs` (Tailscale).
> 구현 기준: **OpenStack 미사용**, 각 거점 **Ubuntu + KVM/libvirt + 독립 k3s**. README도 해당 기준으로 수정.
> 최신 사용자 시나리오(2026-11-04): **A 최초 Writer, B/C 읽기·데이터 반출. A 중단 시 승인된 B 승격, 이후 B 중단 시 승인된 C 승격. 현재 Writer가 살아 있는 동안 다른 Replica 단독 장애는 Writer 전환 사유가 아님. S3는 WAL/Backup 및 데이터 Export 목적이며 실시간 쓰기 Primary가 아님.**
> 고정 요구: Prometheus, Grafana, Loki, Istio, OpenTelemetry, Kiali, Tempo, Grafana Alloy, Blackbox Exporter, Alertmanager.

## 0. 기술적 목표와 원칙

- 커버리지: 물리 Host, Wi-Fi NIC/AP(접근 권한 범위), Tailscale 및 외부 WAN, Host bridge/nftables/conntrack, libvirt VM vCPU/RAM/vNIC/disk, Guest OS, k3s Node/Pod/Container/Service, Istio traffic, API ingress/egress, FastAPI, PostgreSQL replication, HAProxy, AWS SQS/S3/CloudFront, telemetry pipeline/hub 자체.
- 메트릭=Prometheus, 로그=Loki, trace=Tempo, 시각화=Grafana, Istio graph=Kiali, collector=Alloy, probe=Blackbox Exporter, alert=Alertmanager.
- 비목표: 모든 개별 패킷을 항상 저장하는 것, 서비스 코드를 계측하지 않고 모든 함수 내부를 추적하는 것, 허가 없는 AP/NAT 변경, 무중단·무손실 절대 보장.
- 자동 발견은 **등록된 생성 경로**(VM cloud-init 및 libvirt metadata, K8s API+라벨 규약, SD catalog)에서 보장한다. 비관리형 장치는 별도 미등록 경보.
- 리포지토리가 단일 Source of Truth. URL/역할/라벨/retention/scrape interval은 템플릿·inventory 변수로 관리. Secret, Tailscale key, kubeconfig, 인증서 개인 키는 Git에 넣지 않는다.
- 네트워크/서버 단절과 telemetry 도착 실패를 분리해 보고한다. 침묵을 정상으로 표시하지 않는다.

## 1. 설치 전 진단 (Read-only Gate)

각 Host에서 OS/kernel, CPU/RAM/disk/free, 물리 NIC/무선 인터페이스, 실제 Wi-Fi 링크, Tailscale 버전/경로(Direct/DERP), routes, nftables, libvirt domain+NIC+guest agent, k3s version/CNI, 현재 서비스/포트, DB, Prometheus/OTel/Istio 설치 여부를 수집한다.
관측 허브에서는 디스크 여유·파일시스템·Tailscale 주소/태그·시간 동기화·백업 경로를 확인.
필수 확인: 세 사이트가 서로 다른 AP/회선인지; AWS HAProxy 포함 접근 경로, 클러스터의 Pod/Service CIDR 충돌, VM br-vm의 IP 발견 방법, Kubernetes 설치 상태, 관리자 접근 승인, 중앙 로그에 개인정보·토큰 유입 차단.
결과물: `observability/inventory/{sites.yaml,services.yaml,probes.yaml}` (주소가 아니라 역할·DNS 우선), 실측 네트워크 표, 변경 전 상태 스냅샷, 설치 허용 목록.
**Gate**: 인벤토리·접속·권한·스토리지 검증 전 설치 금지.

## 2. 목표 데이터 경로

- 각 사이트: Prometheus(local TSDB, WAL) + Exporters + Alloy(host systemd, k3s DaemonSet) + Blackbox exporter + Istio control plane 및 Kiali(거점별).
- jammy-obs: VictoriaMetrics Single(중앙 PromQL 호환 metrics), Loki Single, Tempo Single, Grafana, Alertmanager, reverse proxy/TLS, 중앙 OTel receiver via Alloy(필요하면), 검증용 외부 probe. 중앙 VictoriaMetrics는 필수 Prometheus의 대체가 아니라 **집계 저장소 추가**.
- Site Prometheus scrape -> Central metrics remote_write; Site Alloy journald/container logs -> Loki; OTLP traces -> Alloy -> Tempo. 관측 허브 UI는 Grafana.
- Kiali 단일 설치가 세 독립 Mesh를 자동 통합하지 않는다. 우선 사이트별 Kiali 설치 후 Grafana Canvas에서 3개 사이트를 묶고 Kiali deep link를 제공한다. 나중에 단일 multi-cluster mesh로 합치는 것은 별도 네트워크·서비스 ID·인증·CNI 검증 프로젝트.
- 독립된 관측 서버가 죽어도 사이트 측 Prometheus TSDB와 일부 로컬 로그 버퍼가 남게 한다. Prometheus remote_write가 장시간 허브 장애 뒤 모든 샘플을 자동 재전송한다고 가정 금지; 재전송 보존 시간 및 복구 테스트 필수.
- CloudWatch 경유 AWS SQS/CloudFront/EC2 메트릭·로그는 최소 권한으로 API를 통해 연동. 임의 public scrape 금지.


## 2-A. 필수: DB Role / 데이터 반출 / S3 동적 상태 모델

이 문서는 물리 사이트와 DB Runtime Role을 **절대 동일하게 취급하지 않는다**. `site=a|b|c`는 안정된 식별자이고, `db_role=primary|standby|unknown`는 **DB 질의로 실측하는 변화 가능한 상태**다. `site=a,role=writer` 같은 영구 고정 구성·대시보드 필터는 금지한다. 장애 감지/승격 자동 실행은 모니터링과 독립된 통제된 절차다.

| 장애 단계 | A | B | C | AWS S3 | 운영 원칙 |
|---|---|---|---|---|---|
| 정상 | Primary + 수집/조회 | Read Replica + 조회/Export | Read Replica + 조회/Export | 주기적 Backup/WAL Archive + 완료 Export 파일 | 모든 앱 요청은 논리 Writer Endpoint로 기록. 읽기는 최신성 조건을 확인 |
| B만 중단 | Primary 유지 | Down | Read Replica + 조회/Export | Backup/WAL/Export 지속 여부 확인 | **C는 승격하지 않음**. B 장애는 Replica 장애 |
| C만 중단 | Primary 유지 | Read Replica | Down | Backup/WAL/Export 상태 확인 | A Primary 유지, B 조회·반출 용량 제한 검증 |
| A 중단 | 격리/Fencing 필요 | 후보→**승인 후** Primary | B에서 WAL 수신하도록 변경, 조회/Export | 수집 보존(SQS 별개), Backup/WAL/Export 구분 | 입력 쓰기 보류/영속 보관 후 데이터 손실 위험 평가·Fencing·승격·Writer Endpoint 전환 |
| A 중단 상태에서 B도 중단 | Down | 격리/Fencing 필요 | 후보→**승인 후** Primary | 복구 데이터 원천·아카이브 제공 (PostgreSQL Primary 아님) | 마지막 C 단독 운영, 용량 축소·접속 안전성·미복제 WAL 확인. Fencing/승격 안전성 증명 불가 시 쓰기 중지 |
| A/B 복귀 | 재동기화 후 Standby 후보 | 재동기화 후 Standby 후보 | 현재 Primary 유지(예시) | 별도 복구/정합성 검증 | 돌아온 과거 Primary를 자동 재승격하지 않음; timeline/LSN 비교, pg_rewind 또는 Base Backup 수행 |
| 네트워크 분할 또는 관측 허브 단절 | 실제 상태 확인 필요 | 실제 상태 확인 필요 | 실제 상태 확인 필요 | 연결 상태 별도 Probe | 장애로 추정해 자동 승격 금지. 현상=Unknown과 Down, Primary 가능성, 이중 쓰기 위험을 구분 |

**위 상태표는 목표/가정이며 실제 DB 전환 자동화 완료를 뜻하지 않는다.** C를 직계 Replica로 둘지 B 경유 Cascading Replica로 둘지는 WAN 대역폭/지연·Failover 운영 비용으로 결정한다. PostgreSQL은 cascading replication을 지원한다. A→B/C와 A→B→C의 Replication Lag, 각 링크 전송량, 승격 후 재지정 시간·실제 DB 최신성을 시험한다.

### DB 원본 상태 발견 및 경보

- 각 PostgreSQL 인스턴스는 `postgres_exporter` + 제한된 권한의 커스텀 SQL 메트릭으로 **실제** `pg_is_in_recovery()`(Primary vs Standby), `pg_stat_replication`(Sender), `pg_stat_wal_receiver`(Receiver), WAL 수신·재생 LSN, timestamp 기반 lag, `pg_stat_archiver`를 수집한다. 특정 확장/Exporter 버전에서 수집 가능한 기본 메트릭과 별도 쿼리는 설치 시 검증.
- `pg_is_in_recovery()=false`인 관측 가능한 인스턴스가 0개면 **Writable Primary Unconfirmed**, 2개 이상이면 **Multiple Primary Suspected (critical)**. 원본이 관측 불가인 경우에도 다른 데이터·격리 확인 없이 안전하다고 주장하지 않는다.
- 의도한 Writer Endpoint 대상과 DB가 실제로 밝히는 Primary 역할을 비교해 **Writer Endpoint Drift** 및 오래된 접속 풀을 경고한다. Endpoint 전환은 DB 승격 승인 이후 수행되며 DB 접속 권한은 Active Writer만 부여하도록 통제.
- Runtime 상태 전이 이벤트(standby→primary), promotion 승인자, fencing 증거, WAL timeline, 연결 Endpoint 변경, 앱 재접속, C downstream 재연결을 변경 이벤트로 Loki에 기록한다. Grafana에는 **현재 Writer**, **후보(승격 전)**, **전환 중**, **관측 불가**를 별도로 표시한다.
- Alert 상태는 전환 작업 중 의도된 지연을 Silence/Change Window와 연결하되, 실제 Multiple-Primary·백업 실패 등 Critical은 무조건 숨기지 않는다.
- 2개 거점이 동시에 끊겨 중앙에서 확인할 수 없는 상황은 **자동 승격 권한의 근거가 아님**. Observability는 Failover Decision Support이지, 임의의 리더 선출기가 아니다.

### 데이터 반출(조회·Export) 관측

- B/C는 읽기와 데이터 반출을 주로 담당한다. `query_api` p95/p99, rows/s, DB Replica Lag, stale-read 차단/허용, Export job queue/processing time, 객체 크기, checksum, 결과 버전, 실패·재시도, S3 업로드 bytes/seconds 및 오류를 수집한다.
- 큰 파일은 거점 서버가 외부 사용자에게 직접 스트리밍하는 대신 **Export Worker→S3 게시→CloudFront 사용자 다운로드**를 기본 비교 구조로 사용한다. 사이트 B/C의 Wi-Fi 업로드 회선과 사용자 CloudFront 다운로드 회선은 독립된 경로로 표시. 첫 게시 지연과 CDN cache hit를 구분한다.
- B 승격 시 B는 쓰기 및 기존 조회/Export 부하를 겸한다. 과부하 보호 규칙에 따라 비필수 Export 동시성을 줄이고 C가 허용 freshness 내 조회/Export를 더 담당하는 **degradation policy**를 검증한다. C 승격 후에는 Export/분석을 더 축소한다.

### S3: 복제·Backup·Archive·Export 역할 구분

- **PostgreSQL Streaming Replica**: A/B/C PostgreSQL 사이 WAL을 전달하고 조회 가능한 Standby를 유지하는 서비스 연속성 수단.
- **pgBackRest→S3 Base Backup + WAL Archive**: 복원/PITR에 필요한 데이터의 오프사이트 보호. 실시간 읽기 DB가 아니라 복구 저장소. `last_backup_success`, `last_backup_age`, `last_archive_success`, `failed_archive_count`, S3 접근 가능성, Repo 용량·보존, 별도 환경 복원 시험으로 검증.
- **Export Snapshot→S3(+CloudFront)**: 외부 사용자가 다운로드할 수 있는 정제 데이터 파일. DB 백업과 구별된 Bucket/Prefix·권한·보존 정책 사용. Content version/checksum 검증. S3로 WAL을 보냈다고 실시간 복제나 0-RPO 달성을 주장하지 않는다.
- A와 B가 동시에 불능일 때 C의 최신 WAL·아카이브 유효성을 확인한 뒤에만 C를 승격할 수 있다. S3 저장이 끊겨 있거나 미복제 이벤트가 있는 경우 RPO 범위를 명시한다.

### 역할 변화에 강한 대시보드/Discovery

- 물리명 `jammy-a/b/c`, 거점 라벨 `site`, DB `system_identifier`/현재 timeline 등의 **실제 객체 ID**는 식별자로 유지. `primary_site`, `replication_upstream`, `allowed_export_sites`는 현재 상태와 승인된 운영 정책에서 동적으로 조회한다.
- 대시보드의 '현재 Primary'는 정적 A 패널이 아니라 현재 Primary로 확인되는 DB 인스턴스를 강조한다. 그래프의 WAL 엣지(A→B/C→B→C)는 DB Receiver/Replay 관측에 따라 갱신한다. 물리 Link 방향·수신/송신 Bandwidth는 시간축으로 표시한다.
- Prometheus Label은 사이트/인스턴스처럼 안정된 식별 위주로 유지하고, Rapidly changing `request_id`, `event_id`, PID 등을 메트릭 라벨에 넣지 않는다. Role 변동은 상태 메트릭과 이벤트 로그로 표현하여 타임시리즈 폭증을 방지한다.
- 신규/삭제 VM·Pod/Service가 등장하면 SD로 대상 목록을 갱신하지만, **업무상 이 서비스가 Writer를 참조해야 하는지/Read Replica를 참조해야 하는지**는 선언된 앱 계약과 현재 상태에 따라 결정한다. 서비스 생성만으로 임의 DB 쓰기 권한을 부여하지 않는다.

### 필수 드릴 추가

| ID | 드릴 | 관측 합격 기준 |
|---|---|---|
| F01 | B만 장애(A 정상) | A Primary 유지, C Read Replica 확인, B 조회/Export 배제, DB 불필요한 승격 없음 |
| F02 | A 장애→B 승격 | A Fencing·B role 전환·C upstream 변경·Writer Endpoint drift 검사, 누락/중복·RTO/RPO 및 AWS 큐 보관 증거 |
| F03 | A 장애 후 B 연속 장애→C 승격 | C의 Writer 전환 가능성·정합성·백업 최신성·서비스 축소, 확실한 Fencing 없으면 fail-closed |
| F04 | 전환 후 A/B 재합류 | Old Writer가 Read Only 상태로 복구, 재동기화/timeline, Archive 및 DB 정합성 검증 |
| F05 | B/C 대용량 Export + WAN 포화 | Query p95, export queue, replica lag, file transfer throughput, CDN 결과 비교 및 Priority/Concurrency 보호 |
| F06 | S3 접근 불가/복원 실패 | 기존 DB 조회와 S3 Archive 실패를 분리, 백업 보호 상태 알림, 외부 복원 경로 검증 |
| F07 | A와 B에 동시에 Primary가 떠 있는 격리 시험 | 외부 인입 쓰기 차단·Critical 경보, 접근 제한된 격리 네트워크에서만 시험, 서비스 정합성/복원 검증 |

### 설계 근거

- PostgreSQL Failover/Fencing: https://www.postgresql.org/docs/current/warm-standby-failover.html
- PostgreSQL Streaming/Cascading Replica: https://www.postgresql.org/docs/current/warm-standby.html
- PostgreSQL Statistics: https://www.postgresql.org/docs/current/monitoring-stats.html
- pgBackRest S3 / Backup: https://pgbackrest.org/user-guide.html

## 3. 이름·접근·허브 이동 정책

- Site identity: `site={a|b|c}`, `cluster={jammy-a|jammy-b|jammy-c}`, `role={host|vm|node|pod|db|network}`, `environment=lab`, `service_name`, `service_instance_id`, `deployment.environment`; hostnames/IP에 의존한 쿼리·대시보드 패널 금지.
- Host 접근: Tailscale MagicDNS 사용. `jammy-obs` 하드코딩 대신 Tailscale Services `svc:observability` 같은 **서비스 아이덴티티**를 승인된 tag host에서 광고하도록 설계(버전·관리자 권한·정책을 먼저 검증). 불가 시 내부 DNS 서비스 별칭 + 변경 가능한 records 사용.
- Metrics/Logs/Traces의 endpoint는 `OBS_METRICS_URL`, `OBS_LOGS_URL`, `OBS_TRACES_URL` 논리 변수로 제공, site overlay에서 주입. reverse proxy가 private Tailnet에서 인증·TLS 적용. Hub 이동은 백업 복원, 동일 서비스 재광고, ACL/인증서/스토리지 확인, end-to-end smoke 검증까지 포함; 서비스 이름 이동만으로 데이터 파일이 옮겨지지 않는다.
- Tailscale 접근 제어에서 Site agents는 전송용 endpoint만 허용하고 Grafana 관리자·Kubernetes API/DB 접근을 분리. 수집 포트는 인터넷에 노출하지 않는다.

## 4. 신규 장치 자동 발견 계약

### 물리 Host / KVM
- `node_exporter`는 각 Host 필수. `libvirt-exporter`는 libvirt socket을 읽고 VM 생성/삭제에 따라 VM 집계 자동 반영.
- 새 VM은 `cloud-init` 기반 이미지로 `node_exporter` + Alloy + (필요할 때) qemu-guest-agent를 자동 설치한다. 하드코딩된 guest IP 대신 libvirt 이벤트/metadata 및 guest-agent, DHCP lease 등 확인된 경로에서 발견한 endpoint를 atomically `file_sd` 또는 HTTP SD registry로 갱신한다. Host의 br-vm 네트워크가 정적 주소인 경우에도 metadata를 단일 진실원으로 사용.
- VM 생성·IP 변경·이전·삭제 시 SD 대상/라벨/대시보드와 경보 대상 정리. **계획된 삭제**와 **예상 밖 소실**을 desired-state inventory로 구분. guest agent 없는 VM은 '미관측 guest' 경보. libvirt 수집만으로 Guest 내부 프로세스 정보를 얻었다고 표시하지 않는다.

### Kubernetes
- kubelet/cAdvisor + kube-state-metrics + node exporter로 모든 Node/Pod/Container 상태가 객체 생성/삭제에 따라 자동 갱신.
- `ServiceMonitor`/`PodMonitor` 또는 Alloy `discovery.kubernetes` 사용. Service/Pod labels와 port name `metrics` 등의 관례로 prometheus target 자동 발견. 메트릭 endpoint가 없는 서비스는 **상태는 발견되나 코드 내부 메트릭은 생성되지 않음**을 명시.
- Istio는 선택된 애플리케이션 namespace에만 sidecar 적용, default namespace/observability/db에 무차별 injection 금지. Mesh telemetry -> Prometheus, mesh graph -> 거점 Kiali. API OTel SDK 또는 Operator auto-instrumentation은 실제 서비스별 테스트 후 적용.
- 신규 서비스 배포 템플릿에는 `/healthz`, `/readyz`, `/metrics`, JSON structured logging, OTLP environment, app labels, ServiceMonitor, resource limits, trace propagation contract을 포함. CI에서 누락 감지. 부하 실험에서 무제한 trace sampling 금지.

## 5. 관측 범위와 담당 수집

| 계층 | 수집기 및 데이터 | 확인할 값 |
|---|---|---|
| Physical Host | node_exporter, smartctl/textfile, lm-sensors (지원 시) | CPU steal/iowait, RAM, Swap, Disk IO/SMART, filesystem, NIC error/drop |
| Wi-Fi | iw/nl80211 -> textfile exporter, node_exporter | RSSI, bit rate, associated AP, retry/tx fail(드라이버 허용 시), send/receive Mbps |
| Tailscale | Tailscale native Prometheus metrics, tailscale status/ping | direct/DERP, peer path, tunnel bytes, route approved, relay fallback |
| Routing/Bridge | node_exporter, conntrack, nftables counters, ss, timed mtr | interfaces br-vm/tailscale0/veth, TCP retransmit, routing/drop, source/dest path |
| WAN/site↔site | Blackbox probes site별 vantage | A→B/B→A/AWS→A 같은 **방향별** HTTP/TCP/ICMP reachability/RTT, 실패율 |
| KVM/VM | libvirt_exporter, guest node_exporter, qemu agent | VM lifecycle/vCPU/RAM/vNIC/Disk, guest CPU/RAM/IO/network |
| k3s | kube-state-metrics, cAdvisor/kubelet, Istio telemetry | pod/node health, restart/OOM, cpu/mem/throttle, service RPS/p95/error |
| App/API | Prometheus SDK, OpenTelemetry, Loki | HTTP latency, DB pool, request_id/trace_id, ingestion ack status |
| PostgreSQL | postgres_exporter, SQL custom metrics, log/OTel client instrumentation | primary/replica role, replay lag, WAL, connections, lock, TPS, query latency |
| AWS | CloudWatch exporter/integration, HAProxy exporter | LB backend state, SQS backlog, CDN cache/error, AWS resource usage |
| Observability itself | Prometheus & Alloy internal metrics, probes | scrape success, remote_write backlog, missing telemetry, hub storage, rule evaluation |

**경계:** 동일 패킷은 Wi-Fi NIC, tailscale0, br-vm, veth에 여러 번 계수될 수 있다. 계층별 카운터를 단순 합산하지 않는다. Kiali는 mesh L7, OTel은 계측된 요청, Blackbox는 Probe, packet capture는 순간 심층 분석 도구다. 모든 패킷의 완전한 E2E 발견을 약속하지 않는다. AP 내부 상태는 AP 관리/SNMP 권한 없으면 얻을 수 없다.

## 6. 계측·보존·자원 비용 초기안(검증 후 조정)

- 사이트 Host/네트워크 핵심 지표 15~30초, DB 핵심 15~30초, 느린 SMART/디스크 상태 60초 이상. 실측 수집 부하로 조정.
- 중앙 metrics 7~14일, logs 3~7일, traces 24~72시간을 초기 시험값으로 사용. 디스크 사용량·일일 ingest·retention 실제 측정 후 확정. Logs high-cardinality labels에 request_id/event_id 금지. 검색 가능한 JSON 필드로 유지.
- OTel traces는 처음 샘플링 5% 전후에서 시작해 실제 이벤트량 측정, 장애 실험 시 목적별 샘플링 변경. 오류 trace를 무조건 100% 보관하려면 tail sampling 비용·버퍼·원본 유실을 별도 검증.
- 허브 32GiB 한도: VictoriaMetrics/Loki/Tempo/Grafana/Alertmanager에 resource caps와 저장 경로 별도 볼륨; high watermark(70%, 85%, 95%) 경보·수집 제한·보존 축소 런북.
- 사이트 32GiB Host의 kube Prometheus/Istio/Kiali overhead를 측정. overhead로 애플리케이션 부하 실험이 왜곡되면 Istio instrument 범위/trace sample/retention을 축소.
- 성능 측정은 계측 적용 전·후 동일 부하로 비교하여 관측 시스템 자체 overhead 공개.

## 7. 대시보드 구조

1. Executive NOC (Grafana Canvas): AWS + A/B/C service edges, Healthy/Degraded/Down/Unknown, RPS/error/p95, WAN RTT/throughput, DB writer/replica lag, SQS backlog. 경고는 **관측 사실**과 **추정 원인**을 분리.
2. Network Path: 방향별 RTT/loss, host Wi-Fi RSSI, Tailscale direct/DERP, tailscale0/br-vm/wlan per-interface Mbps, TCP retrans, nftables drops, AWS HAProxy.
3. Resource Drilldown: Host→VM→Node→Pod→Container CPU/memory/disk/network.
4. Service/Trace: Istio/Kiali local mesh graphs, OpenTelemetry exemplars, Tempo span waterfall, Loki correlated logs.
5. Data Reliability: **A→B→C 순차 Writer 승격 실시간 타임라인**, 실제 Primary/Replica 역할, Writer Endpoint, WAL upstream/lag, ACK(DB committed vs queue accepted), S3 Archive/Backup과 Export 상태, event backlog, duplicate/loss verification.
6. Observability Health: NoData vs Failure, collector backlog, WAL status, logs/trace ingestion, hub storage and independent heartbeat.

## 8. 검증 필수 시나리오와 완료 기준

| ID | 동작 | 검증 기준 |
|---|---|---|
| T01 | 신규 VM 생성 | guest agent 설치, node_exporter 자동 인식, Host+VM+Guest 관측, inventory 자동 등록 |
| T02 | VM 삭제/이동/IP 변경 | stale target 제거·이동, 동일 VM ID로 추적, 계획된 삭제 오경보 방지 |
| T03 | 신규 Pod/Service 생성 | label 기반 자동 발견, Kiali edge/OTel trace/로그-메트릭 상관 확인 |
| T04 | Pod 오류·OOM/재시작 | 경보·Loki 로그·relevant trace/Pod 이벤트를 동일 timeline에서 조회 |
| T05 | A↔B 네트워크 지연/손실 | 방향별 probes + interface counters + 앱 지연 + DB lag, 원인 후보 표시 |
| T06 | A Primary 중단(승인 시험) | 관측으로 writer freeze/replica/promote 절차, split-brain 방지, event ID 대조 |
| T07 | Tailscale DERP fallback | path 레이블·RTT·throughput 변화, relay 감지 |
| T08 | jammy-obs 중단 | 중앙 화면 unavailable 판정, 사이트 로컬 보존·재전송 공백/데이터 손실 확인 |
| T09 | Hub 새 장비로 이동 | 동일 논리 서비스 endpoint 재광고, TSDB/로그/Trace 복원, 대상 설정 수정 최소화 |
| T10 | AWS/모든 site 일부 장애 | 외부 probe에서 Unknown/Down 구분; false failover 방지 |
| T11 | 대량 트래픽 및 Export | 실제 WAN·CPU 병목, 계측 overhead, 압축/CDN 효과 비교 |
| T12 | 삭제/신설 반복 | target/cardinality/alert stale entry가 누적되지 않음 |

각 테스트에 시작 시간·설정 버전·입력 부하·기대 상태·관측 근거·실제 상태·종료 시 cleanup·복귀 결과를 남긴다. 장애 주입은 범위·승인·롤백 수단과 정상 백업 확보 후에만 수행한다.

## 9. 병렬 담당 Unit (공유 환경 동시 변경 금지)

- Agent PLAN: 종속성/보안/복구/용량 리뷰(먼저, 독립 리뷰).
- Agent HUB: `jammy-obs` central stack, TLS, retention, backup/restore, endpoint mobility.
- Agent HOST: 3 site physical/KVM/VM, inventory and SD, cloud-init, Ansible roles.
- Agent K8S: Prometheus/exporters, Alloy DaemonSet, Istio, per-site Kiali, OTel config.
- Agent NET: WAN/Tailscale/Wi-Fi probe, interface/cardinality, network topology.
- Agent APP/DB: FastAPI/Postgres/HAProxy/SQS/AWS service telemetry.
- Agent DASH: Grafana as-code Canvas, drilldowns, alerts, dashboard UX.
- Agent VERIFY: no shared prod write during coding; ephemeral integration test, k6, failure drills, review receipts.

계획 리뷰를 통과한 다음, 독립 Git worktree/branch에서 병렬 코드 작성. 각 Unit의 필수 산출물: source + tests + validation script + rollback + `Review-Agy-UNIT.md`. 작성자가 아닌 Agy reviewer를 **읽기 전용/격리 snapshot**에서 실행하여 리뷰하고, Blocking 0일 때만 통합 담당자가 순차 merge/배포. 모든 거점 인프라를 동시에 변경하지 않는다.

### Agy 리뷰 명령(실제 설치 후 명령 지원 검증)

```bash
agy models
agy --version
# 사용 가능한 Gemini 모델 ID, effort 옵션 및 비대화형 프롬프트 옵션은
# 로컬 'agy --help' 및 'agy models' 출력에서 먼저 확인한다.
# 확인된 옵션으로 다음 리뷰 프롬프트를 실행한다.
# "Read observability/IMPLEMENTATION_PLAN.md. Act as a senior SRE reviewer.
# Check design gaps, security, discovery, telemetry completeness, capacity,
# failure handling and testability. Output BLOCKING/MAJOR/MINOR. Do not edit files."
# 실제 실행 후 stdout/stderr, 모델 ID, 종료코드, 리뷰 결과를 보존한다.
```

요청하신 **Gemini 3.8 High의 실제 모델 식별자와 agy CLI 지원 여부는 미확인**이다. `agy --help`와 `agy models`를 통해 확인하고, 없으면 다른 모델로 조용히 대체하지 않는다. 리뷰 후 수정한 계획에 대해 재리뷰. 개별 diff는 파일별 read-only snapshot을 입력해 같은 모델로 리뷰한다. 병렬 실행은 `agy`가 실행되는 사용자의 Antigravity/agent orchestrator 환경에서만 수행하며 이 문서 생성이 실행 증거는 아니다.

## 10. 구현 순서와 Gate

- P0 INVENTORY: 연결/권한/CNI/스토리지/현재 서비스, 문서 불일치 해소 → 계획 리뷰.
- P1 OBS HUB: 중앙 메트릭·로그·Trace·Grafana·Alertmanager + service identity + Backup. Gate: sample metrics/logs/trace 저장·검색.
- P2 HOST/VM: 3 hosts/VM auto-discovery cloud-init/SD/Ansible. Gate: 생성·삭제·이동 추적.
- P3 K8S: 각 site Prometheus, exporters, Alloy, Istio, Kiali, OTel. Gate: Pod auto-discovery, cross-data trace correlation.
- P4 NETWORK: Wi-Fi/Tailscale/bridge/WAN directional probes, site-to-site and DB replication. Gate: 장애 위치를 구간별로 재현·관측.
- P5 APP/AWS: DB/HAProxy/SQS/S3/CloudFront business metrics, OTel. Gate: 수집 ACK/복제/다운로드 표시.
- P6 NOC: Grafana Canvas drilldown + 4–6 domain dashboards + alert route. Gate: 비전문가에게 장애 영향/근거 설명.
- P7 CHAOS/RELOCATION: read-only validation부터, 승인된 network/pod/db/hub fail test, hub restore. Gate: 보고서·정합성·오경보·미관측 범위 문서화.

## 11. CI / Code Review Gate

- YAML/JSON/schema, `promtool check config/rules`, `amtool check-config`, `alloy validate`, `helm lint/template`, `kubeconform`, `istioctl analyze`(검증 가능한 환경), Dashboards JSON validate, Kubernetes RBAC review, no secrets in Git, no public metrics endpoints.
- 검증은 P0 smoke → site one → site B/C canary → central integration → controlled fault → rollback 시험 순서.
- 설치·변경 마다 config diff, service health, active target coverage, data freshness, correlated log/trace, expected vs observed count, backout command를 첨부.
- Agy 리뷰 결과 파일과 테스트 결과를 PR 필수 증거로 취급하되, 실제 실행하지 않은 경우 `NOT_EXECUTED` 명시.

## 근거 문서

- Grafana Alloy Kubernetes discovery: https://grafana.com/docs/alloy/latest/collect/prometheus-metrics/
- Prometheus service discovery: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus Operator ServiceMonitor/PodMonitor: https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/getting-started/design.md
- Istio multi-cluster: https://istio.io/latest/docs/setup/install/multicluster/
- Kiali multi-cluster requirements: https://kiali.io/docs/features/multi-cluster/
- Tailscale Services: https://tailscale.com/docs/features/tailscale-services
- Tailscale native client metrics: https://tailscale.com/docs/reference/tailscale-client-metrics
- Antigravity CLI headless: https://antigravity.google/docs/cli/headless/

## 현재 실행 상태

- [x] OpenStack 제거 / 순차 A→B→C Writer 역할 변화 시나리오를 계획에 반영
- [x] 기존 설계/Repo 부분 조회
- [x] 공식 문서 기반 설계 초안
- [ ] jammy-* 원격 진단
- [ ] Agy Gemini 3.8 Flash High 계획 리뷰
- [ ] Agy 병렬 구현과 Unit별 code review
- [ ] 실제 설치
- [ ] 라이브 메트릭/로그/Trace/Topology 검증
- [ ] 장애 주입/허브 이전 검증
