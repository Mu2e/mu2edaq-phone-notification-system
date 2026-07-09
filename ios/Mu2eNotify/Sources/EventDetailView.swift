import SwiftUI

struct EventDetailView: View {
    let event: NotifyEvent

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: event.sev.symbol)
                        .foregroundColor(event.sev.color)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text(event.title)
                            .font(.headline)
                        HStack(spacing: 6) {
                            Text(event.sev.rawValue.uppercased())
                                .font(.caption.bold())
                                .foregroundColor(event.sev.color)
                            if !event.category.isEmpty {
                                Text(event.category)
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                if !event.message.isEmpty {
                    Text(event.message)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            Section("Origin") {
                LabeledContent("Source", value: event.source)
                LabeledContent("Host", value: event.host)
                if !event.category.isEmpty {
                    LabeledContent("Category", value: event.category)
                }
                LabeledContent("Event time", value: event.timestamp)
                LabeledContent("Received", value: event.receivedAt)
            }
            if !event.meta.isEmpty {
                Section("Metadata") {
                    ForEach(event.meta.sorted(by: { $0.key < $1.key }),
                            id: \.key) { key, value in
                        LabeledContent(key, value: value)
                    }
                }
            }
        }
        .navigationTitle("Event #\(event.id)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
