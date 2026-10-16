import SwiftUI

@main
struct RyouToolboxApp: App {
    var body: some Scene {
        WindowGroup("Ryou Toolbox") {
            ContentView()
                .frame(minWidth: 900, minHeight: 460)
        }
    }
}

struct ContentView: View {
    @State private var selection: Tool? = ToolRegistry.all.first

    var body: some View {
        NavigationSplitView {
            List(ToolRegistry.all, selection: $selection) { tool in
                Label(tool.title, systemImage: tool.icon).tag(tool)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            if let tool = selection {
                tool.view().id(tool.id)
            } else {
                Text("选择一个工具").foregroundStyle(.secondary)
            }
        }
    }
}
