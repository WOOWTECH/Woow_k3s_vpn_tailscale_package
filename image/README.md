# tailscale image（「VPN 節點（相容 Tailscale）」）

- Registry：`jcr-prod.woowtech.io/woow-paas-docker-local/tailscale:{tag}`（tag = UTC `YYYYMMDD.HHMM`，候選 tag → `/approve` → promote；不推 `latest`）
- 平台側 **pin image digest**（範本 `tag@sha256` 雙釘）；chart 為 `woow-paas-charts` 的 `charts/tailscale`。
- 觸發：dispatch `build-tailscale-image.yml`（input `tag`），或推 git tag `tailscale-v<YYYYMMDD.HHMM>`。
- 來源：**衍生自** `WOOWTECH/Woow_podman_vpn_tailscale_package` @ `4d4a735`（`Containerfile`＋`entrypoint.sh`）。只做 k3s：podman repo 與 HA add-on（`Woow_HA_App_Store/woow-tailscale`）都不動，三邊沒有 parity 合約（PLAN §8 Q11）。
- 上游：`docker.io/tailscale/tailscale:v1.102.5`，index digest `sha256:c507f3a2a6ab1cabd8d809b98edeb41edbd5c3fb6ad9632ffd098b4c7d0b4065`（amd64 `sha256:08a1bc6c82fee62d1a135788fb67fefa9d22deea3830e8a45ebe1a3cb116e325`）。授權：套件 MIT、Tailscale client BSD-3-Clause。

## 與 podman 版的差異

| # | podman 版（4d4a735） | 本 image | 理由 |
|---|---|---|---|
| 1 | base `tailscale/tailscale:v1.102.3`，只釘 tag | `v1.102.5`，**tag＋digest** 一起釘 | 1.102.4 修了重新認證前後斷線；平台一律 pin digest |
| 2 | apk：bash ca-certificates iproute2 iptables ip6tables jq tini | bash ca-certificates jq tini | iptables／iproute2 base 已內建，userspace 也用不到 |
| 3 | 以 root 執行 | `USER 1000:1000`；`/var/lib/tailscale`、`/var/run/tailscale` 屬於 1000 | PaaS 慣例 non-root、drop ALL |
| 4 | 沒重設 CMD（上游 CMD 是 containerboot，被當參數傳給 entrypoint） | `CMD []` | 不帶 containerboot |
| 5 | entrypoint 單一流程 | `WOOW_TS_MODE=podman`＝原流程不變；`k8s`（本 image 預設）＝下表 | 保留 podman 的 env 名稱與流程，方便對照 |

### entrypoint k8s 模式（`WOOW_TS_MODE=k8s`）

沿用 podman 的流程與 env 名稱：tailscaled → 換 login server 就 logout → `tailscale up`（沒有 authkey 時丟背景，讓 web UI 先起來、登入網址寫進 log）→ `tailscale web`。k8s 模式的差異：

