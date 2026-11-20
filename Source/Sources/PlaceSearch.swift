import Combine
import MapKit

struct SearchPlace: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    let point: GeoPoint
}

@MainActor
final class PlaceSearch: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published var isOpen = false
    @Published var query = ""
    @Published var preview: SearchPlace?
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    @Published private(set) var places: [SearchPlace] = []
    @Published private(set) var message: String?
    @Published private(set) var searching = false
    private var completer: MKLocalSearchCompleter?
    private var search: MKLocalSearch?
    private var suggestionTask: Task<Void, Never>?
    var mapRegion: MKCoordinateRegion?

    func update(query: String, region: MKCoordinateRegion) {
        reset()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        suggestionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            let completer = MKLocalSearchCompleter()
            completer.delegate = self
            completer.region = region
            completer.resultTypes = [.address, .pointOfInterest]
            self.completer = completer
            completer.queryFragment = query
        }
    }

    func submit(query: String, region: MKCoordinateRegion) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        resolve(request, region: region)
    }

    func submit(_ completion: MKLocalSearchCompletion, region: MKCoordinateRegion) {
        resolve(MKLocalSearch.Request(completion: completion), region: region, previewSingleResult: true)
    }

    func reset() {
        suggestionTask?.cancel()
        suggestionTask = nil
        completer?.cancel()
        completer = nil
        search?.cancel()
        search = nil
        suggestions = []
        places = []
        message = nil
        searching = false
    }

    private func resolve(_ request: MKLocalSearch.Request, region: MKCoordinateRegion, previewSingleResult: Bool = false) {
        reset()
        request.region = region
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        self.search = search
        searching = true
        Task { [weak self] in
            let result: Result<MKLocalSearch.Response, Error>
            do {
                result = .success(try await search.start())
            } catch {
                result = .failure(error)
            }
            guard let self, self.search === search else { return }
            self.search = nil
            self.searching = false
            switch result {
            case .success(let response):
                self.places = response.mapItems.compactMap { item in
                    let point: GeoPoint
                    let address: String
                    // Swift 6.2（Xcode 26）以上才有 macOS 26 的新 API；舊版工具（例如 Intel Mac 上的 macOS 14/15）走舊寫法。
                    #if compiler(>=6.2)
                    if #available(macOS 26, *) {
                        point = GeoPoint(item.location.coordinate)
                        address = item.address?.fullAddress ?? ""
                    } else {
                        point = GeoPoint(item.placemark.coordinate)
                        address = item.placemark.title ?? ""
                    }
                    #else
                    point = GeoPoint(item.placemark.coordinate)
                    address = item.placemark.title ?? ""
                    #endif
                    guard point.isValid else { return nil }
                    return SearchPlace(
                        name: item.name ?? (address.isEmpty ? "地圖位置" : address),
                        address: address,
                        point: point
                    )
                }
                if self.places.isEmpty {
                    self.message = "找不到符合的地點"
                } else if previewSingleResult && self.places.count == 1 {
                    self.preview = self.places.first
                }
            case .failure(let error):
                if (error as? MKError)?.code == .placemarkNotFound {
                    self.message = "找不到符合的地點"
                } else {
                    self.message = "搜尋失敗，請確認網路連線後再試一次"
                }
            }
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard completer === self.completer else { return }
        suggestions = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard completer === self.completer else { return }
        suggestions = []
        message = "目前無法取得建議，可按 Return 搜尋"
    }
}
