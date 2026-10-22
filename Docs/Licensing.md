# 开源与 AGPL 合规清单（每次发版都要过一遍）

Couchport 以 **AGPL-3.0** 发布，原因是 Remote Play 层链接了 Chiaki / chiaki-ng / Pylux（AGPL-3.0 + OpenSSL 例外）。

## App 内（已实现：Home 右上角 ⓘ，以及 Home 底部的 “About Couchport, Licenses & Source Code”）

AGPL 第 5(d) 条要求交互式程序显示“适当的法律声明”，第 0 条定义了其内容：

- [x] 版权声明：`Copyright © 2026 The Couchport Authors`
- [x] 软件以 AGPL-3.0 许可发布
- [x] 不提供任何担保
- [x] 查看许可证的方式：App 内附 AGPL 全文（`Resources/Licenses/AGPL-3.0.txt`）
- [x] 源代码获取方式：仓库地址（Info.plist 的 `CouchportSourceURL`），以及与当前版本对应的 tag `v<版本号>`
- [x] 第三方组件及其许可证；构建脚本会把各组件自带的许可证全文拷进 `Resources/Licenses/`
- [x] 商标声明

## 仓库（第 6 条：对应源代码）

- [x] 整个 App 的源码，包括付费墙与内购代码，不只是 chiaki 部分
- [x] 构建脚本 `Tools/build_libchiaki_visionos.sh`，Pylux 固定在某个 commit
- [x] `project.yml`（用 xcodegen 生成工程）
- [x] `LICENSE`（AGPL-3.0 全文）、`NOTICE.md`
- [ ] **每次提交审核前**：`git tag v<CFBundleShortVersionString>` 并 push，tag 必须和上架的二进制完全对应
- [ ] 改了 Pylux commit、依赖版本或构建参数，都要一起提交
- [x] 仓库里没有签名证书、描述文件、密钥。`PSNAccountLogin.swift` 里的 PSN client ID/secret 是 Sony 官方 Remote Play 客户端公开使用的值，chiaki-ng 公开源码里也有，不属于机密

## 仍然存在的风险（不是代码能解决的）

- App Store 的使用条款对用户有额外限制，可能和 AGPL 第 10 条（不得附加限制）冲突。只要任何一位 chiaki/chiaki-ng/Pylux 的版权人投诉，App 就可能被下架（2011 年 VLC 就是这样）。上架前请律师看一下，或者征得上游作者的许可。
- 付费墙代码是开源的，别人可以自己编译出去掉限制的版本，这是 AGPL 允许的。
- AGPL 不授予商标权。`NOTICE.md` 已经写明 Couchport 的名字和图标不授权给分支使用。