| 項目 | 行為 |
|---|---|
| 網路 | 一律 `--tun=userspace-networking`（不需要 NET_ADMIN、`/dev/net/tun`）；非 root |
| state／socket | state 在 `STATE_DIR`（chart 掛 PVC，節點身分＝這個目錄），socket 在 `TS_SOCKET`（emptyDir）。`TS_KUBE_SECRET` 一律 unset（不用 kube Secret 存 state、不需要 RBAC） |
| 強制關閉 | 每次開機先 `tailscale set --advertise-exit-node=false --advertise-connector=false --advertise-routes= --exit-node= --ssh=false --webclient=false --shields-up=false --relay-server-port= --accept-dns=false --accept-routes=false --hostname=…`（就地改 prefs，不重連控制平面；peer relay 與 web client 只有 `set` 改得到）。需要登入的節點再跑 `tailscale up --reset …`（同一組強制值）；已登入節點只有 tags 改了才 `up --reset`。先前手動設過的東西（例如 `tailscale set --advertise-exit-node`）重啟後一律清掉。**已登入的節點不跑 `up`**：`up` 會重啟控制連線，而 tailscale 在前一次控制連線 2 分鐘內再連時強制改走 HTTPS :443（controlhttp `forceNoise443`），同工作區 Headscale 的 `http://<service>:8080` 沒有 :443，沙盒實測多跑一次 `up` 會讓節點離線 1–2 分鐘。`TS_ADVERTISE_EXIT_NODE`、`TS_ADVERTISE_CONNECTOR`、`TS_ADVERTISE_ROUTES`、`TS_EXIT_NODE`、`TS_EXTRA_UP_ARGS`、`TS_EXTRA_TAILSCALED_ARGS`、`TS_WEB_ALLOW_NONLOCAL`、`TS_AUTHKEY`（明文 env）一律忽略並寫 log |
| login server | `TS_LOGIN_SERVER` 空＝官方；否則必須是 `http(s)://host[:port][/path]`（不收 userinfo、query、空白）。格式不對 → 寫 log、**不動**節點現有登入（不 logout、不 up）。比對的是 state 實際登記的 `ControlURL`（`tailscale debug prefs`），不是 podman 的 `.last_login_server` 標記檔——podman 版從官方換到 Headscale 時標記是空字串，不會 logout，`up` 會因「can't change --login-server without --force-reauth」失敗。換控制平面時 logout 後等 125 秒才連新的控制平面（同上 :443 強制規則） |
| authkey | 從檔案讀（`TS_AUTHKEY_FILE`，chart 的 Secret volume），**只在 BackendState 是 NeedsLogin／NoState 時**以 `--auth-key=file:…` 交給 tailscaled；已登入的節點一律不用。登入失敗（過期、用過、別的控制平面）→ 退回互動登入 |
| hostname | `TS_HOSTNAME` 必須是 DNS label（轉小寫，≤ 63）；空或不合法 → `TS_HOSTNAME_DEFAULT`（chart 由 release 推導，同 ns 兩台不撞名） |
| tags | `TS_TAGS` CSV，只收 `tag:<字母>[字母數字-]`，其餘略過並寫 log |
| serve 轉發 | `TS_SERVE=<tailnet port>=<service>:<port>,…`，**執行時驗證**：目標只能是本 namespace（`TS_SERVE_NAMESPACE`／`POD_NAMESPACE`）的 Service——短名稱或 `<name>.<ns>[.svc[.<cluster domain>]]`，一律改寫成 FQDN（Service 不存在＝NXDOMAIN，不會經 resolv.conf search 落到外部網域）。IP、外部網域、別的 namespace、`unix:`、重複 port、超過 32 筆 → 略過並寫 log，不會讓容器失敗。背景每 `TS_SERVE_SYNC_SECONDS`（15）秒比對 `tailscale serve status --json`，節點進入 Running（含重新登入成新節點）或設定漂移時 `serve reset` 再逐筆 `serve --bg --tcp` |
| web UI | `tailscale web --readonly` 綁 `TS_WEB_LISTEN`，**必須是 127.x.y.z 且不是 127.0.0.1**（userspace netstack 會把 tailnet 打到節點、沒被 serve 接走的連線送到 `127.0.0.1:<同埠>`）。read-only 模式一樣有「Log in」與重新認證（`/api/up` 同一個 handler），但**不會**打開 tailscaled 的管理 web client（`RunWebClient`，聽在 tailnet IP 的 5252）；podman 版的 `--readonly=false` 會打開它。web 掛了自動重啟 |
| log | 預設 `--no-logs-no-support`（不上傳 log.tailscale.io，與 HA add-on 一致；`TS_NO_LOGS_NO_SUPPORT=false` 可關） |
| 結束 | SIGTERM（tini `-g` 轉給整個 process group）→ 停背景工作與 tailscaled，以 tailscaled 的結束碼離開 |

沒有用上游 containerboot：`TS_KUBE_SECRET` 在 k8s 預設要 kube Secret＋RBAC、開機只等 60 秒（互動登入會 CrashLoop）、`TS_DEST_IP` 不支援 userspace（`notes/tailscale.md` §3）。

## 驗證（`build-tailscale-image.yml` 的 Verify）

amd64、`USER 1000:1000`、`tailscale version`＝1.102.5、ENTRYPOINT `tini -g -- /entrypoint.sh` 且沒有 containerboot、`tests/test-entrypoint.sh`（serve／login server／hostname／tags／web listen 驗證函式）在 image 內跑、唯讀根目錄＋非 root 實際起 tailscaled（userspace、`--no-logs-no-support`）、塞進 podman 的 exit node／routes／passthrough 旋鈕後 prefs 仍全部關閉、`RunWebClient=false`、web 只在 127.0.0.2:8088、serve 清單略過 IP 與別的 namespace、state 寫在 `/var/lib/tailscale`。

本機（不需要 docker）：

```bash
bash tailscale/tests/test-entrypoint.sh
```

## 升版

改 `tailscale/Dockerfile` 的 `ARG BASE=docker.io/tailscale/tailscale:v<版本>@sha256:<index digest>`，同步改 workflow 的 `TAILSCALE_VERSION`（Build 步驟會比對兩者），dispatch build。Headscale 有最低 client 版本（0.29.4：v1.80），兩個套件升版時一起看。
