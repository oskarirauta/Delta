//
//  GBACoreSettingsView.swift
//  Delta
//
//  Created by Caroline Moore on 8/18/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import SwiftUI
import DeltaCore
import GBADeltaCore
import MGBADeltaCore

struct GBACoreSettingsView: CoreSettingsView
{
    var system: System { .gba }
    @State private var selectedCore = (Settings.preferredCore(for: .gba) ?? MGBA.core).identifier

    var additionalSections: some View {
        Section {
            Picker("Emulation Core", selection: $selectedCore) {
                Text("VBA-M").tag(GBA.core.identifier)
                Text("mGBA").tag(MGBA.core.identifier)
            }
            .onChange(of: selectedCore) { identifier in
                Settings.setPreferredCore(identifier == MGBA.core.identifier ? MGBA.core : GBA.core, for: .gba)
            }
        } footer: {
            Text("Applies to the next game launch. Save states and battery saves are separate for each core. On first use, mGBA copies the existing VBA-M battery save. Later progress stays with the selected core.")
        }
    }
    @Environment(\.openURL) var openURL
}

#Preview {
    NavigationView {
        GBACoreSettingsView()
    }
}
