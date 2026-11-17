import AppKit
import CoreLocation
import CoreWLAN

// Bar shows Wi-Fi throughput, CPU load and memory use the way the i3status-rs
// net, cpu and memory blocks do on the Regolith bar, each with a menu of
// details, the Wi-Fi one in place of the system's.
final class Bar: NSObject, NSApplicationDelegate, NSMenuDelegate {
	// macOS places each new item left of the ones before it, so they are made
	// right to left to read net, cpu, mem.
	private let mem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	private let cpu = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	private let net = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	private let wifiMenu = NSMenu()
	private let cpuMenu = NSMenu()
	private let memMenu = NSMenu()
	// Monospaced throughout, not just the digits, so the width holds when K
	// turns to M and the items beside these never shift.
	private let font = NSFont.monospacedSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
	private let wifi = symbol("wifi", "Wi-Fi")
	private let wifiOff = symbol("wifi.slash", "Wi-Fi off")
	// Pinned to the Wi-Fi interface, as on Linux, so a wired or VPN link never
	// stands in for it. Looked up until found, since it may not exist yet when
	// the app starts at login.
	private var wifiName: String?
	private var device: String? {
		if wifiName == nil {
			wifiName = CWWiFiClient.shared().interface()?.interfaceName
		}
		return wifiName
	}
	// macOS gives an app the Wi-Fi network name only with Location access.
	private let location = CLLocationManager()
	private let clusters = cores()
	private var lastBytes: (rx: UInt32, tx: UInt32, at: Double)?
	private var lastTicks: [UInt32]?
	private var split = (user: 0.0, system: 0.0)

