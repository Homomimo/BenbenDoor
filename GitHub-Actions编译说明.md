# GitHub Actions 编译未签名 IPA

此目录已包含 `.github/workflows/ios-unsigned.yml`，不需要上传 Apple 签名证书，不需要设置 Secrets。

## 放入仓库

解压源码包，将 **BenbenDoor 文件夹内的内容** 提交到 GitHub 仓库根目录，包含隐藏的 `.github` 文件夹。仓库根目录应直接看到：

```text
.github/workflows/ios-unsigned.yml
ci/build-ios.sh
ci/package-unsigned.py
App/
Widget/
Tests/
BenbenDoor.xcodeproj/
```

仅提交此源码目录；实际门锁配置 `奔奔门锁配置.private.json` 继续在手机上单独导入。

## 开始构建

1. 打开仓库的 Actions 页，如系统要求启用工作流，则启用。
2. 选择 **Build unsigned iOS IPA** → **Run workflow** → 选择分支 → **Run workflow**。
3. 提交到 main/master 分支以及 Pull Request 也会触发编译。手动运行需先将工作流放入仓库默认分支。
4. main/master 推送或分支手动运行：编译及测试成功后，自动创建并发布 GitHub Release，附带 **BenbenDoor-unsigned.ipa** 和 **SHA256SUMS.txt**。在仓库 Releases 页直接下载 IPA，无需先解压 Artifact。
5. Pull Request 仅构建验证，不发布。也可在运行页 Artifacts 下载 **BenbenDoor-iOS-unsigned**，解压取得 IPA。

工作流使用 `macos-15` runner，自动选择其已安装、带 iOS 26 或更高 SDK 的正式 Xcode，以编译原生 Liquid Glass 界面。如果镜像未安装所需版本，会在开始测试前明确报错。最低运行系统仍是 iOS 17，旧系统使用兼容磨砂效果。

先运行 7 项 XCTest，再以真机 iOS SDK 构建 arm64 App 和 Widget，最后打包 `Payload/BenbenDoor.app`。未通过测试或归档失败时，不会上传 IPA。无需 Gradle、DCloud 或第三方 Swift 依赖。

Artifact 保留 14 天，诊断资料保留 7 天；Release 附件独立保留。私有仓库的 macOS runner 用量遵循你的 GitHub 套餐。

发布使用独立的 release job，只有该 job 获得 `contents: write`，自动使用内置 GITHUB_TOKEN，无需添加个人 Token。Release 标签为 `ios-build-运行序号-重跑次数`，绑定本次构建提交，并标记 Latest。先上传附件至草稿，上传成功再发布，避免公开空附件的 Release。编译、测试或附件上传失败不会发布；失败后可能留下草稿，可在 Releases 中查看。若仓库/组织策略禁止写权限，发布步骤会报错，此时需在仓库策略中允许该工作流创建 Release。

## 签名与安装

这是 **未签名 IPA**，不能直接点开安装。之后需要通过你自己的 iOS 签名流程处理 App 和内嵌的 `BenbenDoorWidget.appex`，并保留小组件扩展。若签名时修改 Bundle ID，应保持 Widget ID 是主 App ID 的下级，并使用相匹配的签名配置。

最低系统版本 iOS 17。安装后先打开 App，导入配置并授予蓝牙权限；先验证 App 内开门，再添加桌面/锁屏小组件。小组件会打开 App 并触发一次开门。模拟器测试不验证真实蓝牙通信。

## 编译失败时

下载同一次运行的 **BenbenDoor-iOS-diagnostics**，内含 Xcode 版本、工程信息、测试日志、归档日志以及生成成功的 `.xcresult` 测试结果。也可以直接查看失败步骤日志。

当前 Windows 环境仅完成工程、配置和脚本静态检查；工作流尚未在 GitHub macOS runner 上执行，尚无实际生成的 IPA。Android 版已获用户实机开门成功反馈；iOS 版仍需独立完成云编译和真机测试。
