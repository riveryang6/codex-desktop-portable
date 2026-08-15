# codex-desktop-portable 贡献规则

## 适用范围

本文件适用于仓库根目录及其子目录。提交前必须检查 Git 状态，确保没有把原始调试工作区、用户数据或本机路径带入仓库。

## 默认开发要求

1. 不新增 checkpoint、hash marker、收据文件或其他用于扩大流程的状态代码。
2. 不保留与当前目标无关的兼容性代码、历史分支或迁移残骸；直接实现当前契约。
3. 所需工具必须统一安装并实际使用。不得因为工具缺失而绕过验证、降低安全性或引入替代流程。
4. 以上要求约束新增和修改内容；除非任务明确要求，不删除已有的安全校验、架构选择和数据保护行为。

## 项目边界

- `src/portable-launcher/` 是启动器源码和构建脚本。
- `src/release-update/` 是发布暂存、清单生成和插件缓存修复脚本。
- `dist/` 只保存已验证的 x86 bootstrapper、x86、x64、ARM64 启动器产物。
- 不把完整桌面 payload、用户数据、日志、截图、远程控制记录或 USB 备份提交到仓库。

## 构建与验证

### 官方版本兼容性门禁（强制）

每一次启动器编译或发布构建都必须执行 `src/portable-launcher/Assert-OfficialCodexCompatibility.ps1` 的两阶段实时官方版本门禁。首次调用必须发生在编译器启动前，从 OpenAI 官方发布源重新获取并验证当前最新的 x64 和 ARM64 Codex Desktop 包元数据、签名、架构与版本；随后只允许编译一个位于事务暂存目录、不可发布的 x64 兼容性探针，并立即使用该探针对两个官方包分别完成兼容性 self-test。两个 self-test 均通过后，才允许编译其余架构或提升任何目标产物。

- 此要求无条件适用于 `src/portable-launcher/build-launcher.ps1`、`src/portable-launcher/build-launcher-matrix.ps1` 和 `src/release-update/New-PortableRelease.ps1`，以及任何新增的启动器或发布构建入口。
- 本次实时检查或任一 x64/ARM64 self-test 未通过时，必须删除暂存探针，禁止继续编译其余架构、产出 `dist/`、打包或发布。必须先针对最新官方包调整源码，并从实时检查开始重新执行完整门禁；仅在均通过后才可继续。
- 不得提供或使用跳过、离线、覆盖版本、覆盖下载地址或其他绕过门禁的开关；历史缓存、版本文件、checkpoint、hash marker、收据或其他持久化状态均不得代替本次实时官方检查与双架构 self-test。

### 发布压缩（强制）

发布构建必须实际使用 7-Zip 24.09 或更高版本，以标准 ZIP/Deflate 兼容格式对 `LFPortable-common.zip` 执行最高压缩（`mx=9`、258 fast bytes、15 passes），并只归档文件而不写入冗余目录条目。最终 `LFPortable-release.zip` 中的小文件使用同一最高 Deflate 配置，已压缩的 common ZIP 与两个官方 MSIX 必须使用 Store，禁止用零级 Deflate 扩大体积。不得提供低压缩或工具缺失时的降级路径；两个 ZIP 都必须通过 7-Zip 完整性测试、压缩方法检查及 .NET ZIP 读取校验。

### 发布闭环（强制）

每一次稳定 GitHub Release 必须在上传前和公共下载回环后验证同一四部分 LF 版本与 SHA-256：当前源码和 `dist/` 的四个启动器、canonical `release`、外层 `LFPortable-release.zip`、以及指定 `CODEX_USB` 设备上的十个托管文件。发布前必须从当前干净源码重新构建事务矩阵，并逐字节匹配 `dist/` 与 canonical release 的四个启动器。必须先通过绑定 canonical manifest 的 Windows Sandbox 零状态首次启动验证，再同步 USB；`Publish-GitHubRelease.ps1` 必须显式接收 USB 根目录和 Sandbox 结果，并重新验证官方双架构包、完整 ZIP 和内层 common ZIP、压缩方法、远端 `main` 和注释 tag 都指向当前 `HEAD`。上传的 draft 必须先完成认证下载回环，公开下载校验失败时必须恢复为 draft。任一项不一致时禁止创建、上传或发布 GitHub Release。

在 Windows PowerShell 中构建架构矩阵：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\portable-launcher\build-launcher-matrix.ps1 `
  -OutputRoot .\build\launcher-matrix `
  -DotNetPath <path-to-dotnet-sdk>
```

必须验证四个 PE 架构：x86 bootstrapper、x86 core、x64 core、ARM64 core。完整 self-test 还需要对应的官方桌面 payload；源码仓库不携带该 payload。

## 脱敏与提交

提交前执行以下检查：

```powershell
git status --short --branch
git grep -n -I -E 'API_KEY|TOKEN|PASSWORD|BEGIN .*PRIVATE KEY|C:\\Users\\|D:\\|wxid_|xwechat'
```

发现真实凭据、用户路径、会话数据或调试截图时，必须移除并重新扫描。只允许提交与项目本身相关的占位符和通用路径示例。

## 修改方式

- 使用 `apply_patch` 进行文本修改，保持 UTF-8 编码。
- 不修改或删除用户未授权范围外的文件。
- 改动后重新构建受影响架构，并在提交信息中说明验证结果。
