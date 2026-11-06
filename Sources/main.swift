
import SwiftUI
import AppKit
import IOKit
import Darwin
import Combine

func dbg(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let url = URL(fileURLWithPath: "/tmp/sysmon-debug.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// ============ Clash 流量 ============
enum Clash {
    static let candidates = [
        "/var/run/clash-verge-service/users/501/verge-mihomo.sock",
        "/tmp/verge-mihomo.sock"
    ]

    static func totals() -> (down: Double, up: Double)? {
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let t = query(path) { return t }
        }
        return nil
    }

    private static func dechunk(_ d: Data) -> Data {
        var out = Data()
        var i = d.startIndex
        let crlf = Data("\r\n".utf8)
        while i < d.endIndex {
            guard let nl = d.range(of: crlf, in: i..<d.endIndex) else { break }
            guard let sizeStr = String(data: d[i..<nl.lowerBound], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces),
                  let size = Int(sizeStr, radix: 16) else { return d }
            if size == 0 { break }
            let start = nl.upperBound
            let end = min(start + size, d.endIndex)
            out.append(d[start..<end])
            i = min(end + 2, d.endIndex)
        }
        return out
    }

    private static func query(_ path: String) -> (Double, Double)? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                    _ = strncpy(dst, src, cap - 1)
                }
            }
        }
        let ok = withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 { dbg("connect fail errno=\(errno)"); return nil }

        let req = "GET /connections HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.count > 16_000_000 { break }
        }
        guard !data.isEmpty else { dbg("empty response"); return nil }

        var body = data
        if let sep = data.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8) ?? ""
            body = data[sep.upperBound...]
            if head.lowercased().contains("transfer-encoding: chunked") { body = dechunk(body) }
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            dbg("parse fail bytes=\(body.count)"); return nil
        }
        guard let d = (json["downloadTotal"] as? NSNumber)?.doubleValue,
              let u = (json["uploadTotal"] as? NSNumber)?.doubleValue else {
            dbg("cast fail keys=\(json.keys)"); return nil
        }
        return (d, u)
    }
}

// ============ 进程排行 ============
struct Proc: Identifiable {
    let id = UUID()
    var name: String
    var cpu: Double
    var pid: Int32
}

func topProcesses(_ limit: Int) -> [Proc] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-A", "-o", "pcpu=,pid=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return [] }

    var agg: [String: (cpu: Double, pid: Int32)] = [:]
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let v = Double(parts[0]), let pid = Int32(parts[1]) else { continue }
        var name = String(parts[2]).trimmingCharacters(in: .whitespaces)
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.isEmpty { continue }
        if let cur = agg[name] {
            agg[name] = (cur.cpu + v, v > cur.cpu ? pid : cur.pid)
        } else {
            agg[name] = (v, pid)
        }
    }
    return agg.map { Proc(name: $0.key, cpu: $0.value.cpu, pid: $0.value.pid) }
        .sorted { $0.cpu > $1.cpu }
        .prefix(limit)
        .map { $0 }
}

// ============ 系统指标 ============
struct Snapshot {
    var cpu: Double = 0
    var gpu: Double = 0
    var ramGB: Double = 0
    var down: Double = 0
    var up: Double = 0
    var downHist: [Double] = []
    var upHist: [Double] = []
    var clashOK = false
}

