import BenchKit
import PocketKit
import SwiftUI

@main
struct PocketApp: App {
    @StateObject private var model = PocketModel()
    /// The benchd Pocket follows, `tcp://<host>:<port>`: the one thing kept across launches.
    @AppStorage("benchURL") private var benchURL = ""

    var body: some Scene {
        WindowGroup {
            RootView(benchURL: $benchURL)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// home, agents and pages under one bar; a session's talk screen pushed over them, the start
/// sheet from home's `+`.
struct RootView: View {
    enum Tab: String, CaseIterable { case home, agents, pages }

    @EnvironmentObject private var model: PocketModel
    @Binding var benchURL: String
    @State private var tab = Tab.home
    @State private var talking: String?
    @State private var connecting = false
    @State private var starting = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                switch tab {
                case .home: HomeView { talking = $0 }
                case .agents: AgentsView { talking = $0 }
                case .pages: PagesView()
                }
                bar
            }
            .background(Palette.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $talking) { TalkView(target: $0) }
        }
        .sheet(isPresented: $connecting) { ConnectView(url: $benchURL) }
        .sheet(isPresented: $starting) { StartView() }
        .onAppear {
            model.connect(benchURL)
            connecting = benchURL.isEmpty
        }
        .onChange(of: benchURL) { model.connect(benchURL) }
        .task { await model.watchSessions() }
    }

    private var header: some View {
        HStack {
            Text(tab.rawValue).font(Mono.title).foregroundStyle(Palette.text)
            if tab == .home {
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
