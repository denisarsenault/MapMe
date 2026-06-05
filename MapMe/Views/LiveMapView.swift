#if os(iOS) || os(macOS)
import SwiftUI
import MapKit
import CoreData

struct LiveMapView: View {
    #if os(iOS)
    @EnvironmentObject private var location: LocationService
    #else
    @StateObject private var location = LocationService()
    #endif

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "timestamp", ascending: false)],
        predicate: NSPredicate(format: "timestamp >= %@", Calendar.current.startOfDay(for: Date()) as NSDate),
        animation: .default
    ) private var todayRecords: FetchedResults<LocationRecord>

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            if todayRecords.count > 1 {
                MapPolyline(coordinates: todayRecords.reversed().map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(.tint, lineWidth: 4)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .top) { statusBar }
        .task {
            location.requestAuthorization()
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(location.isTracking ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(location.isTracking ? "Tracking" : "Idle")
                .font(.footnote.weight(.medium))
            Spacer()
            if let last = location.lastLocation {
                Text(last.timestamp, style: .time)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .padding()
    }
}
#endif