final class Stats: ObservableObject {
    @Published var s = Snapshot()
    private var timer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "mon.sample", qos: .utility)
    private var prevCPU: (used: UInt64, total: UInt64)?
    private var prevTraffic: (down: Double, up: Double, t: CFAbsoluteTime)?

    init() { start() }

    func refreshNow() {
        q.async { [weak self] in self?.sample() }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func sample() {
        let cpu = sampleCPU()
        let gpu = sampleGPU()
        let ram = sampleRAM()
        var down = 0.0, up = 0.0, ok = false
        if let t = Clash.totals() {
            let now = CFAbsoluteTimeGetCurrent()
            if let p = prevTraffic {
                let dt = max(now - p.t, 0.05)
                down = max(0, (t.down - p.down) / dt)
                up = max(0, (t.up - p.up) / dt)
            }
            prevTraffic = (t.down, t.up, now)
            ok = true
        } else {
            prevTraffic = nil
        }
        DispatchQueue.main.async {
            var n = self.s
            n.cpu = cpu; n.gpu = gpu; n.ramGB = ram
            n.down = ok ? down : 0
            n.up = ok ? up : 0
            n.clashOK = ok
            n.downHist.append(ok ? down : 0); n.upHist.append(ok ? up : 0)
            if n.downHist.count > 60 { n.downHist.removeFirst(n.downHist.count - 60) }
            if n.upHist.count > 60 { n.upHist.removeFirst(n.upHist.count - 60) }
            self.s = n
        }
    }

    private func sampleCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0)
        let sys  = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let used = user &+ sys &+ nice
        let total = used &+ idle
        defer { prevCPU = (used, total) }
        guard let p = prevCPU, total > p.total else { return 0 }
        let dUsed = Double(used &- p.used)
        let dTotal = Double(total &- p.total)
        return dTotal > 0 ? (dUsed / dTotal) * 100 : 0
    }

    private func sampleGPU() -> Double {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }
        var entry = IOIteratorNext(iter)
        var best = 0.0
        while entry != 0 {
            if let props = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let v = props["Device Utilization %"] as? Int {
                best = max(best, Double(v))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return best
    }

    private func sampleRAM() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        let active = Double(stats.active_count) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        return (active + wired + compressed) / 1_073_741_824
    }
}

// ============ 界面 ============
let cUp = Color(red: 1.00, green: 0.62, blue: 0.38)
let cDown = Color(red: 0.32, green: 0.58, blue: 1.00)
let cText = Color.white.opacity(0.92)
let cDim = Color.white.opacity(0.42)

func fmtRate(_ v: Double) -> String {
    if v >= 1_048_576 { return String(format: "%.2f MB/s", v / 1_048_576) }
    if v >= 1024 { return String(format: "%.1f KB/s", v / 1024) }
    return String(format: "%.0f B/s", v)
}

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    BlurBG()
                    Color.black.opacity(0.10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.08)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.8
                    )
            )
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}

let glassVariant: Int = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--mat"), i + 1 < a.count { return Int(a[i + 1]) ?? 0 }
    return 0
}()

struct BlurBG: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        switch glassVariant {
        case 1: v.material = .popover
        case 2: v.material = .menu
        case 3: v.material = .underWindowBackground
        case 4: v.material = .fullScreenUI
        default: v.material = .hudWindow
        }
        v.appearance = NSAppearance(named: .darkAqua)
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// 指针表
struct Dial: View {
    var value: Double
    var tint: Color
    var size: CGFloat
    var label: String = ""

    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let R = min(sz.width, sz.height) / 2 - 2.5
            let start = 145.0, sweep = 250.0
            func rad(_ deg: Double) -> Double { deg * .pi / 180 }

