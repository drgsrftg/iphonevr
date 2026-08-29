import SwiftUI

struct ContentView: View {
    @StateObject private var client = TrinusClient()
    @State private var ip = "192.168.1.131"
    @State private var running = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if running {
                HStack(spacing: 0) {
                    eye
                    eye
                }
                .ignoresSafeArea()
                VStack {
                    HStack {
                        Text(client.status)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                        Button("×") {
                            client.stop()
                            running = false
                        }
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding()
            } else {
                VStack(spacing: 18) {
                    Text("TrinusVR")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text("iPhone Trinus client")
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
        .onDisappear { client.stop() }
    }

    private var eye: some View {
        Group {
            if let image = client.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
