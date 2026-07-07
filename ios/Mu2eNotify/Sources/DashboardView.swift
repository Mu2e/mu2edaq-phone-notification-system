import SwiftUI

/// Dashboard: severity summary plus the scrolling list of received
/// error / warning events.
struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @State private var filter: Severity?

    private var filtered: [NotifyEvent] {
        guard let filter = filter else { return state.events }
        return state.events.filter { $0.sev == filter }
    }

    private func count(_ sev: Severity) -> Int {
        state.events.filter { $0.sev == sev }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Severity.allCases.reversed(), id: \.self) { sev in
                            Button {
                                filter = (filter == sev) ? nil : sev
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: sev.symbol)
                                    Text("\(count(sev))")
                                        .fontWeight(.semibold)
                                }
                                .font(.footnote)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(filter == sev
                                    ? sev.color.opacity(0.35)
                                    : Color(.secondarySystemBackground))
                                .foregroundColor(sev.color)
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                List {
                    ForEach(filtered) { event in
                        NavigationLink(value: event.id) {
                            EventRow(event: event)
                        }
                    }
                    if filtered.isEmpty {
                        Text(state.events.isEmpty
                             ? "No events received yet."
                             : "No events at this severity.")
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.plain)
                .refreshable { await state.refreshEvents() }
            }
            .navigationTitle("Mu2e DAQ Notify")
            .navigationDestination(for: Int.self) { id in
                if let event = state.events.first(where: { $0.id == id }) {
                    EventDetailView(event: event)
                }
            }
            .task { await state.refreshEvents() }
            .overlay(alignment: .bottom) {
                if let err = state.lastError {
                    Text(err)
                        .font(.caption)
                        .padding(8)
                        .background(.red.opacity(0.85))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
        }
    }
}

struct EventRow: View {
    let event: NotifyEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.sev.symbol)
                .foregroundColor(event.sev.color)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(event.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Text("\(event.source) @ \(event.host) · \(event.receivedAt)")
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
            }
        }
        .padding(.vertical, 2)
    }
}
