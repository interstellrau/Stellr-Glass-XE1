// MediaTab.swift - screencast mirror, photo sync toggle, transfer progress, recent items.

import Foundation
import SwiftUI
import UIKit

struct MediaTab: View {
    var body: some View {
        NavigationStack {
            Form {
                ScreencastSection()
                PhotoSyncSection()
                RecentMediaSection()
            }
            .navigationTitle("Media")
        }
    }
}

struct ScreencastSection: View {
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        Section {
            Toggle("Mirror Glass screen", isOn: $link.screencastOn)
            if link.screencastOn {
                if let frame = link.screencastFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity)
                } else {
                    Text(waitingText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Screen")
        } footer: {
            Text(footerText)
        }
    }

    private var waitingText: String {
        if !link.connected { return "Glass isn't connected." }
        return "Waiting for frames. StellrGlass has to be the app in front on Glass."
    }

    private var footerText: String {
        if link.screencastOn, let t = link.screencastFrameTime {
            return "Last frame " + GBFormat.clock(t) + ". Shows StellrGlass's own screen only (2 frames a second)."
        }
        return "Shows StellrGlass's own screen on Glass, about 2 frames a second. Other Glass apps can't be mirrored without root."
    }
}

struct PhotoSyncSection: View {
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        Section {
            Toggle("Save to iPhone Photos", isOn: $link.syncEnabled)
            if let t = link.transfer {
                TransferRow(transfer: t)
            }
        } header: {
            Text("Photos and videos")
        } footer: {
            Text("New photos and videos taken on Glass upload while it's connected and land in your Photos library.")
        }
    }
}

struct TransferRow: View {
    let transfer: TransferProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transfer.name)
                .font(.subheadline)
                .lineLimit(1)
            ProgressView(value: transfer.fraction)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        if transfer.saving { return "Saving to Photos…" }
        let progress: String = GBFormat.bytes(transfer.received) + " of " + GBFormat.bytes(transfer.size)
        if transfer.duplicate { return progress + " (already saved, not saving again)" }
        return progress
    }
}

struct RecentMediaSection: View {
    @ObservedObject private var link = GlassLink.shared

    var body: some View {
        Section {
            if link.recentMedia.isEmpty {
                Text("Nothing received yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(link.recentMedia) { item in
                    MediaRow(item: item)
                }
            }
        } header: {
            Text("Recent")
        }
    }
}

struct MediaRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            MediaThumbnail(item: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
            }
        }
    }

    private var detail: String {
        var parts: [String] = [GBFormat.bytes(item.size)]
        if let taken = item.taken {
            parts.append("taken " + GBFormat.dateTime(taken))
        }
        if item.ok {
            parts.append("saved")
        } else {
            let reason: String = item.error ?? "failed"
            parts.append("failed: " + reason)
        }
        return parts.joined(separator: " · ")
    }

    private var detailColor: Color {
        return item.ok ? Color.secondary : Color.red
    }
}

struct MediaThumbnail: View {
    let item: MediaItem

    var body: some View {
        Group {
            if let image = item.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var symbol: String {
        return item.isVideo ? "video" : "photo"
    }
}
