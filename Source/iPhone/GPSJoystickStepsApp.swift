import AVFoundation
import SwiftUI
import VisionKit

@main
struct GPSJoystickStepsApp: App {
    var body: some Scene {
        WindowGroup {
            StepSyncView()
        }
    }
}

private struct StepSyncView: View {
    @StateObject private var receiver = StepReceiver()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingScanner = false
    @State private var scannerError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("模擬步數") {
                    LabeledContent("本次開啟已寫入", value: "\(receiver.savedSteps) 步")
                    Text(receiver.status)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("step-sync-status")
                    if receiver.active {
                        Button("停止同步", action: receiver.stop)
                    } else if receiver.hasPairing {
                        Button("開始同步") {
                            Task {
                                await receiver.start()
                            }
                        }
                        .disabled(receiver.authorizing || receiver.saving)
                    }
                }
                if !receiver.active && !receiver.authorizing && !receiver.saving {
                    Section {
                        Button(receiver.hasPairing ? "重新掃描 Mac 配對碼" : "掃描 Mac 配對碼") {
                            Task { await scanPairingCode() }
                        }
                        PasteButton(payloadType: String.self) { strings in
                            if let code = strings.first {
                                receiver.pair(code: code)
                            }
                        }
                        .accessibilityLabel("貼上 Mac 配對碼")
                        if let scannerError {
                            Text(scannerError).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Mac 配對")
                    } footer: {
                        Text("在 Mac 開啟「藍牙同步至 iPhone」，再展開「顯示 iPhone 配對碼」。")
                    }
                }
                Section {
                    Text("連線後可切換到其他 App。若強制關閉此 App，請重新開啟並開始同步。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("GPS 搖桿步數")
            .onChange(of: scenePhase, initial: true) { _, phase in
                receiver.setForeground(phase == .active)
            }
            .sheet(isPresented: $showingScanner) {
                NavigationStack {
                    PairingScanner { code in
                        showingScanner = false
                        receiver.pair(code: code)
                    } onFailure: {
                        showingScanner = false
                        scannerError = "無法開啟相機。也可以從 Mac 複製並貼上配對碼。"
                    }
                    .navigationTitle("掃描 Mac 配對碼")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showingScanner = false }
                        }
                    }
                }
            }
        }
    }

    private func scanPairingCode() async {
        scannerError = nil
        guard DataScannerViewController.isSupported,
              await AVCaptureDevice.requestAccess(for: .video),
              DataScannerViewController.isAvailable else {
            scannerError = "請在設定允許相機，或從 Mac 複製並貼上配對碼。"
            return
        }
        showingScanner = true
    }
}

private struct PairingScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> ScannerContainer {
        let container = ScannerContainer(onFailure: onFailure)
        container.scanner.delegate = context.coordinator
        return container
    }

    func updateUIViewController(_ uiViewController: ScannerContainer, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var scanned = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !scanned else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let code = barcode.payloadStringValue,
                      code.hasPrefix("GPSJoystickSteps:"), StepPairing(code: code) != nil else { continue }
                scanned = true
                scanner.stopScanning()
                onScan(code)
                return
            }
        }
    }

    final class ScannerContainer: UIViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])])
        let onFailure: () -> Void

        init(onFailure: @escaping () -> Void) {
            self.onFailure = onFailure
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            do {
                try scanner.startScanning()
            } catch {
                onFailure()
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            scanner.stopScanning()
        }
    }
}
