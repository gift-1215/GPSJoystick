import CoreImage.CIFilterBuiltins
import MapKit
import SwiftUI

private let canvasColor = Color(red: 0.075, green: 0.10, blue: 0.095)
private let panel = Color(red: 0.105, green: 0.135, blue: 0.12)
private let surface = Color(red: 0.14, green: 0.18, blue: 0.155)
private let line = Color(red: 0.22, green: 0.26, blue: 0.225)
private let foreground = Color(red: 0.93, green: 0.96, blue: 0.91)
private let secondary = Color(red: 0.66, green: 0.73, blue: 0.68)
private let accent = Color(red: 0.85, green: 0.96, blue: 0.43)
private let warning = Color(red: 1, green: 0.76, blue: 0.48)

struct ControllerView: View {
    @ObservedObject var model: SimulatorModel
    @StateObject private var placeSearch = PlaceSearch()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(line).frame(height: 1)
            HStack(spacing: 0) {
                mapPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(line).frame(width: 1)
                controls
                    .frame(width: 316)
                    .background(panel)
            }
        }
        .background(canvasColor)
        .foregroundStyle(foreground)
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(canvasColor)
                .frame(width: 39, height: 39)
                .background(accent, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("GPS 搖桿")
                    .font(.system(size: 22, weight: .semibold))
                Text("iPhone 定位模擬")
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusTitle).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(surface, in: Capsule())
            .overlay(Capsule().strokeBorder(line))
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
    }

    private var mapPanel: some View {
        ZStack(alignment: .topLeading) {
            LocationMap(
                position: model.navigation.position,
                bearing: model.navigation.bearing,
                trail: model.navigation.trail,
                pickingStart: model.pickingStart,
                following: model.following && !model.pickingStart && placeSearch.preview == nil,
                focusRequest: model.mapFocusRequest,
                zoomRequest: model.zoomRequest,
                previewPlace: placeSearch.preview,
                chooseStart: model.setStart,
                regionChanged: { placeSearch.mapRegion = $0 }
            )

            HStack {
                Button {
                    closeSearch()
                    model.pickingStart.toggle()
                } label: {
                    Label(model.pickingStart ? "取消選點" : "選擇起點",
                          systemImage: model.pickingStart ? "xmark" : "mappin.circle")
                }
                .buttonStyle(ControlButton(prominent: model.pickingStart))
                Button {
                    if placeSearch.isOpen {
                        closeSearch()
                    } else {
                        model.pickingStart = false
                        placeSearch.isOpen = true
                    }
                } label: {
                    Label("搜尋地點", systemImage: "magnifyingglass")
                }
                .buttonStyle(ControlButton(selected: placeSearch.isOpen))
                .accessibilityIdentifier("open-place-search")
                Spacer()
                Toggle(isOn: $model.following) {
                    Label("跟隨位置", systemImage: "location.fill")
                }
                .toggleStyle(FollowToggle())
                Button {
                    closeSearch()
                    model.recenterMap()
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 20, height: 16)
                }
                .buttonStyle(ControlButton())
                .help("回到模擬位置")
                .accessibilityLabel("回到模擬位置")
            }
            .padding(17)
            .zIndex(2)

            if placeSearch.isOpen {
                searchPanel
                    .padding(.leading, 17)
                    .padding(.top, 65)
                    .zIndex(1)
            }

            if model.pickingStart {
                Text("點一下地圖，將搖桿的起點移到該處")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(canvasColor, in: Capsule())
                    .overlay(Capsule().strokeBorder(line))
                    .padding(.leading, 17)
                    .padding(.top, 65)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .trailing, spacing: 10) {
                Spacer()
                VStack(spacing: 5) {
                    zoomButton("plus", label: "放大地圖", steps: 1)
                    zoomButton("minus", label: "縮小地圖", steps: -1)
                }
                telemetry
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 17)
            .padding(.bottom, 35)
        }
    }

    private var searchRegion: MKCoordinateRegion {
        placeSearch.mapRegion ?? MKCoordinateRegion(
            center: model.navigation.position.coordinate, latitudinalMeters: 8_000, longitudinalMeters: 8_000
        )
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TextField("地址、地標或店家", text: Binding(
                    get: { placeSearch.query },
                    set: { query in
                        placeSearch.query = query
                        placeSearch.preview = nil
                        placeSearch.update(query: query, region: searchRegion)
                    }
                ))
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityIdentifier("place-query")
                    .onAppear { searchFocused = true }
                    .onSubmit(submitQuery)
                Button(action: submitQuery) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(ControlButton())
                .disabled(placeSearch.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("搜尋")
            }
            if let previewPlace = placeSearch.preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(previewPlace.name).fontWeight(.semibold)
                    if !previewPlace.address.isEmpty && previewPlace.address != previewPlace.name {
                        Text(previewPlace.address).font(.caption).foregroundStyle(secondary)
                    }
                    Button {
                        model.setStart(previewPlace.point)
                        closeSearch()
                        model.recenterMap()
                    } label: {
                        Label("設為起點", systemImage: "mappin.circle")
                    }
                    .buttonStyle(ControlButton(prominent: true))
                    .accessibilityIdentifier("set-search-start")
                    Button("返回搜尋結果") { placeSearch.preview = nil }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(accent)
                }
            } else if placeSearch.searching {
                ProgressView("搜尋中…").controlSize(.small)
            } else if let message = placeSearch.message {
                Text(message).font(.caption).foregroundStyle(secondary)
            } else if !placeSearch.places.isEmpty || !placeSearch.suggestions.isEmpty {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(placeSearch.places) { place in
                            searchRow(place.name, subtitle: place.address) {
                                placeSearch.preview = place
                                searchFocused = false
                            }
                        }
                        ForEach(Array(placeSearch.suggestions.enumerated()), id: \.offset) { item in
                            searchRow(item.element.title, subtitle: item.element.subtitle) {
                                searchFocused = false
                                placeSearch.submit(item.element, region: searchRegion)
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(12)
        .frame(width: 325, alignment: .leading)
        .background(canvasColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(line))
        .onExitCommand(perform: closeSearch)
    }

    private func searchRow(_ title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !subtitle.isEmpty && subtitle != title {
                    Text(subtitle).font(.caption).foregroundStyle(secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(surface, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func submitQuery() {
        placeSearch.preview = nil
        placeSearch.submit(query: placeSearch.query, region: searchRegion)
    }

    private func closeSearch() {
        placeSearch.isOpen = false
        searchFocused = false
        placeSearch.query = ""
        placeSearch.preview = nil
        placeSearch.reset()
    }

    private func zoomButton(_ icon: String, label: String, steps: Int) -> some View {
        Button {
            model.zoomMap(by: steps)
        } label: {
            Image(systemName: icon).frame(width: 16, height: 15)
        }
        .buttonStyle(ControlButton())
        .help(label)
        .accessibilityLabel(label)
    }

    private var telemetry: some View {
        HStack(spacing: 0) {
            metric("緯度", String(format: "%.6f", model.navigation.position.latitude))
            metric("經度", String(format: "%.6f", model.navigation.position.longitude))
            metric("移動距離", distanceLabel)
        }
        .padding(.vertical, 11)
        .background(canvasColor.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(line))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .accessibilityIdentifier("telemetry-\(label)")
        }
        .frame(minWidth: 98, alignment: .leading)
        .padding(.horizontal, 13)
    }

    private var distanceLabel: String {
        let distance = model.navigation.distance
        if distance >= 1000 {
            return String(format: "%.2f km", distance / 1000)
        }
        return String(format: "%.1f m", distance)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                directionControls
                Rectangle().fill(line).frame(height: 1)
                speedControls
                Rectangle().fill(line).frame(height: 1)
                StepControls(model: model, broadcaster: model.stepBroadcaster)
                Rectangle().fill(line).frame(height: 1)
                deviceControls
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 19)
        }
        .scrollIndicators(.automatic)
    }

    private var directionControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle("方向", "location.north.line")
                Spacer()
                Text(String(format: "%03d°", Int(model.navigation.bearing.rounded()) % 360))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .accessibilityLabel("航向")
            }
            HStack(spacing: 12) {
                Joystick(input: model.input, onChange: model.setPointer)
                    .frame(width: 154, height: 154)
                    .frame(maxWidth: .infinity)
                motionButton
            }
            Text("拖曳搖桿或按方向鍵，放開後持續移動")
                .font(.system(size: 12))
                .foregroundStyle(secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private var motionButton: some View {
        let isMoving = model.motion == .moving
        let hasDirection = model.motion != .awaitingDirection

        return Button(action: model.toggleMotion) {
            Label(isMoving ? "暫停" : "開始", systemImage: isMoving ? "pause.fill" : "play.fill")
                .frame(minWidth: 46)
        }
        .buttonStyle(ControlButton(prominent: !isMoving && hasDirection))
        .disabled(!hasDirection)
        .opacity(hasDirection ? 1 : 0.55)
        .accessibilityIdentifier("motion-toggle")
    }

    private var speedControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("速度", "speedometer")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", model.currentSpeed))
                    .font(.system(size: 34, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.identity)
                    .accessibilityIdentifier("current-speed")
                Text("km/h")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("設定速度")
                        .font(.system(size: 10))
                        .foregroundStyle(secondary)
                    Text(String(format: "%.0f km/h", model.targetSpeed))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                }
            }
            Slider(value: Binding(get: { model.targetSpeed }, set: model.setTargetSpeed), in: 0...120, step: 1) {
                Text("設定速度")
            }
            .labelsHidden()
            .accessibilityIdentifier("target-speed")
            HStack(spacing: 7) {
                preset("步行", speed: 5)
                preset("單車", speed: 18)
                preset("開車", speed: 50)
            }
        }
    }

    private func preset(_ label: String, speed: Double) -> some View {
        Button {
            model.setTargetSpeed(speed)
        } label: {
            Text(label)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ControlButton(selected: model.targetSpeed == speed))
        .help("\(Int(speed)) km/h")
        .accessibilityLabel("\(label)，\(Int(speed)) 公里每小時")
    }

    private var deviceControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("iPhone", "iphone")
            Text(deviceDescription)
                .font(.system(size: 12))
                .foregroundStyle(model.connectionError == nil ? secondary : warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("device-status")

            if model.restoreUnconfirmed && (model.phase == .preview || model.phase == .failed || model.phase == .ready) {
                Text("尚未確認定位已恢復。重接原本的 iPhone，再按「恢復定位」。")
                    .font(.system(size: 12))
                    .foregroundStyle(warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch model.phase {
            case .preview, .failed:
                if model.needsSetup {
                    deviceButton("安裝連線元件", icon: "arrow.down.circle", prominent: true, action: model.setupDeviceSupport)
                }
                deviceButton("連接 iPhone", icon: "cable.connector", prominent: !model.needsSetup, action: model.connect)
            case .connecting:
                deviceButton("取消連線", icon: "xmark", action: model.disconnect)
            case .ready, .syncing, .restoring:
                if model.phase == .ready && !model.restoreUnconfirmed {
                    deviceButton("開始同步位置", icon: "location.fill", prominent: true, action: model.startSync)
                    HStack(spacing: 14) {
                        deviceTextButton("恢復定位", action: model.restore)
                        deviceTextButton("中斷連線", action: model.disconnect)
                    }
                } else {
                    deviceButton("恢復定位", icon: "location.slash", prominent: true, action: model.restore)
                        .disabled(model.phase == .restoring)
                    deviceTextButton("中斷連線", action: model.disconnect)
                }
            case .disconnecting:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func sectionTitle(_ label: String, _ icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.system(size: 14, weight: .semibold))
    }

    private func deviceButton(
        _ label: String, icon: String, prominent: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ControlButton(prominent: prominent))
    }

    private func deviceTextButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(secondary)
            .padding(.vertical, 4)
    }

    private var statusTitle: String {
        switch model.phase {
        case .preview, .failed: "Mac 預覽"
        case .connecting: "連線中"
        case .ready: "iPhone 已連線"
        case .syncing: "iPhone 同步中"
        case .restoring: "正在恢復定位"
        case .disconnecting: "正在中斷連線"
        }
    }

    private var statusColor: Color {
        if model.restoreUnconfirmed && (model.phase == .failed || model.phase == .preview) {
            return warning
        }
        return model.phase == .syncing || model.phase == .ready ? accent : secondary
    }

    private var deviceDescription: String {
        if let error = model.connectionError { return error }
        switch model.phase {
        case .preview, .failed:
            return model.needsSetup ? "首次使用 USB 同步前，請先安裝連線元件。" : "用 USB 接上已解鎖的 iPhone。"
        case .connecting:
            return "正在開啟 iPhone 開發者服務。"
        case .ready, .syncing, .restoring:
            return model.deviceLabel
        case .disconnecting:
            return "正在結束 iPhone 定位模擬。"
        }
    }
}