            var track = Path()
            track.addArc(center: c, radius: R, startAngle: .degrees(start),
                         endAngle: .degrees(start + sweep), clockwise: false)
            ctx.stroke(track, with: .color(.white.opacity(0.14)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

            let v = min(max(value, 0), 100)
            var arc = Path()
            arc.addArc(center: c, radius: R, startAngle: .degrees(start),
                       endAngle: .degrees(start + sweep * v / 100), clockwise: false)
            ctx.stroke(arc, with: .color(tint.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

            for i in 0...8 {
                let a = rad(start + sweep * Double(i) / 8)
                let major = i % 4 == 0
                let r1 = R - (major ? 6 : 4)
                let r2 = R - 2
                var t = Path()
                t.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                t.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
                ctx.stroke(t, with: .color(.white.opacity(major ? 0.40 : 0.16)),
                           style: StrokeStyle(lineWidth: major ? 1.1 : 0.7, lineCap: .round))
            }

            let na = rad(start + sweep * v / 100)
            var needle = Path()
            needle.move(to: CGPoint(x: c.x - cos(na) * R * 0.14, y: c.y - sin(na) * R * 0.14))
            needle.addLine(to: CGPoint(x: c.x + cos(na) * R * 0.66, y: c.y + sin(na) * R * 0.66))
            ctx.stroke(needle, with: .color(.white.opacity(0.92)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2)),
                     with: .color(tint))

            if !label.isEmpty {
                let t = Text(label)
                    .font(.system(size: 6, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                ctx.draw(t, at: CGPoint(x: c.x, y: c.y - R * 0.42), anchor: .center)

                let p = Text("\(Int(v.rounded()))")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                ctx.draw(p, at: CGPoint(x: c.x, y: c.y + R * 0.52), anchor: .center)
            }
        }
        .frame(width: size, height: size)
    }
}

struct Sparkline: View {
    var up: [Double]
    var down: [Double]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let peak = max((up + down).max() ?? 1, 2048)
            ZStack {
                curve(up, peak, w, h).stroke(cUp.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                curve(down, peak, w, h).stroke(cDown,
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
        }
    }

    func curve(_ vals: [Double], _ peak: Double, _ w: CGFloat, _ h: CGFloat) -> Path {
        var p = Path()
        guard vals.count > 1 else { return p }
        let step = w / CGFloat(max(vals.count - 1, 1))
        for (i, v) in vals.enumerated() {
            let x = CGFloat(i) * step
            let y = h - CGFloat(min(v / peak, 1)) * (h - 4) - 2
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

final class UIState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = true
    @Published var procs: [Proc] = []
    @Published var resizing = false
    @Published var scale: CGFloat {
        didSet { UserDefaults.standard.set(Double(scale), forKey: "panelScale") }
    }

    init() {
        let s = UserDefaults.standard.double(forKey: "panelScale")
        scale = s > 0.3 ? CGFloat(s) : 1.0
    }

    func refreshProcs() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = topProcesses(6)
            DispatchQueue.main.async { self?.procs = list }
        }
    }
}

struct PanelView: View {
    @ObservedObject var stats: Stats
    @ObservedObject var ui: UIState
    var W: CGFloat = 268

    @State private var startScale: CGFloat?

    var body: some View {
        content
            .scaleEffect(ui.scale, anchor: .topLeading)
            .frame(width: W * ui.scale, height: 78 * ui.scale, alignment: .topLeading)
            .overlay(alignment: .topLeading) { grip }
            .preferredColorScheme(.dark)
    }

    var grip: some View {
        Image(systemName: "arrow.up.left")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(.white.opacity(0.20))
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if startScale == nil { startScale = ui.scale; ui.resizing = true }
                        // 面板钉在右下角，所以往左上拖＝放大
                        let d = -(v.translation.width + v.translation.height) / 2 / W
                        ui.scale = min(max((startScale ?? 1) + d, 0.6), 2.0)
                    }
                    .onEnded { _ in startScale = nil; ui.resizing = false }
            )
            .help("拖动缩放")
    }

    var content: some View {
        mainRow
            .frame(width: W, height: 78)
            .glassCard()
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 1) {
                    Button {
                        stats.refreshNow()
                        ui.refreshProcs()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(cDim)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { ui.pinned.toggle() } label: {
                        Image(systemName: ui.pinned ? "pin.fill" : "pin.slash")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(ui.pinned ? cText : cDim)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .offset(x: -4, y: 4)
            }
            .preferredColorScheme(.dark)
    }

    var mainRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(stats.s.clashOK ? Color(red: 0.36, green: 0.86, blue: 0.52) : cUp)
                        .frame(width: 4, height: 4)
                    Text("Clash Verge")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(cDim)
                        .tracking(0.3)
                    Spacer(minLength: 0)
                    Text(String(format: "%.1fG", stats.s.ramGB))
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(cDim)
                }

                Sparkline(up: stats.s.upHist, down: stats.s.downHist)
                    .frame(height: 18)

                HStack(spacing: 3) {
                    Text("↑").font(.system(size: 8, weight: .bold)).foregroundStyle(cUp)
                    Text(fmtRate(stats.s.up))
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(cUp)
                    Spacer(minLength: 0)
                    Text("↓").font(.system(size: 8, weight: .bold)).foregroundStyle(cDown)
                    Text(fmtRate(stats.s.down))
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(cDown)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { openClash() }

            Rectangle().fill(.white.opacity(0.10)).frame(width: 1).frame(maxHeight: .infinity)

            HStack(alignment: .center, spacing: 4) {
                Dial(value: stats.s.cpu, tint: cDown, size: 44, label: "CPU")
                Dial(value: stats.s.gpu, tint: cUp, size: 44, label: "GPU")
            }
            .contentShape(Rectangle())
            .onTapGesture { ui.expanded.toggle() }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    func openClash() {
        let url = URL(fileURLWithPath: "/Applications/Clash Verge.app")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            if let err = err { dbg("open clash fail \(err)") }
        }
    }
}

// 独立的进程明细卡（单独一个窗口，主面板永远不变形）
struct ProcListCard: View {
    @ObservedObject var ui: UIState
    var W: CGFloat = 268

    var body: some View {
        rows
            .scaleEffect(ui.scale, anchor: .topLeading)
            .frame(width: W * ui.scale, height: 106 * ui.scale, alignment: .topLeading)
            .preferredColorScheme(.dark)
    }

    var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ui.procs.prefix(6))) { p in
                HStack(spacing: 6) {
                    Text(p.name)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(cText.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f%%", p.cpu))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(cDim)
                    Button { killProc(p) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 15)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(width: W, alignment: .leading)
        .glassCard()
        .preferredColorScheme(.dark)
    }

    func killProc(_ p: Proc) {
        let alert = NSAlert()
        alert.messageText = "结束 \(p.name)？"
        alert.informativeText = "PID \(p.pid) · 占用 \(Int(p.cpu))% CPU。会像「强制退出」一样关掉它。"
        alert.addButton(withTitle: "结束")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            kill(p.pid, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ui.refreshProcs() }
        }
    }
}

// ============ App ============
final class Panel: NSPanel {
    // 默认 AppKit 会把窗口塞回「屏幕可用区域」，导致贴底时被 Dock 顶上去
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var listPanel: NSPanel!
    var statusItem: NSStatusItem!
    let stats = Stats()
    let ui = UIState()
    var sinkPin: AnyCancellable?
    var sinkExp: AnyCancellable?
    var sinkScale: AnyCancellable?
    var sinkResize: AnyCancellable?
    var corner: CGPoint?
    var pinMenuItem: NSMenuItem?

