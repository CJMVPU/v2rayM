# 构建、测试与打包

在 macOS 上使用 Xcode 工具链和 Go。从仓库根目录执行以下命令。Go 版本、Xray 源码、补丁与分流数据摘要由[构建输入清单](../contracts/macos-build-inputs.json)锁定。将锁定版本的 `go` 加入 `PATH`。App 显示版本和构建号均取自 [VERSION](../VERSION)，采用三段单数字，例如 `0.9.9 → 1.0.0`。Xray 保留上游版本号。

## 生成签名 App 和安装镜像

以下示例为 Apple Silicon。发布打包使用干净检出，构建和回环输出写入新建的临时目录。将签名身份替换为本机钥匙串中可用的 Apple Development 身份。真实 TUN 助手要求团队签名。

```sh
out=$(mktemp -d)
version=$(cat VERSION)
bash scripts/fetch-macos-cores.sh osx-arm64 "$out/cores" --data-only
SIGN_IDENTITY='Apple Development: YOUR_SIGNING_IDENTITY' \
  scripts/build-macos-product.sh --output "$out/product" --core-bin "$out/cores"
bash scripts/package-macos-dmg.sh "$out/product/v2rayM.app" \
  "$out/v2rayM-$version-arm64.dmg"
```

构建脚本检查产品与 DDD 边界、助手契约、两份 DAT 和离线定位数据的摘要，构建带本地补丁的 Xray 动态库并签名。随后使用临时数据和本地对端验证 DNS、两跳出站及整包代理转发，并执行 TUN 只读预检。运行中的 App 可以继续使用。DMG 脚本验证 App 签名和镜像校验和。

`source-snapshot.json` 记录提交和源码摘要，`product-manifest.json` 记录签名后各文件的摘要，`verification.json` 汇总本地构建与回环结果。三份文件都在 `$out/product/`。安装前可只读挂载镜像，对卷内 App 执行 `codesign --verify --deep --strict`。

## 开发回归

```sh
scripts/project-tool check-macos-product-boundaries
scripts/project-tool check-ddd-boundaries
scripts/project-tool generate-helper-contract --check
swift test --package-path scripts/ProjectTools
go -C scripts/loopback test ./...
scripts/project-tool prepare-macos-geo
swift test --package-path macos/TunHelper
swift test --package-path macos/Native
```

如已有清单中指定的城市数据源，可用 `scripts/project-tool prepare-macos-geo --source <CSV.gz>` 离线生成资源。已有生成物可用 `--verify-only` 校验。需要签名包的原生用例通过环境变量 `V2RAYM_TEST_SIGNED_APP` 指向刚构建的 App。GitHub Actions 的验证顺序和产物见[工作流](../.github/workflows/macos-product.yml)。

## 单独验收

- **首次绘制**。在有图形桌面的测试机运行 `xcrun swift scripts/test-macos-startup-render.swift "$out/product/v2rayM.app" --runs 10 --report "$out/startup"`，用临时空数据库检查冷启动首帧。
- **TUN 预检**。运行 `scripts/network-check tun-acceptance --check-only --app "$out/product/v2rayM.app"` 核对签名宿主与隔离数据目录。
- **真实网络**。需要验证实际 utun、系统路由和 DNS 恢复时，先退出其他 VPN 并关闭系统代理，再按 [TUN 助手文档](macos-tun-helper.md)使用本机验收入口。休眠、切网、安装和公证分别记录结果。