	func applicationDidFinishLaunching(_ notification: Notification) {
		// Named rather than numbered, so the place a user drags each item to,
		// and Hidden Bar's section for it, survive adding another item.
		for (item, name, menu) in [(net, "net", wifiMenu), (cpu, "cpu", cpuMenu), (mem, "mem", memMenu)] {
			item.autosaveName = name
			item.button?.font = font
			item.button?.imagePosition = .imageLeading
			menu.delegate = self
			item.menu = menu
		}
		cpu.button?.image = symbol("cpu", "CPU")
		mem.button?.image = symbol("memorychip", "Memory")
		if location.authorizationStatus == .notDetermined {
			location.requestWhenInUseAuthorization()
		}
		updateNet()
		updateCPU()
		updateMem()
		every(2, #selector(updateNet))
		every(5, #selector(updateCPU))
		every(5, #selector(updateMem))
	}

	private func every(_ seconds: TimeInterval, _ action: Selector) {
		let timer = Timer(timeInterval: seconds, target: self, selector: action, userInfo: nil, repeats: true)
		timer.tolerance = seconds / 10
		RunLoop.main.add(timer, forMode: .common)
	}

	// menuNeedsUpdate rebuilds a menu on every open, so it never shows stale
	// figures.
	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		switch menu {
		case cpuMenu:
			fillCPU(menu)
		case memMenu:
			fillMemory(menu)
		default:
			fillWiFi(menu)
		}
	}

	// The three menus follow the system Battery menu: a bold title with its
	// figure in gray, smaller dimmed detail lines, then sections of entries.
	private func fillWiFi(_ menu: NSMenu) {
		let wlan = device.flatMap { CWWiFiClient.shared().interface(withName: $0) }
		let on = wlan?.powerOn() ?? false
		wifiHeader(menu, on: on)
		var lines: [String] = []
		var needsLocation = false
		if let wlan, on {
			let ip = device.flatMap { link($0)?.ip }
			if let ssid = wlan.ssid() {
				lines.append("Network: \(ssid)")
			} else if ip == nil {
				lines.append("Not Connected")
			} else if location.authorizationStatus != .authorizedAlways {
				needsLocation = true
			}
			lines += wifiLines(wlan, ip: ip)
		}
		details(menu, lines)
		if needsLocation {
			add(menu, "Network Name Needs Location Access…", #selector(openLocationSettings))
		}
		menu.addItem(.separator())
		add(menu, "Open Wi-Fi Settings", #selector(openWiFiSettings))
	}

	private func fillCPU(_ menu: NSMenu) {
		header(menu, "CPU", String(format: "%.0f%%", split.user + split.system))
		var lines = [String(format: "User: %.0f%%, System: %.0f%%", split.user, split.system)]
		var loads = [Double](repeating: 0, count: 3)
		if getloadavg(&loads, 3) == 3 {
			lines.append(String(format: "Load Average: %.2f, %.2f, %.2f", loads[0], loads[1], loads[2]))
		}
		if !clusters.isEmpty {
			lines.append("Cores: \(clusters)")
		}
		lines.append("Thermal State: \(thermal(ProcessInfo.processInfo.thermalState))")
		details(menu, lines)
		processes(menu, top("pcpu", sortedBy: "-r"), { String(format: "%.0f%%", $0) }, #selector(openCPUTab))
		menu.addItem(.separator())
		add(menu, "Open Activity Monitor", #selector(openCPUTab))
	}

	private func fillMemory(_ menu: NSMenu) {
		let m = memory()
		header(menu, "Memory", m.map { String(format: "%.0f%%", $0.used / ram * 100) } ?? "")
		var lines: [String] = []
		if let m {
			lines.append("Used: \(gb(m.used)) of \(gb(ram))")
			lines.append("App: \(gb(m.app)), Wired: \(gb(m.wired)), Compressed: \(gb(m.compressed))")
		}
		if let level = pressure() {
			lines.append("Pressure: \(level)")
		}
		if let s = swap() {
			lines.append("Swap: \(gb(s.used)) of \(gb(s.total))")
		}
		details(menu, lines)
		processes(menu, top("rss", sortedBy: "-m"), { gb($0 * 1024) }, #selector(openMemoryTab))
		menu.addItem(.separator())
		add(menu, "Open Activity Monitor", #selector(openMemoryTab))
	}

	// header adds the bold title row with its figure in gray at the right. It
	// is a view, so it reads at full contrast without highlighting like an item.
	private func header(_ menu: NSMenu, _ text: String, _ value: String) {
		let name = title(text)
		let figure = NSTextField(labelWithString: value)
		figure.font = .monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
		figure.textColor = .secondaryLabelColor
		figure.sizeToFit()
		let height = name.frame.height + 8
		name.frame.origin = NSPoint(x: menuInset, y: (height - name.frame.height) / 2)
		figure.frame.origin = NSPoint(x: figureEdge - figure.frame.width, y: (height - figure.frame.height) / 2)
		add(menu, view: [name, figure], height: height)
	}

	// wifiHeader is the Wi-Fi title row with a switch at the right, as in the
	// system Wi-Fi menu.
	private func wifiHeader(_ menu: NSMenu, on: Bool) {
		let name = title("Wi-Fi")
		let toggle = Pill(isOn: on, label: "Wi-Fi") { [weak self] on in
			self?.setWiFi(on)
		}
		let height = max(name.frame.height, toggle.frame.height) + 8
		name.frame.origin = NSPoint(x: menuInset, y: (height - name.frame.height) / 2)
		toggle.frame.origin = NSPoint(x: figureEdge - 2 - toggle.frame.width, y: (height - toggle.frame.height) / 2)
		add(menu, view: [name, toggle], height: height)
	}

	private func title(_ text: String) -> NSTextField {
		let name = NSTextField(labelWithString: text)
		name.font = .boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)
		name.sizeToFit()
		return name
	}

	// details adds the lines that only report figures as one block of smaller
	// gray text, as the Battery menu does. Being a view, the lines sit close
	// together and never highlight, where disabled items would be spaced like
	// commands.
	private func details(_ menu: NSMenu, _ lines: [String]) {
		guard !lines.isEmpty else { return }
		let text = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
		text.font = detailFont
		text.textColor = .secondaryLabelColor
		text.preferredMaxLayoutWidth = valueColumn
		let size = text.fittingSize
		text.frame = NSRect(x: menuInset, y: 4, width: size.width, height: size.height)
		add(menu, view: [text], height: size.height + 8)
	}

	private func add(_ menu: NSMenu, view parts: [NSView], height: CGFloat) {
		let view = NSView(frame: NSRect(x: 0, y: 0, width: figureEdge + menuInset, height: height))
		parts.forEach(view.addSubview)
		let item = NSMenuItem()
		item.view = view
		menu.addItem(item)
	}

	// processes adds the Top Processes section, one row per process that opens
	// Activity Monitor, with the figure right-aligned under the header's.
	private func processes(_ menu: NSMenu, _ list: [Proc], _ figure: (Double) -> String, _ action: Selector) {
		guard !list.isEmpty else { return }
		menu.addItem(.separator())
		menu.addItem(.sectionHeader(title: "Top Processes"))
		for p in list {
			let item = menu.addItem(withTitle: p.name, action: action, keyEquivalent: "")
			item.target = self
			item.attributedTitle = NSAttributedString(string: "\(clip(p.name))\t\(figure(p.value))", attributes: rowAttributes)
		}
	}

	private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
		menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
	}

	private func setWiFi(_ on: Bool) {
		guard let name = device, let wlan = CWWiFiClient.shared().interface(withName: name) else { return }
		do {
			try wlan.setPower(on)
		} catch {
			NSLog("Net CPU: switching Wi-Fi power failed: %@", error.localizedDescription)
		}
		updateNet()
		// Rebuilt on the next turn of the run loop, not inside the switch's own
		// click, so the open menu shows the details and the switch for the state
		// Wi-Fi actually reached.
		DispatchQueue.main.async {
			self.menuNeedsUpdate(self.wifiMenu)
		}
	}

	@objc private func openCPUTab() {
		openActivityMonitor(tab: cpuTab)
	}

	@objc private func openMemoryTab() {
		openActivityMonitor(tab: memoryTab)
	}

	// Activity Monitor reads its tab only at launch and has no scripting for
	// tabs, so a running copy is quit and reopened on the tab. The tab is set
	// only after it exits, since it saves its own tab as it quits.
	private func openActivityMonitor(tab: Int) {
		let running = NSRunningApplication.runningApplications(withBundleIdentifier: activityMonitor)
		running.forEach { $0.terminate() }
		var waited = 0
		Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
			waited += 1
			guard running.allSatisfy(\.isTerminated) || waited >= 50 else { return }
			timer.invalidate()
			launchActivityMonitor(tab: tab)
		}
	}

	@objc private func openWiFiSettings() {
		NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
	}

	@objc private func openLocationSettings() {
		NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
	}

	@objc private func updateNet() {
		guard let button = net.button else { return }
		guard let name = device, let c = link(name), c.ip != nil else {
			lastBytes = nil
			button.image = wifiOff
			button.title = ""
			return
		}
		// CLOCK_MONOTONIC keeps counting through sleep, so bytes moved during a
		// dark wake are spread over the whole gap rather than one tick.
		let now = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
		var rx = 0.0
		var tx = 0.0
		if let last = lastBytes, now > last.at {
			// The counters are 32 bits; wrapping subtraction stays right across
			// one wrap, which takes far longer than a tick at Wi-Fi speeds. A
			// delta past resetBytes is a counter that went back to zero, not
			// traffic, so it reads as none.
			let drx = c.rx &- last.rx
			let dtx = c.tx &- last.tx
			rx = drx < resetBytes ? Double(drx) / (now - last.at) : 0
			tx = dtx < resetBytes ? Double(dtx) / (now - last.at) : 0
		}
		lastBytes = (c.rx, c.tx, now)
		button.image = wifi
		button.title = "rx \(eng(rx)) tx \(eng(tx))"
	}

	@objc private func updateCPU() {
		guard let button = cpu.button, let ticks = cpuTicks() else { return }
		var load = 0.0
		if let last = lastTicks {
			let d = zip(ticks, last).map { Double($0 &- $1) }
			let user = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
			let system = d[Int(CPU_STATE_SYSTEM)]
			let total = user + system + d[Int(CPU_STATE_IDLE)]
			if total > 0 {
				split = (user / total * 100, system / total * 100)
				load = split.user + split.system
			}
		}
		lastTicks = ticks
		show(String(format: "%2.0f%%", load), stateColor(load, warning: 60, critical: 90), on: button)
	}

	@objc private func updateMem() {
		guard let button = mem.button, let m = memory() else { return }
		let used = m.used / ram * 100
		show(String(format: "%2.0f%%", used), stateColor(used, warning: 80, critical: 95), on: button)
	}

	// show colors only the text. On macOS 27 a status button with a
	// contentTintColor drew nothing at all, icon and text included.
	private func show(_ text: String, _ color: NSColor?, on button: NSStatusBarButton) {
		guard let color else {
			button.title = text
			return
		}
		button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
	}
}

// Pill is an on/off switch drawn in the accent color whatever the app's state.
// NSSwitch draws its on state gray unless its app is active, and a menu bar app
// is not active while its menu is open.
final class Pill: NSView {
	private var isOn: Bool
	private let changed: (Bool) -> Void

	init(isOn: Bool, label: String, changed: @escaping (Bool) -> Void) {
		self.isOn = isOn
		self.changed = changed
		super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 18))
		setAccessibilityElement(true)
		setAccessibilityRole(.checkBox)
		setAccessibilityLabel(label)
	}

	required init?(coder: NSCoder) { nil }

	override func accessibilityValue() -> Any? { isOn }

	override func accessibilityPerformPress() -> Bool {
		flip()
		return true
	}

	override func mouseUp(with event: NSEvent) {
		flip()
	}

	private func flip() {
		isOn.toggle()
		needsDisplay = true
		changed(isOn)
	}

	override func draw(_ dirtyRect: NSRect) {
		let radius = bounds.height / 2
		(isOn ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
		NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
		let knob = bounds.height - 4
		let x = isOn ? bounds.maxX - knob - 2 : bounds.minX + 2
		NSColor.white.setFill()
		NSBezierPath(ovalIn: NSRect(x: x, y: 2, width: knob, height: knob)).fill()
	}
}

// eng formats bytes per second as i3status-rs's eng(w:3, prefix:K) does: three
// characters of number, then K, M, G or T.
func eng(_ bytesPerSecond: Double) -> String {
	let prefixes = ["K", "M", "G", "T"]
	var n = bytesPerSecond / 1000
	var i = 0
	while n >= 999.5, i < prefixes.count - 1 {
		n /= 1000
		i += 1
	}
	let digits = n < 9.95 ? String(format: "%.1f", n) : String(format: "%3.0f", n)
	return digits + prefixes[i]
}

func gb(_ bytes: Double) -> String {
	String(format: "%.1f GB", bytes / 1_073_741_824)
}

// stateColor follows an i3status-rs block's warning and critical states at the
// block's thresholds, in the system colors nearest the Linux theme's.
func stateColor(_ percent: Double, warning: Double, critical: Double) -> NSColor? {
	if percent >= critical {
		return .systemRed
	}
	if percent >= warning {
		return .systemYellow
	}
	return nil
}

// wifiLines lists the connection facts the Wi-Fi menu shows under the network
// name, leaving out any the driver does not report.
func wifiLines(_ wlan: CWInterface, ip: String?) -> [String] {
	var lines: [String] = []
	let rssi = wlan.rssiValue()
	if rssi != 0 {
		lines.append("Signal: \(rssi) dBm")
	}
	if let channel = wlan.wlanChannel() {
		lines.append("Channel: \(channel.channelNumber) (\(band(channel.channelBand)))")
	}
	let rate = wlan.transmitRate()
	if rate > 0 {
		lines.append(String(format: "Rate: %.0f Mbps", rate))
	}
	if let ip {
		lines.append("IP Address: \(ip)")
	}
	return lines
}

func band(_ b: CWChannelBand) -> String {
	switch b {
	case .band2GHz: return "2.4 GHz"
	case .band5GHz: return "5 GHz"
	case .band6GHz: return "6 GHz"
	default: return "unknown band"
	}
}

// link returns the interface's byte counters and its IPv4 address; Wi-Fi
// counts as connected while it holds one.
func link(_ name: String) -> (rx: UInt32, tx: UInt32, ip: String?)? {
	var head: UnsafeMutablePointer<ifaddrs>?
	guard getifaddrs(&head) == 0 else { return nil }
	defer { freeifaddrs(head) }
	var bytes: (rx: UInt32, tx: UInt32)?
	var ip: String?
	var next = head
	while let ifa = next?.pointee {
		next = ifa.ifa_next
		guard strcmp(ifa.ifa_name, name) == 0, let addr = ifa.ifa_addr else { continue }
		switch Int32(addr.pointee.sa_family) {
		case AF_LINK:
			if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
				bytes = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
			}
		case AF_INET:
			ip = ipv4(addr)
		default:
			break
		}
	}
	guard let bytes else { return nil }
	return (bytes.rx, bytes.tx, ip)
}

func ipv4(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
	var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
	var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
	guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil else { return nil }
	return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

// Menu layout. Item titles start 16 points in from a menu view's edge, and a
// label draws its text 2 points in from its frame, so a label at menuInset
// lines up with item titles and one ending at figureEdge lines up with figures
// on a valueColumn tab stop (measured on macOS 27).
let menuInset: CGFloat = 14
let valueColumn: CGFloat = 230
let figureEdge = menuInset + valueColumn + 4
let detailFont = NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2)

let rowAttributes: [NSAttributedString.Key: Any] = {
	let style = NSMutableParagraphStyle()
	style.tabStops = [NSTextTab(textAlignment: .right, location: valueColumn)]
	return [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style]
}()

func clip(_ name: String) -> String {
	name.count > 24 ? name.prefix(23) + "…" : name
}

let activityMonitor = "com.apple.ActivityMonitor"

// resetBytes is more than Wi-Fi moves in a tick, 2 GB, and well short of the
// 4 GB a 32-bit counter wraps at.
let resetBytes: UInt32 = 1 << 31

// Activity Monitor's SelectedTab values.
let cpuTab = 0
let memoryTab = 1

// launchActivityMonitor opens Activity Monitor on the tab, in front, with its
// main window showing.
func launchActivityMonitor(tab: Int) {
	CFPreferencesSetAppValue("SelectedTab" as CFString, tab as CFNumber, activityMonitor as CFString)
	CFPreferencesAppSynchronize(activityMonitor as CFString)
	guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: activityMonitor) else { return }
	NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

// mach_host_self returns a new send right on every call, so it is taken once.
let host = mach_host_self()
let ram = Double(ProcessInfo.processInfo.physicalMemory)

// Memory is RAM in use by kind, in bytes. Used counts the three kinds that
// make up Activity Monitor's Memory Used.
struct Memory {
	var app, wired, compressed: Double

	var used: Double { app + wired + compressed }
}

func memory() -> Memory? {
	var info = vm_statistics64()
	var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
	let status = withUnsafeMutablePointer(to: &info) {
		$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
			host_statistics64(host, HOST_VM_INFO64, $0, &count)
		}
	}
	guard status == KERN_SUCCESS else { return nil }
	let page = Double(vm_kernel_page_size)
	let app = max(Double(info.internal_page_count) - Double(info.purgeable_count), 0)
	return Memory(app: app * page, wired: Double(info.wire_count) * page, compressed: Double(info.compressor_page_count) * page)
}

// pressure names the kernel's memory pressure level, which it reports as 1,
// 2 or 4, the values of the DISPATCH_MEMORYPRESSURE_* flags.
func pressure() -> String? {
	guard let level = sysctlInt("kern.memorystatus_vm_pressure_level") else { return nil }
	switch level {
	case 1: return "Normal"
	case 2: return "Warning"
	case 4: return "Critical"
	default: return "level \(level)"
	}
}

func swap() -> (used: Double, total: Double)? {
	var usage = xsw_usage()
	var size = MemoryLayout<xsw_usage>.size
	guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
	return (Double(usage.xsu_used), Double(usage.xsu_total))
}

// cores lists the CPU clusters by the names macOS gives them, most powerful
// first.
func cores() -> String {
	let levels = sysctlInt("hw.nperflevels") ?? 0
	return (0..<levels).compactMap { level -> String? in
		guard let n = sysctlInt("hw.perflevel\(level).logicalcpu"),
		      let name = sysctlString("hw.perflevel\(level).name") else { return nil }
		return "\(n) \(name)"
	}.joined(separator: ", ")
}

func thermal(_ state: ProcessInfo.ThermalState) -> String {
	switch state {
	case .nominal: return "Nominal"
	case .fair: return "Fair"
	case .serious: return "Serious"
	case .critical: return "Critical"
	@unknown default: return "Unknown"
	}
}

struct Proc {
	var value: Double
	var name: String
}

// top returns the first three processes ps lists when sorted by -r (CPU) or
// -m (memory), each with the value of the given column. ps's CPU figure is a
// decaying average, and its memory figure is resident size, which is close to
// but not Activity Monitor's Memory column.
func top(_ column: String, sortedBy flag: String) -> [Proc] {
	let ps = Process()
	ps.executableURL = URL(fileURLWithPath: "/bin/ps")
	ps.arguments = ["-Aceo", "\(column)=,comm=", flag]
	let out = Pipe()
	ps.standardOutput = out
	do {
		try ps.run()
	} catch {
		NSLog("Net CPU: running ps failed: %@", error.localizedDescription)
		return []
	}
	let data = out.fileHandleForReading.readDataToEndOfFile()
	ps.waitUntilExit()
	return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(3).compactMap { line in
		let fields = line.split(separator: " ", maxSplits: 1)
		guard fields.count == 2, let value = Double(fields[0]) else { return nil }
		return Proc(value: value, name: fields[1].trimmingCharacters(in: .whitespaces))
	}
}

func sysctlInt(_ name: String) -> Int32? {
	var value: Int32 = 0
	var size = MemoryLayout<Int32>.size
	guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
	return value
}

func sysctlString(_ name: String) -> String? {
	var size = 0
	guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
	var buf = [CChar](repeating: 0, count: size)
	guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
	return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

// cpuTicks returns the ticks spent in each CPU state, indexed by CPU_STATE_*.
func cpuTicks() -> [UInt32]? {
	var info = host_cpu_load_info()
	var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
	let status = withUnsafeMutablePointer(to: &info) {
		$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
			host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
		}
	}
	guard status == KERN_SUCCESS else { return nil }
	let t = info.cpu_ticks
	return [t.0, t.1, t.2, t.3]
}

func symbol(_ name: String, _ description: String) -> NSImage? {
	let config = NSImage.SymbolConfiguration(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
	return NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(config)
}

let bar = Bar()
NSApplication.shared.delegate = bar
NSApplication.shared.run()
