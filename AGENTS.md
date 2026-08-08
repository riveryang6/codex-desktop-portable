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