private struct StepControls: View {
    @ObservedObject var model: SimulatorModel
    @ObservedObject var broadcaster: StepBroadcaster

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("模擬步數", systemImage: "figure.walk")
                .font(.system(size: 14, weight: .semibold))
            Toggle("累計步數", isOn: Binding(get: { model.simulatingSteps }, set: model.setStepSimulation))
                .toggleStyle(.switch)
            HStack {
                Text("本次開啟")
                Spacer()
                Text("\(model.simulatedStepCount) 步")
                    .monospacedDigit()
                    .accessibilityIdentifier("simulated-step-count")
            }
            if model.simulatingSteps {
                Slider(value: Binding(get: { model.stride }, set: model.setStride), in: 0.3...1.5, step: 0.05) {
                    Text("步幅")
                }
                Text(String(format: "步幅 %.0f 公分 · 時速 8 公里以下累計", model.stride * 100))
                    .font(.caption)
                    .foregroundStyle(secondary)
            }
            Toggle("藍牙同步至 iPhone", isOn: Binding(get: { broadcaster.enabled }, set: broadcaster.setEnabled))
                .toggleStyle(.switch)
            if let pairing = broadcaster.pairing {
                DisclosureGroup("顯示 iPhone 配對碼") {
                    StepPairingCode(pairing: pairing).equatable()
                }
            }
            Button(action: broadcaster.enqueueTestSteps) {
                Label("傳送 \(StepBroadcaster.testStepCount.formatted()) 測試步", systemImage: "paperplane")
            }
            .buttonStyle(ControlButton())
            .accessibilityIdentifier("send-test-steps")
            if let testStepStatus = broadcaster.testStepStatus {
                switch testStepStatus {
                case .queued:
                    Text("測試步數等待 iPhone 確認")
                        .font(.caption)
                        .foregroundStyle(secondary)
                case .acknowledged:
                    Label("iPhone 已確認寫入測試步數", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(accent)
                }
            }
            if broadcaster.pendingSteps > 0 {
                Text("待同步 \(broadcaster.pendingSteps) 步")
                    .font(.caption)
                    .foregroundStyle(secondary)
            }
            if let error = broadcaster.storageError {
                Text(error).font(.caption).foregroundStyle(warning)
            } else if broadcaster.status != "藍牙同步已關閉" {
                Text(broadcaster.status).font(.caption).foregroundStyle(secondary)
            }
        }
    }
}

