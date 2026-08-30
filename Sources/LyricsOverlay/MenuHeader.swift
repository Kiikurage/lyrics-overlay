import AppKit
import SwiftUI

/// メニューバーのメニュー最上部に出す、いま流れている曲の情報。
/// レイアウトはオーバーレイの左寄せと同じだが、幅が限られるので
/// 曲名とアーティストは 2 行に分け、入らないぶんは省略する。
struct MenuHeader: View {
    @ObservedObject var model: OverlayModel

    static let width: Double = 260
    static let height: Double = 76

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title.isEmpty ? "再生していません" : model.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if !model.artist.isEmpty {
                    Text(model.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !model.timeText.isEmpty {
                    Text(model.timeText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = model.artwork {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
        }
    }
}