    let W: CGFloat = 268
    let H: CGFloat = 78
    let LH: CGFloat = 106

    func makePanel(_ content: NSView, size: NSSize) -> NSPanel {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)

        let p = Panel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = container
        p.appearance = NSAppearance(named: .darkAqua)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        return p
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let s = ui.scale
        let host = NSHostingView(rootView: PanelView(stats: stats, ui: ui))
        panel = makePanel(host, size: NSSize(width: W * s, height: H * s))
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let listHost = NSHostingView(rootView: ProcListCard(ui: ui))
        listPanel = makePanel(listHost, size: NSSize(width: W * s, height: LH * s))
        listPanel.isMovableByWindowBackground = false

        var origin = anchorPoint()
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            let parts = saved.split(separator: ",")
            if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                let sf = (NSScreen.main ?? NSScreen.screens[0]).frame
                let inside = x >= sf.minX - 20 && x <= sf.maxX - 60
                    && y >= sf.minY - 20 && y <= sf.maxY - 60
                if inside { origin = NSPoint(x: x, y: y) }
            }
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: W * s, height: H * s), display: false)
        panel.orderFrontRegardless()

        if CommandLine.arguments.contains("--expanded") { ui.expanded = true }

        sinkPin = ui.$pinned.sink { [weak self] p in
            self?.panel.level = p ? .floating : .normal
            self?.listPanel.level = p ? .floating : .normal
            self?.pinMenuItem?.state = p ? .on : .off
        }
        sinkExp = ui.$expanded.sink { [weak self] exp in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if exp {
                    self.positionList()
                    self.listPanel.orderFrontRegardless()
                    self.ui.refreshProcs()
                } else {
                    self.listPanel.orderOut(nil)
                }
            }
        }
        sinkScale = ui.$scale.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyScale() }
        }
        sinkResize = ui.$resizing.sink { [weak self] on in
            guard let self = self else { return }
            if on {
                self.corner = CGPoint(x: self.panel.frame.maxX, y: self.panel.frame.minY)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.corner = nil }
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Clash Verge 码表")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示 / 隐藏", action: #selector(toggle), keyEquivalent: "h"))
        let pin = NSMenuItem(title: "固定在最上层", action: #selector(togglePin), keyEquivalent: "p")
        pin.state = ui.pinned ? .on : .off
        pinMenuItem = pin
        menu.addItem(pin)
        menu.addItem(NSMenuItem(title: "展开 / 收起进程", action: #selector(toggleExpand), keyEquivalent: "e"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "放大", action: #selector(bigger), keyEquivalent: "+"))
        menu.addItem(NSMenuItem(title: "缩小", action: #selector(smaller), keyEquivalent: "-"))
        menu.addItem(NSMenuItem(title: "实际大小", action: #selector(resetScale), keyEquivalent: "0"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "回到右下角", action: #selector(snapBack), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.ui.expanded { self.ui.refreshProcs() }
        }
    }

    func anchorPoint() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.frame
        return NSPoint(x: sf.maxX - W * ui.scale - 46, y: sf.minY)
    }

    func applyScale() {
        let s = ui.scale
        var f = panel.frame
        let right = corner?.x ?? f.maxX
        let bottom = corner?.y ?? f.minY
        f.size = NSSize(width: W * s, height: H * s)
        f.origin.x = right - f.size.width
        f.origin.y = bottom
        panel.setFrame(f, display: true)
        if ui.expanded { positionList() } else { listPanel.setContentSize(NSSize(width: W * s, height: LH * s)) }
    }

    func positionList() {
        let s = ui.scale
        let pf = panel.frame
        listPanel.setFrame(NSRect(x: pf.minX, y: pf.maxY + 6 * s, width: W * s, height: LH * s),
                           display: true)
    }

    func windowDidMove(_ n: Notification) {
        let o = panel.frame.origin
        let sf = (NSScreen.main ?? NSScreen.screens[0]).frame
        if o.y >= sf.minY - 20 && o.y <= sf.maxY - 60 && o.x >= sf.minX - 20 {
            UserDefaults.standard.set("\(o.x),\(o.y)", forKey: "panelOrigin")
        }
        if ui.expanded { positionList() }
    }

    @objc func bigger() { ui.scale = min(ui.scale + 0.1, 2.0) }
    @objc func smaller() { ui.scale = max(ui.scale - 0.1, 0.6) }
    @objc func resetScale() { ui.scale = 1.0 }

    @objc func snapBack() {
        let o = anchorPoint()
        panel.setFrame(NSRect(x: o.x, y: o.y, width: W * ui.scale, height: H * ui.scale), display: true)
        if ui.expanded { positionList() }
    }

    @objc func toggleExpand() { ui.expanded.toggle() }

    @objc func togglePin() { ui.pinned.toggle() }

    @objc func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            listPanel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
            if ui.expanded { positionList(); listPanel.orderFrontRegardless() }
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
