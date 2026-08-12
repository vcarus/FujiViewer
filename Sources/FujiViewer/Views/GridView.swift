import SwiftUI

/// Contact-sheet grid backed by the 256px thumbnail level.
struct GridView: View {
    let library: PhotoLibrary
    let ui: ViewerState

    private let spacing: CGFloat = 10
    private let targetCellWidth: CGFloat = 190

    var body: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - spacing) / (targetCellWidth + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                              spacing: spacing) {
                        ForEach(Array(library.photos.enumerated()), id: \.element.id) { index, photo in
                            GridCell(photo: photo,
                                     isSelected: index == library.currentIndex,
                                     isMarked: library.isMarked(photo))
                                .id(photo.id)
                                .onTapGesture(count: 2) {
                                    library.select(index: index)
                                    ui.mode = .loupe
                                }
                                .onTapGesture {
                                    library.select(index: index)
                                }
                        }
                    }
                    .padding(spacing)
                }
                .onAppear {
                    ui.gridColumns = columns
                    let target = library.currentPhoto?.id
                    DispatchQueue.main.async {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                .onChange(of: columns) { _, newValue in
                    ui.gridColumns = newValue
                }
                .onChange(of: library.currentIndex) { _, _ in
                    guard let target = library.currentPhoto?.id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .background(Color.black)
    }
}

private struct GridCell: View {
    let photo: Photo
    let isSelected: Bool
    let isMarked: Bool

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(white: 0.09))

            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(5)
            }

            VStack {
                Spacer()
                HStack {
                    Text(photo.name)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isMarked {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
        .contentShape(Rectangle())
        .onAppear(perform: loadThumbnail)
    }

    private func loadThumbnail() {
        guard image == nil else { return }
        ImagePipeline.shared.load(photo.url, level: .thumb, generation: nil) { decoded in
            image = decoded?.cgImage
        }
    }
}
