import SwiftUI

struct GlobeDisplaySettings: View {
    @AppStorage("globe.originCity") private var originCity = "上海"
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("本机城市", selection: $originCity) {
                Text("不显示本机位置").tag("")
                ForEach(GlobeOrigin.cities, id: \.city) { place in Text(place.city).tag(place.city) }
            }.frame(maxWidth: 320)
            Text("本机位置由你指定，默认上海；不采集设备定位。平面地图以太平洋为中心，比例与位置固定，上海、洛杉矶保持可见；视野外位置以边缘光点指示；不支持滚轮缩放。")
                .font(AppFont.caption).foregroundStyle(.secondary)
            Text("连接来自 Xray 日志，域名使用系统 DNS 解析，再查询离线城市库。位置仅为估计，可能与实际 CDN 节点不同；光点轨迹表示逻辑连接，不是实际网络路径。青色和紫色粒子分别随代理上行、下行流量显示，不能识别每一次加密请求的响应。")
                .font(AppFont.caption).foregroundStyle(.secondary)
            HStack {
                Link("IP Geolocation by DB-IP", destination: URL(string: "https://db-ip.com")!)
                Text("· CC BY 4.0 · 2026-10")
            }.font(AppFont.caption)
            Text("地图轮廓：基于 Natural Earth 公共领域海岸线绘制。")
                .font(AppFont.caption).foregroundStyle(.secondary)
        }
    }
}
