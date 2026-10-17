import AppKit
import SwiftUI

struct ShelfView: View {
    @ObservedObject var store: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 10) {
                    if store.items.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.items) { item in
                            Thumb(item: item, store: store)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 100)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18,
                                          style: .continuous))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.22), .white.opacity(0.0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
    }

    private var background: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(.white.opacity(0.35)).frame(width: 5, height: 5)
            Text("PEG")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text("⌃⌥X 截图　·　点图复制　·　双击打开　·　拖出去用　·　⌃⌥S 收起")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.38))
        }
    }

    private var emptyState: some View {
        Text("按 ⌃⌥X 截一张，它就挂在这儿")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.45))
            .frame(height: 96)
            .padding(.horizontal, 4)
    }
}

private struct Thumb: View {
    let item: ShotItem
    let store: Shelf
    @State private var hovering = false

    var body: some View {
        Image(nsImage: item.thumb)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: 96)
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.55 : 0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: hovering ? 12 : 5, y: hovering ? 6 : 2)
            .scaleEffect(hovering ? 1.05 : 1, anchor: .bottom)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
            .onTapGesture { Clip.copy(contentsOf: item.url) }
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
            .contextMenu {
                Button("复制") { Clip.copy(contentsOf: item.url) }
                Button("用「预览」打开") { NSWorkspace.shared.open(item.url) }
                Button("保存到桌面") { saveToDesktop() }
                Button("在访达中显示") { Storage.reveal(item.url) }
                Divider()
                Button("移入废纸篓") { store.remove(item) }
            }
            .help(item.url.lastPathComponent)
    }

    private func saveToDesktop() {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        let target = desktop.appendingPathComponent(item.url.lastPathComponent)
        try? FileManager.default.copyItem(at: item.url, to: target)
    }
}
