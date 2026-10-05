# Woow VPN 節點（相容 Tailscale，WOOW PaaS 雲端服務）

[English](README.md) · **繁體中文**

相容 [Tailscale](https://github.com/tailscale/tailscale) 的 VPN 節點，是 WOOW PaaS 平台上每個租戶一套的雲端服務（商品名稱「VPN 節點（相容 Tailscale）」）。節點加入租戶自己的 tailnet，把**同一個工作區**裡指定的服務經由 tailnet 開放給租戶自己的裝置，不需要公開網址。

> **這個 repo 是唯讀鏡像。** 正本在內部 Gitea（`woow-paas/woow-paas-charts` 的 `charts/tailscale/`，以及 `woow-paas/paas-odoo-ci` 的 `tailscale/`）。對應的來源 commit 見 [MIRROR.md](MIRROR.md)。這裡不接受修改 `chart/` 或 `image/` 的 PR，請到 Gitea 的 repo 改。

## 正式 image

```
jcr-prod.woowtech.io/woow-paas-docker-local/tailscale:20261004.0747@sha256:1868576adfe7a81fb0b36189cc224c6f5f3116971d2d8b32986365fbd4fb28cf
```

Tailscale **1.102.5**，chart `tailscale` **0.1.1**。平台以 tag＋digest 雙釘這顆 image；registry 只供平台使用，不對外。

## 你會得到什麼

| | |
|---|---|
| **定位** | 工作區私有入口：節點加入你的 tailnet，用 `tailscale serve` 把指定的 TCP 埠轉發到同工作區的服務 |
| **控制伺服器** | 官方 Tailscale（預設），或任何 Headscale；同工作區的 Headscale 填它的叢集內部網址 `http://<release>-headscale:8080` |
| **登入** | 互動登入（web UI 的「Log in」，或 log 裡的登入網址），或在服務頁填選填的 auth key |
| **轉發清單** | `<tailnet 埠>=<服務>:<埠>,…`，例如 `8069=svc-1a2b3c4d-woow-odoo:8069,8123=svc-5e6f7a8b-home-assistant:8123` |
| **Web UI** | `tailscale web` 唯讀模式（看狀態、登入／重新認證），前面有 HTTP Basic auth |
| **管理員帳密** | 帳號預設 `admin`，密碼在開通時顯示一次；兩者都可以在服務頁「Admin Credentials」修改。重設密碼會重啟服務，約數十秒後恢復 |
| **儲存** | 1 GB PVC 存放節點身分：重啟、重設密碼後在 tailnet 上仍是同一台機器 |
| **規格／價格** | 1 vCPU／0.5 GB RAM／1 GB 磁碟，每月 400 點（7 天免費試用） |

### 不提供的功能

- **不提供 exit node，也不提供子網路由。** exit node、app connector 與子網路由每次開機都強制關閉（叢集的公網 IP 與平台共用；子網路由等於把 pod 能連到的網路範圍交給 tailnet）。
- 不提供 Tailscale SSH、Funnel、Taildrop、SOCKS5／HTTP proxy。
- 轉發只能連到節點自己 namespace（租戶的工作區）裡的 Service。IP、外部網域、別的 namespace 一律略過並寫 log。
- 不上傳 log 給 Tailscale（`--no-logs-no-support`）。

## 使用方式

1. **選控制伺服器。** 留空＝官方 Tailscale。同工作區的 Headscale 填 `http://<release>-headscale:8080`（Headscale 服務的 release 名稱）。之後換控制伺服器，節點會登出並重新登記成新機器。
2. **登入。** 開 web UI 按「Log in」，或在服務頁貼上 auth key（Tailscale 的 `tskey-auth-…` 或 Headscale 的 pre-auth key）。auth key 只在節點需要登入時使用，已登入的節點不會讀它。建議用一次性、預先核准、帶 tag 的 key，第一次登入後把欄位清空。
3. **開放服務。** 在轉發清單填同工作區的 Service。清單在節點啟動時（以及之後每 15 秒）驗證；寫錯的項目會略過並寫 log，不會讓部署失敗。
4. 在你的裝置上用節點的 tailnet 名稱（預設 `woow-<release>`，或你設定的 hostname）加上 tailnet 埠連線。

## 架構

```
租戶瀏覽器 ──▶ Cloudflare tunnel（平台子網域）
                        │
                        ▼
              Service <release>-tailscale :8080
                        │
   ┌────────────────────┴──────────────────────────────────────────┐
   │ StatefulSet <release>-tailscale（1 份）                        │
   │  entrance   nginx :8080，Basic auth（htpasswd 來自 Secret）    │
   │             └─▶ tailscale web --readonly，綁 127.0.0.2:8088    │
   │  tailscale  tailscaled --tun=userspace-networking（uid 1000）  │
   │             tailscale serve --tcp <埠> → <svc>.<ns>.svc:<埠>   │
   └────────────────────┬──────────────────────────────────────────┘
                        ▼
          PVC <release>-tailscale-state（1 Gi）— 節點身分

租戶裝置 ──WireGuard（直連或 DERP）──▶ 節點 ──▶ 同 namespace 的 Service
```

- userspace 網路：不需要 `NET_ADMIN`、`/dev/net/tun`，也不用 host network。非 root（uid 1000），拿掉所有 capabilities，根目錄唯讀，不掛 service account token。
- NetworkPolicy 預設全擋。egress 只允許 DNS、同一個 namespace（轉發目標、同工作區的 Headscale），以及排除所有私有、link-local、CGNAT 網段後的公網——tailnet 經由節點連不到叢集、主機區網和 apiserver。這不是租戶可調的選項。
- 對 web UI 做 `kubectl port-forward` 會被拒絕（403），這是刻意的：port-forward 從 pod 的 loopback 進來，而打到節點的 tailnet 流量也會落在那裡，所以 nginx 一律拒絕 loopback。
- 帳號和密碼只放在 Secret（htpasswd volume），修改時 pod template 不會變；StatefulSet 有加入平台「重設帳密時重啟」的標記。
- 控制伺服器是純 `http://`（同工作區的 Headscale）時，有 liveness 看門狗：tailscaled 跟控制伺服器失聯超過 8 分鐘就重啟 tailscaled——不然 Headscale 重啟後 tailscaled 會一直改撥 :443，永遠回不來。

## 與 podman 版的差異

image 衍生自 [`WOOWTECH/Woow_podman_vpn_tailscale_package`](https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package) 的 `4d4a735`（`Containerfile` 與 `entrypoint.sh`），再針對 k3s 改寫。細節見 [`image/README.md`](image/README.md)，摘要如下：

| | podman 版（`4d4a735`） | 本 image |
|---|---|---|
| base | `tailscale/tailscale:v1.102.3`，只釘 tag | `v1.102.5`，tag **和** digest 一起釘 |
| 使用者 | root | `USER 1000:1000`，拿掉所有 capabilities |
| 網路 | host network；rootless Quadlet 走 userspace，可選 kernel TUN（`TS_USERSPACE_NETWORKING`） | pod 網路，只有 userspace |
| exit node／子網路由／app connector／SSH | 可用 env 設定 | 每次開機強制關閉；這些 env 與 passthrough 參數一律忽略並寫 log |
| auth key | `TS_AUTHKEY` env | chart Secret 掛成檔案，只在節點需要登入時使用 |
| 轉發 | 手動設 `tailscale serve`，轉到主機的 `127.0.0.1:<埠>` | 宣告式清單（`TS_SERVE`），執行時驗證，只收同 namespace 的 Service，每 15 秒重新比對 |
| Web UI | 選用、可寫（`--readonly=false`）、無驗證、只綁 loopback | 一律開啟、唯讀、綁 `127.0.0.2`，前面有 chart 的 Basic auth |
| entrypoint | 單一流程 | `WOOW_TS_MODE=podman` 保留原流程；`k8s`（本 image 預設）＝上述行為 |

`image/ci/build-tailscale-image.yml` 是 Gitea 建置流程的參考副本（build → 驗證 → 候選 tag → 正式環境核可 → promote）。GitHub 不會執行它，這個 repo 也不建置、不推送任何 image。

## 與 podman、Home Assistant 版沒有對齊合約

跟 WOOWTECH code-server 三件組不同，這個雲端服務與 podman package、Home Assistant add-on 之間**沒有 parity 合約**。Tailscale 雲端服務只做 k3s：podman package 與 Home Assistant add-on 維持原樣，不會跟這顆 image 一起升版，版本與功能可能不同。

## 同步

```bash
scripts/sync-from-gitea.sh                         # 兩個 Gitea repo 都用 main
scripts/sync-from-gitea.sh <charts-ref> <ci-ref>
```

這裡的 CI 只做 chart lint／render、entrypoint 單元測試、同步腳本與鏡像結構檢查，不建置、不發佈任何東西。

## 商標

Tailscale 是 Tailscale Inc. 的商標。本專案與 Tailscale Inc. 沒有隸屬或背書關係，只是封裝開源的 Tailscale client。Headscale 是獨立的開源專案。

## 授權

本套件為 [MIT](LICENSE)；Tailscale client 為 BSD-3-Clause。
