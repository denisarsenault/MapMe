import SwiftUI
import CoreData

struct HistoryListView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)],
        animation: .default
    ) private var archives: FetchedResults<DayArchive>

    var body: some View {
        NavigationStack {
            List {
                if archives.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Records older than today are archived automatically every 24 hours.")
                    )
                } else {
                    ForEach(archives, id: \.objectID) { archive in
                        NavigationLink(value: archive.objectID) {
                            row(for: archive)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: NSManagedObjectID.self) { id in
                DayDetailView(archiveID: id)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func row(for archive: DayArchive) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(archive.date ?? .distantPast, style: .date)
                .font(.headline)
            HStack(spacing: 12) {
                Label("\(archive.recordCount) points", systemImage: "mappin.and.ellipse")
                Label(formatDistance(archive.distanceMeters), systemImage: "ruler")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatDistance(_ meters: Double) -> String {
        let km = meters / 1000
        return String(format: km >= 1 ? "%.1f km" : "%.0f m", km >= 1 ? km : meters)
    }
}
