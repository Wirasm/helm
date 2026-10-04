import BenchKit
import PocketKit
import SwiftUI

@main
struct PocketApp: App {
    @StateObject private var model = PocketModel()
    @StateObject private var memory = ChatMemory()
    /// The benchd Pocket follows, `tcp://<host>:<port>`: the one thing kept across launches.
    @AppStorage("benchURL") private var benchURL = ""

    var body: some Scene {
        WindowGroup {
            RootView(benchURL: $benchURL)
                .environmentObject(model)
                .environmentObject(memory)
                .preferredColorScheme(.dark)
                // Links in a reply and the text cursor: the palette's, not the system blue.
                .tint(Palette.finished)
        }
    }
}

/// chats and pages under one bar; a chat pushed over them (back swipe returns to the list
/// where it was), the start sheet from the chats' `+`.
struct RootView: View {
    enum Tab: String, CaseIterable { case chats, pages }

    @EnvironmentObject private var model: PocketModel
    @Environment(\.scenePhase) private var phase
    @Binding var benchURL: String
    @State private var tab = Tab.chats
    @State private var talking: String?
    @State private var connecting = false
    @State private var starting = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                switch tab {
                case .chats: ChatsView { talking = $0 }
                case .pages: PagesView()
                }
                bar
            }
            .background(Palette.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $talking) { ChatView(chat: $0) }
        }
        .sheet(isPresented: $connecting) { ConnectView(url: $benchURL) }
        .sheet(isPresented: $starting) { StartView() }
        .onAppear {
            model.connect(benchURL)
            connecting = benchURL.isEmpty
        }
        .onChange(of: benchURL) { model.connect(benchURL) }
        // Back from the background or a sleep: the old socket may be dead without knowing it.
        .onChange(of: phase) { if phase == .active { model.resume() } }
        .task { await model.watchSessions() }
        .task { await model.watchPreviews() }
    }

    private var header: some View {
        HStack {
            Text(tab.rawValue).font(Mono.title).foregroundStyle(Palette.text)
            if tab == .chats {
                Button("+") { starting = true }.font(Mono.title).foregroundStyle(Palette.finished)
            }
            Spacer()
            Button {
                connecting = true
            } label: {
                Text(model.state.word).font(Mono.small).foregroundStyle(model.state.color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var bar: some View {
        HStack {
            ForEach(Tab.allCases, id: \.self) { item in
                Button(item.rawValue) { tab = item }
                    .font(Mono.body)
                    .foregroundStyle(item == tab ? Palette.text : Palette.dim)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }
}

extension BenchClient.State {
    /// A word or two for the header: what the follower is doing.
    var word: String {
        switch self {
        case .connecting: "○ connecting"
        case .connected: "● connected"
        case .disconnected: "○ offline"
        }
    }

    var color: Color {
        if case .connected = self { Palette.finished } else { Palette.dim }
    }
}
