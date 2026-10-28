# NetBox

自己用的 iOS 网络工具箱，SwiftUI 写的，没引任何第三方库。

起因是排查网络问题时手边只有手机，索性把常用的几个小工具凑一块了：

- Ping（次数、包大小、间隔、超时都能调）
- 路由轨迹
- DNS 查询（可指定解析器）
- 端口扫描
- Whois
- 局域网扫描
- 服务器监测 / 服务器列表

需要 iOS 18 以上。

## 构建

工程文件用 XcodeGen 生成，没入库：

```bash
brew install xcodegen
xcodegen generate
```

有 Mac 就直接用 Xcode 打开跑；没有的话仓库里有个手动触发的 Actions，能打出无签名 IPA，自己签名装。

注：project.yml 里给 target 显式指定了 INFOPLIST_FILE，别删，删了打出来的包会缺权限说明。

## 已知问题

- iOS 沙盒里读不到局域网设备的 MAC 地址，只能显示 IP 和主机名
- 服务器监测只能在打开 App 时刷新，做不了后台常驻

## License

MIT
