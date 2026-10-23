import SwiftUI

struct DashboardDisplaySettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("青色外环表示代理上传活动，紫色内环表示下载活动；圆环从下方开始填充，以各方向最近一分钟内的最高采样速度为满环，平滑过渡。圆环不表示带宽利用率。")
            Text("趋势图保留当前连接最近 5 分钟的数据，每 5 秒一个采样点，显示最近 1 分钟均速；采样中断时留空。隐藏窗口或开启系统“减少动态效果”时停止仪表盘动画。")
            Text("节点城市通过系统 DNS 和离线 IP 城市库估计，不采集设备定位，可能与实际服务器位置不同。近期连接来自 Xray 日志。")
            HStack {
                Link("IP Geolocation by DB-IP", destination: URL(string: "https://db-ip.com")!)
                Text("· CC BY 4.0 · 2026-10")
            }
        }.font(AppFont.caption).foregroundStyle(.secondary)
    }
}