private struct StepPairingCode: View, Equatable {
    let pairing: StepPairing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在 iPhone 的「GPS 搖桿步數」按「掃描 Mac 配對碼」。")
                .font(.caption)
            if let qrImage {
                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(.white)
                    .accessibilityLabel("iPhone 步數配對 QR 碼")
            }
            Button("複製配對碼") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pairing.code, forType: .string)
            }
            .buttonStyle(ControlButton())
        }
        .padding(.vertical, 8)
    }

    private var qrImage: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(pairing.qrValue.utf8)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

private struct Joystick: View {
    let input: StickInput
    let onChange: (StickInput) -> Void

    var body: some View {
        GeometryReader { geometry in
            let center = geometry.size.width / 2
            let travel = center * 0.58

            ZStack {
                Circle().fill(canvasColor)
                Circle().strokeBorder(line, lineWidth: 1)
                Circle().strokeBorder(line, lineWidth: 1).padding(18)
                Circle().strokeBorder(line.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .padding(35)
                Rectangle().fill(line).frame(width: 1, height: 70)
                Rectangle().fill(line).frame(width: 70, height: 1)
                compassLetter("N", x: 0, y: -center + 13)
                compassLetter("E", x: center - 13, y: 0)
                compassLetter("S", x: 0, y: center - 13)
                compassLetter("W", x: -center + 13, y: 0)
                Circle()
                    .fill(input.isDeflected ? accent : surface)
                    .overlay(Circle().strokeBorder(input.isDeflected ? foreground.opacity(0.5) : accent, lineWidth: 1.5))
                    .overlay {
                        Image(systemName: "circle.grid.2x2.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(input.isDeflected ? canvasColor : accent)
                    }
                    .frame(width: 43, height: 43)
                    .shadow(color: .black.opacity(0.32), radius: 6, y: 3)
                    .offset(x: input.east * travel, y: -input.north * travel)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        onChange(StickInput(
                            east: (value.location.x - center) / travel,
                            north: (center - value.location.y) / travel
                        ))
                    }
                    .onEnded { _ in onChange(.neutral) }
            )
        }
        .accessibilityLabel("方向搖桿")
        .accessibilityHint("也可用鍵盤方向鍵移動")
        .accessibilityIdentifier("joystick")
    }

    private func compassLetter(_ letter: String, x: CGFloat, y: CGFloat) -> some View {
        Text(letter)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(letter == "N" ? accent : secondary)
            .offset(x: x, y: y)
            .accessibilityHidden(true)
    }
}

private struct ControlButton: ButtonStyle {
    var prominent = false
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? canvasColor : (selected ? accent : foreground))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(prominent ? accent : canvasColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? accent : line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

private struct FollowToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(ControlButton(selected: configuration.isOn))
        .accessibilityValue(configuration.isOn ? "開啟" : "關閉")
    }
}
