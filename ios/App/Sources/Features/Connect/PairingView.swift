// First-run pairing: scan the QR the relay prints (its URL carries #token=…)
// or paste the URL. The token goes to the Keychain and is never shown again.

import ConductorKit
import SwiftUI
import VisionKit

struct PairingView: View {
	@Environment(AppModel.self) private var model
	@State private var pasted = ""
	@State private var error: String?
	@State private var scanning = false
	@State private var connecting = false

	var body: some View {
		VStack(spacing: 24) {
			Spacer()
			Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
				.font(.system(size: 72))
				.foregroundStyle(Color.accent)
			Text("Conductor Remote")
				.font(.largeTitle.weight(.bold))
			Text("Control your agents from anywhere.")
				.font(.headline)
				.foregroundStyle(.secondary)

			Spacer()

			if DataScannerViewController.isSupported {
				Button {
					scanning = true
				} label: {
					Label("Scan to Connect", systemImage: "qrcode.viewfinder")
						.font(.headline)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 6)
				}
				.buttonStyle(.borderedProminent)
			}

			VStack(spacing: 8) {
				TextField("Paste the relay link (https://…#token=…)", text: $pasted)
					.textFieldStyle(.roundedBorder)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.URL)
					.onSubmit { connect(pasted) }
				if let error {
					Text(error)
						.font(.footnote)
						.foregroundStyle(Color.diffDelete)
				}
				Button("Connect") { connect(pasted) }
					.disabled(pasted.isEmpty || connecting)
			}
			.padding(.horizontal)

			Text("On your Mac, `yarn service status` prints the link and QR.")
				.font(.footnote)
				.foregroundStyle(.tertiary)
			Spacer()
		}
		.padding()
		.background(Color.appBackground)
		.sheet(isPresented: $scanning) {
			QRScannerSheet { payload in
				scanning = false
				connect(payload)
			}
		}
	}

	private func connect(_ input: String) {
		guard let credentials = PairingParser.parse(input) else {
			error = "That doesn't look like a relay link — it needs the full URL with token=…"
			return
		}
		error = nil
		connecting = true
		Task {
			await model.connect(credentials)
			connecting = false
		}
	}
}

/// VisionKit's live scanner — replaces the PWA's ~150 lines of jsQR/canvas.
private struct QRScannerSheet: UIViewControllerRepresentable {
	let onScan: (String) -> Void

	func makeUIViewController(context: Context) -> DataScannerViewController {
		let scanner = DataScannerViewController(
			recognizedDataTypes: [.barcode(symbologies: [.qr])],
			qualityLevel: .fast,
			isHighlightingEnabled: true)
		scanner.delegate = context.coordinator
		try? scanner.startScanning()
		return scanner
	}

	func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

	func makeCoordinator() -> Coordinator {
		Coordinator(onScan: onScan)
	}

	final class Coordinator: NSObject, DataScannerViewControllerDelegate {
		let onScan: (String) -> Void

		init(onScan: @escaping (String) -> Void) {
			self.onScan = onScan
		}

		func dataScanner(
			_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]
		) {
			for case .barcode(let barcode) in added {
				if let payload = barcode.payloadStringValue {
					scanner.stopScanning()
					onScan(payload)
					return
				}
			}
		}
	}
}
