import SwiftUI

struct ContentView: View {
    @StateObject private var client = TrinusClient()
    @State private var ip = "192.168.1.131"
    @State private var running = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if running {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        eye(side: .left, size: CGSize(
                            width: geometry.size.width / 2,
                            height: geometry.size.height
                        ))

                        eye(side: .right, size: CGSize(
                            width: geometry.size.width / 2,
                            height: geometry.size.height
                        ))
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                }
                .ignoresSafeArea(.all)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            client.stop()
                            running = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Circle())
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .ignoresSafeArea(.all)
            } else {
                VStack(spacing: 18) {
                    Text("iPhoneVR")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)

                    Text("PC ekranını iPhone'da VR olarak kullan")
                        .foregroundStyle(.gray)

                    TextField("PC IP adresi", text: $ip)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .frame(maxWidth: 320)

                    Button("BAĞLAN") {
                        client.start(ip: ip)
                        running = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea(.all)
        .onDisappear {
            client.stop()
        }
    }

    private enum EyeSide {
        case left
        case right
    }

    @ViewBuilder
    private func eye(side: EyeSide, size: CGSize) -> some View {
        if let image = client.image,
           let cg = image.cgImage {
            let width = cg.width
            let height = cg.height
            let half = width / 2

            // IMPORTANT: keep all geometry calculations outside the ViewBuilder.
            // SwiftUI's ViewBuilder cannot contain assignments such as
            // `rect = ...` inside its body.
            let cropX = side == .left ? 0 : half
            let cropWidth = side == .left ? half : width - half
            let rect = CGRect(
                x: cropX,
                y: 0,
                width: cropWidth,
                height: height
            )

            if let cropped = cg.cropping(to: rect) {
                Image(uiImage: UIImage(
                    cgImage: cropped,
                    scale: image.scale,
                    orientation: image.imageOrientation
                ))
                .resizable()
                .frame(width: size.width, height: size.height)
                .clipped()
            } else {
                Color.black
                    .frame(width: size.width, height: size.height)
            }
        } else {
            Color.black
                .frame(width: size.width, height: size.height)
        }
    }
}
