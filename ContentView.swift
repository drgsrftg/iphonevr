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
                        eye
                        eye
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                .background(.black.opacity(0.55))
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
        .onDisappear { client.stop() }
    }

    private var eye: some View {
        GeometryReader { geometry in
            if let image = client.image {
                Image(uiImage: image)
                    .resizable()
                    // Intentionally stretch to the complete eye viewport.
                    // No aspect-fit bars and no aspect-fill cropping.
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
